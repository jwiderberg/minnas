//
// System audio capture via ScreenCaptureKit.
//
// ScreenCaptureKit is the only first-party API that captures system
// audio without a virtual audio driver. The trick is that the API is
// nominally for screen capture, so we still have to pick a display and
// configure a (tiny, ignored) video stream alongside the audio stream
// we actually want. excludesCurrentProcessAudio is set so we don't
// loop our own playback back into the capture.
//
// TCC: the first call to SCShareableContent prompts the user for
// Screen Recording permission. There is no Info.plist key for it.
// On denial, ScreenCaptureKit returns an error from startCapture().
//
// Liveness: like the mic (see MicCapture), this stream must never die
// quietly. The delegate's didStopWithError and a watchdog driven from the
// app's recording tick (no buffer for 3 s) both re-create the SCStream on
// the same writer. The gap is filled with silence — computed on the
// delivery queue from the presentation timestamps on either side of the
// restart, so the file stays aligned with the mic track whatever the
// writer does with a timestamp gap. Only if restarting keeps failing does
// the recording end (onUnexpectedStop), and then with an alert.
//

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import Synchronization
import os.log

private let sysLog = Logger(subsystem: "com.jwiderberg.minnas", category: "SystemAudioCapture")

enum SystemAudioCaptureError: Error {
    case noDisplaysAvailable
    case writerInitFailed(underlying: Error)
    case streamStartFailed(underlying: Error)
}

