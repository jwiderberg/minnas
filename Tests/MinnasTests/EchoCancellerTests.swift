import AVFoundation
import Foundation
import Testing
@testable import Minnas

/// Echo cancellation: the alignment maths on its own, then the whole
/// pipeline on synthetic files in the formats the app records (48 kHz mono
/// mic, 48 kHz stereo system track).
@Suite struct EchoCancellerTests {
    // MARK: signals

    /// Deterministic white noise (xorshift), so the tests never flake.
    static func noise(_ count: Int, seed: UInt64, amplitude: Float = 0.1) -> [Float] {
        var state = seed &* 2 &+ 1   // odd and distinct for every seed
        return (0..<count).map { _ in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return (Float(state % 20_001) / 10_000 - 1) * amplitude
        }
    }

    /// Speech-like: noise gated on and off in 300 ms syllables, with gaps.
    static func talk(_ count: Int, seed: UInt64, rate: Int, from: Int = 0, to: Int = .max) -> [Float] {
        let base = noise(count, seed: seed, amplitude: 0.2)
        let syllable = rate * 3 / 10
        return (0..<count).map { i in
            guard i >= from, i < to else { return 0 }
            return (i / syllable) % 3 == 2 ? 0 : base[i]
        }
    }

    /// The echo path: delay, a short room tail, attenuation.
    static func echo(of x: [Float], delay: Int, count: Int) -> [Float] {
        let taps: [(Int, Float)] = [(0, 0.5), (7, 0.25), (23, -0.15), (61, 0.08), (149, 0.04)]
        var y = [Float](repeating: 0, count: count)
        for (i, v) in x.enumerated() where v != 0 {
            for (k, g) in taps where i + delay + k < count && i + delay + k >= 0 { y[i + delay + k] += v * g }
        }
        return y
    }

    static func energy(_ x: [Float], _ range: Range<Int>) -> Double {
        range.clamped(to: 0..<x.count).reduce(0) { $0 + Double(x[$1]) * Double(x[$1]) }
    }

    static func write(_ samples: [Float], channels: AVAudioChannelCount, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for ch in 0..<Int(channels) {
            for i in 0..<samples.count { buffer.floatChannelData![ch][i] = samples[i] }
        }
        try file.write(from: buffer)
    }

