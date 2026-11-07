//
// Microphone capture via AVAudioEngine.
//
// Writes the mic input to mic.caf as PCM. The format is whatever the
// engine's input node natively delivers — usually 48 kHz mono float on
// the M-series MBP. WhisperKit can resample, so we don't fight the
// hardware here.
//
// TCC: AVCaptureDevice.requestAccess(for: .audio) triggers the system
// mic prompt. NSMicrophoneUsageDescription must be present in Info.plist
// or the OS refuses to even show the prompt.
//
// Route changes: AVAudioEngine STOPS itself whenever the audio hardware
// configuration changes under it — plugging in AirPods, the default
// output switching, the voice-processing aggregate device being torn
// down — and posts AVAudioEngineConfigurationChange. It never restarts on
// its own. Unhandled, that silently kills the mic track when headphones
// connect (default output changed → VPIO aggregate torn down → engine
// stopped) while the app keeps showing "recording"; see CLAUDE.md.
// So: on that notification, and from a watchdog that notices the engine
// not running / not delivering buffers, the tap is torn down and
// re-attached. The gap is padded with silence so the mic track stays
// time-aligned with the system track, and the AEC decision is re-made
// for the new route (headphones in → no bleed → AEC off). The stall
// threshold and the restart batch size come from RestartBackoff
// (CaptureSupport.swift), shared with the system-audio engines.
//
// Threading: AVAudioEngine taps run on the AVAudio thread. start()/stop()
// and the restart path run on the main actor. `file` is written from the
// tap while a tap is installed, and from the restart path only after the
// tap is removed — so writes never interleave.
//
// Host time: the tap records the host time (mach_absolute_time) at which
// each buffer's audio ends, and the restart pad covers host time from
// there to now, like the system engines' gap fill. Host time does not
// advance while the Mac sleeps, so a sleep is never padded, and the dead
// stretch the Mac was awake for (before the sleep and after the wake) is,
// which keeps the mic track aligned with the system track (whose PTS is
// host time too) when the engine dies across a sleep. The watchdog's
// lastBufferAt is derived from the same host ticks, so a sleep never looks
// like a stall. Any single pad is capped at 5 min (padPlan). The clocks
// are injectable (CaptureClock) so a test can simulate a sleep.
// A stall can also end without a restart: the engine starts delivering
// again on its own. The tap then sees a buffer whose start host time is
// past the end of the last one and writes zeros for the gap before the
// buffer (same padPlan, same bounds), from a zero buffer preallocated
// when the tap is built, so the render thread does not allocate for it.
//

import AppKit
import AVFoundation
import Foundation
import Synchronization
import os.log

private let micLog = Logger(subsystem: "com.jwiderberg.minnas", category: "MicCapture")

enum MicCaptureError: Error {
    case permissionDenied
    case engineStartFailed(underlying: Error)
    case fileCreateFailed(underlying: Error)
}

final class TapStats: @unchecked Sendable {
    var frameCount: UInt64 = 0
    var nonSilentFrames: UInt64 = 0
    var peakAmplitude: Float = 0
    var writeErrors: UInt64 = 0
    var firstWriteError: String?
    // Wall-clock of the last non-silent buffer (auto-stop), stored as the
    // bit pattern of an epoch Double so the tap-thread write and the
    // MainActor read are a single atomic 64-bit access — an Optional<Date>
    // is 16 bytes and would tear. 0 = no signal yet.
    let lastSignalBits = Atomic<UInt64>(0)
    // Host time (mach ticks) at which the last buffer of ANY kind (silent or
    // not) ends, or the instant a restart pad covered up to. Drives the
    // stall watchdog and the silence padding on restart. 0 = none yet.
    let lastHostEndTicks = Atomic<UInt64>(0)
    // The last buffer's NOMINAL end (start + duration, not clamped to now),
    // for continuity decisions: whether the next buffer starts after a gap.
    // lastHostEndTicks is clamped to now so the watchdog never sees a
    // buffer from the future; using the clamped value for continuity would
    // insert silence between contiguous buffers whose nominal end runs
    // ahead of the callback. 0 = none yet.
    let lastNominalEndTicks = Atomic<UInt64>(0)
    var restarts: Int = 0
    // Restart pads (padGapWithSilence, main actor only).
    var paddedSeconds: Double = 0
    // Resume pads written by the tap (see tapBlock), as Double bit patterns
    // so the tap thread and the main actor share them atomically: the total
    // for the stop line / capture_health, and the amount not yet logged,
    // which checkHealth drains into one notice. 0 = 0.0 s.
    let resumePaddedBits = Atomic<UInt64>(0)
    let resumePadPendingBits = Atomic<UInt64>(0)

