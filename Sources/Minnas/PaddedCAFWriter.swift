//
// The CAF file both system-audio engines write, and the padding that keeps
// it aligned with the mic: an AVAssetWriter with one audio input in the
// fixed output format (48 kHz stereo 16-bit interleaved little-endian PCM),
// a timeline end, silence fills for gaps (≤ 300 s, finite, a 2 s wait for
// the writer per 1 s chunk, a partial fill moves the timeline to where it
// stopped), and a bounded finish (10 s; on timeout the writer is abandoned,
// NEVER cancelled: per AVAssetWriter.h -cancelWriting "will block until
// writing is canceled" and "If an output file was created by the receiver
// during the writing process, -cancelWriting will delete the file" — that
// would throw away the whole system track).
//
// Thread model (why `@unchecked Sendable` is sound): the writer is
// QUEUE-CONFINED, not internally synchronized. Every method runs on the
// `queue` passed to init (ScreenCaptureKit: the SCStream sample-handler
// queue; taps: the drain queue), except:
//   - open(url:sourceFormatHint:) — before anything is delivered on the
//     queue (it sets the writer the queue then reads),
//   - cancelBeforeFirstAppend() — start-failure path, nothing delivering,
//   - finish(timeout:) — called off the queue; reads the writer reference
//     once, then does all its work on the queue.
// DEBUG builds assert the queue with dispatchPrecondition. The IOProc of the
// taps engine never touches this object. The counters live in
// CAFWriterStats (atomics), which outlives the writer: capture_health reads
// them after stop().
//
// Logging: only the lines that were identical in both engines are logged
// here, through the engine's own Logger; every engine-specific line (drops,
// rejected gaps, "padded …") stays in the engine, driven by the outcomes.
//

import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import os.log

/// Health counters of one PaddedCAFWriter, safe to read from any thread.
/// Only the writer's queue writes them, except markTimedOut().
final class CAFWriterStats: Sendable {
    private let paddedBits = Atomic<UInt64>(0)
    private let droppedCount = Atomic<UInt64>(0)
    private let failed = Atomic<Bool>(false)
    private let timedOut = Atomic<Bool>(false)

    /// Seconds of silence written into gaps so far.
    var paddedSeconds: Double { Double(bitPattern: paddedBits.load(ordering: .relaxed)) }
    /// Buffers refused because the writer input was not ready.
    var dropped: UInt64 { droppedCount.load(ordering: .relaxed) }
    /// The asset writer refused data; a stream restart can't fix the file.
    var hasFailed: Bool { failed.load(ordering: .relaxed) }
    /// A finish missed its deadline and the writer was abandoned.
    var hasTimedOut: Bool { timedOut.load(ordering: .relaxed) }

    /// Also set by an engine's own outer stop deadline.
    func markTimedOut() {
        timedOut.store(true, ordering: .relaxed)
    }

    /// Single writer (the queue), so load + store does not lose updates.
    fileprivate func addPadded(_ seconds: Double) {
        paddedBits.store((paddedSeconds + seconds).bitPattern, ordering: .relaxed)
    }

    fileprivate func noteDrop() -> UInt64 {
        droppedCount.wrappingAdd(1, ordering: .relaxed).newValue
    }

    /// True the first time only.
    fileprivate func markFailed() -> Bool {
        !failed.exchange(true, ordering: .relaxed)
    }
}

/// QUEUE-CONFINED, not internally synchronized: every method except
/// open / cancelBeforeFirstAppend / finish(timeout:) runs on `queue`.
final class PaddedCAFWriter: @unchecked Sendable {
    /// 48 kHz / 2 ch / 16-bit integer / little-endian / interleaved.
    static let outputSettings: [String: any Sendable] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48000,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    /// Upper bound on one silence fill. A restart is back in seconds; a
    /// bigger gap is a clock anomaly, and padding it could fill the disk.
    static let maxFillSeconds: Double = 300
    /// How long a gap fill waits for the writer input per chunk.
    static let gapFillReadyTimeout: Double = 2
    /// How long a finish waits for finishWriting before abandoning the writer.
    static let finishTimeout: Double = 10

