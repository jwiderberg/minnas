// Echo cancellation of the mic track, after the call, before transcription.
//
// When the call plays on speakers, the mic hears the other side as well as
// you, and Whisper writes their words a second time under "Me" (when they
// are louder than you at the mic, it writes only theirs). Call apps solve
// this live with an echo canceller: they subtract what they played from
// what the mic heard. The recorder has the same two signals on disk, the
// system track being exactly what the speakers played, so it runs the same
// kind of canceller (WebRTC's AEC3, the one in Chrome and Meet) over the
// files instead. Nothing touches the microphone during the call, and the
// recording itself is never changed: the cleaned mic goes to a temporary
// file that only the transcriber reads.
//
// Two passes, both streaming (a 90-minute call never sits in memory):
// 1. Alignment. AEC3 tracks an echo delay of up to about 300 ms, while the
//    two files can be offset by seconds (the system engine starts its file
//    at its first buffer, ScreenCaptureKit's up to ~7 s in) and their
//    clocks can drift apart. The offset is measured by cross-correlating
//    the tracks (GCC-PHAT) in 30 s blocks wherever the system track has
//    sound, and a line (offset + drift) is fitted through the blocks. No
//    line backed by most blocks means no acoustic path from the speakers
//    to the mic (headphones, a virtual mic): nothing to cancel, skipped.
// 2. Cancellation. The reference is read at the mic's clock (resampled by
//    the fitted drift) and shifted so the echo arrives 40 ms after it, and
//    both go through AEC3 in 10 ms frames at 16 kHz, Whisper's rate.

import Accelerate
import AudioToolbox
import CWebRTCAEC
import Foundation
import os

private let echoLog = Logger(subsystem: "com.jwiderberg.minnas", category: "EchoCanceller")

enum EchoCanceller {
    static let sampleRate = Double(WEBRTC_AEC_SAMPLE_RATE)
    static let frame = Int(WEBRTC_AEC_FRAME)

    /// Where the mic's echo sits relative to the system track, as a line
    /// over the recording: the two files' clocks can drift apart (a USB mic
    /// beside the built-in speakers), so the offset is fitted against time.
    struct Alignment: Equatable, Sendable {
        /// How far the echo in the mic lags the system track at the start
        /// of the mic file, in samples at `sampleRate`.
        let delaySamples: Int
        /// How much that lag grows per mic sample (clock drift; 1e-5 is
        /// 10 ppm, 36 ms an hour).
        let drift: Double
        /// Blocks on the fitted line, blocks with a confident peak, and
        /// blocks where the system track had sound at all.
        let agreeingBlocks: Int
        let confidentBlocks: Int
        let eligibleBlocks: Int
        var delaySeconds: Double { Double(delaySamples) / EchoCanceller.sampleRate }
        var driftPPM: Double { drift * 1e6 }
    }

    enum Outcome: Sendable {
        /// The cleaned mic was written; `reductionDB` is the drop in the
        /// mic track's overall energy (echo removed, speech kept).
        case cancelled(Alignment, reductionDB: Double)
        /// No acoustic echo was found; nothing was written.
        case noEcho
    }

    enum EchoError: Error, CustomStringConvertible {
        case audio(String, OSStatus)
        case cancellerUnavailable
        var description: String {
            switch self {
            case .audio(let what, let status): return "\(what) failed (OSStatus \(status))"
            case .cancellerUnavailable: return "the echo canceller could not be created"
            }
        }
    }

