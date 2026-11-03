//
// Where a finished transcript goes. A sink is one destination (today: a
// Markdown folder); SinkDispatcher runs every active sink over
// a slot and owns the per-sink pending/retry state in meta.json.
//
// Sinks are stateless values: everything they need comes from the slot's
// files and its meta, so a delivery can be retried after an app restart.
// They never write meta.json themselves — the dispatcher records the
// returned SinkDelivery (or a failed attempt) against the sink's id
// (SinkDispatcher.recordOutcome, through Outbox.mutateMeta), which keeps
// one funnel for the read-modify-write.
//

import Foundation

protocol TranscriptSink: Sendable {
    /// Stable key into RecordingMeta.deliveries / delivery_attempts. Never
    /// change it once shipped: a new id re-delivers every recording.
    var id: String { get }
    var displayName: String { get }
    /// Whether this recording should go to this sink at all (a sink that
    /// sends data off the Mac would filter here).
    func applies(to meta: RecordingMeta) -> Bool
    /// The slot files this sink reads. The dispatcher delivers only once
    /// all of them exist and none is older than meta's transcript_written_at
    /// (a stale file from the previous generation). Default: transcript.md.
    func requiredFiles(slot: OutboxSlot) -> [URL]
    /// One delivery attempt. Throws to leave the slot pending for retry.
    func deliver(slot: OutboxSlot, meta: RecordingMeta) async throws -> SinkDelivery
}

extension TranscriptSink {
    func requiredFiles(slot: OutboxSlot) -> [URL] { [slot.transcriptURL] }
}

/// A successful delivery, persisted per sink id in meta.json.
struct SinkDelivery: Codable, Sendable {
    var delivered_at: Date
    /// Where it landed: a file path, a URL. Optional because a sink may not
    /// learn one.
    var location: String?
}

/// Backoff state for a sink that hasn't delivered yet (RetrySchedule).
struct DeliveryAttempt: Codable, Sendable {
    var attempt_count: Int
    var last_attempt_at: Date?
}
