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

/// One-shot latch for stop()'s finishWriting-versus-deadline race: the first
/// claim() wins and resumes the continuation, the other side does nothing.
private final class FinishLatch: Sendable {
    private let claimed = Atomic<Bool>(false)
    func claim() -> Bool { !claimed.exchange(true, ordering: .acquiringAndReleasing) }
}

final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, SystemAudioEngine, @unchecked Sendable {
    private let outputURL: URL
    private var stream: SCStream?
    private var filter: SCContentFilter?
    private var config: SCStreamConfiguration?
    private var writer: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var stoppingByRequest = false
    private var running = false
    private var peakAmplitude: Float = 0
    // Latches true once any real (non-silent) audio arrives. Stays false
    // when the stream only ever delivers digital silence (the broken-capture
    // case), which the pre-flight check uses to warn early. Written from the
    // SCKit delivery queue, read from MainActor — a bool latch is safe.
    private(set) var hasSignal = false
    // Wall-clock of the last non-silent buffer (auto-stop). Bit pattern of an
    // epoch Double, so the SCKit-delivery-queue write and the MainActor read
    // are a single atomic 64-bit access (an Optional<Date> is 16 bytes and
    // would tear). 0 = no signal yet.
    private let lastSignalBits = Atomic<UInt64>(0)
    // Wall-clock of the last buffer of ANY kind — the liveness signal.
    private let lastBufferBits = Atomic<UInt64>(0)
    private let bufferCount = Atomic<UInt64>(0)
    // Buffers SCKit delivered that the writer input wasn't ready for. Their
    // span becomes a hole the next buffer pads (see didOutputSampleBuffer).
    private let droppedCount = Atomic<UInt64>(0)
    private let writerFailed = Atomic<Bool>(false)
    // Delivery-queue state for gap filling across a restart.
    private var lastPTSEnd: CMTime = .invalid
    private var lastFormat: CMFormatDescription?
    private var fillGapOnNextBuffer = false
    private var paddedSeconds: Double = 0
    private var restartTask: Task<Void, Never>?
    private var attachedAt = Date.distantPast
    private var silentRestarts = 0
    private(set) var restartCount = 0
    /// When the stream stopped delivering and hasn't come back; nil while
    /// healthy.
    private(set) var stalledSince: Date?

    var lastSignalAt: Date? { Self.date(fromBits: lastSignalBits.load(ordering: .relaxed)) }
    var lastBufferAt: Date? { Self.date(fromBits: lastBufferBits.load(ordering: .relaxed)) }
    var buffersDelivered: UInt64 { bufferCount.load(ordering: .relaxed) }
    var buffersDropped: UInt64 { droppedCount.load(ordering: .relaxed) }
    var paddedSecondsTotal: Double { paddedSeconds }
    /// The asset writer refused data — the file can't be recovered by a
    /// stream restart; the user has to stop and start a new recording.
    var hasWriterFailed: Bool { writerFailed.load(ordering: .relaxed) }

    private let writeQueue = DispatchQueue(label: "minnas.system-audio.write")

    /// How long stop() waits for finishWriting before abandoning the writer.
    static let finishWritingTimeout: Double = 10

    /// Upper bound on one silence fill. A restart is back in seconds; a
    /// bigger PTS gap is a clock anomaly, and padding it could fill the disk.
    static let maxFillSeconds: Double = 300

    // Called when the stream is gone and could not be brought back (20
    // restart attempts failed, e.g. Screen Recording permission revoked).
    // Fires off the SCKit delivery queue or a Task; the closure body is
    // responsible for hopping to whichever actor it needs.
    var onUnexpectedStop: (@Sendable () -> Void)?

    init(outputURL: URL) {
        self.outputURL = outputURL
        super.init()
    }

    private static func date(fromBits bits: UInt64) -> Date? {
        bits == 0 ? nil : Date(timeIntervalSince1970: Double(bitPattern: bits))
    }

    /// Live peak amplitude since last query (0.0 — 1.0). Used by the
    /// menubar level meter. Atomic float read on arm64 is safe enough.
    func snapshotPeak() -> Float {
        let p = peakAmplitude
        peakAmplitude = 0
        return p
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
        // own mic back out (through a virtual device into the call app) would otherwise
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

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .caf)
        } catch {
            throw SystemAudioCaptureError.writerInitFailed(underlying: error)
        }

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true
        if writer.canAdd(input) {
            writer.add(input)
        }
        self.writer = writer
        self.audioInput = input

        guard writer.startWriting() else {
            throw SystemAudioCaptureError.writerInitFailed(
                underlying: writer.error ?? NSError(domain: "SystemAudioCapture", code: -1)
            )
        }

        do {
            try await startStream()
        } catch {
            writer.cancelWriting()
            self.writer = nil
            self.audioInput = nil
            self.stream = nil
            throw error
        }
        running = true
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
        attachedAt = Date()
    }

    /// Watchdog hook, called from the app's recording tick. Re-creates the
    /// stream when it has delivered nothing for a few seconds (3 s, backing
    /// off for restarts that never produce a buffer).
    @MainActor
    func checkHealth() {
        guard running, !stoppingByRequest, restartTask == nil else { return }
        let last = lastBufferAt.map { max($0, attachedAt) } ?? attachedAt
        let threshold = min(60.0, 3.0 * pow(2.0, Double(silentRestarts)))
        if Date().timeIntervalSince(last) > threshold {
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
        if stalledSince == nil { stalledSince = Date() }
        let deliveredSinceAttach = (lastBufferAt ?? .distantPast) > attachedAt
        if restartCount > 0, !deliveredSinceAttach { silentRestarts += 1 } else { silentRestarts = 0 }
        sysLog.error("system audio stalled (\(reason, privacy: .public)); restarting stream")
        restartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.restartTask = nil }
            for attempt in 1...20 {
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
                    self.stalledSince = nil
                    sysLog.notice("system audio stream restarted (\(reason, privacy: .public), attempt \(attempt, privacy: .public))")
                    return
                } catch {
                    sysLog.error("system audio restart attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    try? await Task.sleep(for: .seconds(1))
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

        // Flush the writer. finishWriting is async on a callback; bridge
        // it to async/await so RecordingSession can sequence cleanup.
        // Bounded like the taps engine: a wedged writer must not hang stop()
        // (AppDelegate's isStopping would stay true, Stop would be dead and
        // the mic would keep recording). The deadline fires from a global
        // queue, so even a blocked writeQueue can't hold stop() past it.
        // On timeout the writer is abandoned, NOT cancelled: per
        // AVAssetWriter.h, -cancelWriting "will block until writing is
        // canceled" and "If an output file was created by the receiver
        // during the writing process, -cancelWriting will delete the file"
        // — that would throw away the whole system track. The completion
        // handler keeps the writer alive, so a late finish still finalises
        // the file.
        var writerTimedOut = false
        if let writer, let input = audioInput {
            let latch = FinishLatch()
            nonisolated(unsafe) let keepAlive = writer
            let finished: Bool = await withCheckedContinuation { cont in
                writeQueue.async {
                    input.markAsFinished()
                    writer.finishWriting {
                        if latch.claim() {
                            cont.resume(returning: true)
                        } else {
                            sysLog.notice("finishWriting completed after the deadline (writer status \(keepAlive.status.rawValue, privacy: .public))")
                        }
                    }
                }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.finishWritingTimeout) {
                    if latch.claim() { cont.resume(returning: false) }
                }
            }
            if !finished {
                writerTimedOut = true
                sysLog.error("finishWriting did not complete within \(Int(Self.finishWritingTimeout), privacy: .public) s (writer status \(keepAlive.status.rawValue, privacy: .public)); abandoning the writer without cancelWriting, which would delete the file")
            }
        }
        sysLog.notice("stop: buffers=\(self.buffersDelivered, privacy: .public) hasSignal=\(self.hasSignal, privacy: .public) restarts=\(self.restartCount, privacy: .public) dropped=\(self.buffersDropped, privacy: .public) paddedSeconds=\(String(format: "%.1f", self.paddedSeconds), privacy: .public) writerFailed=\(self.hasWriterFailed, privacy: .public) writerTimedOut=\(writerTimedOut, privacy: .public)")
        writer = nil
        audioInput = nil
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
        guard let writer, let input = audioInput else { return }
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        // A buffer from a stream we've already replaced must not land
        // between the restart's padding and the new stream's audio.
        guard stream === self.stream else { return }

        if !sessionStarted {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            sessionStarted = true
        }

        lastBufferBits.store(Date().timeIntervalSince1970.bitPattern, ordering: .relaxed)
        bufferCount.wrappingAdd(1, ordering: .relaxed)
        updatePeakAmplitude(from: sampleBuffer)

        if fillGapOnNextBuffer {
            fillGapOnNextBuffer = false
            fillGap(upTo: sampleBuffer.presentationTimeStamp, input: input, writer: writer)
        }

        lastFormat = sampleBuffer.formatDescription
        guard input.isReadyForMoreMediaData else {
            // Backpressure. lastPTSEnd stays at the last buffer that made it
            // into the file, so the hole is padded by the next buffer instead
            // of silently shortening the track, and the drop is counted.
            let dropped = droppedCount.wrappingAdd(1, ordering: .relaxed).newValue
            if dropped == 1 || dropped.isMultiple(of: 100) {
                sysLog.error("writer input not ready; dropped system-audio buffer (\(dropped, privacy: .public) so far)")
            }
            fillGapOnNextBuffer = true
            return
        }
        if !input.append(sampleBuffer), writer.status == .failed {
            if !writerFailed.load(ordering: .relaxed) {
                sysLog.error("asset writer failed: \(writer.error?.localizedDescription ?? "unknown", privacy: .public)")
            }
            writerFailed.store(true, ordering: .relaxed)
        }
        lastPTSEnd = CMTimeAdd(sampleBuffer.presentationTimeStamp, sampleBuffer.duration)
    }

    /// Appends zeros covering [lastPTSEnd, pts) so a stream restart or a
    /// run of dropped buffers leaves no hole: whatever the writer would do
    /// with a timestamp gap, the file now carries real time. Delivery queue
    /// only.
    private func fillGap(upTo pts: CMTime, input: AVAssetWriterInput, writer: AVAssetWriter) {
        guard lastPTSEnd.isValid, let format = lastFormat,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return }
        let gap = CMTimeSubtract(pts, lastPTSEnd).seconds
        guard gap.isFinite, gap <= Self.maxFillSeconds else {
            sysLog.error("system-audio PTS gap \(String(format: "%.3f", gap), privacy: .public) s is non-finite or over the \(Int(Self.maxFillSeconds), privacy: .public) s cap; not padding it")
            return
        }
        guard gap > 0.05 else {
            sysLog.notice("system-audio gap \(String(format: "%.3f", gap), privacy: .public) s — no padding needed")
            return
        }
        let rate = asbd.mSampleRate
        let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bytesPerFrameAllChannels = Int(asbd.mBytesPerFrame) * (nonInterleaved ? Int(asbd.mChannelsPerFrame) : 1)
        var remaining = Int(gap * rate)
        var cursor = lastPTSEnd
        var written = 0
        while remaining > 0 {
            let frames = min(remaining, Int(rate))
            let bytes = frames * bytesPerFrameAllChannels
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                                     blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                     dataLength: bytes, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
                  let block, CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) == kCMBlockBufferNoErr
            else { break }
            var silent: CMSampleBuffer?
            let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: frames, presentationTimeStamp: cursor, packetDescriptions: nil, sampleBufferOut: &silent)
            guard status == noErr, let silent else { break }
            // Bounded: after markAsFinished or a writer failure the input
            // never becomes ready again, and this runs on the delivery queue.
            let deadline = Date().addingTimeInterval(2)
            var ready = input.isReadyForMoreMediaData
            while !ready, writer.status == .writing, Date() < deadline {
                usleep(2_000)
                ready = input.isReadyForMoreMediaData
            }
            guard ready else {
                sysLog.error("gap fill gave up: writer input not ready after 2 s (writer status \(writer.status.rawValue, privacy: .public))")
                break
            }
            guard input.append(silent) else { break }
            written += frames
            remaining -= frames
            cursor = CMTimeAdd(cursor, CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate)))
        }
        paddedSeconds += Double(written) / rate
        // A partial fill (gave up mid-way) must not be padded again from the
        // old end by the next fill: the file now ends at the cursor.
        lastPTSEnd = cursor
        sysLog.notice("padded system track with \(String(format: "%.2f", Double(written) / rate), privacy: .public) s of silence across a stream restart or dropped buffers (gap \(String(format: "%.2f", gap), privacy: .public) s)")
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
            if localPeak > self.peakAmplitude {
                self.peakAmplitude = localPeak
            }
            if localPeak > 0.0001 {
                self.hasSignal = true
                self.lastSignalBits.store(Date().timeIntervalSince1970.bitPattern, ordering: .relaxed)
            }
        }
    }
}
