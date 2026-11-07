//
// Small pieces the three capture engines (MicCapture, SystemAudioCapture,
// SystemAudioTapCapture) share. Pure values only: no engine state, no
// logging, no threading of their own.
//
//   RestartBackoff   the stall watchdog's threshold and restart bookkeeping
//                    (3 s, doubling per restart that never delivered a
//                    buffer, capped at 60 s; batches of 20 attempts, 1 s
//                    apart). Each engine holds one in main-actor state and
//                    keeps its own restart loop inline, because the loops'
//                    guards differ and the invariants depend on them.
//   Date.epochBits   a wall-clock Date as the bit pattern of its epoch
//                    Double, so an audio thread can publish it through one
//                    Atomic<UInt64> (an Optional<Date> is 16 bytes and would
//                    tear). 0 means "none yet".
//   HostClock        mach_absolute_time ticks per second.
//   CaptureClock     host ticks + wall time + ticks per second behind a
//                    protocol, so a test can make wall time run ahead of
//                    host time (a sleep). MachClock is the real one.
//   CaptureSignal    the amplitude above which a sample counts as signal.
//

import Foundation

/// Stall-watchdog state for one capture engine. A plain value held in
/// main-actor state; every mutation happens on the main actor.
struct RestartBackoff: Sendable {
    /// Stall threshold with no silent restarts behind it.
    static let baseSeconds: Double = 3
    /// The threshold never backs off past this.
    static let maxSeconds: Double = 60
    /// Attempts in one restart batch before the loop gives up for now.
    static let attemptsPerBatch = 20
    /// Wait between failed attempts in a batch.
    static let retryDelay: Duration = .seconds(1)

    /// When the engine last came up (start or a successful re-attach).
    private(set) var attachedAt: Date = .distantPast
    /// Restarts that came up but never delivered a buffer. Backs the stall
    /// threshold off so a dead device doesn't spin the restart loop.
    private(set) var silentRestarts = 0
    /// When the engine stopped delivering and a restart is in progress or
    /// has failed; nil while healthy.
    private(set) var stalledSince: Date?

    /// Seconds without a buffer before the watchdog restarts:
    /// min(60, 3 · 2^silentRestarts).
    var threshold: Double { min(Self.maxSeconds, Self.baseSeconds * pow(2.0, Double(silentRestarts))) }

    mutating func noteAttached(at date: Date = Date()) {
        attachedAt = date
    }

    /// The threshold, when more than that has passed since the later of the
    /// last buffer and the last attach; nil while within it.
    func overdue(lastBufferAt: Date?, now: Date = Date()) -> Double? {
        let last = lastBufferAt.map { max($0, attachedAt) } ?? attachedAt
        let threshold = self.threshold
        return now.timeIntervalSince(last) > threshold ? threshold : nil
    }

    /// Call when a restart is about to be scheduled. Marks the stall start
    /// (once) and counts the restart as silent when an earlier restart
    /// produced no buffer since its attach; any delivery resets the count.
    /// The first restart of a recording never counts as silent.
    mutating func noteRestartScheduled(restartsSoFar: Int, lastBufferAt: Date?, now: Date = Date()) {
        if stalledSince == nil { stalledSince = now }
        let deliveredSinceAttach = (lastBufferAt ?? .distantPast) > attachedAt
        if restartsSoFar > 0, !deliveredSinceAttach { silentRestarts += 1 } else { silentRestarts = 0 }
    }

    /// Call when a restart attempt succeeded.
    mutating func noteRecovered() {
        stalledSince = nil
    }
}

extension Date {
    /// A Date from `epochBits`; nil for 0 ("none yet").
    init?(epochBits bits: UInt64) {
        guard bits != 0 else { return nil }
        self.init(timeIntervalSince1970: Double(bitPattern: bits))
    }

    /// The bit pattern of timeIntervalSince1970, for an Atomic<UInt64>.
    var epochBits: UInt64 { timeIntervalSince1970.bitPattern }
}

enum HostClock {
    /// mach_absolute_time ticks per second.
    static let ticksPerSecond: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return 1e9 * Double(tb.denom) / Double(tb.numer)
    }()
}

/// The two clocks a capture engine reads: host time (mach_absolute_time,
/// which does not advance while the Mac sleeps) and wall time.
protocol CaptureClock: Sendable {
    func hostTicks() -> UInt64
    func wall() -> Date
    var ticksPerSecond: Double { get }
}

/// mach_absolute_time and Date().
struct MachClock: CaptureClock {
    func hostTicks() -> UInt64 { mach_absolute_time() }
    func wall() -> Date { Date() }
    var ticksPerSecond: Double { HostClock.ticksPerSecond }
}

enum CaptureSignal {
    /// A sample whose magnitude is above this counts as signal (not silence).
    static let epsilon: Float = 0.0001
}
