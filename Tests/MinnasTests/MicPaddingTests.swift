import AVFoundation
import Foundation
import Testing
@testable import Minnas

/// A clock whose host ticks and wall time the test moves independently, so
/// a sleep (wall time runs on, host time stands still) can be simulated.
private struct FakeClock: CaptureClock {
    var host: UInt64
    var now: Date
    let ticksPerSecond: Double

    func hostTicks() -> UInt64 { host }
    func wall() -> Date { now }

    mutating func advance(host seconds: Double, wall wallSeconds: Double) {
        host += UInt64(seconds * ticksPerSecond)
        now = now.addingTimeInterval(wallSeconds)
    }
}

@Suite struct MicPaddingTests {
    /// Apple Silicon's timebase: 24 MHz.
    private let tps: Double = 24_000_000
    private let base: UInt64 = 1_000_000_000_000

    private func plan(gapSeconds: Double, tps: Double? = nil) -> MicCapture.PadPlan {
        let t = tps ?? self.tps
        return MicCapture.padPlan(lastHostEnd: base, hostNow: base + UInt64(gapSeconds * t), ticksPerSecond: t,
                                  maxPadSeconds: MicCapture.maxPadSeconds, minimum: MicCapture.minPadSeconds)
    }

    // MARK: padPlan

    @Test func constantsAreUnchanged() {
        #expect(MicCapture.maxPadSeconds == 300)
        #expect(MicCapture.minPadSeconds == 0.05)
    }

    @Test func belowMinimumIsNotPadded() {
        #expect(plan(gapSeconds: 0) == .none)
        #expect(plan(gapSeconds: 0.04) == .none)
        #expect(plan(gapSeconds: 0.05) == .none)   // strictly above the minimum
    }

    @Test func ordinaryGapIsPaddedWhole() {
        #expect(plan(gapSeconds: 2.5) == .pad(seconds: 2.5))
        #expect(plan(gapSeconds: 300) == .pad(seconds: 300))
    }

    @Test func gapOverTheCapPadsTheCappedAmount() {
        #expect(plan(gapSeconds: 400) == .capped(seconds: 300, gap: 400))
    }