    /// Tap thread: account for `seconds` of resume padding. Lock-free.
    func addResumePad(_ seconds: Double) {
        Self.add(seconds, to: resumePaddedBits)
        Self.add(seconds, to: resumePadPendingBits)
    }

    /// Main actor: resume padding written since the last call, in seconds.
    func takePendingResumePad() -> Double {
        Double(bitPattern: resumePadPendingBits.exchange(0, ordering: .relaxed))
    }

    var resumePaddedSeconds: Double { Double(bitPattern: resumePaddedBits.load(ordering: .relaxed)) }

    private static func add(_ seconds: Double, to bits: borrowing Atomic<UInt64>) {
        var current = bits.load(ordering: .relaxed)
        while true {
            let next = (Double(bitPattern: current) + seconds).bitPattern
            let (exchanged, original) = bits.compareExchange(expected: current, desired: next, ordering: .relaxed)
            if exchanged { return }
            current = original
        }
    }
}

final class MicCapture: @unchecked Sendable {
    private let outputURL: URL
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var running = false
    private let stats = TapStats()
    private var configObserver: NSObjectProtocol?
    private var restartTask: Task<Void, Never>?
    // attachedAt, silentRestarts (restarts that came up but never delivered
    // a buffer; backs the stall threshold off so a dead device doesn't spin
    // the restart loop) and stalledSince. Main actor only.
    private var backoff = RestartBackoff()
    // will-sleep/did-wake observers; they only log, for post-mortems.
    private var sleepObservers: [NSObjectProtocol] = []
    private let clock: any CaptureClock

    /// Upper bound on one silence pad. A real route-change restart is back
    /// in well under a second; anything past this is a clock jump or a
    /// stuck timestamp, and padding it could fill the disk.
    static let maxPadSeconds: Double = 300
    /// Gaps at or below this are not padded.
    static let minPadSeconds: Double = 0.05

    /// When the mic stopped delivering audio and a restart is in progress
    /// or has failed; nil while healthy. The menubar shows a warning off it.
    var stalledSince: Date? { backoff.stalledSince }

    init(outputURL: URL, clock: any CaptureClock = MachClock()) {
        self.outputURL = outputURL
        self.clock = clock
    }

    /// Live peak amplitude since the last call. Reset after read so the
    /// menubar level meter reflects the last window of audio rather than
    /// the all-time peak. Called from MainActor; written from the tap
    /// thread. Atomic float read on arm64 is safe enough for a UI meter.
    func snapshotPeak() -> Float {
        let p = stats.peakAmplitude
        stats.peakAmplitude = 0
        return p
    }

    /// True once the mic has delivered any non-silent audio (the tap counts
    /// frames above a small epsilon). Used by the pre-flight check.
    var hasSignal: Bool { stats.nonSilentFrames > 0 }

    /// Wall-clock of the most recent non-silent buffer (auto-stop).
    var lastSignalAt: Date? { Date(epochBits: stats.lastSignalBits.load(ordering: .relaxed)) }

    /// Wall-clock of the most recent buffer of any kind, derived from host
    /// ticks (now minus the host time since the buffer ended), so time the
    /// Mac spent asleep is not counted.
    var lastBufferAt: Date? {
        let ticks = stats.lastHostEndTicks.load(ordering: .relaxed)
        guard ticks != 0 else { return nil }
        return Self.wallTime(ofHostTicks: ticks, hostNow: clock.hostTicks(), wallNow: clock.wall(),
                             ticksPerSecond: clock.ticksPerSecond)
    }