    static func read16k(_ url: URL) throws -> [Float] {
        let reader = try MonoReader(url: url, sampleRate: 16_000)
        var out: [Float] = []
        var chunk = [Float](repeating: 0, count: 16_000)
        while true {
            let n = try reader.read(into: &chunk)
            if n == 0 { break }
            out += chunk[0..<n]
        }
        return out
    }

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("echo-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The echo path at a lag that can drift: `delay(t) = delay + drift·t`
    /// samples, linearly interpolated, through a short room tail.
    static func driftingEcho(of x: [Float], delay: Double, drift: Double, count: Int, gain: Float = 1) -> [Float] {
        let taps: [(Int, Float)] = [(0, 0.5), (7, 0.25), (23, -0.15), (61, 0.08), (149, 0.04)]
        var y = [Float](repeating: 0, count: count)
        for t in 0..<count {
            let src = Double(t) - (delay + drift * Double(t))
            var sum: Float = 0
            for (k, g) in taps {
                let p = src - Double(k)
                let i = Int(p.rounded(.down))
                guard i >= 0, i + 1 < x.count else { continue }
                let f = Float(p - Double(i))
                sum += g * (x[i] * (1 - f) + x[i + 1] * f)
            }
            y[t] = sum * gain
        }
        return y
    }

    static func files(mic: [Float], system: [Float], systemChannels: AVAudioChannelCount = 2) throws -> (dir: URL, mic: URL, system: URL, out: URL) {
        let dir = try tempDir()
        let micURL = dir.appendingPathComponent("mic.caf"), sysURL = dir.appendingPathComponent("system.caf")
        try write(mic, channels: 1, to: micURL)
        try write(system, channels: systemChannels, to: sysURL)
        return (dir, micURL, sysURL, dir.appendingPathComponent("clean.caf"))
    }

    static func db(_ a: Double, over b: Double) -> Double { 10 * log10(max(1e-12, a) / max(1e-12, b)) }

    // MARK: alignment

    @Test func correlatorFindsLagsAndPolarity() {
        let n = 80_000   // 5 s at 16 kHz
        let correlator = EchoCanceller.Correlator(blockSamples: n)
        let reference = Self.noise(n, seed: 7)
        for (lag, gain) in [(0, Float(1)), (1, 1), (2_345, 1), (-500, 1), (48_000, 1), (2_345, -1)] {
            let echo = Self.driftingEcho(of: reference, delay: Double(lag), drift: 0, count: n, gain: gain)
            let mic = zip(echo, Self.noise(n, seed: 99, amplitude: 0.02)).map { $0 + $1 }
            let peak = correlator.peak(mic: mic, reference: reference, count: n, lags: -800...60_000)
            #expect(peak?.lag == lag, "lag \(lag) gain \(gain)")
            #expect((peak?.confidence ?? 0) >= EchoCanceller.confidenceThreshold)
        }
    }

    @Test func correlatorStaysBelowThresholdForUnrelatedTracks() {
        let n = EchoCanceller.blockSamples
        let correlator = EchoCanceller.Correlator(blockSamples: n)
        for seed: UInt64 in [1, 2, 3] {
            let peak = correlator.peak(mic: Self.noise(n, seed: seed * 10), reference: Self.noise(n, seed: seed * 10 + 1), count: n,
                                       lags: EchoCanceller.minLagSamples...EchoCanceller.maxLagSamples)
            #expect((peak?.confidence ?? 0) < EchoCanceller.confidenceThreshold)
        }
    }

    static func obs(_ pairs: [(Double, Int)]) -> [EchoCanceller.Observation] {
        pairs.map { EchoCanceller.Observation(time: $0.0, lag: $0.1) }
    }

    @Test func decideFitsAConstantLag() {
        #expect(EchoCanceller.decide([], eligibleBlocks: 3) == nil)
        let a = EchoCanceller.decide(Self.obs([(0, 1_000), (1, 1_010), (2, 990), (3, 1_005), (4, 40_000)].map { ($0.0 * 480_000, $0.1) }), eligibleBlocks: 5)
        #expect(a.map { abs($0.delaySamples - 1_002) <= 10 } == true)
        #expect(a?.agreeingBlocks == 4)
        #expect(a?.drift == 0)
        // No majority on one line: no consistent echo path.
        #expect(EchoCanceller.decide(Self.obs([(0, 100), (480_000, 9_000), (960_000, 20_000), (1_440_000, 50_000)]), eligibleBlocks: 4) == nil)
    }

    @Test func decideFollowsClockDrift() {
        // 100 ppm over 60 blocks (30 min): the lag walks 180 ms.
        let drift = 100e-6
        let points = (0..<60).map { i -> (Double, Int) in
            let t = Double(i) * 480_000 + 240_000
            return (t, Int((5_000 + drift * t).rounded()))
        }
        let a = EchoCanceller.decide(Self.obs(points), eligibleBlocks: 60)
        #expect(a != nil)
        #expect(abs((a?.drift ?? 0) - drift) < 2e-6)
        #expect(abs((a?.delaySamples ?? 0) - 5_000) <= 3)
        #expect(a?.agreeingBlocks == 60)
    }

    @Test func decideRejectsAStrayBlock() {
        // One confident block among many with sound is not an echo path...
        #expect(EchoCanceller.decide(Self.obs([(240_000, 12_000)]), eligibleBlocks: 5) == nil)
        // ...but a short call with one block of sound can have one.
        #expect(EchoCanceller.decide(Self.obs([(240_000, 12_000)]), eligibleBlocks: 1)?.delaySamples == 12_000)
    }

    @Test func referencePlanLinesTheReferenceUp() {
        func alignment(_ delay: Int, _ drift: Double) -> EchoCanceller.Alignment {
            .init(delaySamples: delay, drift: drift, agreeingBlocks: 1, confidentBlocks: 1, eligibleBlocks: 1)
        }
        let still = EchoCanceller.referencePlan(alignment(16_000, 0))
        #expect(still.readRate == 16_000)
        #expect(still.skip == EchoCanceller.marginSamples - 16_000)
        #expect(EchoCanceller.referencePlan(alignment(-800, 0)).skip == EchoCanceller.marginSamples + 800)
        // The echo lags more and more: read the reference faster.
        #expect(EchoCanceller.referencePlan(alignment(0, 100e-6)).readRate > 16_000)
    }

    // MARK: whole pipeline

    /// The far side talks 0–8 s; its echo reaches the mic `offset` s later;
    /// you talk for 4 s after the echo has died away.
    static func scenario(offset: Double, rate: Int = 48_000) throws -> (EchoCanceller.Outcome, clean: [Float], mic: [Float], nearStart: Int, cleanup: URL) {
        let nearStart = Int((8 + offset + 0.5) * Double(rate))
        let n = nearStart + 4 * rate
        let far = talk(n, seed: 11, rate: rate, to: 8 * rate)
        let near = talk(n, seed: 23, rate: rate, from: nearStart)
        let echo = driftingEcho(of: far, delay: offset * Double(rate), drift: 0, count: n)
        let floor = noise(n, seed: 5, amplitude: 0.0005)
        let mic = (0..<n).map { echo[$0] + near[$0] + floor[$0] }
        let f = try files(mic: mic, system: far)
        let outcome = try EchoCanceller.cancel(mic: f.mic, reference: f.system, output: f.out)
        let clean = (try? read16k(f.out)) ?? []
        return (outcome, clean, try read16k(f.mic), nearStart / 3, f.dir)
    }

    @Test(arguments: [0.75, 3.5])
    func cancelsEchoAndKeepsTheNearSpeaker(offset: Double) throws {
        let (outcome, clean, mic16, nearStart, dir) = try Self.scenario(offset: offset)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case .cancelled(let alignment, _) = outcome else {
            Issue.record("expected the echo to be found, got \(outcome)")
            return
        }
        #expect(abs(alignment.delaySamples - Int(offset * 16_000)) <= 2)
        #expect(clean.count == mic16.count)
        let farOnly = (3 * 16_000)..<(7 * 16_000)
        let removed = Self.db(Self.energy(mic16, farOnly), over: Self.energy(clean, farOnly))
        #expect(removed >= 25, "echo reduced by only \(removed) dB")
        let nearOnly = (nearStart + 16_000)..<(mic16.count - 1_600)
        let level = Self.db(Self.energy(clean, nearOnly), over: Self.energy(mic16, nearOnly))
        #expect(abs(level) <= 1.5, "near speaker changed by \(level) dB")
    }

    /// AEC3's latency is taken off: the output sits on the mic's timeline
    /// to the sample, and keeps its last samples.
    @Test func outputIsSampleAlignedWithTheMic() throws {
        let rate = 48_000, n = 6 * rate
        let near = Self.talk(n, seed: 41, rate: rate, from: rate)
        let f = try Self.files(mic: near, system: [Float](repeating: 0, count: n))
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let still = EchoCanceller.Alignment(delaySamples: 0, drift: 0, agreeingBlocks: 1, confidentBlocks: 1, eligibleBlocks: 1)
        _ = try EchoCanceller.process(mic: f.mic, reference: f.system, output: f.out, alignment: still)
        let clean = try Self.read16k(f.out), mic16 = try Self.read16k(f.mic)
        #expect(clean.count == mic16.count)
        // The best-matching shift between input and output is zero.
        let range = (2 * 16_000)..<(5 * 16_000)
        var best = (corr: -Double.infinity, lag: 0)
        for lag in -200...200 {
            var c = 0.0
            for i in range { c += Double(mic16[i]) * Double(clean[i + lag]) }
            if c > best.corr { best = (c, lag) }
        }
        #expect(best.lag == 0)
        // The tail made it out (the last 100 ms is not silence).
        let tail = (mic16.count - 1_600)..<mic16.count
        #expect(Self.db(Self.energy(clean, tail), over: Self.energy(mic16, tail)) > -3)
    }

    /// The two clocks drift 200 ppm apart over 90 s (18 ms, past the 5 ms a
    /// fixed lag allows); the fitted line follows it and the reference is
    /// read at the mic's clock. (Within one 30 s block the lag moves 6 ms,
    /// which blurs each block's peak, hence the loose tolerance.)
    @Test func followsClockDrift() throws {
        let rate = 48_000, n = 90 * rate
        let far = Self.talk(n, seed: 13, rate: rate)
        let echo = Self.driftingEcho(of: far, delay: 0.4 * Double(rate), drift: 200e-6, count: n)
        let mic = zip(echo, Self.noise(n, seed: 3, amplitude: 0.0005)).map { $0 + $1 }
        let f = try Self.files(mic: mic, system: far)
        defer { try? FileManager.default.removeItem(at: f.dir) }
        guard case .cancelled(let alignment, _) = try EchoCanceller.cancel(mic: f.mic, reference: f.system, output: f.out) else {
            Issue.record("drifting echo not found")
            return
        }
        #expect(abs(alignment.driftPPM - 200) < 50, "drift \(alignment.driftPPM) ppm")
        let clean = try Self.read16k(f.out), mic16 = try Self.read16k(f.mic)
        // Removed at the end too, where the start's lag would be 18 ms off.
        let late = (70 * 16_000)..<(88 * 16_000)
        let removed = Self.db(Self.energy(mic16, late), over: Self.energy(clean, late))
        #expect(removed >= 20, "late echo reduced by only \(removed) dB")
    }

    /// The system track carries your own voice back, 0.4 s after the mic
    /// heard it (a far end without echo cancellation). That is a negative
    /// lag; cancelling it would erase you, so nothing is done.
    @Test func neverCancelsTheMicsOwnVoiceComingBack() throws {
        let rate = 48_000, n = 70 * rate
        let you = Self.talk(n, seed: 17, rate: rate)
        let back = Self.driftingEcho(of: you, delay: 0, drift: 0, count: n).enumerated().map { i, _ in
            i >= Int(0.4 * Double(rate)) ? you[i - Int(0.4 * Double(rate))] * 0.5 : 0
        }
        let f = try Self.files(mic: you, system: back)
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let outcome = try EchoCanceller.cancel(mic: f.mic, reference: f.system, output: f.out)
        guard case .noEcho = outcome else {
            Issue.record("the mic's own voice was treated as echo: \(outcome)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: f.out.path))
    }

    /// Headphones or a virtual mic: the system track has sound, the mic
    /// has none of it. Long enough (35 s) for the correlator to run.
    @Test func noEchoWhenTheMicNeverHearsTheSystemTrack() throws {
        let rate = 48_000, n = 35 * rate
        let f = try Self.files(mic: Self.talk(n, seed: 31, rate: rate), system: Self.talk(n, seed: 37, rate: rate))
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let outcome = try EchoCanceller.cancel(mic: f.mic, reference: f.system, output: f.out)
        guard case .noEcho = outcome else {
            Issue.record("expected no echo, got \(outcome)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: f.out.path))
    }
}

/// The recorded start offset: it narrows the echo search to the
/// speaker-to-mic path and puts both tracks on one transcript timeline.
@Suite struct StartOffsetTests {
    typealias T = EchoCancellerTests

    @Test func searchWindowFollowsTheRecordedOffset() {
        #expect(EchoCanceller.searchLags(startOffset: nil) == EchoCanceller.minLagSamples...EchoCanceller.maxLagSamples)
        let lags = EchoCanceller.searchLags(startOffset: 3)
        #expect(lags.lowerBound == 48_000 - EchoCanceller.knownOffsetEarlySamples)
        #expect(lags.upperBound == 48_000 + EchoCanceller.knownOffsetLateSamples)
    }

    @Test func offsetIsTrustedOnlyWhenPlausible() {
        #expect(CaptureHealth.startOffset(mic: 100, system: 103.25) == 3.25)
        #expect(CaptureHealth.startOffset(mic: 100, system: nil) == nil)
        #expect(CaptureHealth.startOffset(mic: 100, system: 99) == nil)     // system before mic
        #expect(CaptureHealth.startOffset(mic: 100, system: 150) == nil)    // a clock mix-up
        #expect(CaptureHealth.startOffset(mic: 100, system: 99.5) == -0.5)
        #expect(CaptureHealth.startOffset(mic: 100, system: 120) == 20)
        #expect(CaptureHealth.startOffset(mic: 100, system: 99.4) == nil)
        #expect(CaptureHealth.startOffset(mic: 100, system: 120.1) == nil)
    }

    /// Files with real origins: the system file starts 3 s into the mic
    /// file. `system(s)` is the system file's sample at its own index s.
    static func offsetFiles(seconds: Int, start: Int = 3, system: (Int) -> Float, mic: (Int) -> Float, rate: Int = 48_000) throws -> (dir: URL, mic: URL, system: URL, out: URL) {
        let micSamples = (0..<(seconds * rate)).map(mic)
        let systemSamples = (0..<((seconds - start) * rate)).map(system)
        return try T.files(mic: micSamples, system: systemSamples)
    }

    @Test func findsTheEchoBehindAThreeSecondStart() throws {
        let rate = 48_000, start = 3 * rate, path = rate / 20   // 50 ms speaker-to-mic
        let far = T.talk(70 * rate, seed: 61, rate: rate)
        let echo = T.driftingEcho(of: far, delay: Double(start + path), drift: 0, count: 70 * rate)
        let f = try Self.offsetFiles(seconds: 70, system: { far[$0] }, mic: { echo[$0] })
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let outcome = try EchoCanceller.cancel(mic: f.mic, reference: f.system, output: f.out, startOffset: 3)
        guard case .cancelled(let alignment, _) = outcome else {
            Issue.record("echo not found: \(outcome)")
            return
        }
        #expect(abs(alignment.delaySamples - (48_000 + 800)) <= 2)
    }

    /// Your voice comes back in the system track 0.5 s after the mic heard
    /// it, and the system file started 3 s late: the return sits at +2.5 s,
    /// which the wide search would take for an echo. With the offset known
    /// it is before the offset and never searched.
    @Test func ownVoiceBehindAStartOffsetIsLeftAlone() throws {
        let rate = 48_000
        let you = T.talk(70 * rate, seed: 67, rate: rate)
        let back = Int(2.5 * Double(rate))
        let f = try Self.offsetFiles(seconds: 70, system: { $0 + back < you.count ? you[$0 + back] * 0.5 : 0 }, mic: { you[$0] })
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let outcome = try EchoCanceller.cancel(mic: f.mic, reference: f.system, output: f.out, startOffset: 3)
        guard case .noEcho = outcome else {
            Issue.record("the returned voice was cancelled: \(outcome)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: f.out.path))
        // The other side of it: without the offset the wide search does take
        // the return for an echo. That is the risk left for recordings made
        // before the offset was stored.
        let wide = try EchoCanceller.align(mic: f.mic, reference: f.system)
        #expect(wide.map { abs($0.delaySamples - 40_000) <= 2 } == true)
    }

    /// The system file starts 20 s in (the largest offset trusted): the mic
    /// is read ahead by it, so every block pair overlaps fully.
    @Test func alignsBehindATwentySecondStart() throws {
        let rate = 48_000, path = rate / 20
        let far = T.talk(80 * rate, seed: 83, rate: rate)
        let echo = T.driftingEcho(of: far, delay: Double(20 * rate + path), drift: 0, count: 80 * rate)
        let f = try Self.offsetFiles(seconds: 80, start: 20, system: { far[$0] }, mic: { echo[$0] })
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let a = try EchoCanceller.align(mic: f.mic, reference: f.system, lags: EchoCanceller.searchLags(startOffset: 20))
        #expect(a.map { abs($0.delaySamples - (320_000 + 800)) <= 2 } == true)
        #expect(a.map { $0.agreeingBlocks == $0.eligibleBlocks } == true)
    }

    /// AirPlay-style output: the echo arrives 2 s after the system track.
    @Test func findsASlowOutputPath() throws {
        let rate = 48_000
        let far = T.talk(70 * rate, seed: 89, rate: rate)
        let echo = T.driftingEcho(of: far, delay: Double(3 * rate + 2 * rate), drift: 0, count: 70 * rate)
        let f = try Self.offsetFiles(seconds: 70, system: { far[$0] }, mic: { echo[$0] })
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let a = try EchoCanceller.align(mic: f.mic, reference: f.system, lags: EchoCanceller.searchLags(startOffset: 3))
        #expect(a.map { abs($0.delaySamples - 80_000) <= 2 } == true)
    }

    @Test func referencePlanUsesTheExactMapping() {
        let a = EchoCanceller.Alignment(delaySamples: 1_000, drift: 400e-6, agreeingBlocks: 2, confidentBlocks: 2, eligibleBlocks: 2)
        let plan = EchoCanceller.referencePlan(a)
        #expect(plan.skip == Int((Double(EchoCanceller.marginSamples) - 1_000 / (1 - 400e-6)).rounded()))
        #expect(abs(plan.readRate - 16_000 / (1 - 400e-6)) < 1e-9)
        let b = EchoCanceller.Alignment(delaySamples: 1_000, drift: -400e-6, agreeingBlocks: 2, confidentBlocks: 2, eligibleBlocks: 2)
        #expect(EchoCanceller.referencePlan(b).readRate < 16_000)
    }

    @Test func twoBlocksCanCarryADrift() {
        // 400 ppm between blocks 30 s apart: 12 ms, past the 5 ms a fixed
        // lag allows.
        let obs = [EchoCanceller.Observation(time: 240_000, lag: 5_000), .init(time: 720_000, lag: 5_192)]
        let a = EchoCanceller.decide(obs, eligibleBlocks: 2)
        #expect(a != nil)
        #expect(abs((a?.driftPPM ?? 0) - 400) < 1)
    }

    /// The last chunk is shorter than a second and the far side talks up to
    /// the end: the reference must stay continuous into the flush.
    @Test func echoIsRemovedUpToTheLastSample() throws {
        let rate = 48_000, n = Int(7.3 * Double(rate))
        let far = T.talk(n, seed: 71, rate: rate)
        let echo = T.driftingEcho(of: far, delay: 0.2 * Double(rate), drift: 0, count: n)
        let f = try T.files(mic: echo, system: far)
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let still = EchoCanceller.Alignment(delaySamples: 3_200, drift: 0, agreeingBlocks: 1, confidentBlocks: 1, eligibleBlocks: 1)
        _ = try EchoCanceller.process(mic: f.mic, reference: f.system, output: f.out, alignment: still)
        let clean = try T.read16k(f.out), mic16 = try T.read16k(f.mic)
        #expect(clean.count == mic16.count)
        let tail = (mic16.count - 4_000)..<mic16.count
        #expect(T.db(T.energy(mic16, tail), over: T.energy(clean, tail)) >= 20)
    }

    @Test func micShorterThanTheLatencyKeepsItsLength() throws {
        let f = try T.files(mic: T.noise(300, seed: 73), system: T.noise(300, seed: 79))
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let still = EchoCanceller.Alignment(delaySamples: 0, drift: 0, agreeingBlocks: 1, confidentBlocks: 1, eligibleBlocks: 1)
        _ = try EchoCanceller.process(mic: f.mic, reference: f.system, output: f.out, alignment: still)
        #expect(try T.read16k(f.out).count == T.read16k(f.mic).count)
    }
}

@Suite struct TranscriptTimelineTests {
    /// The system track started 2 s into the mic track: its segments move
    /// by 2 s, so a reply at system t=1 s lands after "Me" at 2.5 s.
    @Test func systemSegmentsMoveOntoTheMicTimeline() {
        var meta = RecordingMeta(title: "t", started_at: Date(), device: AppInfo.device, client_version: AppInfo.version)
        meta.capture_health = CaptureHealth(mic_restarts: 0, mic_padded_seconds: 0, mic_seconds_captured: 10, mic_had_signal: true,
                                            system_restarts: 0, system_padded_seconds: 0, system_buffers: 1, system_had_signal: true,
                                            system_writer_failed: false, system_start_offset_seconds: 2)
        let mic = [STTResult(segments: [STTSegment(start: 2.5, end: 3.5, text: "Did the contract arrive yesterday afternoon?", speaker: nil)], language: "en")]
        let system = [STTResult(segments: [STTSegment(start: 1.0, end: 2.0, text: "Yes, it came in just before five o'clock.", speaker: nil)], language: "en")]
        let out = TranscriptBuilder.build(meta: meta, micResults: mic, systemResults: system)
        #expect(out.segments.map(\.speaker) == ["Me", "Them"])
        #expect(out.segments.last?.start == 3.0)

        // A slightly negative offset (clock jitter) moves the mic instead,
        // so no segment starts before 0.
        meta.capture_health?.system_start_offset_seconds = -0.25
        let jitter = TranscriptBuilder.build(meta: meta, micResults: mic,
                                             systemResults: [STTResult(segments: [STTSegment(start: 0, end: 1, text: "Good morning to you all, shall we start?", speaker: nil)], language: "en")])
        #expect(jitter.segments.allSatisfy { $0.start >= 0 })
        #expect(jitter.segments.first(where: { $0.speaker == "Me" })?.start == 2.75)

        // Without a recorded offset the tracks keep their own t=0.
        meta.capture_health?.system_start_offset_seconds = nil
        let old = TranscriptBuilder.build(meta: meta, micResults: mic, systemResults: system)
        #expect(old.segments.map(\.speaker) == ["Them", "Me"])
    }
}