    enum OpenError: Error {
        /// AVAssetWriter(outputURL:fileType:) threw.
        case create(any Error)
        /// canAdd(input) was false. Without the input, startWriting would
        /// succeed and every append would fail — a recording of nothing
        /// that looks healthy at start.
        case inputRefused
        /// startWriting() returned false; the writer's error, if any.
        case startFailed((any Error)?)
    }

    enum AppendOutcome {
        case appended
        /// The input was not ready within the wait; the buffer is not in
        /// the file and the timeline did not move. `total` counts all drops.
        case dropped(total: UInt64)
        /// Nothing was written: the writer has failed (stats.hasFailed,
        /// logged once), is not open, or CoreMedia could not build the
        /// sample buffer (out of memory).
        case writerFailed
    }

    enum GapFillOutcome {
        /// No timeline end yet (nothing appended), or the format has no
        /// stream description; nothing written.
        case noTimeline
        /// Non-finite or over maxFillSeconds; nothing written.
        case rejected(gap: Double)
        /// At or under the caller's minimum; nothing written.
        case belowMinimum(gap: Double)
        /// `seconds` of silence written (less than `gap` if the writer gave
        /// up part-way); the timeline end moved by exactly that much.
        case filled(seconds: Double, gap: Double)
    }

    let stats: CAFWriterStats
    private let queue: DispatchQueue
    private let log: Logger
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?

    // The three getters are queue-confined like the methods: `writer`,
    // `sessionStarted` and `timelineEnd` are written on the queue, so a read
    // elsewhere would race. DEBUG asserts the queue here too.
    var isOpen: Bool { assertOnQueue(); return writer != nil && input != nil }
    private var sessionStartedStorage = false
    var sessionStarted: Bool { assertOnQueue(); return sessionStartedStorage }
    private var timelineEndStorage = CMTime.invalid
    /// End of the file's timeline, in the source's time domain; invalid
    /// until the first append (or a seeded startSession).
    var timelineEnd: CMTime { assertOnQueue(); return timelineEndStorage }

    init(queue: DispatchQueue, stats: CAFWriterStats, log: Logger) {
        self.queue = queue
        self.stats = stats
        self.log = log
    }