    /// How many times the engine was re-attached after a route change or
    /// stall during this recording.
    var restartCount: Int { stats.restarts }
    var paddedSecondsTotal: Double { stats.paddedSeconds + stats.resumePaddedSeconds }
    var writeErrorCount: UInt64 { stats.writeErrors }
    /// Seconds of audio the tap actually delivered (excluding padding).
    var secondsCaptured: Double {
        guard let rate = file?.processingFormat.sampleRate, rate > 0 else { return 0 }
        return Double(stats.frameCount) / rate
    }

    @MainActor
    func start() async throws {
        let preAuth = AVCaptureDevice.authorizationStatus(for: .audio)
        micLog.info("start() preAuth=\(preAuth.rawValue, privacy: .public)")
        guard await Self.ensurePermission() else {
            micLog.error("permission denied")
            throw MicCaptureError.permissionDenied
        }
        micLog.info("permission ok")

        try attach(reason: "start")
        running = true

        // The engine stops itself on a hardware configuration change and
        // posts this; nothing restarts it but us.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleRestart(reason: "configuration change")
            }
        }

        // Log lines only, for post-mortems: host time does not advance in a
        // sleep, so neither the pad nor the watchdog needs to know about it.
        let ws = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                micLog.notice("system will sleep")
            },
            ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                micLog.notice("system did wake")
            },
        ]
    }

    /// Belt-and-braces for route changes the notification doesn't cover:
    /// called from the app's recording tick. If the engine isn't running,
    /// or has delivered nothing for a few seconds, re-attach.
    @MainActor
    func checkHealth() {
        logResumePad()
        guard running, restartTask == nil else { return }
        if !engine.isRunning {
            scheduleRestart(reason: "engine not running")
            return
        }
        // 3 s normally; doubles for each restart that never produced a
        // buffer, up to a minute, so a dead device is retried, not spun on.
        if let threshold = backoff.overdue(lastBufferAt: lastBufferAt, now: clock.wall()) {
            scheduleRestart(reason: "no buffers for \(Int(threshold)) s")
        }
    }

    /// Logs the resume padding the tap wrote since the last call, if any.
    @MainActor
    private func logResumePad() {
        let seconds = stats.takePendingResumePad()
        guard seconds > 0 else { return }
        micLog.notice("padded mic track with \(String(format: "%.1f", seconds), privacy: .public) s of silence after buffers resumed")
    }

    @MainActor
    private func scheduleRestart(reason: String) {
        guard running, restartTask == nil else { return }
        backoff.noteRestartScheduled(restartsSoFar: stats.restarts, lastBufferAt: lastBufferAt, now: clock.wall())
        micLog.error("mic stalled (\(reason, privacy: .public)); restarting")
        restartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.restartTask = nil }
            for attempt in 1...RestartBackoff.attemptsPerBatch {
                guard self.running else { return }
                do {
                    try self.reattach(reason: reason, attempt: attempt)
                    self.backoff.noteRecovered()
                    return
                } catch {
                    micLog.error("mic restart attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    try? await Task.sleep(for: RestartBackoff.retryDelay)
                }
            }
            // Not terminal, on purpose, unlike both system engines (which
            // clear `running` and fire onUnexpectedStop here): a mic comes
            // back when a device is plugged in, so `running` stays true and
            // the next checkHealth starts another batch once its threshold
            // (min(60, 3·2^silentRestarts) s since the last buffer or pad)
            // has passed. A failed attempt that follows a delivered buffer
            // pads the gap (when it is over 0.05 s and the pad can be
            // written) and that resets the stall clock, so after such a
            // batch the threshold is the 3 s floor and batches run roughly
            // 3 s apart, one attempt a second; if the mic never delivered
            // there is nothing to pad and the next batch starts on the next
            // tick.
            // A mic that stays dead is reported by AppDelegate's 10 s
            // stalled alert (stalledSince stays set until an attach
            // succeeds); a mic that delivers only digital zeros, by the
            // 2-minute zeros alert.
            micLog.error("mic restart gave up after 20 attempts; the watchdog will retry after the backoff")
        }
    }

    /// Tear the tap down, pad the file with silence for the time the engine
    /// was dead, and attach again on whatever the route is now.
    @MainActor
    private func reattach(reason: String, attempt: Int) throws {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        padGapWithSilence()
        try attach(reason: "\(reason), attempt \(attempt)")
        stats.restarts += 1
    }

    /// What padGapWithSilence writes for a host-time gap.
    enum PadPlan: Equatable, Sendable {
        /// No gap worth padding (or no usable timestamps).
        case none
        /// Pad the whole gap.
        case pad(seconds: Double)
        /// The gap is over the cap; pad only `seconds` of it.
        case capped(seconds: Double, gap: Double)
    }

    /// The gap from the end of the last buffer to `hostNow`, in host time,
    /// and how much of it to pad: nothing at or below `minimum`, at most
    /// `maxPadSeconds`. A zero `lastHostEnd` (no buffer yet), a `hostNow`
    /// that is not after it, or a non-finite result plans nothing.
    static func padPlan(lastHostEnd: UInt64, hostNow: UInt64, ticksPerSecond: Double,
                        maxPadSeconds: Double, minimum: Double) -> PadPlan {
        guard lastHostEnd != 0, hostNow > lastHostEnd,
              ticksPerSecond.isFinite, ticksPerSecond > 0 else { return .none }
        let gap = Double(hostNow - lastHostEnd) / ticksPerSecond
        guard gap.isFinite, gap > minimum else { return .none }
        if gap > maxPadSeconds { return .capped(seconds: maxPadSeconds, gap: gap) }
        return .pad(seconds: gap)
    }

    /// Seconds of silence the tap writes before a buffer that starts at
    /// host time `start`, when the last buffer (or restart pad) ended at
    /// `lastHostEnd`: padPlan over that gap (padded or capped amount; 0 for
    /// none). Only with a valid host time: without one the start is
    /// unknown, and using the delivery time would pad every buffer by its
    /// own duration. A start in the future is taken as `now`.
    nonisolated static func resumePadSeconds(lastHostEnd: UInt64, start: UInt64, hostTimeValid: Bool,
                                             now: UInt64, ticksPerSecond: Double) -> Double {
        guard hostTimeValid else { return 0 }
        switch padPlan(lastHostEnd: lastHostEnd, hostNow: min(start, now), ticksPerSecond: ticksPerSecond,
                       maxPadSeconds: maxPadSeconds, minimum: minPadSeconds) {
        case .none: return 0
        case .pad(let seconds): return seconds
        case .capped(let seconds, _): return seconds
        }
    }

    /// Appends `seconds` of silence at `rate` to `file`, in chunks of at
    /// most `zero.frameCapacity` frames from `zero` (a zero-filled buffer in
    /// the file's processing format). Allocates nothing. Returns the frames
    /// written and the first write error, which ends the pad.
    nonisolated static func writeSilence(into file: AVAudioFile, zero: AVAudioPCMBuffer, seconds: Double,
                                         rate: Double) -> (frames: Int, error: (any Error)?) {
        let capacity = Int(zero.frameCapacity)
        guard seconds.isFinite, seconds > 0, rate.isFinite, rate > 0, capacity > 0,
              seconds <= maxPadSeconds else { return (0, nil) }
        var remaining = Int(seconds * rate)
        var written = 0
        while remaining > 0 {
            let n = min(remaining, capacity)
            zero.frameLength = AVAudioFrameCount(n)
            do { try file.write(from: zero) } catch { return (written, error) }
            written += n
            remaining -= n
        }
        return (written, nil)
    }

    /// One second of zeros in `format`, for the tap's resume pad. Built on
    /// the main actor when the tap is; nil if it cannot be allocated (the
    /// tap then skips resume pads).
    static func makeZeroBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate)
        guard frames > 0, let zeros = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        zeros.frameLength = frames
        for buffer in UnsafeMutableAudioBufferListPointer(zeros.mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        return zeros
    }

    /// Host time at which a buffer's audio ends: its start (the AVAudioTime's
    /// host time when valid, else `now`) plus its duration, never later than
    /// `now` — audio that was delivered has already been captured, and a
    /// future timestamp would hold the watchdog off.
    /// start + duration, unclamped; `previous` when the host time is invalid
    /// or the sum overflows (then nothing is known about where this buffer
    /// ends, so continuity is judged from the last known end).
    nonisolated static func nominalEndTicks(start: UInt64, hostTimeValid: Bool, frames: AVAudioFrameCount,
                                            sampleRate: Double, ticksPerSecond: Double, previous: UInt64) -> UInt64 {
        guard hostTimeValid, sampleRate > 0 else { return previous }
        let duration = Double(frames) * ticksPerSecond / sampleRate
        guard duration.isFinite, duration >= 0, duration < Double(UInt64.max / 2) else { return previous }
        let (end, overflow) = start.addingReportingOverflow(UInt64(duration))
        return overflow ? previous : end
    }

    nonisolated static func bufferEndTicks(start: UInt64, hostTimeValid: Bool, frames: AVAudioFrameCount,
                                           sampleRate: Double, ticksPerSecond: Double, now: UInt64) -> UInt64 {
        let begin = hostTimeValid ? start : now
        let duration = Double(frames) * ticksPerSecond / sampleRate
        guard duration.isFinite, duration >= 0, duration < Double(UInt64.max / 2) else { return min(begin, now) }
        let (end, overflow) = begin.addingReportingOverflow(UInt64(duration))
        return overflow ? now : min(end, now)
    }

    /// The wall-clock instant of host time `ticks`: `wallNow` minus the host
    /// time since then (0 when `ticks` is not before `hostNow`).
    static func wallTime(ofHostTicks ticks: UInt64, hostNow: UInt64, wallNow: Date,
                         ticksPerSecond: Double) -> Date {
        guard hostNow > ticks, ticksPerSecond.isFinite, ticksPerSecond > 0 else { return wallNow }
        return wallNow.addingTimeInterval(-Double(hostNow - ticks) / ticksPerSecond)
    }

    /// Writes zeros covering the host-time gap since the last buffer ended,
    /// so a mic segment captured after a restart lands at the right offset
    /// relative to the system track (the transcript merges the two by
    /// timestamp). Host time does not advance in a sleep, so a sleep is not
    /// padded. Called only while no tap is installed.
    @MainActor
    private func padGapWithSilence() {
        guard let file else { return }
        let hostNow = clock.hostTicks()
        let gap: Double
        let nominal = stats.lastNominalEndTicks.load(ordering: .relaxed)
        let lastEnd = nominal != 0 ? nominal : stats.lastHostEndTicks.load(ordering: .relaxed)
        switch Self.padPlan(lastHostEnd: lastEnd, hostNow: hostNow,
                            ticksPerSecond: clock.ticksPerSecond, maxPadSeconds: Self.maxPadSeconds,
                            minimum: Self.minPadSeconds) {
        case .none:
            return
        case .pad(let seconds):
            gap = seconds
        case .capped(let seconds, let rawGap):
            gap = seconds
            micLog.error("mic gap of \(String(format: "%.1f", rawGap), privacy: .public) s exceeds the \(Int(Self.maxPadSeconds), privacy: .public) s pad cap (clock jump or unseen sleep?); padding only \(Int(gap), privacy: .public) s")
        }
        let format = file.processingFormat
        var remaining = Int(gap * format.sampleRate)
        let chunk = AVAudioFrameCount(format.sampleRate)   // 1 s
        guard let zeros = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
        zeros.frameLength = chunk
        // A fresh buffer is zero-filled; frameLength just exposes it.
        while remaining > 0 {
            zeros.frameLength = AVAudioFrameCount(min(remaining, Int(chunk)))
            do { try file.write(from: zeros) } catch {
                micLog.error("silence padding write failed: \(error.localizedDescription, privacy: .public)")
                break
            }
            remaining -= Int(zeros.frameLength)
        }
        stats.paddedSeconds += gap
        // The padding stands in for the dead stretch up to hostNow; the stall
        // clock restarts from there.
        stats.lastHostEndTicks.store(hostNow, ordering: .relaxed)
        stats.lastNominalEndTicks.store(hostNow, ordering: .relaxed)
        micLog.notice("padded mic track with \(String(format: "%.1f", gap), privacy: .public) s of silence across the restart")
    }

    /// Decides AEC for the current route, opens the file on first call,
    /// installs the tap (converting to the file's format when the new
    /// route's rate differs) and starts the engine. Engine must be stopped.
    @MainActor
    private func attach(reason: String) throws {
        let input = engine.inputNode
        micLog.notice("attach (\(reason, privacy: .public)): default input device: \(AudioRoute.defaultInputDeviceName() ?? "unknown", privacy: .public) risky=\(AudioRoute.defaultInputLooksRisky(), privacy: .public)")

        // Acoustic echo cancellation. Enabled per Config (default "auto":
        // only on built-in-speaker output with a non-Bluetooth mic, where it
        // both helps — cancels room bleed for clean Me/Them — and works —
        // VPIO over Bluetooth captures pure silence). Must be set before
        // reading the input format (voice processing can change it), and
        // re-decided on every attach because the route may have changed.
        // Best-effort: fall back to the current state if the OS refuses.
        let wantVoiceProcessing = Config.shouldEnableMicVoiceProcessing()
        if input.isVoiceProcessingEnabled != wantVoiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(wantVoiceProcessing)
                if wantVoiceProcessing {
                    // Voice processing makes macOS DUCK every other app's
                    // audio by default — on a call that turns the remote side
                    // down for the user and for our system-audio track (peak
                    // 0.03 vs 0.82 with AEC off). We only want the echo
                    // cancellation, so ask for the minimum ducking and no
                    // dynamic ("advanced") ducking.
                    input.voiceProcessingOtherAudioDuckingConfiguration =
                        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                            enableAdvancedDucking: false,
                            duckingLevel: .min
                        )
                }
                micLog.notice("voice processing (AEC) \(wantVoiceProcessing ? "enabled, other-audio ducking=min" : "disabled", privacy: .public)")
            } catch {
                micLog.error("voice processing set(\(wantVoiceProcessing, privacy: .public)) failed, keeping \(input.isVoiceProcessingEnabled, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        let format = input.inputFormat(forBus: 0)
        micLog.notice("input format: sampleRate=\(format.sampleRate, privacy: .public) channels=\(format.channelCount, privacy: .public) commonFormat=\(format.commonFormat.rawValue, privacy: .public)")
        if format.sampleRate == 0 || format.channelCount == 0 {
            micLog.error("degenerate input format — no real input device")
            throw MicCaptureError.engineStartFailed(
                underlying: NSError(domain: "MicCapture", code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "No active microphone input (sampleRate=\(format.sampleRate), channels=\(format.channelCount))"])
            )
        }

        // Open the file as 16-bit signed PCM at the tap's sample rate,
        // always MONO. AVAudioFile will internally convert each Float32
        // buffer to Int16 on write — well-trodden path, unlike forcing the
        // file's processingFormat to match a non-interleaved Float32 mic
        // input (which silently writes zeros on Tahoe in some
        // configurations).
        //
        // Why mono: with voice processing (AEC) on, the input node reports a
        // multi-channel format (7 identical channels seen with a USB mic on
        // built-in speakers). A 7-channel CAF has no channel layout the
        // AppleM4A export understands, so the compressed copy came out
        // SILENT and the raw file (~40 MB/min) had to be kept. A mic is one
        // voice; channel 0 carries it (the same channel the silence stats
        // read), so we write just that.
        let audioFile: AVAudioFile
        if let existing = file {
            audioFile = existing
        } else {
            let fileSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            do {
                audioFile = try AVAudioFile(forWriting: outputURL, settings: fileSettings)
            } catch {
                micLog.error("AVAudioFile init failed: \(error.localizedDescription, privacy: .public)")
                throw MicCaptureError.fileCreateFailed(underlying: error)
            }
            file = audioFile
        }
        let fileFormat = audioFile.processingFormat

        // After a restart the route may run at another rate (AirPods mic:
        // 16/24 kHz vs the file's 48 kHz). The file's rate is fixed, so
        // convert channel 0 into it.
        let needsRateConversion = format.sampleRate != fileFormat.sampleRate
        let needsMonoCopy = format.channelCount > 1 || needsRateConversion
        var converter: AVAudioConverter?
        var monoInputFormat = fileFormat
        if needsRateConversion {
            guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                           channels: 1, interleaved: false),
                  let c = AVAudioConverter(from: mono, to: fileFormat) else {
                throw MicCaptureError.engineStartFailed(
                    underlying: NSError(domain: "MicCapture", code: -4,
                                        userInfo: [NSLocalizedDescriptionKey: "no converter from \(format.sampleRate) Hz to \(fileFormat.sampleRate) Hz"]))
            }
            monoInputFormat = mono
            converter = c
        }
        micLog.info("file processingFormat: sampleRate=\(fileFormat.sampleRate, privacy: .public) channels=\(fileFormat.channelCount, privacy: .public) tapMatches=\(format == fileFormat, privacy: .public) rateConversion=\(needsRateConversion, privacy: .public)")

        // The tap runs on the AVAudio thread. It must be built OUTSIDE any
        // actor-isolated context: a closure formed inside this @MainActor
        // method inherits main-actor isolation, and Swift's runtime check
        // then traps the first time the audio thread calls it (SIGTRAP in
        // dispatch_assert_queue — reproduced with the --mic-test harness).
        // Preallocated here so the tap's resume pad never allocates.
        let zeros = Self.makeZeroBuffer(format: fileFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: format,
                         block: Self.tapBlock(stats: stats, clock: clock, audioFile: audioFile,
                                              needsMonoCopy: needsMonoCopy,
                                              monoInputFormat: monoInputFormat, converter: converter,
                                              fileFormat: fileFormat, zeros: zeros))

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw MicCaptureError.engineStartFailed(underlying: error)
        }
        backoff.noteAttached(at: clock.wall())
    }

    /// The per-buffer tap. nonisolated so the closure carries no actor
    /// isolation (see the call site). Writes to `audioFile` only from the
    /// audio thread while installed. Before a buffer that starts more than
    /// 0.05 s of host time after the last one ended (buffers resumed after a
    /// stall without a restart), writes that gap as zeros from `zeros`.
    private nonisolated static func tapBlock(stats: TapStats, clock: any CaptureClock, audioFile: AVAudioFile,
                                             needsMonoCopy: Bool,
                                             monoInputFormat: AVAudioFormat, converter: AVAudioConverter?,
                                             fileFormat: AVAudioFormat,
                                             zeros: AVAudioPCMBuffer?) -> AVAudioNodeTapBlock {
        return { buffer, when in
                // Sample-content check so we can tell silent-buffer vs no-buffer
                // cases apart in the post-recording log. Cheap: peek one
                // channel of float32; skip if format is something else.
                if let channelData = buffer.floatChannelData?[0] {
                    let count = Int(buffer.frameLength)
                    var localPeak: Float = 0
                    var nonSilent: UInt64 = 0
                    for i in 0..<count {
                        let v = abs(channelData[i])
                        if v > CaptureSignal.epsilon { nonSilent += 1 }
                        if v > localPeak { localPeak = v }
                    }
                    stats.frameCount &+= UInt64(buffer.frameLength)
                    stats.nonSilentFrames &+= nonSilent
                    if localPeak > stats.peakAmplitude { stats.peakAmplitude = localPeak }
                    if nonSilent > 0 {
                        stats.lastSignalBits.store(Date().epochBits, ordering: .relaxed)
                    }
                } else {
                    stats.frameCount &+= UInt64(buffer.frameLength)
                }
                let hostNow = clock.hostTicks()
                let previousNominal = stats.lastNominalEndTicks.load(ordering: .relaxed)
                stats.lastHostEndTicks.store(
                    Self.bufferEndTicks(start: when.hostTime, hostTimeValid: when.isHostTimeValid,
                                        frames: buffer.frameLength, sampleRate: buffer.format.sampleRate,
                                        ticksPerSecond: clock.ticksPerSecond, now: hostNow),
                    ordering: .relaxed)
                stats.lastNominalEndTicks.store(
                    Self.nominalEndTicks(start: when.hostTime, hostTimeValid: when.isHostTimeValid,
                                         frames: buffer.frameLength, sampleRate: buffer.format.sampleRate,
                                         ticksPerSecond: clock.ticksPerSecond, previous: previousNominal),
                    ordering: .relaxed)
                // Buffers resumed after a gap with no restart in between (a
                // restart pads up to its own instant and advances
                // lastHostEndTicks): fill the gap before this buffer.
                if let zeros {
                    let gap = Self.resumePadSeconds(lastHostEnd: previousNominal, start: when.hostTime,
                                                    hostTimeValid: when.isHostTimeValid, now: hostNow,
                                                    ticksPerSecond: clock.ticksPerSecond)
                    if gap > 0 {
                        let rate = fileFormat.sampleRate
                        let padded = Self.writeSilence(into: audioFile, zero: zeros, seconds: gap, rate: rate)
                        if padded.frames > 0 { stats.addResumePad(Double(padded.frames) / rate) }
                        // Counted only: formatting the error would allocate
                        // on the render thread. The buffer write that follows
                        // fails the same way and records the text.
                        if padded.error != nil { stats.writeErrors &+= 1 }
                    }
                }
                do {
                    var toWrite = buffer
                    if needsMonoCopy {
                        guard let mono = Self.monoCopy(of: buffer, format: monoInputFormat) else {
                            throw NSError(domain: "MicCapture", code: -3,
                                          userInfo: [NSLocalizedDescriptionKey: "could not extract channel 0 from a \(buffer.format.channelCount)-channel buffer"])
                        }
                        toWrite = mono
                    }
                    if let converter {
                        toWrite = try Self.convert(toWrite, with: converter, to: fileFormat)
                    }
                    try audioFile.write(from: toWrite)
                } catch {
                    stats.writeErrors &+= 1
                    if stats.firstWriteError == nil {
                        stats.firstWriteError = "\(error)"
                    }
                }
        
        }
    }

    @MainActor
    func stop() {
        guard running else { return }
        running = false
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        for observer in sleepObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        sleepObservers = []
        restartTask?.cancel()
        restartTask = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        logResumePad()
        micLog.notice("stop: frames=\(self.stats.frameCount, privacy: .public) nonSilentFrames=\(self.stats.nonSilentFrames, privacy: .public) peak=\(self.stats.peakAmplitude, privacy: .public) writeErrors=\(self.stats.writeErrors, privacy: .public) firstWriteError=\(self.stats.firstWriteError ?? "nil", privacy: .public) restarts=\(self.stats.restarts, privacy: .public) paddedSeconds=\(String(format: "%.1f", self.paddedSecondsTotal), privacy: .public)")
        // AVAudioFile flushes/closes on deinit.
        file = nil
    }

    /// Channel 0 of a multi-channel Float32 tap buffer as a mono buffer in
    /// `format` (mono Float32 at the buffer's own rate). nil when the
    /// buffer isn't deinterleaved Float32 or `format` isn't mono Float32 —
    /// the caller records that as a write error rather than writing junk.
    static func monoCopy(of buffer: AVAudioPCMBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard format.channelCount == 1,
              let source = buffer.floatChannelData?[0],
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let destination = mono.floatChannelData?[0] else { return nil }
        destination.update(from: source, count: Int(buffer.frameLength))
        mono.frameLength = buffer.frameLength
        return mono
    }

    /// Resamples one mono buffer into `format` (the file's rate).
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter,
                        to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw NSError(domain: "MicCapture", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "could not allocate a \(capacity)-frame conversion buffer"])
        }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error { throw error ?? NSError(domain: "MicCapture", code: -6) }
        return out
    }

    private static func ensurePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