    /// Cleans `mic` against `reference` (the system track) into `output`, a
    /// 16 kHz mono file as long as the mic. `onProgress` gets 0…1 over both
    /// passes. Throws CancellationError when the current task is cancelled.
    static func cancel(
        mic: URL, reference: URL, output: URL, startOffset: Double? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) throws -> Outcome {
        let alignProgress: (@Sendable (Double) -> Void)? = onProgress.map { cb in { @Sendable f in cb(f * 0.2) } }
        let processProgress: (@Sendable (Double) -> Void)? = onProgress.map { cb in { @Sendable f in cb(0.2 + f * 0.8) } }
        guard let alignment = try align(mic: mic, reference: reference, lags: searchLags(startOffset: startOffset), onProgress: alignProgress) else {
            echoLog.notice("no echo of the system track in the mic track; not cancelling")
            return .noEcho
        }
        let reduction = try process(
            mic: mic, reference: reference, output: output, alignment: alignment,
            onProgress: processProgress
        )
        echoLog.notice("echo cancelled: delay \(String(format: "%.3f", alignment.delaySeconds), privacy: .public) s, drift \(String(format: "%.1f", alignment.driftPPM), privacy: .public) ppm (\(alignment.agreeingBlocks, privacy: .public)/\(alignment.confidentBlocks, privacy: .public)/\(alignment.eligibleBlocks, privacy: .public) blocks), mic energy \(String(format: "%.1f", -reduction), privacy: .public) dB")
        return .cancelled(alignment, reductionDB: reduction)
    }

    // MARK: - Alignment

    /// Correlation blocks of 30 s.
    static let blockSamples = 30 * Int(WEBRTC_AEC_SAMPLE_RATE)
    /// Lags searched when the system track's start is not known (recordings
    /// from before it was recorded). The mic file starts first and the
    /// system file at its engine's first buffer, which ScreenCaptureKit
    /// delivers up to ~7 s later, so a real echo lags by up to that much
    /// plus the acoustic delay: +10 s covers it. A lag below -50 ms is the
    /// mic's own sound coming back in the system track (a far end without
    /// echo cancellation, a monitored mic) and is never searched. Within
    /// the window that return can still look like an echo (start offset
    /// minus return delay), which only a known start offset rules out.
    static let minLagSamples = -Int(WEBRTC_AEC_SAMPLE_RATE) / 20
    static let maxLagSamples = 10 * Int(WEBRTC_AEC_SAMPLE_RATE)
    /// With the start offset known, the echo is the speaker-to-mic path on
    /// top of it: output latency plus air, from a few ms (built-in) to a few
    /// hundred (Bluetooth) and up to ~2 s (AirPlay). Searched: 100 ms before
    /// (clock jitter, and the mic gaps of ≤ 50 ms that are not padded) to 3 s
    /// after. The mic's own voice coming back left the mic before it reached
    /// the far end and returned, a network round trip of well over 100 ms,
    /// so it lands before the window.
    static let knownOffsetEarlySamples = Int(WEBRTC_AEC_SAMPLE_RATE) / 10
    static let knownOffsetLateSamples = 3 * Int(WEBRTC_AEC_SAMPLE_RATE)

    /// The lags to search. Pure, for the tests.
    static func searchLags(startOffset: Double?) -> ClosedRange<Int> {
        guard let startOffset, startOffset.isFinite else { return minLagSamples...maxLagSamples }
        let center = Int((startOffset * sampleRate).rounded())
        return (center - knownOffsetEarlySamples)...(center + knownOffsetLateSamples)
    }
    /// A block's peak must stand this far above the correlation's RMS over
    /// the searched lags. Unrelated tracks top out near 5 (the largest of
    /// ~160k Gaussian values); an acoustic echo gives 15 and up.
    static let confidenceThreshold: Float = 9
    /// Blocks within this of the fitted line agree (5 ms).
    static let agreementSamples = Int(WEBRTC_AEC_SAMPLE_RATE) / 200
    /// The drift a real device pair can have; beyond it, a fitted slope is
    /// an outlier artefact, not a clock.
    static let maxDrift = 500e-6
    /// The system track must have at least this RMS in a block (-50 dBFS)
    /// for the block to count: silence carries no echo to find.
    static let referenceFloor: Float = 0.003

    /// One block's correlation peak: its centre in the mic file, and lag.
    struct Observation: Equatable, Sendable {
        let time: Double
        let lag: Int
    }