    private func assertOnQueue() {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(queue))
        #endif
    }

    // MARK: Open / cancel (before delivery starts)

    func open(url: URL, sourceFormatHint: CMFormatDescription?) throws(OpenError) {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .caf)
        } catch {
            throw .create(error)
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.outputSettings,
                                       sourceFormatHint: sourceFormatHint)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw .inputRefused }
        writer.add(input)
        guard writer.startWriting() else { throw .startFailed(writer.error) }
        self.writer = writer
        self.input = input
    }

    /// Start-failure path only (nothing appended, the file is empty):
    /// cancelWriting deletes it.
    func cancelBeforeFirstAppend() {
        writer?.cancelWriting()
        writer = nil
        input = nil
    }

    // MARK: Writing (queue only)

    /// `seedTimeline`: the timeline end starts at `t` (taps, whose first
    /// append comes right after); otherwise it stays invalid until the first
    /// append (ScreenCaptureKit).
    func startSession(atSourceTime t: CMTime, seedTimeline: Bool) {
        assertOnQueue()
        guard let writer else { return }
        writer.startSession(atSourceTime: t)
        sessionStartedStorage = true
        if seedTimeline { timelineEndStorage = t }
    }

    /// Appends a delivered buffer (ScreenCaptureKit). The timeline end
    /// becomes pts + duration also after a failed append, so a failure
    /// never makes the next fill pad over audio that was offered. A drop
    /// leaves it where it was, so the next fill covers the hole.
    /// `readyWait` 0 = drop at once when the input is not ready.
    func append(_ buffer: CMSampleBuffer, readyWait: Double) -> AppendOutcome {
        assertOnQueue()
        guard let writer, let input else { return .writerFailed }
        guard waitUntilReady(input, writer: writer, seconds: readyWait) else {
            return .dropped(total: stats.noteDrop())
        }
        let ok = input.append(buffer) || !noteFailure(writer)
        timelineEndStorage = CMTimeAdd(buffer.presentationTimeStamp, buffer.duration)
        return ok ? .appended : .writerFailed
    }

    /// Appends `frames` frames of `format` copied from `data` at the
    /// timeline end (taps). The timeline moves only when the append went in
    /// (or failed without the writer failing).
    func appendFrames(_ data: UnsafeRawPointer, frames: Int, format: CMAudioFormatDescription,
                      readyWait: Double) -> AppendOutcome {
        assertOnQueue()
        guard let writer, let input, frames > 0,
              let buffer = Self.sampleBuffer(copying: data, frames: frames, format: format, pts: timelineEnd)
        else { return .writerFailed }
        guard waitUntilReady(input, writer: writer, seconds: readyWait) else {
            return .dropped(total: stats.noteDrop())
        }
        if !input.append(buffer), noteFailure(writer) { return .writerFailed }
        advance(by: frames, format: format)
        return .appended
    }

    /// Silence covering [timelineEnd, pts) (ScreenCaptureKit). Checked in
    /// this order: no timeline → non-finite or over the cap → at or under
    /// `minimum` → fill.
    func fillGap(upTo pts: CMTime, format: CMAudioFormatDescription, minimum: Double) -> GapFillOutcome {
        assertOnQueue()
        guard timelineEnd.isValid else { return .noTimeline }
        let gap = CMTimeSubtract(pts, timelineEnd).seconds
        guard gap.isFinite, gap <= Self.maxFillSeconds else { return .rejected(gap: gap) }
        guard gap > minimum else { return .belowMinimum(gap: gap) }
        return fill(gap: gap, format: format)
    }

    /// Silence covering `seconds` from the timeline end (taps, which gates
    /// the gap itself). Non-finite or over the cap → rejected.
    func fillGap(seconds gap: Double, format: CMAudioFormatDescription) -> GapFillOutcome {
        assertOnQueue()
        guard timelineEnd.isValid else { return .noTimeline }
        guard gap.isFinite, gap <= Self.maxFillSeconds else { return .rejected(gap: gap) }
        return fill(gap: gap, format: format)
    }

    // MARK: Finish

    /// On the queue: marks the input finished and waits at most `timeout`
    /// for finishWriting. True when it completed in time (or the writer was
    /// never opened). On timeout stats.markTimedOut() and the writer is
    /// abandoned; a finish that lands later still finalises the file.
    func finishBlocking(timeout: Double) -> Bool {
        assertOnQueue()
        guard let writer, let input else { return true }
        self.writer = nil
        self.input = nil
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        // The handler holds the writer until AVFoundation is done with it.
        nonisolated(unsafe) let keepAlive = writer
        let stats = self.stats
        let log = self.log
        writer.finishWriting {
            if stats.hasTimedOut {
                log.notice("finishWriting completed after the deadline (writer status \(keepAlive.status.rawValue, privacy: .public))")
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .timedOut else { return true }
        stats.markTimedOut()
        log.error("finishWriting did not complete within \(Int(timeout), privacy: .public) s (writer status \(writer.status.rawValue, privacy: .public)); abandoning the writer without cancelWriting, which would delete the file")
        return false
    }

    /// Off the queue: the finish runs on the queue and races a deadline
    /// fired from a global queue, so even a blocked queue can't hold the
    /// caller past `timeout`. True when finishWriting completed in time (or
    /// the writer was never opened). The writer reference is released on
    /// the queue, so isOpen is false for any buffer delivered after it.
    func finish(timeout: Double) async -> Bool {
        // Read once, before the hop: open set it before delivery started,
        // and only the queue closure below clears it.
        guard let writer else { return true }
        nonisolated(unsafe) let keepAlive = writer
        let stats = self.stats
        let log = self.log
        let latch = FinishLatch()
        let finished: Bool = await withCheckedContinuation { cont in
            queue.async { [self] in
                let input = self.input
                self.writer = nil
                self.input = nil
                guard let input else {
                    if latch.claim() { cont.resume(returning: true) }
                    return
                }
                input.markAsFinished()
                keepAlive.finishWriting {
                    if latch.claim() {
                        cont.resume(returning: true)
                    } else {
                        log.notice("finishWriting completed after the deadline (writer status \(keepAlive.status.rawValue, privacy: .public))")
                    }
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                if latch.claim() {
                    stats.markTimedOut()
                    cont.resume(returning: false)
                }
            }
        }
        if !finished {
            log.error("finishWriting did not complete within \(Int(timeout), privacy: .public) s (writer status \(keepAlive.status.rawValue, privacy: .public)); abandoning the writer without cancelWriting, which would delete the file")
        }
        return finished
    }

    // MARK: Sample buffers

    /// A CMSampleBuffer of `frames` frames in `format`: a copy of `data`, or
    /// zeros when `data` is nil. Bytes per frame = mBytesPerFrame ×
    /// (non-interleaved ? channels : 1), one contiguous block.
    static func sampleBuffer(copying data: UnsafeRawPointer?, frames: Int, format: CMAudioFormatDescription,
                             pts: CMTime) -> CMSampleBuffer? {
        guard frames > 0, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return nil }
        let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bytes = frames * Int(asbd.mBytesPerFrame) * (nonInterleaved ? Int(asbd.mChannelsPerFrame) : 1)
        guard bytes > 0 else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { return nil }
        let filled = data.map {
            CMBlockBufferReplaceDataBytes(with: $0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        } ?? CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        guard filled == kCMBlockBufferNoErr else { return nil }
        var buffer: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &buffer)
        return status == noErr ? buffer : nil
    }

    // MARK: Private (queue only)

    /// Not the realtime thread, so a short wait is fine. `seconds` 0 checks
    /// once.
    private func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter, seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        var ready = input.isReadyForMoreMediaData
        while !ready, writer.status == .writing, Date() < deadline {
            usleep(2_000)
            ready = input.isReadyForMoreMediaData
        }
        return ready
    }

    /// After a refused append: true (and logged once) when the writer has
    /// failed for good.
    private func noteFailure(_ writer: AVAssetWriter) -> Bool {
        guard writer.status == .failed else { return false }
        if stats.markFailed() {
            log.error("asset writer failed: \(writer.error?.localizedDescription ?? "unknown", privacy: .public)")
        }
        return true
    }

    private func advance(by frames: Int, format: CMAudioFormatDescription) {
        guard let rate = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate else { return }
        timelineEndStorage = CMTimeAdd(timelineEnd, CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate)))
    }

    /// Zeros in 1 s chunks from the timeline end. A chunk the input is not
    /// ready for within gapFillReadyTimeout ends the fill (after
    /// markAsFinished or a writer failure the input never becomes ready
    /// again); the timeline end is wherever the fill stopped, so the next
    /// fill does not pad the same stretch again.
    private func fill(gap: Double, format: CMAudioFormatDescription) -> GapFillOutcome {
        guard let writer, let input,
              let rate = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate,
              rate > 0 else { return .noTimeline }
        var remaining = Int(gap * rate)
        var written = 0
        while remaining > 0 {
            let frames = min(remaining, Int(rate))
            guard let silent = Self.sampleBuffer(copying: nil, frames: frames, format: format, pts: timelineEnd) else { break }
            guard waitUntilReady(input, writer: writer, seconds: Self.gapFillReadyTimeout) else {
                log.error("gap fill gave up: writer input not ready after \(Int(Self.gapFillReadyTimeout), privacy: .public) s (writer status \(writer.status.rawValue, privacy: .public))")
                break
            }
            guard input.append(silent) else { break }
            written += frames
            remaining -= frames
            advance(by: frames, format: format)
        }
        let seconds = Double(written) / rate
        stats.addPadded(seconds)
        return .filled(seconds: seconds, gap: gap)
    }
}
