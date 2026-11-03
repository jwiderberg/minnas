//
// The transcribe → build → persist core, shared by the menubar flow
// (AppDelegate.startTranscription) and the --retranscribe CLI harness so the
// two can't drift.
//
// Reads a slot's meta + audio, resolves ONE language over both streams (so
// mic and system never disagree), transcribes each stream, builds the
// transcript, and writes transcript.md then meta.json (in that order — see
// finish). It does NOT deliver or compress — the caller owns those side
// effects (the UI path delivers + compresses; the CLI path deliberately
// does neither).
//
// Progress: `onProgress` reports a 0…1 fraction for the whole job — mic
// spans 0–50% and system 50–100%, or mic spans the full 0–100% when the
// system stream is a near-duplicate of the mic and skipped.
//

import Foundation
import os.log

private let jobLog = Logger(subsystem: "com.jwiderberg.minnas", category: "TranscriptionJob")

enum TranscriptionJob {
    enum JobError: Error, CustomStringConvertible {
        case badSegmentTimes(index: Int, start: Float, end: Float)
        var description: String {
            switch self {
            case .badSegmentTimes(let index, let start, let end):
                return "transcript segment \(index) has bad times (start \(start), end \(end)); nothing was written"
            }
        }
    }

    @discardableResult
    static func run(
        slot: OutboxSlot,
        model: TranscriptionModel = .default,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> TranscriptBuilder.Output {
        // Reload meta from disk so the call is decoupled from any in-memory
        // RecordingSession state (which stop() may have cleared).
        let meta = try Outbox.readMeta(from: slot.metaURL)

        // Local engines don't separate speakers; the "Them" stream (or a
        // single-stream import, where everyone is in one file) gets a
        // diarization pass that stamps each segment with a speaker letter.
        // Skipped in a 1:1 — the stream IS the other attendee by name.
        let diarize = Config.diarizationEnabled() && model.engine == .whisperKit
            && (meta.isSingleStream || TranscriptBuilder.soleOtherAttendeeName(meta.attendees) == nil)
        // Progress budget: the diarization pass is fast next to STT, so it
        // takes the last tenth when it runs.
        let sttShare = diarize ? 0.9 : 1.0

        // An imported voice memo or file is a single stream stored in the
        // system slot (there is no "mic" side — everyone is in it). Skip
        // the two-stream dance and transcribe just that file.
        if meta.isSingleStream {
            let audio = slot.systemAudioReadURL
            let policy = LanguagePolicy.current(attendees: meta.attendees)
            let start = (try? await Transcriber.shared.resolveLanguage(forStreams: [audio], model: model, policy: policy)) ?? nil
            var results = try await Transcriber.shared.transcribe(
                audioPath: audio.path, model: model, language: Config.sttLanguage(),
                startLanguage: start, policy: policy,
                onProgress: onProgress.map { cb in { @Sendable f in cb(f * sttShare) } }
            )
            if diarize {
                results = await labelSpeakers(results, audio: audio, onProgress: onProgress.map { cb in { @Sendable f in cb(sttShare + f * (1 - sttShare)) } })
            }
            return try finish(
                slot: slot, meta: meta, micResults: [], systemResults: results,
                provenance: TranscriptionProvenance(engine: model.engine.rawValue, model: model.rawValue, transcribed_at: Date())
            )
        }

        // When the mic and system streams are near-duplicates (recording on
        // speakers — the mic caught everything), skip the redundant system
        // pass: halves the work and avoids duplicated Me/Them turns.
        let micAudio = slot.micAudioReadURL
        let systemAudio = slot.systemAudioReadURL
        let duplicate = AudioDuplication.systemDuplicatesMic(mic: micAudio, system: systemAudio)
        let streams = duplicate ? [micAudio] : [micAudio, systemAudio]
        // One dominant language across both streams is the STARTING point;
        // each stream then re-checks per chunk (a Swedish stretch inside an
        // English meeting, or vice versa). An explicit pin skips all that.
        let pinned = Config.sttLanguage()
        let policy = LanguagePolicy.current(attendees: meta.attendees)
        let start = (try? await Transcriber.shared.resolveLanguage(forStreams: streams, model: model, policy: policy)) ?? nil

        let micResults = try await Transcriber.shared.transcribe(
            audioPath: micAudio.path, model: model, language: pinned, startLanguage: start, policy: policy,
            onProgress: onProgress.map { cb in { @Sendable f in cb(duplicate ? f : f * 0.5 * sttShare) } }
        )
        var systemResults: [STTResult] = duplicate ? [] : try await Transcriber.shared.transcribe(
            audioPath: systemAudio.path, model: model, language: pinned, startLanguage: start, policy: policy,
            onProgress: onProgress.map { cb in { @Sendable f in cb((0.5 + f * 0.5) * sttShare) } }
        )
        if diarize && !duplicate && !systemResults.isEmpty {
            systemResults = await labelSpeakers(systemResults, audio: systemAudio, onProgress: onProgress.map { cb in { @Sendable f in cb(sttShare + f * (1 - sttShare)) } })
        }

        return try finish(
            slot: slot, meta: meta, micResults: micResults, systemResults: systemResults,
            provenance: TranscriptionProvenance(engine: model.engine.rawValue, model: model.rawValue, transcribed_at: Date())
        )
    }

    /// Best-effort: a diarization failure (models not downloadable, odd
    /// file) must never cost the transcript, so it logs and returns the
    /// results unlabelled.
    private static func labelSpeakers(
        _ results: [STTResult], audio: URL, onProgress: (@Sendable (Double) -> Void)?
    ) async -> [STTResult] {
        do {
            guard let turns = try await Diarizer.shared.diarize(audioPath: audio.path, onProgress: onProgress) else {
                return results
            }
            return Diarizer.label(results, with: turns)
        } catch {
            Transcriber.shared.trace?("diarize failed: \(error)")
            jobLog.error("diarization failed for \(audio.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public); transcript left unlabelled")
            return results
        }
    }

    /// The build → persist half, shared with the Voice Memos import, which
    /// already has STT results (Apple's embedded transcript) and only needs
    /// transcript.md + meta.json written.
    @discardableResult
    static func finish(
        slot: OutboxSlot,
        meta: RecordingMeta,
        micResults: [STTResult],
        systemResults: [STTResult],
        provenance: TranscriptionProvenance
    ) throws -> TranscriptBuilder.Output {
        // Imports and slots made by older code may carry an un-normalised
        // title; the transcript's heading, frontmatter and the folder file
        // name all come from it, so bound it here too.
        var meta = meta
        meta.title = Outbox.normalizeTitle(meta.title)
        let output = TranscriptBuilder.build(meta: meta, micResults: micResults, systemResults: systemResults)
        // Segment sanity check before anything is written: a NaN, negative or
        // reversed timestamp means the engine returned garbage, and a
        // transcript ordered by it would be nonsense. The audio stays, so
        // the recording can be re-transcribed.
        try checkSegments(output.segments)
        // ORDERING INVARIANT (SinkDispatcher relies on it): transcript.md is
        // written FIRST, meta.json — which resets every sink's delivery to
        // pending — LAST. Written the other way round, a retry tick (or
        // `--deliver`) landing between the meta write and the transcript
        // write would see "pending" and deliver the PREVIOUS transcript as if
        // it were this generation, then mark it delivered. Now a tick in
        // that window sees the old meta: either still delivered (nothing
        // sent), or pending and sending the new file, recorded against the
        // old generation and so re-sent once the reset lands. The stamp is
        // taken before the file is written, so its mtime is ≥ it; the
        // dispatcher refuses a required file older than the stamp.
        let writtenAt = Date()

        // Everything this generation changes in meta, applied under the meta
        // lock at the end to whatever is on disk then (so a field another
        // path wrote during a long transcription — a delivery — survives).
        func apply(_ m: inout RecordingMeta) {
            m.title = meta.title
            // Keep the prior pass's languages if this engine reported none
            // (e.g. a cloud diarize rerun over a local transcript).
            if !output.languages.isEmpty { m.languages_detected = output.languages }
            m.transcription = provenance
            m.transcript_written_at = writtenAt
            // New transcript content supersedes every prior delivery: each
            // sink re-delivers, and the folder sink overwrites its old file
            // via the location resetDeliveries keeps in previous_locations.
            m.resetDeliveries()
        }

        try output.markdown.write(to: slot.transcriptURL, atomically: true, encoding: .utf8)
        // Last. `meta` (as the job began) stands in only if meta.json has
        // become unreadable.
        try Outbox.mutateMeta(slot, ifUnreadable: meta, apply)
        return output
    }

    /// Every segment must have finite, non-negative times with end ≥ start.
    static func checkSegments(_ segments: [TranscriptSegment]) throws {
        for (i, s) in segments.enumerated() {
            guard s.start.isFinite, s.end.isFinite, s.start >= 0, s.end >= s.start else {
                throw JobError.badSegmentTimes(index: i, start: s.start, end: s.end)
            }
        }
    }
}