    /// Streams both files block by block and returns the echo offset, or
    /// nil when the blocks show no consistent one.
    static func align(mic: URL, reference: URL, lags: ClosedRange<Int> = minLagSamples...maxLagSamples,
                      onProgress: (@Sendable (Double) -> Void)? = nil) throws -> Alignment? {
        let micReader = try MonoReader(url: mic, sampleRate: sampleRate)
        let refReader = try MonoReader(url: reference, sampleRate: sampleRate)
        // A window that starts seconds in (a known start offset) is searched
        // with the mic read that far ahead, so each block pair overlaps fully
        // and the correlation searches only the residual path.
        let preroll = max(0, lags.lowerBound)
        if preroll > 0 {
            var skip = [Float](repeating: 0, count: min(preroll, 16_000))
            var left = preroll
            while left > 0 {
                if skip.count > left { skip = [Float](repeating: 0, count: left) }
                let got = try micReader.read(into: &skip)
                if got == 0 { return nil }
                left -= got
            }
        }
        let searched = (lags.lowerBound - preroll)...(lags.upperBound - preroll)
        let correlator = Correlator(blockSamples: blockSamples, maxLag: max(abs(searched.lowerBound), abs(searched.upperBound)))
        let total = max(1, micReader.estimatedFrames)
        var micBlock = [Float](repeating: 0, count: blockSamples)
        var refBlock = [Float](repeating: 0, count: blockSamples)
        var observations: [Observation] = []
        var eligible = 0
        var start = preroll
        while true {
            if Task.isCancelled { throw CancellationError() }
            let m = try micReader.read(into: &micBlock)
            let r = try refReader.read(into: &refBlock)
            if m == 0 || r == 0 { break }
            let n = min(m, r)
            defer { start += m }
            onProgress?(min(1, Double(start + m) / Double(total)))
            // A short tail can't carry a reliable peak.
            guard n >= blockSamples / 3, rms(refBlock, count: n) >= referenceFloor else { continue }
            eligible += 1
            if let peak = correlator.peak(mic: micBlock, reference: refBlock, count: n, lags: searched),
               peak.confidence >= confidenceThreshold {
                observations.append(Observation(time: Double(start) + Double(n) / 2, lag: peak.lag + preroll))
            }
        }
        return decide(observations, eligibleBlocks: eligible)
    }

    /// Fits lag against time through the confident blocks and accepts the
    /// line when it is backed by a majority of them and by a fair share of
    /// all blocks that had sound. Pure, for the tests.
    static func decide(_ observations: [Observation], eligibleBlocks: Int) -> Alignment? {
        guard !observations.isEmpty else { return nil }
        // Candidate lines: a constant lag (the median) and the Theil–Sen
        // fit (median of pairwise slopes), which tolerates stray blocks.
        var candidates: [(slope: Double, intercept: Double)] = []
        let lags = observations.map { Double($0.lag) }.sorted()
        candidates.append((0, lags[lags.count / 2]))
        if observations.count >= 2 {
            var slopes: [Double] = []
            for i in 0..<observations.count {
                for j in (i + 1)..<observations.count where observations[j].time != observations[i].time {
                    slopes.append(Double(observations[j].lag - observations[i].lag) / (observations[j].time - observations[i].time))
                }
            }
            if !slopes.isEmpty {
                slopes.sort()
                let slope = slopes[slopes.count / 2]
                if abs(slope) <= maxDrift {
                    let intercepts = observations.map { Double($0.lag) - slope * $0.time }.sorted()
                    candidates.append((slope, intercepts[intercepts.count / 2]))
                }
            }
        }
        func inliers(_ line: (slope: Double, intercept: Double)) -> [Observation] {
            observations.filter { abs(Double($0.lag) - (line.intercept + line.slope * $0.time)) <= Double(agreementSamples) }
        }
        guard let best = candidates.max(by: { inliers($0).count < inliers($1).count }) else { return nil }
        let agreeing = inliers(best)
        // A majority of the confident blocks, at least two when there were
        // two blocks with sound, and at least a quarter of those blocks: one
        // stray peak in a long call is not an echo path.
        guard agreeing.count * 2 > observations.count,
              agreeing.count >= min(2, eligibleBlocks),
              agreeing.count * 4 >= eligibleBlocks else { return nil }
        // Refine on the agreeing blocks (least squares; constant when the
        // blocks can't support a slope).
        var line = best
        if agreeing.count >= 2, best.slope != 0 {
            let mt = agreeing.map(\.time).reduce(0, +) / Double(agreeing.count)
            let ml = agreeing.map { Double($0.lag) }.reduce(0, +) / Double(agreeing.count)
            let sxx = agreeing.map { ($0.time - mt) * ($0.time - mt) }.reduce(0, +)
            let sxy = agreeing.map { ($0.time - mt) * (Double($0.lag) - ml) }.reduce(0, +)
            if sxx > 0, abs(sxy / sxx) <= maxDrift {
                line = (sxy / sxx, ml - sxy / sxx * mt)
            }
        } else {
            line = (0, agreeing.map { Double($0.lag) }.sorted()[agreeing.count / 2])
        }
        return Alignment(delaySamples: Int(line.intercept.rounded()), drift: line.slope,
                         agreeingBlocks: agreeing.count, confidentBlocks: observations.count, eligibleBlocks: eligibleBlocks)
    }