    @Test func unusableTimestampsPlanNothing() {
        let cap = MicCapture.maxPadSeconds, min = MicCapture.minPadSeconds
        // No buffer yet.
        #expect(MicCapture.padPlan(lastHostEnd: 0, hostNow: base, ticksPerSecond: tps,
                                   maxPadSeconds: cap, minimum: min) == .none)
        // hostNow before the last buffer's end (would underflow).
        #expect(MicCapture.padPlan(lastHostEnd: base, hostNow: base - 1, ticksPerSecond: tps,
                                   maxPadSeconds: cap, minimum: min) == .none)
        #expect(MicCapture.padPlan(lastHostEnd: UInt64.max, hostNow: 1, ticksPerSecond: tps,
                                   maxPadSeconds: cap, minimum: min) == .none)
        // Non-finite or zero timebase.
        for bad in [0, -1, Double.nan, Double.infinity] {
            #expect(MicCapture.padPlan(lastHostEnd: base, hostNow: base + 48_000_000, ticksPerSecond: bad,
                                       maxPadSeconds: cap, minimum: min) == .none)
        }
        // A tiny timebase over a huge span gives an infinite gap: nothing.
        #expect(MicCapture.padPlan(lastHostEnd: 1, hostNow: UInt64.max, ticksPerSecond: 1e-300,
                                   maxPadSeconds: cap, minimum: min) == .none)
    }

    // MARK: bufferEndTicks

    @Test func bufferEndIsStartPlusDuration() {
        // 4800 frames at 48 kHz = 0.1 s = 2_400_000 ticks.
        let end = MicCapture.bufferEndTicks(start: base, hostTimeValid: true, frames: 4800, sampleRate: 48_000,
                                            ticksPerSecond: tps, now: base + 10_000_000)
        #expect(end == base + 2_400_000)
    }

    @Test func bufferEndFallsBackToNowAndNeverPassesIt() {
        // Invalid host time: the buffer has been captured by now.
        #expect(MicCapture.bufferEndTicks(start: 0, hostTimeValid: false, frames: 4800, sampleRate: 48_000,
                                          ticksPerSecond: tps, now: base) == base)
        // A host time in the future is clamped to now (would hold the watchdog off).
        #expect(MicCapture.bufferEndTicks(start: base + 1_000_000_000, hostTimeValid: true, frames: 4800,
                                          sampleRate: 48_000, ticksPerSecond: tps, now: base) == base)
        // Degenerate rate: no duration, start kept.
        #expect(MicCapture.bufferEndTicks(start: base - 5, hostTimeValid: true, frames: 4800, sampleRate: 0,
                                          ticksPerSecond: tps, now: base) == base - 5)
        // Overflowing start.
        #expect(MicCapture.bufferEndTicks(start: UInt64.max - 1, hostTimeValid: true, frames: 4800,
                                          sampleRate: 48_000, ticksPerSecond: tps, now: base) == base)
    }

    // MARK: wallTime

    @Test func wallTimeSubtractsHostTimeSince() {
        let wallNow = Date(timeIntervalSince1970: 1_800_000_000)
        let at = MicCapture.wallTime(ofHostTicks: base, hostNow: base + UInt64(2 * tps), wallNow: wallNow,
                                     ticksPerSecond: tps)
        #expect(at == wallNow.addingTimeInterval(-2))
        // Not before hostNow: now.
        #expect(MicCapture.wallTime(ofHostTicks: base + 1, hostNow: base, wallNow: wallNow,
                                    ticksPerSecond: tps) == wallNow)
    }

    // MARK: a simulated sleep

    /// The engine dies, the Mac sleeps 87 s, wakes, the restart pads: wall
    /// time moved 90 s, host time 3 s. The pad is the 3 awake seconds.
    @Test func sleepIsNotPadded() {
        var clock = FakeClock(host: base, now: Date(timeIntervalSince1970: 1_800_000_000), ticksPerSecond: tps)
        let lastEnd = MicCapture.bufferEndTicks(start: clock.hostTicks(), hostTimeValid: true, frames: 0,
                                                sampleRate: 48_000, ticksPerSecond: tps, now: clock.hostTicks())
        clock.advance(host: 3, wall: 90)
        let plan = MicCapture.padPlan(lastHostEnd: lastEnd, hostNow: clock.hostTicks(),
                                      ticksPerSecond: clock.ticksPerSecond,
                                      maxPadSeconds: MicCapture.maxPadSeconds, minimum: MicCapture.minPadSeconds)
        #expect(plan == .pad(seconds: 3))
    }

    /// The watchdog, fed the host-derived lastBufferAt, does not fire across
    /// a sleep, and does fire once 3 s of host time pass without a buffer.
    @Test func watchdogIgnoresSleepButNotHostTimeStall() {
        var clock = FakeClock(host: base, now: Date(timeIntervalSince1970: 1_800_000_000), ticksPerSecond: tps)
        var backoff = RestartBackoff()
        backoff.noteAttached(at: clock.wall())
        let lastEnd = clock.hostTicks()
        func lastBufferAt() -> Date {
            MicCapture.wallTime(ofHostTicks: lastEnd, hostNow: clock.hostTicks(), wallNow: clock.wall(),
                                ticksPerSecond: clock.ticksPerSecond)
        }
        let wallBefore = clock.wall()

        // 1 s awake, then an 88 s sleep: 89 s of wall time, 1 s of host time.
        clock.advance(host: 1, wall: 89)
        #expect(backoff.overdue(lastBufferAt: lastBufferAt(), now: clock.wall()) == nil)
        // A wall-clock lastBufferAt (the old rule) would have fired here.
        #expect(backoff.overdue(lastBufferAt: wallBefore, now: clock.wall()) == 3)

        // 2 more awake seconds: exactly 3 s of host time, not yet over.
        clock.advance(host: 2, wall: 2)
        #expect(backoff.overdue(lastBufferAt: lastBufferAt(), now: clock.wall()) == nil)
        // Past 3 s of host time with no buffer: the watchdog fires.
        clock.advance(host: 0.5, wall: 0.5)
        #expect(backoff.overdue(lastBufferAt: lastBufferAt(), now: clock.wall()) == 3)
    }

    // MARK: resume pad (buffers come back without a restart)

    /// The sleep run of 2026-11-07: buffers end at host t, the engine is dead
    /// for 5 s of host time, the Mac sleeps 120 s (host time frozen), and
    /// buffers resume 1.3 s of host time after the wake. The gap before the
    /// first resumed buffer is the 6.3 awake seconds, not 126.3.
    @Test func resumeAfterSleepPadsOnlyAwakeTime() {
        var clock = FakeClock(host: base, now: Date(timeIntervalSince1970: 1_800_000_000), ticksPerSecond: tps)
        let lastEnd = MicCapture.bufferEndTicks(start: clock.hostTicks() - 2_400_000, hostTimeValid: true,
                                                frames: 4800, sampleRate: 48_000, ticksPerSecond: tps,
                                                now: clock.hostTicks())
        #expect(lastEnd == base)
        clock.advance(host: 5, wall: 5)       // dead, awake
        clock.advance(host: 0, wall: 120)     // asleep
        clock.advance(host: 1.3, wall: 1.3)   // awake again, still dead
        let resumedStart = clock.hostTicks()
        clock.advance(host: 0.1, wall: 0.1)   // the buffer is delivered once captured
        let plan = MicCapture.padPlan(lastHostEnd: lastEnd, hostNow: resumedStart, ticksPerSecond: tps,
                                      maxPadSeconds: MicCapture.maxPadSeconds, minimum: MicCapture.minPadSeconds)
        guard case .pad(let seconds) = plan else {
            Issue.record("expected a pad, got \(plan)")
            return
        }
        #expect(abs(seconds - 6.3) < 1e-6)
        let resume = MicCapture.resumePadSeconds(lastHostEnd: lastEnd, start: resumedStart, hostTimeValid: true,
                                                 now: clock.hostTicks(), ticksPerSecond: tps)
        #expect(abs(resume - 6.3) < 1e-6)
    }

    @Test func contiguousBuffersAreNotResumePadded() {
        // 4800 frames at 48 kHz back to back: each starts where the last ended.
        let end = MicCapture.bufferEndTicks(start: base, hostTimeValid: true, frames: 4800, sampleRate: 48_000,
                                            ticksPerSecond: tps, now: base + 10_000_000)
        #expect(MicCapture.resumePadSeconds(lastHostEnd: end, start: end, hostTimeValid: true,
                                            now: end + 2_400_000, ticksPerSecond: tps) == 0)
        // Within the 0.05 s minimum: nothing.
        #expect(MicCapture.resumePadSeconds(lastHostEnd: end, start: end + UInt64(0.04 * tps), hostTimeValid: true,
                                            now: end + UInt64(0.2 * tps), ticksPerSecond: tps) == 0)
    }

    @Test func resumePadNeedsAValidHostTimeAndIsCapped() {
        // No host time: the start is unknown, so no pad (delivery time would
        // pad every buffer by its own length).
        #expect(MicCapture.resumePadSeconds(lastHostEnd: base, start: 0, hostTimeValid: false,
                                            now: base + UInt64(0.1 * tps), ticksPerSecond: tps) == 0)
        // No buffer yet.
        #expect(MicCapture.resumePadSeconds(lastHostEnd: 0, start: base, hostTimeValid: true,
                                            now: base, ticksPerSecond: tps) == 0)
        // A start in the future counts as now.
        #expect(MicCapture.resumePadSeconds(lastHostEnd: base, start: base + UInt64(50 * tps), hostTimeValid: true,
                                            now: base + UInt64(2 * tps), ticksPerSecond: tps) == 2)
        // Over the cap: the capped amount.
        #expect(MicCapture.resumePadSeconds(lastHostEnd: base, start: base + UInt64(400 * tps), hostTimeValid: true,
                                            now: base + UInt64(401 * tps), ticksPerSecond: tps) == 300)
    }

    /// A restart pads up to its own instant and stores it as the last end;
    /// the first buffer of the restarted engine is then padded only for the
    /// time after that instant (engine start-up), never again for the gap
    /// the restart already covered.
    @Test func restartPadAndResumePadDoNotOverlap() {
        let lastEnd = base
        let restartAt = base + UInt64(4 * tps)
        guard case .pad(let restartPad) = MicCapture.padPlan(lastHostEnd: lastEnd, hostNow: restartAt,
                                                             ticksPerSecond: tps,
                                                             maxPadSeconds: MicCapture.maxPadSeconds,
                                                             minimum: MicCapture.minPadSeconds) else {
            Issue.record("expected a restart pad")
            return
        }
        // The restart stores restartAt; the engine's first buffer starts 0.3 s later.
        let firstStart = restartAt + UInt64(0.3 * tps)
        let resume = MicCapture.resumePadSeconds(lastHostEnd: restartAt, start: firstStart, hostTimeValid: true,
                                                 now: firstStart + 2_400_000, ticksPerSecond: tps)
        #expect(abs(restartPad - 4) < 1e-6)
        #expect(abs(resume - 0.3) < 1e-6)
        #expect(abs(restartPad + resume - 4.3) < 1e-6)   // the whole gap, once
    }

    @Test func writeSilenceAppendsZerosInOneSecondChunks() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mic-silence-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let format = file.processingFormat
            let zeros = try #require(MicCapture.makeZeroBuffer(format: format))
            #expect(zeros.frameCapacity == 48_000)
            let result = MicCapture.writeSilence(into: file, zero: zeros, seconds: 2.5, rate: format.sampleRate)
            #expect(result.frames == 120_000)
            #expect(result.error == nil)
            // Degenerate requests write nothing.
            #expect(MicCapture.writeSilence(into: file, zero: zeros, seconds: .nan, rate: 48_000).frames == 0)
            #expect(MicCapture.writeSilence(into: file, zero: zeros, seconds: 1, rate: 0).frames == 0)
            #expect(MicCapture.writeSilence(into: file, zero: zeros, seconds: 301, rate: 48_000).frames == 0)
        }
        let read = try AVAudioFile(forReading: url)
        #expect(read.length == 120_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: read.processingFormat, frameCapacity: 120_000))
        try read.read(into: buffer)
        #expect(buffer.frameLength == 120_000)
        let samples = try #require(buffer.floatChannelData?[0])
        var peak: Float = 0
        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[i])) }
        #expect(peak == 0)
    }

    @Test func resumePadAccountingIsDrainedOnce() {
        let stats = TapStats()
        stats.addResumePad(1.5)
        stats.addResumePad(0.25)
        #expect(stats.resumePaddedSeconds == 1.75)
        #expect(stats.takePendingResumePad() == 1.75)
        #expect(stats.takePendingResumePad() == 0)
        #expect(stats.resumePaddedSeconds == 1.75)
    }

    @Test func machClockUsesTheHostTimebase() {
        let clock = MachClock()
        #expect(clock.ticksPerSecond == HostClock.ticksPerSecond)
        let a = clock.hostTicks()
        let b = clock.hostTicks()
        #expect(b >= a)
    }

    /// A buffer whose nominal end runs ahead of the callback (8192 frames =
    /// 171 ms at 48 kHz, delivered 100 ms after its start) must not make the
    /// next contiguous buffer look like it followed a gap: continuity is
    /// judged from the nominal end, not from the end clamped to now.
    @Test func clampedEndDoesNotCauseResumePad() {
        let tps = 1_000_000.0   // 1 tick = 1 µs
        let start: UInt64 = 10_000_000
        let frames: AVAudioFrameCount = 8192
        let now = start + 100_000
        let clamped = MicCapture.bufferEndTicks(start: start, hostTimeValid: true, frames: frames,
                                                sampleRate: 48_000, ticksPerSecond: tps, now: now)
        let nominal = MicCapture.nominalEndTicks(start: start, hostTimeValid: true, frames: frames,
                                                 sampleRate: 48_000, ticksPerSecond: tps, previous: 0)
        #expect(clamped == now)
        #expect(nominal == start + 170_666)
        // The next buffer starts exactly where this one nominally ended.
        let nextStart = nominal
        let fromClamped = MicCapture.resumePadSeconds(lastHostEnd: clamped, start: nextStart, hostTimeValid: true,
                                                      now: nextStart + 200_000, ticksPerSecond: tps)
        let fromNominal = MicCapture.resumePadSeconds(lastHostEnd: nominal, start: nextStart, hostTimeValid: true,
                                                      now: nextStart + 200_000, ticksPerSecond: tps)
        #expect(fromClamped > 0.05)   // the clamp alone would have padded 70 ms
        #expect(fromNominal == 0)     // the nominal end sees contiguous audio
        // An invalid host time keeps the previous nominal end.
        #expect(MicCapture.nominalEndTicks(start: 0, hostTimeValid: false, frames: frames, sampleRate: 48_000,
                                           ticksPerSecond: tps, previous: 42) == 42)
    }
}
