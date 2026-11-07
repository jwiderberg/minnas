//
// Where a finished transcript goes. A sink is one destination (the
// Markdown folder every build has, plus the build's own: BuildFlavor.sinks);
// SinkDispatcher runs every active sink over
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
    /// sends data off the Mac skips a 🔒 local-only recording here).
    func applies(to meta: RecordingMeta) -> Bool
    /// The slot files this sink reads. The dispatcher delivers only once
    /// all of them exist and none is older than meta's transcript_written_at
    /// (a stale file from the previous generation). Default: transcript.md.
    func requiredFiles(slot: OutboxSlot) -> [URL]
    /// One delivery attempt. Throws to leave the slot pending for retry.
    func deliver(slot: OutboxSlot, meta: RecordingMeta) async throws -> SinkDelivery

    /// Whether the sink can deliver right now (a destination chosen, a
    /// secret set). SinkDispatcher.activeSinks() lists only configured
    /// sinks. Default: true.
    var isConfigured: Bool { get }
    /// Whether a recording this sink applies to and hasn't received still
    /// counts as owed while the sink is NOT configured, so pruning keeps
    /// it. For a sink whose configuration can vanish for one launch (a
    /// missing or misspelt secret) without the user meaning "never deliver
    /// these": deleting every undelivered recording then would be wrong.
    /// Default: false (an unconfigured sink owes nothing).
    var keepsOwedSlotsWhenUnconfigured: Bool { get }
    /// Whether this recording's current transcript has reached the sink.
    /// Default: a `deliveries` entry under `id`.
    func isDelivered(_ meta: RecordingMeta) -> Bool
    /// The retry backoff state. Default: `delivery_attempts[id]`, zero
    /// attempts when there is none.
    func attempt(_ meta: RecordingMeta) -> DeliveryAttempt
    /// Where the last delivery landed, for the --deliver plan. Default:
    /// `deliveries[id].location`.
    func location(_ meta: RecordingMeta) -> String?
    /// Files the sink builds from a new transcript, written by
    /// TranscriptionJob.finish after transcript.md and BEFORE meta.json (the
    /// ordering invariant: see SinkDispatcher). `meta` is the meta as it
    /// will be saved. Runs for every sink the build registers, configured or
    /// not, so a sink switched on later finds this generation's files.
    /// Default: nothing.
    func writeArtifacts(slot: OutboxSlot, meta: RecordingMeta, output: TranscriptBuilder.Output) throws
    /// Called inside the dispatcher's meta mutation right after a success
    /// was recorded under `id` (deliveries set, attempts cleared), for a
    /// sink that keeps older bookkeeping fields of its own in step.
    /// Default: nothing.
    func didRecordDelivery(_ delivery: SinkDelivery, in meta: inout RecordingMeta)
    /// The same, after a failed attempt was recorded; `attempt` is the new
    /// state in `delivery_attempts[id]`. Default: nothing.
    func didRecordAttempt(_ attempt: DeliveryAttempt, in meta: inout RecordingMeta)
}

extension TranscriptSink {
    func requiredFiles(slot: OutboxSlot) -> [URL] { [slot.transcriptURL] }
    var isConfigured: Bool { true }
    var keepsOwedSlotsWhenUnconfigured: Bool { false }
    // These read the fields directly, never RecordingMeta.isDelivered(to:) /
    // attempt(for:): those resolve through the registered sink and would
    // recurse.
    func isDelivered(_ meta: RecordingMeta) -> Bool { meta.deliveries?[id] != nil }
    func attempt(_ meta: RecordingMeta) -> DeliveryAttempt {
        meta.delivery_attempts?[id] ?? DeliveryAttempt(attempt_count: 0, last_attempt_at: nil)
    }
    func location(_ meta: RecordingMeta) -> String? { meta.deliveries?[id]?.location }
    func writeArtifacts(slot: OutboxSlot, meta: RecordingMeta, output: TranscriptBuilder.Output) throws {}
    func didRecordDelivery(_ delivery: SinkDelivery, in meta: inout RecordingMeta) {}
    func didRecordAttempt(_ attempt: DeliveryAttempt, in meta: inout RecordingMeta) {}
}

/// A successful delivery, persisted per sink id in meta.json.
struct SinkDelivery: Codable, Sendable {
    var delivered_at: Date
    /// Where it landed: a file path, a URL. Optional because a sink may not
    /// learn one (a server can 2xx with an unreadable body).
    var location: String?
}

/// Backoff state for a sink that hasn't delivered yet (RetrySchedule).
struct DeliveryAttempt: Codable, Sendable {
    var attempt_count: Int
    var last_attempt_at: Date?
}