    static func rms(_ x: [Float], count: Int) -> Float {
        guard count > 0 else { return 0 }
        var value: Float = 0
        x.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &value, vDSP_Length(count)) }
        return value
    }

    /// GCC-PHAT cross-correlation of two equal-length blocks: the spectra's
    /// cross-power with the magnitude divided out, so the peak marks the
    /// delay regardless of how loud or coloured the echo is.
    final class Correlator {
        let log2n: vDSP_Length
        let n: Int
        private let setup: FFTSetup
        private var a: [Float], b: [Float], c: [Float], d: [Float]

        /// `maxLag`: the largest |lag| that will be searched; the transform
        /// is long enough that no searched lag wraps around.
        init(blockSamples: Int, maxLag: Int = 0) {
            var log2n: vDSP_Length = 1
            while (1 << log2n) < 2 * max(blockSamples, maxLag + 1) { log2n += 1 }
            self.log2n = log2n
            n = 1 << Int(log2n)
            setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
            a = [Float](repeating: 0, count: n / 2); b = a; c = a; d = a
        }

        deinit { vDSP_destroy_fftsetup(setup) }

        struct Peak { let lag: Int; let confidence: Float }

        /// `lag` > 0: the mic lags the reference by that many samples. The
        /// peak is taken by magnitude, so a polarity-inverted path counts.
        func peak(mic: [Float], reference: [Float], count: Int, lags: ClosedRange<Int>) -> Peak? {
            let half = n / 2
            precondition(-lags.lowerBound < n / 2 && lags.upperBound < n / 2)
            // Pack each real block (zero-padded to n) as split complex.
            pack(mic, count: count, into: &a, &b)
            pack(reference, count: count, into: &c, &d)
            var lag = 0
            var confidence: Float = 0
            a.withUnsafeMutableBufferPointer { ar in b.withUnsafeMutableBufferPointer { br in
            c.withUnsafeMutableBufferPointer { cr in d.withUnsafeMutableBufferPointer { dr in
                var x = DSPSplitComplex(realp: ar.baseAddress!, imagp: br.baseAddress!)
                var y = DSPSplitComplex(realp: cr.baseAddress!, imagp: dr.baseAddress!)
                vDSP_fft_zrip(setup, &x, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_fft_zrip(setup, &y, 1, log2n, FFTDirection(FFT_FORWARD))
                // Bin 0 packs DC (real) and Nyquist (imag): both real, so
                // their phase transform is just the sign of the product.
                let dc = x.realp[0] * y.realp[0], ny = x.imagp[0] * y.imagp[0]
                for k in 1..<half {
                    // X · conj(Y), divided by its magnitude.
                    let re = x.realp[k] * y.realp[k] + x.imagp[k] * y.imagp[k]
                    let im = x.imagp[k] * y.realp[k] - x.realp[k] * y.imagp[k]
                    let mag = (re * re + im * im).squareRoot()
                    if mag > 1e-20 {
                        x.realp[k] = re / mag; x.imagp[k] = im / mag
                    } else {
                        x.realp[k] = 0; x.imagp[k] = 0
                    }
                }
                x.realp[0] = dc == 0 ? 0 : (dc > 0 ? 1 : -1)
                x.imagp[0] = ny == 0 ? 0 : (ny > 0 ? 1 : -1)
                vDSP_fft_zrip(setup, &x, 1, log2n, FFTDirection(FFT_INVERSE))
                // Unpack the real correlation: r[2i] = realp[i], r[2i+1] = imagp[i].
                func r(_ i: Int) -> Float { i & 1 == 0 ? x.realp[i >> 1] : x.imagp[i >> 1] }
                var best: Float = -1
                var sumSquares: Double = 0
                for l in lags {
                    let v = r(l >= 0 ? l : n + l)
                    sumSquares += Double(v) * Double(v)
                    if abs(v) > best { best = abs(v); lag = l }
                }
                let rmsValue = Float((sumSquares / Double(lags.count)).squareRoot())
                confidence = rmsValue > 0 ? best / rmsValue : 0
            } } } }
            return confidence.isFinite ? Peak(lag: lag, confidence: confidence) : nil
        }

        private func pack(_ x: [Float], count: Int, into re: inout [Float], _ im: inout [Float]) {
            let half = n / 2
            for i in 0..<half {
                let j = 2 * i
                re[i] = j < count ? x[j] : 0
                im[i] = j + 1 < count ? x[j + 1] : 0
            }
        }
    }

    // MARK: - Cancellation

    /// The echo is placed this long after the shifted reference: AEC3 needs
    /// the reference first, and an estimate that is a few milliseconds off
    /// must not put the echo before it.
    static let marginSamples = Int(WEBRTC_AEC_SAMPLE_RATE) / 25   // 40 ms
    /// AEC3 returns each sample this many samples late (its 64-sample block
    /// framing on 160-sample frames); measured, and checked by the tests.
    static let latencySamples = Int(WEBRTC_AEC_LATENCY)

    /// How the reference file is read so that it lines up with the mic: at
    /// `readRate` (above 16 kHz when the echo lags more and more, which
    /// stretches the reference to the mic's clock), after dropping `skip`
    /// samples, or after `-skip` zeros when negative. Pure, for the tests.
    static func referencePlan(_ alignment: Alignment) -> (readRate: Double, skip: Int) {
        // Mic sample m holds the echo of reference sample m·f − delay, with
        // f = 1 − drift. Read at 16 kHz / f, feed index k is reference
        // sample k·f; feeding at mic sample m the reference whose echo
        // lands `margin` mic samples later, (m + margin)·f − delay, needs
        // k = m + margin − delay / f, so skip = margin − delay / f.
        let factor = 1 - alignment.drift
        return (sampleRate / factor, Int((Double(marginSamples) - Double(alignment.delaySamples) / factor).rounded()))
    }

    /// Hands out the lined-up reference: leading zeros, the file, then
    /// zeros once it has ended.
    final class ReferenceFeed {
        private let reader: MonoReader
        private var leadingZeros: Int
        private var ended = false
        private var scratch: [Float] = []

        init(reader: MonoReader, skip: Int) throws {
            self.reader = reader
            leadingZeros = max(0, -skip)
            var remaining = max(0, skip)
            var discard = [Float](repeating: 0, count: min(max(remaining, 1), 16_000))
            while remaining > 0 {
                if discard.count > remaining { discard = [Float](repeating: 0, count: remaining) }
                let got = try reader.read(into: &discard)
                remaining -= got
                if got < discard.count { ended = true; break }
            }
        }

        /// Fills the first `count` samples of `buffer`, consuming exactly
        /// that much of the reference.
        func next(into buffer: inout [Float], count: Int) throws {
            precondition(count <= buffer.count)
            var filled = 0
            if leadingZeros > 0 {
                let z = min(leadingZeros, count)
                for i in 0..<z { buffer[i] = 0 }
                leadingZeros -= z
                filled = z
            }
            if filled < count && !ended {
                if scratch.count != count - filled { scratch = [Float](repeating: 0, count: count - filled) }
                let got = try reader.read(into: &scratch)
                for i in 0..<got { buffer[filled + i] = scratch[i] }
                filled += got
                if got < scratch.count { ended = true }
            }
            for i in filled..<count { buffer[i] = 0 }
        }
    }


    /// Runs AEC3 over the whole mic track; returns how much the mic's
    /// energy dropped, in dB. The output has exactly the mic's length and
    /// timeline (AEC3's latency is taken off the front and flushed at the end).
    static func process(
        mic: URL, reference: URL, output: URL, alignment: Alignment,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) throws -> Double {
        let plan = referencePlan(alignment)
        let micReader = try MonoReader(url: mic, sampleRate: sampleRate)
        let reference = try ReferenceFeed(reader: try MonoReader(url: reference, sampleRate: plan.readRate), skip: plan.skip)
        let writer = try MonoWriter(url: output, sampleRate: sampleRate)
        guard let aec = webrtc_aec_create() else { throw EchoError.cancellerUnavailable }
        defer { webrtc_aec_destroy(aec) }

        let chunk = frame * 100   // 1 s
        var micBuffer = [Float](repeating: 0, count: chunk)
        var refBuffer = [Float](repeating: 0, count: chunk)
        var outBuffer = [Float](repeating: 0, count: chunk)

        let total = max(1, micReader.estimatedFrames)
        var micLength = 0            // mic samples read
        var known = false            // micLength is final
        var produced = 0             // AEC3 output samples so far
        var written = 0
        var energyIn: Double = 0, energyOut: Double = 0

        // Runs `frames` frames of the buffers through AEC3 and writes the
        // output that maps onto mic samples (index − latency) within the mic.
        func run(frames: Int) throws {
            micBuffer.withUnsafeBufferPointer { mp in refBuffer.withUnsafeBufferPointer { rp in
                outBuffer.withUnsafeMutableBufferPointer { op in
                    for f in 0..<frames {
                        let o = f * frame
                        webrtc_aec_process(aec, rp.baseAddress! + o, mp.baseAddress! + o, op.baseAddress! + o)
                    }
                } } }
            let count = frames * frame
            let first = max(0, latencySamples - produced)          // still inside the latency
            var last = count
            if known { last = min(count, max(first, micLength - written + first)) }
            if last > first {
                for i in first..<last { energyOut += Double(outBuffer[i]) * Double(outBuffer[i]) }
                try writer.write(outBuffer, from: first, count: last - first)
                written += last - first
            }
            produced += count
        }

        while true {
            if Task.isCancelled { throw CancellationError() }
            let m = try micReader.read(into: &micBuffer)
            if m < chunk { known = true }
            micLength += m
            if m == 0 { break }
            for i in 0..<m { energyIn += Double(micBuffer[i]) * Double(micBuffer[i]) }
            for i in m..<chunk { micBuffer[i] = 0 }
            let frames = (m + frame - 1) / frame
            try reference.next(into: &refBuffer, count: frames * frame)
            try run(frames: frames)
            onProgress?(min(1, Double(micLength) / Double(total)))
            if known { break }
        }
        // Flush AEC3's latency with silence so the mic's last samples come out.
        for i in 0..<chunk { micBuffer[i] = 0 }
        let flushFrames = (latencySamples + frame - 1) / frame + 1
        while written < micLength {
            try reference.next(into: &refBuffer, count: flushFrames * frame)
            try run(frames: flushFrames)
        }
        try writer.close()
        guard energyIn > 0, energyOut > 0 else { return 0 }
        return 10 * log10(energyIn / energyOut)
    }
}

