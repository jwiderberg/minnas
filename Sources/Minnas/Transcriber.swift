//
// Lazy-loaded WhisperKit wrapper.
//
// The model (~1.5GB of CoreML packages) downloads on first use into
// ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/ by
// default; subsequent calls reuse the on-disk cache. WhisperKit's
// pipeline state itself takes a few seconds to load even from cache,
// so we cache the WhisperKit instance for the lifetime of the app.
//
// Concurrency: WhisperKit instances are not safe to use from multiple
// callers concurrently — only one transcription can run at a time
// against a given pipeline. We rely on caller discipline (AppDelegate's
// transcribingTitle gates serialize the menu UX, and only one Task
// awaits transcribe() at a time). The class is marked @unchecked
// Sendable so the static `shared` reference can cross actors;
// WhisperKit itself is not Sendable and can't be wrapped in an actor
// because calling its nonisolated async methods would require sending
// the non-Sendable instance across the isolation boundary.
//

import AVFoundation
import Accelerate
import Foundation
import WhisperKit
import os.log

private let transcribeLog = Logger(subsystem: "com.jwiderberg.minnas", category: "Transcribe")

/// A selectable speech-to-text model. Today these are all local WhisperKit
/// models running on the Apple Neural Engine; cloud engines slot in later
/// as additional cases behind the same `Transcriber.transcribe` entry
/// point, so the rest of the app picks an engine without caring where it
/// runs. `rawValue` is WhisperKit's published Hugging Face model id.
///
/// Naming gotcha: WhisperKit joins version and "turbo" with an
/// UNDERSCORE, not a hyphen — "large-v3-turbo" returns modelsUnavailable.
enum TranscriptionModel: String, CaseIterable, Codable, Sendable {
    case turbo = "large-v3_turbo"
    case largeV3 = "large-v3"
    case medium = "medium"
    // Cloud. rawValue is the OpenAI API model id. The diarize variant is
    // the one cloud model we offer because it's the only gpt-4o tier that
    // returns segment timestamps (via diarized_json) — plain
    // gpt-4o-transcribe returns text only, which would break the Me/Them
    // interleaving in TranscriptBuilder.
    case openAIDiarize = "gpt-4o-transcribe-diarize"

    // Large v3 over Turbo: accuracy beats speed for this tool — a recording
    // is transcribed once in the background and read many times, so the
    // extra minutes on the ANE are invisible while the mis-heard names in
    // Turbo output are not. Turbo stays selectable from the Re-transcribe
    // menu for a quick first pass.
    static let `default`: TranscriptionModel = .largeV3

    /// Where the model runs. Drives which engine Transcriber dispatches to.
    enum Engine: String, Codable, Sendable {
        case whisperKit = "whisperkit"
        case openAI = "openai"
    }

    var engine: Engine {
        switch self {
        case .turbo, .largeV3, .medium: return .whisperKit
        case .openAIDiarize: return .openAI
        }
    }

    /// Human-readable label for the re-transcribe menu.
    var displayName: String {
        switch self {
        case .turbo:        return "Large v3 Turbo — local, fast, lower accuracy"
        case .largeV3:      return "Large v3 — local, best local accuracy (default)"
        case .medium:       return "Medium — local, fastest, lower accuracy"
        case .openAIDiarize: return "GPT-4o Transcribe Diarize — cloud, highest accuracy"
        }
    }

    var whisperKitName: String { rawValue }
}

final class Transcriber: @unchecked Sendable {
    static let shared = Transcriber()

    enum TranscriberError: Error {
        case loadFailed(underlying: Error)
        case transcribeFailed(underlying: Error)
    }

    private var pipeline: WhisperKit?
    // Which model the cached pipeline holds. A re-transcribe with a
    // different model reloads the pipeline (a few seconds), so we only
    // pay that cost when the requested model actually changes.
    private var loadedModel: TranscriptionModel?

    var isLoaded: Bool { pipeline != nil }

