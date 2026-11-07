import AVFoundation
import CoreMedia
import Foundation
import Testing
import os.log
@testable import Minnas

/// PaddedCAFWriter against a real CAF in a temp directory, driven on a test
/// queue the way the engines drive it on their write queues, and read back
/// with AVAudioFile.
// Serialized: each test blocks a cooperative thread in `queue.sync` (and
// finishBlocking waits on a semaphore) while AVFoundation finishes the file
// on its own queue. Run in parallel on a two-core CI runner, the suite
// starved itself until the 10 s finish deadline fired (2026-11-07). The
// finish calls use a generous timeout for the same reason: the tests prove
// the writer finishes, not the production deadline, which
// constantsAreUnchanged pins.
@Suite(.serialized) struct PaddedCAFWriterTests {
    /// Long enough for a cold hosted runner; the production value is
    /// PaddedCAFWriter.finishTimeout.
    static let testFinishTimeout: Double = 60

    private static let rate: Double = 48000
    private let log = Logger(subsystem: "com.jwiderberg.minnas", category: "PaddedCAFWriterTests")

    // MARK: Helpers

    private static func format(float: Bool, bits: UInt32, interleaved: Bool, channels: UInt32 = 2) -> CMAudioFormatDescription {
        var flags: AudioFormatFlags = (float ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) | kAudioFormatFlagIsPacked
        if !interleaved { flags |= kAudioFormatFlagIsNonInterleaved }
        let bytesPerSample = bits / 8
        let bytesPerFrame = interleaved ? bytesPerSample * channels : bytesPerSample
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0)
        var desc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                                    magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                    formatDescriptionOut: &desc)
        precondition(status == noErr && desc != nil)
        return desc!
    }

    /// The taps engine's ring format: 48 kHz interleaved stereo Float32.
    private static let tapFormat = format(float: true, bits: 32, interleaved: true)

    private struct Fixture {
        let url: URL
        let queue: DispatchQueue
        let stats: CAFWriterStats
        let writer: PaddedCAFWriter
    }

    private func makeWriter(open: Bool = true) throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("padded-caf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("system.caf")
        let queue = DispatchQueue(label: "test.padded-caf.\(UUID().uuidString)")
        let stats = CAFWriterStats()
        let writer = PaddedCAFWriter(queue: queue, stats: stats, log: log)
        if open { try writer.open(url: url, sourceFormatHint: Self.tapFormat) }
        return Fixture(url: url, queue: queue, stats: stats, writer: writer)
    }

    private static func seconds(_ s: Double) -> CMTime { CMTime(value: CMTimeValue(s * rate), timescale: CMTimeScale(rate)) }

    /// `seconds` of interleaved stereo Float32 at a constant 0.25.
    private static func appendTone(_ writer: PaddedCAFWriter, seconds: Double) -> PaddedCAFWriter.AppendOutcome {
        let frames = Int(seconds * rate)
        let samples = [Float](repeating: 0.25, count: frames * 2)
        return samples.withUnsafeBytes { raw in
            writer.appendFrames(raw.baseAddress!, frames: frames, format: tapFormat, readyWait: 2)
        }
    }

    private static func isAppended(_ outcome: PaddedCAFWriter.AppendOutcome) -> Bool {
        if case .appended = outcome { return true }
        return false
    }

    /// Frames in the file, plus the first channel's samples.
    private static func readBack(_ url: URL) throws -> (frames: Int64, rate: Double, left: [Float]) {
        let file = try AVAudioFile(forReading: url)
        let frames = file.length
        guard frames > 0 else { return (0, file.processingFormat.sampleRate, []) }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
        try file.read(into: buffer)
        let left = try #require(buffer.floatChannelData?[0])
        return (frames, file.processingFormat.sampleRate, Array(UnsafeBufferPointer(start: left, count: Int(buffer.frameLength))))
    }

    // MARK: Constants

    @Test func constantsAreUnchanged() {
        #expect(PaddedCAFWriter.maxFillSeconds == 300)
        #expect(PaddedCAFWriter.gapFillReadyTimeout == 2)
        #expect(PaddedCAFWriter.finishTimeout == 10)
        #expect(PaddedCAFWriter.outputSettings[AVSampleRateKey] as? Int == 48000)
        #expect(PaddedCAFWriter.outputSettings[AVNumberOfChannelsKey] as? Int == 2)
        #expect(PaddedCAFWriter.outputSettings[AVLinearPCMBitDepthKey] as? Int == 16)
        #expect(PaddedCAFWriter.outputSettings[AVLinearPCMIsFloatKey] as? Bool == false)
        #expect(PaddedCAFWriter.outputSettings[AVLinearPCMIsBigEndianKey] as? Bool == false)
        #expect(PaddedCAFWriter.outputSettings[AVLinearPCMIsNonInterleaved] as? Bool == false)
    }

    // MARK: Append + fill

    /// 1 s of audio, a fill to 3 s, 1 s more: a 4.00 s file whose middle
    /// 2 s are zeros, and 2.00 s padded.
    @Test func appendFillAppendGivesFourSeconds() throws {
        let f = try makeWriter()
        let (first, fill, second, end, finished) = f.queue.sync {
            f.writer.startSession(atSourceTime: .zero, seedTimeline: true)
            let first = Self.appendTone(f.writer, seconds: 1)
            let fill = f.writer.fillGap(upTo: Self.seconds(3), format: Self.tapFormat, minimum: 0.05)
            let second = Self.appendTone(f.writer, seconds: 1)
            let end = f.writer.timelineEnd
            return (first, fill, second, end, f.writer.finishBlocking(timeout: Self.testFinishTimeout))
        }
        #expect(Self.isAppended(first))
        #expect(Self.isAppended(second))
        guard case .filled(let padded, let gap) = fill else {
            Issue.record("expected .filled, got \(fill)")
            return
        }
        #expect(padded == 2.0)
        #expect(gap == 2.0)
        #expect(end == Self.seconds(4))
        #expect(finished)
        #expect(f.stats.paddedSeconds == 2.0)
        #expect(f.stats.dropped == 0)
        #expect(!f.stats.hasFailed)
        #expect(!f.stats.hasTimedOut)
        #expect(f.queue.sync { !f.writer.isOpen })

        let back = try Self.readBack(f.url)
        #expect(back.rate == 48000)
        #expect(back.frames == 4 * 48000)
        #expect(String(format: "%.2f", Double(back.frames) / back.rate) == "4.00")
        // Tone, silence, tone.
        #expect(abs(back.left[24_000] - 0.25) < 0.001)
        #expect(back.left[48_000..<144_000].allSatisfy { $0 == 0 })
        #expect(abs(back.left[168_000] - 0.25) < 0.001)
    }

    /// 301 s and NaN are rejected, 0.04 s is under the 0.05 minimum; none
    /// of them writes anything or moves the timeline.
    @Test func rejectedAndBelowMinimumGapsLeaveTheFileUnchanged() throws {
        let f = try makeWriter()
        let results = f.queue.sync {
            f.writer.startSession(atSourceTime: .zero, seedTimeline: true)
            _ = Self.appendTone(f.writer, seconds: 1)
            let over = f.writer.fillGap(upTo: Self.seconds(1 + 301), format: Self.tapFormat, minimum: 0.05)
            let nan = f.writer.fillGap(upTo: .invalid, format: Self.tapFormat, minimum: 0.05)
            let small = f.writer.fillGap(upTo: Self.seconds(1.04), format: Self.tapFormat, minimum: 0.05)
            let overSeconds = f.writer.fillGap(seconds: 301, format: Self.tapFormat)
            let nanSeconds = f.writer.fillGap(seconds: .nan, format: Self.tapFormat)
            let end = f.writer.timelineEnd
            _ = f.writer.finishBlocking(timeout: Self.testFinishTimeout)
            return (over, nan, small, overSeconds, nanSeconds, end)
        }
        if case .rejected(let gap) = results.0 { #expect(abs(gap - 301) < 1e-9) } else { Issue.record("301 s: \(results.0)") }
        if case .rejected(let gap) = results.1 { #expect(gap.isNaN) } else { Issue.record("NaN: \(results.1)") }
        if case .belowMinimum(let gap) = results.2 { #expect(abs(gap - 0.04) < 1e-9) } else { Issue.record("0.04 s: \(results.2)") }
        if case .rejected = results.3 {} else { Issue.record("301 s (seconds form): \(results.3)") }
        if case .rejected = results.4 {} else { Issue.record("NaN (seconds form): \(results.4)") }
        #expect(results.5 == Self.seconds(1))
        #expect(f.stats.paddedSeconds == 0)
        #expect(try Self.readBack(f.url).frames == 48000)
    }

    /// ScreenCaptureKit's form: no seeded timeline, so a fill before the
    /// first append has nothing to measure from; append sets the end to
    /// pts + duration.
    @Test func unseededTimelineStartsAtTheFirstAppend() throws {
        let f = try makeWriter()
        let (before, appended, end) = f.queue.sync {
            f.writer.startSession(atSourceTime: Self.seconds(10), seedTimeline: false)
            let before = f.writer.fillGap(upTo: Self.seconds(12), format: Self.tapFormat, minimum: 0.05)
            let samples = [Float](repeating: 0.25, count: 4800 * 2)
            let buffer = samples.withUnsafeBytes {
                PaddedCAFWriter.sampleBuffer(copying: $0.baseAddress, frames: 4800, format: Self.tapFormat, pts: Self.seconds(10))
            }
            let appended = buffer.map { f.writer.append($0, readyWait: 0) }
            let end = f.writer.timelineEnd
            _ = f.writer.finishBlocking(timeout: Self.testFinishTimeout)
            return (before, appended, end)
        }
        if case .noTimeline = before {} else { Issue.record("expected .noTimeline, got \(before)") }
        #expect(appended.map(Self.isAppended) == true)
        #expect(end == Self.seconds(10.1))
    }

    // MARK: Sample buffers

    @Test func sampleBufferNonInterleavedFloat32Stereo() throws {
        let format = Self.format(float: true, bits: 32, interleaved: false)
        let frames = 480
        let source = (0..<(frames * 2)).map { Float($0) }
        let buffer = try #require(source.withUnsafeBytes {
            PaddedCAFWriter.sampleBuffer(copying: $0.baseAddress, frames: frames, format: format, pts: .zero)
        })
        #expect(buffer.numSamples == frames)
        let block = try #require(buffer.dataBuffer)
        // 4 bytes per frame per channel buffer × 2 channels, one block.
        #expect(CMBlockBufferGetDataLength(block) == frames * 4 * 2)
        var copy = [Float](repeating: -1, count: frames * 2)
        let status = copy.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frames * 8, destination: $0.baseAddress!)
        }
        #expect(status == kCMBlockBufferNoErr)
        #expect(copy == source)
    }

    @Test func sampleBufferInterleavedInt16Stereo() throws {
        let format = Self.format(float: false, bits: 16, interleaved: true)
        let frames = 480
        let silent = try #require(PaddedCAFWriter.sampleBuffer(copying: nil, frames: frames, format: format, pts: Self.seconds(1)))
        #expect(silent.numSamples == frames)
        #expect(silent.presentationTimeStamp == Self.seconds(1))
        let block = try #require(silent.dataBuffer)
        #expect(CMBlockBufferGetDataLength(block) == frames * 4)
        var copy = [Int16](repeating: 7, count: frames * 2)
        let status = copy.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frames * 4, destination: $0.baseAddress!)
        }
        #expect(status == kCMBlockBufferNoErr)
        #expect(copy.allSatisfy { $0 == 0 })
    }

    @Test func sampleBufferRefusesZeroFrames() {
        #expect(PaddedCAFWriter.sampleBuffer(copying: nil, frames: 0, format: Self.tapFormat, pts: .zero) == nil)
    }

    // MARK: Finish

    /// The off-queue form, as ScreenCaptureKit's stop() uses it.
    @Test func asyncFinishCompletesInTime() async throws {
        let f = try makeWriter()
        f.queue.sync {
            f.writer.startSession(atSourceTime: .zero, seedTimeline: true)
            _ = Self.appendTone(f.writer, seconds: 0.5)
        }
        let finished = await f.writer.finish(timeout: Self.testFinishTimeout)
        #expect(finished)
        #expect(!f.stats.hasTimedOut)
        #expect(f.queue.sync { f.writer.isOpen } == false)
        #expect(try Self.readBack(f.url).frames == 24_000)
    }

    @Test func neverOpenedFinishReturnsTrue() async throws {
        let blocking = try makeWriter(open: false)
        #expect(blocking.queue.sync { blocking.writer.finishBlocking(timeout: 1) })
        let nonBlocking = try makeWriter(open: false)
        #expect(await nonBlocking.writer.finish(timeout: 1))
        #expect(!blocking.stats.hasTimedOut)
        #expect(!nonBlocking.stats.hasTimedOut)
    }

    @Test func markTimedOutLatches() {
        let stats = CAFWriterStats()
        #expect(!stats.hasTimedOut)
        stats.markTimedOut()
        #expect(stats.hasTimedOut)
    }
}