/// Thread ownership (why `@unchecked Sendable` is sound here):
///
/// - Main actor: `running`, `restartTask`, `backoff`, `restartCount`, and
///   `stream`. start() and startStream() are nonisolated and assign
///   `stream` (and note the attach in `backoff`) right after startCapture
///   returns, before RecordingSession returns from start, i.e. before the
///   recording tick can call checkHealth; every later assignment is
///   @MainActor. A buffer SCKit delivers in the moment between startCapture
///   returning and that assignment fails the identity check below and is
///   dropped; the next buffer's gap fill covers it. The delivery queue never
///   reads `stream` itself, only its mirrored identity.
/// - Written by start() only while no stream is delivering, read on the
///   delivery queue: `filter`, `config`.
/// - `caf`, the PaddedCAFWriter that owns the AVAssetWriter, its input, the
///   session start and the timeline end: confined to `writeQueue`. The
///   exceptions are its own: start() opens it (and, if the first stream
///   fails, cancels it) before any stream delivers, and stop()'s
///   finish(timeout:) does its work on the write queue and releases the
///   writer there, so a buffer still in flight after a timed-out finish
///   cannot race the release.
/// - `writeQueue` (SCKit's sample-handler queue for every stream we
///   create): `lastFormat`, `fillGapOnNextBuffer` (the restart path sets it
///   with `writeQueue.async`, never directly).
/// - Shared across threads, so atomic or locked: `currentStreamID` (the
///   identity of `stream`, mirrored by its didSet, compared on the delivery
///   queue), `stopRequested` (behind `stoppingByRequest`; also read by the
///   delegate on SCKit's queue), `peakBits`, `signalLatch`, `cafStats`
///   (writer drops, padding, failure, timeout), and the counters below.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, SystemAudioEngine, @unchecked Sendable {
    private let outputURL: URL
    private var stream: SCStream? {
        didSet { currentStreamID.withLock { $0 = stream.map(ObjectIdentifier.init) } }
    }
    /// Identity of `stream` for the delivery queue's stale-buffer check. The
    /// SCStream object itself is only touched by the main actor.
    private let currentStreamID = Mutex<ObjectIdentifier?>(nil)
    private var filter: SCContentFilter?
    private var config: SCStreamConfiguration?
    /// The file, confined to writeQueue (see above). Its timeline end is in
    /// SCKit's presentation-time domain.
    private let caf: PaddedCAFWriter
    /// Set by stop() on the main actor, read there and by the delegate's
    /// didStopWithError on SCKit's queue.
    private let stopRequested = Atomic<Bool>(false)
    private var stoppingByRequest: Bool {
        get { stopRequested.load(ordering: .acquiring) }
        set { stopRequested.store(newValue, ordering: .releasing) }
    }
    private var running = false
    /// Float bit pattern of the peak since the last snapshotPeak (delivery
    /// queue writes, main actor exchanges). A lost update only nudges the
    /// meter.
    private let peakBits = Atomic<UInt32>(0)
    // Latches true once any real (non-silent) audio arrives. Stays false
    // when the stream only ever delivers digital silence (the broken-capture
    // case), which the pre-flight check uses to warn early. Written from the
    // SCKit delivery queue, read from MainActor.
    private let signalLatch = Atomic<Bool>(false)
    var hasSignal: Bool { signalLatch.load(ordering: .relaxed) }
    // Wall-clock of the last non-silent buffer (auto-stop). Bit pattern of an
    // epoch Double, so the SCKit-delivery-queue write and the MainActor read
    // are a single atomic 64-bit access (an Optional<Date> is 16 bytes and
    // would tear). 0 = no signal yet.
    private let lastSignalBits = Atomic<UInt64>(0)
    // Wall-clock of the last buffer of ANY kind — the liveness signal.
    private let lastBufferBits = Atomic<UInt64>(0)
    private let bufferCount = Atomic<UInt64>(0)
    /// Writer drops (buffers SCKit delivered that the writer input wasn't
    /// ready for; their span becomes a hole the next buffer pads, see
    /// didOutputSampleBuffer), padding, failure and finish timeout. Outlives
    /// the writer: capture_health reads it after stop().
    private let cafStats = CAFWriterStats()
    // Delivery-queue state for gap filling across a restart.
    private var lastFormat: CMFormatDescription?
    private var fillGapOnNextBuffer = false
    private var restartTask: Task<Void, Never>?
    private var backoff = RestartBackoff()
    private(set) var restartCount = 0
    /// When the stream stopped delivering and hasn't come back; nil while
    /// healthy.
    var stalledSince: Date? { backoff.stalledSince }

    var lastSignalAt: Date? { Date(epochBits: lastSignalBits.load(ordering: .relaxed)) }
    var lastBufferAt: Date? { Date(epochBits: lastBufferBits.load(ordering: .relaxed)) }
    var buffersDelivered: UInt64 { bufferCount.load(ordering: .relaxed) }
    var buffersDropped: UInt64 { cafStats.dropped }
    var paddedSecondsTotal: Double { cafStats.paddedSeconds }
    /// The asset writer refused data — the file can't be recovered by a
    /// stream restart; the user has to stop and start a new recording.
    var hasWriterFailed: Bool { cafStats.hasFailed }

    private let writeQueue: DispatchQueue

    // Called when the stream is gone and could not be brought back (20
    // restart attempts failed, e.g. Screen Recording permission revoked).
    // Fires off the SCKit delivery queue or a Task; the closure body is
    // responsible for hopping to whichever actor it needs.
    var onUnexpectedStop: (@Sendable () -> Void)?

    init(outputURL: URL) {
        self.outputURL = outputURL
        let writeQueue = DispatchQueue(label: "minnas.system-audio.write")
        self.writeQueue = writeQueue
        self.caf = PaddedCAFWriter(queue: writeQueue, stats: cafStats, log: sysLog)
        super.init()
    }

    /// Live peak amplitude since last query (0.0 — 1.0). Used by the
    /// menubar level meter.
    func snapshotPeak() -> Float {
        Float(bitPattern: peakBits.exchange(0, ordering: .relaxed))
    }

    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            // Most likely TCC denial. Surface as a stream-start failure
            // so the AppDelegate shows one consistent error path.
            throw SystemAudioCaptureError.streamStartFailed(underlying: error)
        }

        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplaysAvailable
        }

        // Capture the whole display's content. We tried excluding every
        // window (to make the unused video stream cheap) — but that also
        // excludes those windows' AUDIO, so the stream delivered pure
        // silence (a 36-min meeting recorded a 396 MB file of zeros). Audio
        // follows the included content, so we must include the windows;
        // excludesCurrentProcessAudio still keeps our own playback out, and
        // the 2x2 video is negligible regardless of how many windows it
        // nominally contains.
        //
        // That same "audio follows content" rule is what lets us drop
        // specific apps on purpose: an audio tool that monitors the user's
        // own mic back out (an audio tool → virtual device → the call) would otherwise
        // put the user's voice in the "Them" track. Excluding the app
        // excludes its audio. Only apps that are currently running can be
        // matched; a configured bundle that isn't running is simply absent.
        let excludedIDs = Config.systemAudioExcludedBundleIDs()
        let excludedApps = content.applications.filter { excludedIDs.contains($0.bundleIdentifier) }
        if !excludedIDs.isEmpty {
            let matched = excludedApps.map(\.bundleIdentifier).joined(separator: ",")
            sysLog.notice("system-audio exclusions configured=\(excludedIDs.joined(separator: ","), privacy: .public) running=\(matched.isEmpty ? "none" : matched, privacy: .public)")
        }
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // We don't consume video frames, but the config requires a
        // sensible size. Keep it tiny to minimize wasted work.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        // Default audio: 48 kHz stereo PCM, which is fine to feed into
        // AVAssetWriter without resampling.
        self.filter = filter
        self.config = config

        // The fixed CAF output format, no source hint (SCKit's format is
        // only known from the first buffer). Nothing delivers yet, so this
        // runs off the write queue.
        do throws(PaddedCAFWriter.OpenError) {
            try caf.open(url: outputURL, sourceFormatHint: nil)
        } catch {
            throw Self.writerInitError(error)
        }

        do {
            try await startStream()
        } catch {
            caf.cancelBeforeFirstAppend()
            self.stream = nil
            throw error
        }
        running = true
    }

    /// PaddedCAFWriter's open errors, as the errors this engine has always
    /// reported: the AVAssetWriter init error as is, -3 for canAdd refused,
    /// startWriting's error or else -1.
    private static func writerInitError(_ error: PaddedCAFWriter.OpenError) -> SystemAudioCaptureError {
        switch error {
        case .create(let underlying):
            return .writerInitFailed(underlying: underlying)
        case .inputRefused:
            return .writerInitFailed(
                underlying: NSError(domain: "SystemAudioCapture", code: -3,
                                    userInfo: [NSLocalizedDescriptionKey: "asset writer refused the audio input (canAdd == false)"]))
        case .startFailed(let underlying):
            return .writerInitFailed(underlying: underlying ?? NSError(domain: "SystemAudioCapture", code: -1))
        }
    }

    /// Creates and starts an SCStream on the stored filter/config. Used by
    /// start() and by every restart.
    private func startStream() async throws {
        guard let filter, let config else {
            throw SystemAudioCaptureError.streamStartFailed(
                underlying: NSError(domain: "SystemAudioCapture", code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "stream configuration missing"]))
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writeQueue)
            try await stream.startCapture()
        } catch {
            throw SystemAudioCaptureError.streamStartFailed(underlying: error)
        }
        self.stream = stream
        backoff.noteAttached()
    }

    /// Watchdog hook, called from the app's recording tick. Re-creates the
    /// stream when it has delivered nothing for a few seconds (3 s, backing
    /// off for restarts that never produce a buffer).
    @MainActor
    func checkHealth() {
        guard running, !stoppingByRequest, restartTask == nil else { return }
        if let threshold = backoff.overdue(lastBufferAt: lastBufferAt) {
            scheduleRestart(reason: "no buffers for \(Int(threshold)) s")
        }
    }

    /// Test hook: stop the stream the way the system would (no request flag),
    /// so the watchdog has to notice and recover. Used by --system-test.
    func simulateStreamDeath() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        sysLog.notice("simulated stream death")
    }

    @MainActor
    private func scheduleRestart(reason: String) {
        guard running, !stoppingByRequest, restartTask == nil else { return }
        backoff.noteRestartScheduled(restartsSoFar: restartCount, lastBufferAt: lastBufferAt)
        sysLog.error("system audio stalled (\(reason, privacy: .public)); restarting stream")
        restartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.restartTask = nil }
            for attempt in 1...RestartBackoff.attemptsPerBatch {
                guard self.running, !self.stoppingByRequest, !Task.isCancelled else { return }
                do {
                    if let old = self.stream {
                        try? await old.stopCapture()
                        self.stream = nil
                    }
                    guard !self.stoppingByRequest, !Task.isCancelled else { return }
                    // The next buffer fills the timestamp gap with silence.
                    // async, never sync: a delivery queue stuck in a write
                    // would otherwise freeze the main actor and every
                    // watchdog with it. FIFO on the serial queue still sets
                    // the flag before the new stream's first buffer.
                    self.writeQueue.async { self.fillGapOnNextBuffer = true }
                    try await self.startStream()
                    // stop() may have run while startStream was suspended;
                    // it waits for this task, so a stream created now must
                    // not outlive it.
                    if self.stoppingByRequest || Task.isCancelled {
                        if let fresh = self.stream {
                            try? await fresh.stopCapture()
                            self.stream = nil
                        }
                        sysLog.notice("system audio restart finished after stop was requested; new stream stopped")
                        return
                    }
                    self.restartCount += 1
                    self.backoff.noteRecovered()
                    sysLog.notice("system audio stream restarted (\(reason, privacy: .public), attempt \(attempt, privacy: .public))")
                    return
                } catch {
                    sysLog.error("system audio restart attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    try? await Task.sleep(for: RestartBackoff.retryDelay)
                }
            }
            guard !self.stoppingByRequest, !Task.isCancelled else { return }
            // Terminal: clear `running` BEFORE telling the session, or the next
            // health tick would schedule another 20-attempt batch forever.
            self.running = false
            sysLog.error("system audio restart gave up after 20 attempts")
            self.onUnexpectedStop?()
        }
    }

    @MainActor
    func stop() async {
        stoppingByRequest = true
        running = false
        // Wait the restart out before touching the stream or the writer: an
        // in-flight startStream would otherwise leave a live SCStream (and
        // the capture indicator) running after stop, writing to a finished
        // writer.
        if let restartTask {
            restartTask.cancel()
            await restartTask.value
        }
        restartTask = nil
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        // Flush the writer, bounded: a wedged writer must not hang stop()
        // (AppDelegate's isStopping would stay true, Stop would be dead and
        // the mic would keep recording). PaddedCAFWriter.finish runs
        // finishWriting on the write queue and races a 10 s deadline fired
        // from a global queue, so even a blocked writeQueue can't hold stop()
        // past it. On timeout it logs and abandons the writer, NOT cancels
        // it (cancelWriting deletes the file); a late finish still finalises
        // the file. The writer is released on the write queue, so a buffer
        // still in flight after a timed-out finish cannot race the release.
        let finished = await caf.finish(timeout: PaddedCAFWriter.finishTimeout)
        let writerTimedOut = !finished
        sysLog.notice("stop: buffers=\(self.buffersDelivered, privacy: .public) hasSignal=\(self.hasSignal, privacy: .public) restarts=\(self.restartCount, privacy: .public) dropped=\(self.buffersDropped, privacy: .public) paddedSeconds=\(String(format: "%.1f", self.paddedSecondsTotal), privacy: .public) writerFailed=\(self.hasWriterFailed, privacy: .public) writerTimedOut=\(writerTimedOut, privacy: .public)")
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // SCKit's delivery queue, not main. If our own stop() set the
        // flag, this is the expected end-of-stream callback and we have
        // nothing to do — RecordingSession is already finishing things.
        guard !stoppingByRequest else { return }
        sysLog.error("stream stopped by the system: \(error.localizedDescription, privacy: .public)")
        Task { @MainActor [weak self] in
            self?.scheduleRestart(reason: "stream stopped: \(error.localizedDescription)")
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard caf.isOpen else { return }
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        // A buffer from a stream we've already replaced must not land
        // between the restart's padding and the new stream's audio. Compared
        // by identity through the lock: `self.stream` belongs to the main
        // actor.
        guard currentStreamID.withLock({ $0 }) == ObjectIdentifier(stream) else { return }

        if !caf.sessionStarted {
            caf.startSession(atSourceTime: sampleBuffer.presentationTimeStamp, seedTimeline: false)
        }

        lastBufferBits.store(Date().epochBits, ordering: .relaxed)
        bufferCount.wrappingAdd(1, ordering: .relaxed)
        updatePeakAmplitude(from: sampleBuffer)

        if fillGapOnNextBuffer {
            fillGapOnNextBuffer = false
            fillGap(upTo: sampleBuffer.presentationTimeStamp)
        }

        lastFormat = sampleBuffer.formatDescription
        // No wait for the input. A refused append that failed the writer is
        // logged once by PaddedCAFWriter and latched in cafStats; the
        // timeline end still moves past the buffer.
        switch caf.append(sampleBuffer, readyWait: 0) {
        case .appended, .writerFailed:
            break
        case .dropped(let dropped):
            // Backpressure. The timeline end stays at the last buffer that
            // made it into the file, so the hole is padded by the next
            // buffer instead of silently shortening the track, and the drop
            // is counted.
            if dropped == 1 || dropped.isMultiple(of: 100) {
                sysLog.error("writer input not ready; dropped system-audio buffer (\(dropped, privacy: .public) so far)")
            }
            fillGapOnNextBuffer = true
        }
    }

    /// Appends zeros covering [timeline end, pts) so a stream restart or a
    /// run of dropped buffers leaves no hole: whatever the writer would do
    /// with a timestamp gap, the file now carries real time. Delivery queue
    /// only. PaddedCAFWriter rejects a non-finite gap or one over its 300 s
    /// cap, skips one of 0.05 s or less, writes 1 s chunks with a 2 s wait
    /// for the writer each, and leaves the timeline end where a partial fill
    /// stopped, so the next fill doesn't pad the same stretch again.
    private func fillGap(upTo pts: CMTime) {
        guard let format = lastFormat,
              CMAudioFormatDescriptionGetStreamBasicDescription(format) != nil else { return }
        switch caf.fillGap(upTo: pts, format: format, minimum: 0.05) {
        case .noTimeline:
            break
        case .rejected(let gap):
            sysLog.error("system-audio PTS gap \(String(format: "%.3f", gap), privacy: .public) s is non-finite or over the \(Int(PaddedCAFWriter.maxFillSeconds), privacy: .public) s cap; not padding it")
        case .belowMinimum(let gap):
            sysLog.notice("system-audio gap \(String(format: "%.3f", gap), privacy: .public) s — no padding needed")
        case .filled(let padded, let gap):
            sysLog.notice("padded system track with \(String(format: "%.2f", padded), privacy: .public) s of silence across a stream restart or dropped buffers (gap \(String(format: "%.2f", gap), privacy: .public) s)")
        }
    }

    /// Walk the first contiguous chunk of the sample buffer's PCM data
    /// and update peak amplitude. Assumes SCStream's default delivery
    /// format on Tahoe: Float32 48 kHz. If a future configuration changes
    /// that, the meter goes wrong but doesn't crash — the meter is purely
    /// UX and never feeds the writer.
    private func updatePeakAmplitude(from sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = sampleBuffer.dataBuffer else { return }
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>? = nil
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer else { return }
        let floatCount = lengthAtOffset / MemoryLayout<Float>.stride
        guard floatCount > 0 else { return }
        dataPointer.withMemoryRebound(to: Float.self, capacity: floatCount) { samples in
            var localPeak: Float = 0
            for i in 0..<floatCount {
                let v = abs(samples[i])
                if v > localPeak { localPeak = v }
            }
            if localPeak > Float(bitPattern: self.peakBits.load(ordering: .relaxed)) {
                self.peakBits.store(localPeak.bitPattern, ordering: .relaxed)
            }
            if localPeak > CaptureSignal.epsilon {
                self.signalLatch.store(true, ordering: .relaxed)
                self.lastSignalBits.store(Date().epochBits, ordering: .relaxed)
            }
        }
    }
}