    /// Transcribes an audio file with the given model, returning
    /// engine-agnostic results. Dispatches to the local WhisperKit
    /// pipeline or a cloud engine based on `model.engine`.
    /// `onProgress` reports a 0…1 fraction for THIS file as decoding
    /// proceeds (called off the main actor; hop before touching UI).
    /// `language` PINS the whole file to one language ("en"/"sv"). nil
    /// means detect: the file is transcribed in chunks starting from
    /// `startLanguage` (the recording-wide dominant language, so both
    /// streams begin in agreement) and each chunk may switch to another
    /// `policy` candidate when the model is clearly more confident there.
    func transcribe(
        audioPath: String,
        model: TranscriptionModel = .default,
        language: String? = nil,
        startLanguage: String? = nil,
        policy: LanguagePolicy? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [STTResult] {
        switch model.engine {
        case .whisperKit:
            return try await whisperKitTranscribe(
                audioPath: audioPath, model: model, language: language,
                startLanguage: startLanguage, policy: policy ?? .current(), onProgress: onProgress
            )
        case .openAI:
            // The cloud model code-switches natively; the hint is the
            // explicit pin, else the dominant language.
            return try await CloudTranscriber.transcribe(audioPath: audioPath, model: model, language: language ?? startLanguage, onProgress: onProgress)
        }
    }

    /// Optional per-chunk trace line sink (the CLI harnesses print it);
    /// the same lines always go to the unified log at notice level.
    var trace: (@Sendable (String) -> Void)?

    private func traceLine(_ line: String) {
        transcribeLog.notice("\(line, privacy: .public)")
        trace?(line)
    }

    /// Resolves one language for a whole recording by combining the
    /// transcribe-confidence probe across every stream — so the mic and
    /// system streams never disagree (e.g. a mostly-silent mic mis-probing
    /// "en" while the system clearly reads "sv"). Returns a pin or, for
    /// auto, the combined winner.
    func resolveLanguage(forStreams urls: [URL], model: TranscriptionModel = .default, policy: LanguagePolicy = .current()) async throws -> String? {
        if let pinned = Config.sttLanguage() { return pinned }
        let candidates = policy.candidates
        var total: [String: Float] = [:]
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            // Probe each stream independently: one stream failing to read
            // must not abort language resolution for the whole recording.
            guard let (_, scores) = try? await detectLanguageScores(audioPath: url.path, candidates: candidates, model: model) else { continue }
            for (lang, score) in scores { total[lang, default: 0] += score }
        }
        // Votes are SUMMED across streams: a mostly-silent mic contributes
        // the few confident windows it has, the talkative stream the rest.
        let winner = policy.winner(total) ?? policy.primary
        traceLine("language: votes " + Self.format(total) + " margin=\(String(format: "%.2f", policy.margin)) → \(winner)")
        return winner
    }

