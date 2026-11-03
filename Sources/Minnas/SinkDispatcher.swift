//
// Runs every active TranscriptSink over a recording and owns the per-sink
// pending/retry state in meta.json (deliveries / delivery_attempts).
//
// "Pending" for a sink = it is active, applies to the recording, and has
// not delivered it. A recording is ready for a sink once every file that
// sink reads (requiredFiles: transcript.md for the folder sink) exists and
// is no older than meta's transcript_written_at.
//
// The one sink today is MarkdownFolderSink. Another destination is one new
// TranscriptSink type plus a line in activeSinks(); the per-sink state in
// meta (deliveries, delivery_attempts, previous_locations) and the retry
// backoff already key on the sink id.
//
// Ordering invariant with TranscriptionJob.finish: finish writes
// transcript.md FIRST and the meta.json that resets the deliveries LAST. So whenever meta says "this generation is pending", the
// files on disk are already that generation's; the mtime check is the
// second fence, against a file left over from an earlier generation (a
// write that failed half-way, an older build).
//
// Meta writes go through Outbox.mutateMeta (one lock, re-read right before
// writing) and change only the delivery fields, so a field another path
// wrote meanwhile survives. A delivery that finishes after a re-transcribe
// replaced the transcript is not recorded as delivered (the new transcript
// still has to go out); its location is kept so the folder sink overwrites
// that file next time.
//
// Nonisolated by design: the app calls it from the main actor, the CLI
// from a plain Task.
//

import Foundation
import os

private let dispatchLog = Logger(subsystem: "com.jwiderberg.minnas", category: "Delivery")

struct DeliveryOutcome: Sendable {
    let sinkID: String
    let sinkName: String
    let result: Result<SinkDelivery, any Error>

    var succeeded: Bool {
        if case .success = result { return true }
        return false
    }

    var error: (any Error)? {
        if case .failure(let error) = result { return error }
        return nil
    }
}

enum SinkDispatcher {
    /// Slugs whose meta.json didn't decode, so the error is logged once per
    /// process rather than on every menu rebuild.
    private static let undecodableLogged = OSAllocatedUnfairLock(initialState: Set<String>())

    /// The sinks configured right now. Read fresh on every call: the folder
    /// can change in Settings while the app runs.
    static func activeSinks() -> [any TranscriptSink] {
        var sinks: [any TranscriptSink] = []
        if let folder = Config.transcriptsFolderURL() { sinks.append(MarkdownFolderSink(folder: folder)) }
        return sinks
    }

    static func pendingSinks(for meta: RecordingMeta) -> [any TranscriptSink] {
        pendingSinks(for: meta, among: activeSinks())
    }

    static func pendingSinks(for meta: RecordingMeta, among sinks: [any TranscriptSink]) -> [any TranscriptSink] {
        sinks.filter { $0.applies(to: meta) && !meta.isDelivered(to: $0.id) }
    }

    static func isDue(_ sink: any TranscriptSink, meta: RecordingMeta, now: Date = Date()) -> Bool {
        let attempt = meta.attempt(for: sink.id)
        return RetrySchedule.isDue(attemptCount: attempt.attempt_count, lastAttemptAt: attempt.last_attempt_at, now: now)
    }

    /// Slack for the mtime comparison: meta stores dates at whole-second
    /// precision (ISO 8601), and a file's mtime can round the other way.
    private static let freshnessTolerance: TimeInterval = 1

    /// Whether `sink` can deliver this slot now: each of its required files
    /// exists and none predates the current transcript generation.
    static func isReady(_ sink: any TranscriptSink, slot: OutboxSlot, meta: RecordingMeta) -> Bool {
        filesReady(sink.requiredFiles(slot: slot), meta: meta)
    }

    /// Slot-level readiness for the menu and the --deliver plan: ready for
    /// at least one active sink that applies to it (with no active sink,
    /// just a current transcript.md). Unreadable meta = not ready.
    static func isReady(_ slot: OutboxSlot) -> Bool {
        guard let meta = readMetaOrLogOnce(slot) else { return false }
        let applicable = activeSinks().filter { $0.applies(to: meta) }
        if applicable.isEmpty { return filesReady([slot.transcriptURL], meta: meta) }
        return applicable.contains { isReady($0, slot: slot, meta: meta) }
    }