// MARK: - File I/O

/// Reads any file Core Audio opens (CAF, m4a, wav, …) as mono Float32 at
/// a given rate: Extended Audio File does the decoding and resampling, and
/// the channels are averaged here (a stereo system track keeps both sides).
final class MonoReader {
    private let file: ExtAudioFileRef
    private let channels: Int
    private var interleaved: [Float] = []
    /// Length in output frames, from the file's own length (approximate
    /// for compressed files; for progress only).
    let estimatedFrames: Int

    init(url: URL, sampleRate: Double) throws {
        var ref: ExtAudioFileRef?
        var status = ExtAudioFileOpenURL(url as CFURL, &ref)
        guard status == noErr, let ref else { throw EchoCanceller.EchoError.audio("opening \(url.lastPathComponent)", status) }
        file = ref
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileGetProperty(ref, kExtAudioFileProperty_FileDataFormat, &size, &format)
        guard status == noErr else { ExtAudioFileDispose(ref); throw EchoCanceller.EchoError.audio("reading the format of \(url.lastPathComponent)", status) }
        channels = max(1, Int(format.mChannelsPerFrame))
        var fileFrames: Int64 = 0
        size = UInt32(MemoryLayout<Int64>.size)
        if ExtAudioFileGetProperty(ref, kExtAudioFileProperty_FileLengthFrames, &size, &fileFrames) == noErr, format.mSampleRate > 0 {
            estimatedFrames = Int(Double(fileFrames) * sampleRate / format.mSampleRate)
        } else {
            estimatedFrames = 0
        }
        var client = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)
        status = ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard status == noErr else { ExtAudioFileDispose(ref); throw EchoCanceller.EchoError.audio("setting the read format of \(url.lastPathComponent)", status) }
    }

    deinit { ExtAudioFileDispose(file) }

    /// Fills `out` from the start; returns how many samples it got, fewer
    /// than `out.count` only at the end of the file.
    func read(into out: inout [Float]) throws -> Int {
        let want = out.count
        if interleaved.count < want * channels { interleaved = [Float](repeating: 0, count: want * channels) }
        var got = 0
        while got < want {
            var frames = UInt32(want - got)
            let status: OSStatus = interleaved.withUnsafeMutableBufferPointer { buf in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: frames * UInt32(4 * channels),
                                          mData: UnsafeMutableRawPointer(buf.baseAddress! + got * channels)))
                return ExtAudioFileRead(file, &frames, &list)
            }
            guard status == noErr else { throw EchoCanceller.EchoError.audio("reading audio", status) }
            if frames == 0 { break }
            got += Int(frames)
        }
        if channels == 1 {
            for i in 0..<got { out[i] = interleaved[i] }
        } else {
            let scale = 1 / Float(channels)
            for i in 0..<got {
                var sum: Float = 0
                for ch in 0..<channels { sum += interleaved[i * channels + ch] }
                out[i] = sum * scale
            }
        }
        return got
    }
}