    private static func format(_ scores: [String: Float]) -> String {
        scores.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.3f", $0.value))" }.joined(separator: " ")
    }

    /// Picks the dominant language among `candidates` by sampling several
    /// 30s windows spread across the recording and summing WhisperKit's
    /// per-window language log-probs. Sampling the whole file (not just the
    /// first window, which `detectLanguage(audioPath:)` uses) is what makes
    /// this robust: a Swedish meeting that opens with a few English words no
    /// longer mis-detects as English. Returns nil if nothing could be read.
    func detectDominantLanguage(audioPath: String, candidates: [String], model: TranscriptionModel = .default) async throws -> String? {
        try await detectLanguageScores(audioPath: audioPath, candidates: candidates, model: model).winner
    }

    /// Scores each candidate by Whisper's language token over several 30 s
    /// windows spread across the file: each window where the detector's
    /// best candidate has probability p adds p to that language's score.
    /// Windows of silence or noise (the detector says "nn"/"da" with no
    /// candidate mass) are skipped — the mic stream is mostly silent while
    /// "Them" talk. Comparing pinned-transcription confidence instead was
    /// tried and is biased: pinned to "en" on Swedish audio the model
    /// quietly translates, fluently and confidently, so Swedish speech can
    /// score BETTER as English. The language token has no such bias.
    func detectLanguageScores(audioPath: String, candidates: [String], model: TranscriptionModel = .default) async throws -> (winner: String?, scores: [String: Float]) {
        guard candidates.count > 1 else { return (candidates.first, [:]) }
        let probeModel = model.engine == .whisperKit ? model : .default
        let pipe = try await ensureLoaded(model: probeModel)
        let duration = CMTimeGetSeconds(try await AVURLAsset(url: URL(fileURLWithPath: audioPath)).load(.duration))

        // Every ~45 s (cap 24 windows): detection is one encoder pass, so
        // a dense sample is cheap, and the per-window detector is noisy on
        // compressed call audio (a third of a non-English speaker's windows
        // can lean "en" at 0.5–0.8) — many votes beat a few.
        let step = max(45.0, duration / 24)
        let starts: [Double] = stride(from: min(15, duration / 2), to: duration - 10, by: step).map { $0 }
        var scores: [String: Float] = [:]
        for start in starts {
            guard let array = Self.loadWindow(audioPath, start: start, length: 30),
                  Self.speechSeconds(array) >= 2.5 else { continue }
            let vote = try await languageVote(pipe, array, candidates: candidates)
            traceLine("probe \(Int(start))s: \(vote.describe)")
            if let best = vote.best { scores[best.language, default: 0] += best.probability }
        }
        guard !scores.isEmpty else { return (candidates.first, scores) }
        return (scores.max { $0.value < $1.value }?.key, scores)
    }

    /// One language-token detection, restricted to the candidates.
    private struct LanguageVote {
        let top: String                           // what the detector itself picked (any of 99)
        let probabilities: [String: Float]        // per candidate
        var best: (language: String, probability: Float)? {
            guard let b = probabilities.max(by: { $0.value < $1.value }), b.value > 0 else { return nil }
            return (b.key, b.value)
        }
        var describe: String {
            let list = probabilities.sorted { $0.key < $1.key }.map { "\($0.key):\(String(format: "%.2f", $0.value))" }.joined(separator: " ")
            return "det=\(top)[\(list)]"
        }
    }

    private func languageVote(_ pipe: WhisperKit, _ array: [Float], candidates: [String]) async throws -> LanguageVote {
        let detected: (language: String, langProbs: [String: Float])
        do { detected = try await pipe.detectLangauge(audioArray: array) } catch {
            throw TranscriberError.transcribeFailed(underlying: error)
        }
        // langProbs are log-probabilities over the languages the detector
        // ranked; an absent candidate is effectively zero.
        var probabilities: [String: Float] = [:]
        for language in candidates {
            probabilities[language] = detected.langProbs[language].map { exp($0) } ?? 0
        }
        return LanguageVote(top: detected.language, probabilities: probabilities)
    }

    private static func loadWindow(_ audioPath: String, start: Double, length: Double) -> [Float]? {
        guard let buffer = try? AudioProcessor.loadAudio(
            fromPath: audioPath, channelMode: .sumChannels(nil),
            startTime: start, endTime: start + length, maxReadFrameSize: nil
        ) else { return nil }
        let array = AudioProcessor.convertBufferToArray(buffer: buffer)
        return array.count > 16_000 ? array : nil
    }

    // MARK: Chunked decoding

    /// One decode of an audio slice pinned to `language`. `score` is the
    /// mean log-prob over CONTENT segments only — stock silence
    /// hallucinations ("Tack.", "Thank you.") would otherwise drag or lift
    /// the mean and say nothing about the language.
    private struct ChunkPass {
        let segments: [STTSegment]
        let score: Float
        let hasContent: Bool
        /// End of the last segment, relative to the slice start.
        let lastEnd: Double
    }

    private func decodeChunk(_ pipe: WhisperKit, _ array: [Float], language: String, offset: Double, fallbacks: Int = 3) async throws -> ChunkPass {
        let options = DecodingOptions(
            task: .transcribe, language: language,
            temperature: 0, temperatureFallbackCount: fallbacks, detectLanguage: false
        )
        let raw: [TranscriptionSegment]
        do { raw = try await pipe.transcribe(audioArray: array, decodeOptions: options).flatMap { $0.segments } } catch {
            throw TranscriberError.transcribeFailed(underlying: error)
        }
        let content = raw.filter { seg in
            let stripped = TranscriptBuilder.stripWhisperTokens(seg.text).trimmingCharacters(in: .whitespacesAndNewlines)
            return !stripped.isEmpty && !TranscriptBuilder.isKnownHallucination(seg.text)
        }
        let score = content.isEmpty ? -Float.infinity : content.map(\.avgLogprob).reduce(0, +) / Float(content.count)
        return ChunkPass(
            segments: raw.map { STTSegment(start: $0.start + Float(offset), end: $0.end + Float(offset), text: $0.text, speaker: nil) },
            score: score, hasContent: !content.isEmpty,
            lastEnd: raw.last.map { Double($0.end) } ?? 0
        )
    }

    /// Transcribes the file in Whisper's natural 30 s windows, each pinned
    /// to the current language, deciding per window from the language
    /// token restricted to the policy's candidates, over windows that decode
    /// with ≥ 2.5 s of speech-level audio: one window at p ≥ 0.85 or two in
    /// a row at ≥ 0.7 switches; silent or near-empty windows never vote,
    /// and windows with < 0.5 s of speech are not decoded (hallucinations). Window boundaries follow Whisper's own segment ends — a
    /// segment cut by the window end is dropped and re-decoded at the start
    /// of the next window — so nothing is split mid-sentence. One STTResult
    /// per window carries that window's language.
    private func whisperKitTranscribeChunked(
        audioPath: String,
        model: TranscriptionModel,
        startLanguage: String,
        policy: LanguagePolicy,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> [STTResult] {
        let pipe = try await ensureLoaded(model: model)
        let duration = CMTimeGetSeconds(try await AVURLAsset(url: URL(fileURLWithPath: audioPath)).load(.duration))
        let window = 30.0
        let minTail = 5.0              // fold a very short final remainder into the previous window
        let switchNow: Float = 0.85    // one window this confident switches
        let switchSoon: Float = 0.7    // or two content windows in a row at this
        let minSpeech = 2.5            // seconds of speech-level audio before a window may vote
        let skipBelow = 0.5            // below this the window isn't decoded at all
        let speechRMS: Float = 0.01    // a degenerate pass over audio this loud is a re-roll

        var language = startLanguage
        var pending: String?           // a moderate reading of another language, awaiting confirmation
        var results: [STTResult] = []
        var t = 0.0
        while t < duration - 0.5 {
            var end = min(t + window, duration)
            if duration - end < minTail { end = duration }
            guard let array = Self.loadWindow(audioPath, start: t, length: end - t) else { break }

            // Language switching considers only windows with enough
            // speech-level audio: on silence/breath the detector leans "en"
            // at 0.5–0.7, which was enough to flip a Swedish meeting into a
            // translated window. The gate is ACOUSTIC on purpose — gating
            // on the decoded word count fails when the current language is
            // the wrong one (pinned to "en", Swedish decodes to a few
            // translated words, so the window never earned a vote).
            // Measured on compressed call audio: correct-language readings are
            // almost all ≥ 0.9, stray readings almost all < 0.7.
            // A window with (almost) no speech-level audio is not decoded at
            // all: Whisper hallucinates on silence — a quiet mic produces
            // invented sentences, the same short phrase every 30 s, or one
            // word repeated dozens of times — and the mic stream is silent whenever "Them"
            // talk, so this is also most of its decode time saved.
            let speech = Self.speechSeconds(array)
            if speech < skipBelow {
                traceLine("chunk \(Int(t))–\(Int(end))s skipped (\(String(format: "%.1f", speech)) s of speech)")
                onProgress?(min(1, end / max(duration, 1)))
                t = end
                continue
            }
            var note = ""
            if speech >= minSpeech {
                let vote = try await languageVote(pipe, array, candidates: policy.candidates)
                note = " [\(vote.describe)]"
                if let best = vote.best, best.language != language {
                    if best.probability >= switchNow || (pending == best.language && best.probability >= switchSoon) {
                        note += " \(language)→\(best.language)"
                        language = best.language
                        pending = nil
                    } else if best.probability >= switchSoon {
                        pending = best.language
                        note += " pending"
                    } else {
                        pending = nil
                    }
                } else {
                    pending = nil
                }
            }

            var pass = try await decodeChunk(pipe, array, language: language, offset: t)
            // WhisperKit occasionally returns an empty/stock pass on audio
            // that plainly has speech (temperature-fallback variance). One
            // re-roll; silent windows (quiet mic while "Them" talk) are left.
            if !pass.hasContent, Self.rms(array) > speechRMS {
                let retry = try await decodeChunk(pipe, array, language: language, offset: t, fallbacks: 5)
                if retry.hasContent { pass = retry }
            }
            traceLine("chunk \(Int(t))–\(Int(end))s \(language)\(pass.hasContent ? "" : " silent")\(note)")

            // Seek like Whisper does: a segment ending within 1 s of the
            // window end was probably cut; re-decode it in the next window.
            var kept = pass.segments
            var next = end
            if end < duration, kept.count > 1, pass.lastEnd > (end - t) - 1.0 {
                kept.removeLast()
                next = Double(kept.last!.end)
                if next - t < 5 { next = end; kept = pass.segments }
            }
            results.append(STTResult(segments: kept, language: language))
            onProgress?(min(1, next / max(duration, 1)))
            t = next
        }
        return results
    }

    /// Seconds of speech-level audio in a 16 kHz window: 100 ms frames whose
    /// RMS clears a fixed floor (Teams/mic speech sits at 0.02–0.2).
    private static func speechSeconds(_ array: [Float]) -> Double {
        let frame = 1_600
        guard array.count >= frame else { return 0 }
        var loud = 0
        array.withUnsafeBufferPointer { buf in
            var i = 0
            while i + frame <= buf.count {
                var value: Float = 0
                vDSP_rmsqv(buf.baseAddress! + i, 1, &value, vDSP_Length(frame))
                if value > 0.01 { loud += 1 }
                i += frame
            }
        }
        return Double(loud) * 0.1
    }

    private static func rms(_ array: [Float]) -> Float {
        var value: Float = 0
        vDSP_rmsqv(array, 1, &value, vDSP_Length(array.count))
        return value
    }

    private func whisperKitTranscribe(
        audioPath: String,
        model: TranscriptionModel,
        language languageOverride: String?,
        startLanguage: String?,
        policy: LanguagePolicy,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> [STTResult] {
        // An explicit pin (caller, menu, or STT_LANGUAGE) means one
        // language for the whole file — the original path below. A single
        // candidate is the same thing. Otherwise detect per chunk.
        if let pin = languageOverride ?? Config.sttLanguage() ?? (policy.candidates.count == 1 ? policy.primary : nil) {
            return try await whisperKitTranscribePinned(audioPath: audioPath, model: model, language: pin, onProgress: onProgress)
        }
        let start: String
        if let startLanguage {
            start = startLanguage
        } else {
            start = (try? await resolveLanguage(forStreams: [URL(fileURLWithPath: audioPath)], model: model, policy: policy)) ?? policy.primary
        }
        return try await whisperKitTranscribeChunked(audioPath: audioPath, model: model, startLanguage: start, policy: policy, onProgress: onProgress)
    }

    private func whisperKitTranscribePinned(
        audioPath: String,
        model: TranscriptionModel,
        language: String,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> [STTResult] {
        let pipe = try await ensureLoaded(model: model)
        // WhisperKit is stochastically unreliable on short/quiet audio: the
        // same file decodes to anywhere from the full transcript to a single
        // empty or silence-hallucination ("you") token, run to run — the
        // variance is inherent to temperature fallback, and greedy temp-0 with
        // no fallback collapses to empty instead (worse). VAD chunking made it
        // WORSE here: the energy detector treats quiet speech as silence and
        // chunks it away. So: keep default windowing, and when a pass comes
        // back degenerate (no real text — empty or only stock hallucinations)
        // re-roll. The failure is random, so a retry almost always recovers;
        // bounded so genuinely-silent audio can't loop.
        // One language for every window. Whisper's own free per-window
        // detection is never used: it flaps to whatever each 30 s window
        // looks like (a window of call audio can come back in an unrelated
        // language). Detection, when wanted, is the chunked path above,
        // constrained to the policy's candidates.
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0,
            temperatureFallbackCount: 5,
            detectLanguage: false
        )
        // Retries reuse the already-loaded pipeline (cheap — no reload), and
        // for normal meeting audio a degenerate pass is rare so this never
        // fires. 5 attempts drives the residual failure rate on marginal
        // (short/quiet) audio low without risking a long loop.
        let maxAttempts = 5
        var lastResults: [STTResult] = []
        var lastSignature: String?
        for attempt in 1...maxAttempts {
            let results: [STTResult]
            do {
                let raw = try await pipe.transcribe(
                    audioPath: audioPath,
                    decodeOptions: options,
                    callback: { _ in
                        // pipe.progress tracks audio-seconds processed for
                        // this call (0…1); forward it as the fraction.
                        onProgress?(pipe.progress.fractionCompleted)
                        return nil
                    }
                )
                results = raw.map { result in
                    STTResult(
                        segments: result.segments.map {
                            STTSegment(start: $0.start, end: $0.end, text: $0.text, speaker: nil)
                        },
                        language: result.language
                    )
                }
            } catch {
                throw TranscriberError.transcribeFailed(underlying: error)
            }
            lastResults = results
            if !Self.isDegenerate(results) { break }
            // A retry only helps when temperature fallback re-rolls to
            // something different. If this degenerate pass is byte-identical
            // to the previous one (e.g. truly silent audio greedy-decoding to
            // the same empty result every time), further attempts are
            // guaranteed identical — stop wasting ANE time.
            let signature = Self.signature(of: results)
            if signature == lastSignature {
                transcribeLog.error("WhisperKit degenerate pass identical to previous (attempt \(attempt, privacy: .public)) — stopping retries for \(audioPath, privacy: .public)")
                break
            }
            lastSignature = signature
            transcribeLog.error("WhisperKit pass was degenerate (attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public)) for \(audioPath, privacy: .public)")
        }
        return lastResults
    }

    /// Stable fingerprint of a pass's text content, for detecting a retry
    /// that produced exactly the same (degenerate) output as the last one.
    private static func signature(of results: [STTResult]) -> String {
        results.flatMap { $0.segments }.map(\.text).joined(separator: "\u{1f}")
    }

    /// A pass is degenerate when no segment carries real content — every
    /// segment is empty (just control tokens) or a stock silence
    /// hallucination ("you", "Thank you."). Such a pass is worth retrying.
    private static func isDegenerate(_ results: [STTResult]) -> Bool {
        for result in results {
            for segment in result.segments {
                let stripped = TranscriptBuilder.stripWhisperTokens(segment.text)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !stripped.isEmpty && !TranscriptBuilder.isKnownHallucination(segment.text) {
                    return false
                }
            }
        }
        return true
    }

    private func ensureLoaded(model: TranscriptionModel) async throws -> WhisperKit {
        if let pipeline, loadedModel == model { return pipeline }
        do {
            let pipe = try await WhisperKit(
                model: model.whisperKitName,
                verbose: false,
                logLevel: .error,
                prewarm: nil,
                load: true,
                download: true
            )
            self.pipeline = pipe
            self.loadedModel = model
            return pipe
        } catch {
            throw TranscriberError.loadFailed(underlying: error)
        }
    }
}