    private static func filesReady(_ files: [URL], meta: RecordingMeta) -> Bool {
        let fm = FileManager.default
        let floor = meta.transcript_written_at?.addingTimeInterval(-freshnessTolerance)
        return files.allSatisfy { url in
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return false }
            guard let floor else { return true }
            guard let modified = attrs[.modificationDate] as? Date else { return false }
            return modified >= floor
        }
    }

    /// One attempt for every pending sink that is due. `ignoringSchedule`
    /// is for a user-initiated retry.
    static func deliverPending(
        slot: OutboxSlot,
        now: Date = Date(),
        ignoringSchedule: Bool = false
    ) async -> [DeliveryOutcome] {
        let sinks = activeSinks()
        var outcomes: [DeliveryOutcome] = []
        for sink in sinks {
            // Fresh meta per sink: the previous sink's write is on disk, and
            // fail closed — unreadable meta is never delivered.
            guard let meta = readMetaOrLogOnce(slot),
                  sink.applies(to: meta), !meta.isDelivered(to: sink.id),
                  isReady(sink, slot: slot, meta: meta),
                  ignoringSchedule || isDue(sink, meta: meta, now: now) else { continue }
            let result: Result<SinkDelivery, any Error>
            do {
                result = .success(try await sink.deliver(slot: slot, meta: meta))
            } catch {
                result = .failure(error)
            }
            outcomes.append(recordOutcome(result, sink: sink, slot: slot, deliveredMeta: meta))
        }
        return outcomes
    }

    /// The one place a delivery's result lands in meta.json; a caller that
    /// drives a sink directly must record through it too. `deliveredMeta`
    /// is the meta the delivery was made from: if a re-transcribe replaced the transcript meanwhile, a success
    /// is NOT recorded as delivered, only its location is remembered.
    @discardableResult
    static func recordOutcome(
        _ result: Result<SinkDelivery, any Error>,
        sink: any TranscriptSink,
        slot: OutboxSlot,
        deliveredMeta: RecordingMeta
    ) -> DeliveryOutcome {
        let transcribedAt = deliveredMeta.transcription?.transcribed_at
        switch result {
        case .success(let delivery):
            updateMeta(slot) { current in
                if current.transcription?.transcribed_at == transcribedAt {
                    current.recordDelivery(delivery, for: sink.id)
                } else if let location = delivery.location {
                    var previous = current.previous_locations ?? [:]
                    previous[sink.id] = location
                    current.previous_locations = previous
                }
            }
            dispatchLog.notice("delivered \(slot.slug, privacy: .public) → \(sink.id, privacy: .public)")
        case .failure(let error):
            updateMeta(slot) { $0.recordAttempt(for: sink.id) }
            // Error text can echo transcript content or a home-folder path:
            // private. The sink id stays readable.
            dispatchLog.error("delivery of \(slot.slug, privacy: .public) → \(sink.id, privacy: .public) failed: \(String(describing: error), privacy: .private)")
        }
        return DeliveryOutcome(sinkID: sink.id, sinkName: sink.displayName, result: result)
    }

    /// Recordings with at least one pending sink that is ready for them,
    /// newest first.
    static func pendingSlots() -> [OutboxSlot] {
        let sinks = activeSinks()
        guard !sinks.isEmpty else { return [] }
        return Outbox.listSlots().filter { slot in
            guard let meta = readMetaOrLogOnce(slot) else { return false }
            return pendingSinks(for: meta, among: sinks).contains { isReady($0, slot: slot, meta: meta) }
        }
    }

    static func pendingCount() -> Int { pendingSlots().count }

    /// Re-read, mutate, write. A failure is logged, not thrown: the
    /// delivery itself already happened (or failed) and the caller can't
    /// undo that.
    private static func updateMeta(_ slot: OutboxSlot, _ change: (inout RecordingMeta) -> Void) {
        do {
            try Outbox.mutateMeta(slot, change)
        } catch {
            dispatchLog.error("couldn't record delivery state for \(slot.slug, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private static func readMetaOrLogOnce(_ slot: OutboxSlot) -> RecordingMeta? {
        do {
            return try Outbox.readMeta(from: slot.metaURL)
        } catch {
            if undecodableLogged.withLock({ $0.insert(slot.slug).inserted }) {
                dispatchLog.error("meta.json for \(slot.slug, privacy: .public) unreadable; not delivering it: \(String(describing: error), privacy: .public)")
            }
            return nil
        }
    }
}
