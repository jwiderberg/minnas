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

    @Test func machClockUsesTheHostTimebase() {
        let clock = MachClock()
        #expect(clock.ticksPerSecond == HostClock.ticksPerSecond)
        let a = clock.hostTicks()
        let b = clock.hostTicks()
        #expect(b >= a)
    }
}
