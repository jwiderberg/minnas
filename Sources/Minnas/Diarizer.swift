//
// On-device speaker diarization for the "Them" stream.
//
// The system stream is everyone-but-me. WhisperKit has no notion of
// speakers, so without the cloud tier a three-way call came out as one
// undifferentiated "Them". FluidAudio's offline pipeline (pyannote
// community-1 segmentation + WeSpeaker embeddings + VBx clustering, all as
// Core ML) tells us who spoke when; `label(_:with:)` then stamps each STT
// segment with the speaker that covers most of it, and TranscriptBuilder
// renders those as "Them (A)" / "Them (B)" exactly like the cloud engine's
// output.
//
// Granularity caveat: a WhisperKit segment can span a speaker change (they
// run up to ~30 s). We label by the dominant speaker and don't split —
// word-level timestamps would be the fix, deferred.
//
// Models (~50 MB) download from Hugging Face on first use into
// ~/Library/Application Support/FluidAudio/Models/ and are cached. The
// pipeline instance is kept for the app's lifetime like the WhisperKit one.
// Diarization is best-effort: any failure is logged and the transcript is
// produced without speaker letters.
//

import AVFoundation
import FluidAudio
import Foundation
import os.log

private let diarizeLog = Logger(subsystem: "com.jwiderberg.minnas", category: "Diarize")

/// One stretch of one speaker's speech, in seconds from the file start.
struct SpeakerTurn: Sendable {
    let speaker: String   // "A", "B", … in order of first appearance
    let start: Float
    let end: Float
}

final class Diarizer: @unchecked Sendable {
    static let shared = Diarizer()

    private var manager: OfflineDiarizerManager?

    /// Diarizes `audioPath` (anything AVAudioFile reads: caf, m4a, wav…).
    /// Returns nil when only one speaker was found — the caller then leaves
    /// segments unlabelled rather than tagging every line "(A)".
    /// `onProgress` reports 0…1 for the segmentation pass.
    func diarize(audioPath: String, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> [SpeakerTurn]? {
        let manager = try await ensureLoaded()
        let started = Date()
        let result = try await manager.process(URL(fileURLWithPath: audioPath)) { done, total in
            guard total > 0 else { return }
            onProgress?(Double(done) / Double(total))
        }
        // Letters by first appearance so "A" is whoever spoke first.
        var letters: [String: String] = [:]
        var turns: [SpeakerTurn] = []
        for seg in result.segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            let letter: String
            if let known = letters[seg.speakerId] {
                letter = known
            } else {
                letter = Self.letter(for: letters.count)
                letters[seg.speakerId] = letter
            }
            turns.append(SpeakerTurn(speaker: letter, start: seg.startTimeSeconds, end: seg.endTimeSeconds))
        }
        let elapsed = Date().timeIntervalSince(started)
        let speech = turns.reduce(Float(0)) { $0 + max(0, $1.end - $1.start) }
        diarizeLog.notice("diarized \((audioPath as NSString).lastPathComponent, privacy: .public): \(letters.count, privacy: .public) speaker(s), \(turns.count, privacy: .public) turns, \(Int(speech), privacy: .public)s speech, \(String(format: "%.1f", elapsed), privacy: .public)s")
        Transcriber.shared.trace?("diarize: \(letters.count) speaker(s), \(turns.count) turns in \(String(format: "%.1f", elapsed))s")
        return letters.count >= 2 ? turns : nil
    }

    private func ensureLoaded() async throws -> OfflineDiarizerManager {
        if let manager { return manager }
        // FluidAudio logs every pipeline stage at debug level to stdout by
        // default; keep only warnings and above, and in the unified log.
        AppLogger.minimumLevel = .warning
        AppLogger.mirrorsToConsole = false
        var config = OfflineDiarizerConfig.default
        // A meeting's remote side is rarely more than a handful of people;
        // capping keeps a noisy line from fragmenting into phantom speakers.
        config.clustering.maxSpeakers = 8
        let m = OfflineDiarizerManager(config: config)
        let started = Date()
        try await m.prepareModels()
        diarizeLog.notice("diarizer models ready in \(String(format: "%.1f", Date().timeIntervalSince(started)), privacy: .public)s")
        manager = m
        return m
    }

    private static func letter(for index: Int) -> String {
        let scalars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        if index < scalars.count { return String(scalars[index]) }
        return "\(scalars[index % scalars.count])\(index / scalars.count + 1)"
    }

    /// Stamps every segment with the speaker whose turns overlap it most.
    /// A segment touching no turn (Whisper padded a silence, or the
    /// diarizer missed a short utterance) takes the nearest turn's speaker
    /// so no line is left as a bare "Them" among lettered ones.
    static func label(_ results: [STTResult], with turns: [SpeakerTurn]) -> [STTResult] {
        guard !turns.isEmpty else { return results }
        return results.map { result in
            STTResult(
                segments: result.segments.map { seg in
                    STTSegment(start: seg.start, end: seg.end, text: seg.text, speaker: speaker(for: seg, in: turns))
                },
                language: result.language
            )
        }
    }

    static func speaker(for seg: STTSegment, in turns: [SpeakerTurn]) -> String {
        var overlap: [String: Float] = [:]
        var nearest: (speaker: String, distance: Float)?
        for turn in turns {
            let shared = min(seg.end, turn.end) - max(seg.start, turn.start)
            if shared > 0 {
                overlap[turn.speaker, default: 0] += shared
            } else {
                let distance = max(turn.start - seg.end, seg.start - turn.end)
                if nearest == nil || distance < nearest!.distance {
                    nearest = (turn.speaker, distance)
                }
            }
        }
        if let best = overlap.max(by: { $0.value < $1.value }) { return best.key }
        return nearest?.speaker ?? turns[0].speaker
    }
}