/// Writes mono Float32 samples to a 16-bit CAF (half the size of float;
/// far more resolution than a transcript needs).
final class MonoWriter {
    private var file: ExtAudioFileRef?

    init(url: URL, sampleRate: Double) throws {
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var ref: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(url as CFURL, kAudioFileCAFType, &fileFormat, nil, AudioFileFlags.eraseFile.rawValue, &ref)
        guard status == noErr, let ref else { throw EchoCanceller.EchoError.audio("creating \(url.lastPathComponent)", status) }
        var client = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
            mBitsPerChannel: 32, mReserved: 0)
        status = ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard status == noErr else { ExtAudioFileDispose(ref); throw EchoCanceller.EchoError.audio("setting the write format", status) }
        file = ref
    }

    deinit { if let file { ExtAudioFileDispose(file) } }

    func write(_ samples: [Float], from start: Int = 0, count: Int) throws {
        guard let file, count > 0 else { return }
        precondition(start >= 0 && start + count <= samples.count)
        let status: OSStatus = samples.withUnsafeBufferPointer { buf in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(count * 4),
                                      mData: UnsafeMutableRawPointer(mutating: buf.baseAddress! + start)))
            return ExtAudioFileWrite(file, UInt32(count), &list)
        }
        guard status == noErr else { throw EchoCanceller.EchoError.audio("writing audio", status) }
    }

    func close() throws {
        guard let file else { return }
        self.file = nil
        let status = ExtAudioFileDispose(file)
        guard status == noErr else { throw EchoCanceller.EchoError.audio("closing the cleaned mic file", status) }
    }
}
