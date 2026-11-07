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
// Sleep: the padding is wall-clock based, but a sleep is not a dead mic —
// the system track's host-time PTS doesn't advance in sleep either, so
// padding it would push the mic track ahead and write minutes-to-hours of
// zeros on wake. Across a sleep the stall clock restarts at wake and the
// sleep itself is never padded. If the engine died over the sleep, the
// two tracks may then be offset by up to the sleep length; that's logged
// with its cause and is a far smaller harm than gigabytes of silence.
// Any single pad is also capped at 5 min (clock jumps, a missed wake).
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
    // Wall-clock of the last buffer of ANY kind (silent or not). Drives the
    // stall watchdog and the silence padding on restart. 0 = none yet.
    let lastBufferBits = Atomic<UInt64>(0)
    var restarts: Int = 0
    var paddedSeconds: Double = 0
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
    private var sleepObservers: [NSObjectProtocol] = []
    // Set between willSleep and didWake. A restart that runs in that window
    // (the engine's config-change can land before didWake) must not pad.
    private var sleepingSince: Date?

    /// Upper bound on one silence pad. A real route-change restart is back
    /// in well under a second; anything past this is a clock jump or a
    /// sleep we didn't see, and padding it could fill the disk.
    static let maxPadSeconds: Double = 300

    /// When the mic stopped delivering audio and a restart is in progress
    /// or has failed; nil while healthy. The menubar shows a warning off it.
    var stalledSince: Date? { backoff.stalledSince }

    init(outputURL: URL) {
        self.outputURL = outputURL
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

    /// Wall-clock of the most recent buffer of any kind.
    var lastBufferAt: Date? { Date(epochBits: stats.lastBufferBits.load(ordering: .relaxed)) }

    /// How many times the engine was re-attached after a route change or
    /// stall during this recording.
    var restartCount: Int { stats.restarts }
    var paddedSecondsTotal: Double { stats.paddedSeconds }
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

        // queue: .main so the handlers run synchronously on the main thread,
        // ahead of any restart Task queued behind them.
        let ws = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemWillSleep() }
            },
            ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemDidWake() }
            },
        ]
    }

    @MainActor
    private func systemWillSleep() {
        guard running else { return }
        sleepingSince = Date()
        micLog.notice("system going to sleep while recording; the sleep will not be padded")
    }

    /// Restart the stall clock at wake, before any restart can pad, so the
    /// sleep never turns into silence in the file (see the header).
    @MainActor
    private func systemDidWake() {
        guard running else { return }
        let slept = sleepingSince.map { Date().timeIntervalSince($0) }
        sleepingSince = nil
        stats.lastBufferBits.store(Date().epochBits, ordering: .relaxed)
        micLog.notice("system woke after \(slept.map { String(format: "%.0f", $0) } ?? "unknown", privacy: .public) s asleep; mic stall clock reset, sleep not padded (mic/system tracks may be offset by up to that if the engine died over the sleep)")
    }

    /// Belt-and-braces for route changes the notification doesn't cover:
    /// called from the app's recording tick. If the engine isn't running,
    /// or has delivered nothing for a few seconds, re-attach.
    @MainActor
    func checkHealth() {
        guard running, restartTask == nil else { return }
        if !engine.isRunning {
            scheduleRestart(reason: "engine not running")
            return
        }
        // 3 s normally; doubles for each restart that never produced a
        // buffer, up to a minute, so a dead device is retried, not spun on.
        if let threshold = backoff.overdue(lastBufferAt: lastBufferAt) {
            scheduleRestart(reason: "no buffers for \(Int(threshold)) s")
        }
    }

    @MainActor
    private func scheduleRestart(reason: String) {
        guard running, restartTask == nil else { return }
        backoff.noteRestartScheduled(restartsSoFar: stats.restarts, lastBufferAt: lastBufferAt)
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

    /// Writes zeros covering the wall-clock gap since the last buffer, so a
    /// mic segment captured after a restart lands at the right offset
    /// relative to the system track (the transcript merges the two by
    /// timestamp). Called only while no tap is installed.
    @MainActor
    private func padGapWithSilence() {
        guard let file, let last = lastBufferAt else { return }
        if let sleepingSince {
            // Restart fired between willSleep and didWake: the gap is mostly
            // sleep. Don't pad; restart the stall clock from here.
            micLog.notice("mic restart during sleep/wake (asleep since \(sleepingSince.formatted(.iso8601), privacy: .public)); gap of \(String(format: "%.1f", Date().timeIntervalSince(last)), privacy: .public) s not padded")
            stats.lastBufferBits.store(Date().epochBits, ordering: .relaxed)
            return
        }
        let rawGap = Date().timeIntervalSince(last)
        guard rawGap.isFinite, rawGap > 0.05 else { return }
        let gap = min(rawGap, Self.maxPadSeconds)
        if rawGap > Self.maxPadSeconds {
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
        // The padding stands in for the dead stretch; the stall clock
        // restarts from here.
        stats.lastBufferBits.store(Date().epochBits, ordering: .relaxed)
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
        input.installTap(onBus: 0, bufferSize: 4096, format: format,
                         block: Self.tapBlock(stats: stats, audioFile: audioFile, needsMonoCopy: needsMonoCopy,
                                              monoInputFormat: monoInputFormat, converter: converter,
                                              fileFormat: fileFormat))

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw MicCaptureError.engineStartFailed(underlying: error)
        }
        backoff.noteAttached()
    }

    /// The per-buffer tap. nonisolated so the closure carries no actor
    /// isolation (see the call site). Writes to `audioFile` only from the
    /// audio thread while installed.
    private nonisolated static func tapBlock(stats: TapStats, audioFile: AVAudioFile, needsMonoCopy: Bool,
                                             monoInputFormat: AVAudioFormat, converter: AVAudioConverter?,
                                             fileFormat: AVAudioFormat) -> AVAudioNodeTapBlock {
        return { buffer, _ in
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
                stats.lastBufferBits.store(Date().epochBits, ordering: .relaxed)
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
        sleepingSince = nil
        restartTask?.cancel()
        restartTask = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        micLog.notice("stop: frames=\(self.stats.frameCount, privacy: .public) nonSilentFrames=\(self.stats.nonSilentFrames, privacy: .public) peak=\(self.stats.peakAmplitude, privacy: .public) writeErrors=\(self.stats.writeErrors, privacy: .public) firstWriteError=\(self.stats.firstWriteError ?? "nil", privacy: .public) restarts=\(self.stats.restarts, privacy: .public) paddedSeconds=\(String(format: "%.1f", self.stats.paddedSeconds), privacy: .public)")
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
