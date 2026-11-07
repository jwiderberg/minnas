//
// Exponential-backoff schedule for the auto-retry timer (mr#3).
//
// Per-recording, per-sink state lives on `RecordingMeta`
// (delivery_attempts[sink id]; an upload sink falls back to the older
// upload_attempt_count + last_upload_attempt_at) so the schedule survives
// app restarts. The timer ticks every 5 min; on each tick
// SinkDispatcher asks `RetrySchedule.isDue(...)` whether a sink's next
// attempt window for a recording has elapsed.
//
// Schedule (per the issue spec): 5 → 10 → 30 → 60 min, capping at 60.
// `upload_attempt_count == 0` means we've never tried — fire on the
// next tick. After the 1st failure (count==1), wait 5 min from the
// last attempt before the next try; after the 2nd, 10 min; etc.
//

import Foundation

enum RetrySchedule {
    /// Minutes to wait after the Nth failed attempt before trying
    /// again. Index = attempt count, value = required gap in minutes.
    /// Cap at 60 min for any count >= the last index.
    static let backoffMinutes: [Int] = [0, 5, 10, 30, 60]

    /// How long to wait after `attemptCount` failures before
    /// attempting again.
    static func interval(forAttemptCount attemptCount: Int) -> TimeInterval {
        guard attemptCount > 0 else { return 0 }
        let idx = min(attemptCount, backoffMinutes.count - 1)
        return TimeInterval(backoffMinutes[idx] * 60)
    }

    /// True when a recording with the given last-attempt + attempt
    /// count is due for another try.
    ///
    /// - attemptCount: 0 means never tried — always due.
    /// - lastAttemptAt: nil means never tried — always due.
    /// - now: current time. Pass `Date()` from callers; tests pass a
    ///   fixed value to drive the schedule deterministically.
    static func isDue(
        attemptCount: Int,
        lastAttemptAt: Date?,
        now: Date
    ) -> Bool {
        guard attemptCount > 0, let last = lastAttemptAt else { return true }
        let gap = interval(forAttemptCount: attemptCount)
        return now.timeIntervalSince(last) >= gap
    }
}
