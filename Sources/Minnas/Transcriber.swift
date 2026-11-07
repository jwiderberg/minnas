//
// Lazy-loaded WhisperKit wrapper.
//
// The model (~2.9 GB of CoreML packages) downloads on first use into
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
        case audioReadFailed(path: String, start: Double, underlying: Error)
        case audioEndedEarly(path: String, start: Double, expectedEnd: Double)
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
    /// The file is decoded in 30 s windows either way (silent windows are
    /// skipped). `language` PINS every window to one language ("en"/"sv").
    /// nil means detect: decoding starts from `startLanguage` (the
    /// recording-wide dominant language, so both streams begin in
    /// agreement) and a window may switch to another `policy` candidate
    /// when the model is clearly more confident there.
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

    /// Picks the dominant language among `candidates` by sampling 30 s
    /// windows spread across the recording (at least 45 s apart) and summing
    /// the detector's probability for its best candidate in each. Sampling
    /// the whole file (not just the
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
            guard let array = try? Self.loadWindow(audioPath, start: start, length: DecodeWindow.seconds),
                  Self.speechSeconds(array) >= DecodeWindow.minVoteSpeech else { continue }
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

    private static func loadWindow(_ audioPath: String, start: Double, length: Double) throws -> [Float]? {
        let buffer = try AudioProcessor.loadAudio(
            fromPath: audioPath, channelMode: .sumChannels(nil),
            startTime: start, endTime: start + length, maxReadFrameSize: nil
        )
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

    /// The one decode loop, used for every local transcription: the file
    /// is decoded in Whisper's natural 30 s windows, each pinned to the
    /// current language. `DecodeWindow.plan` decides per window: under
    /// 0.5 s of speech-level audio the window is not decoded at all
    /// (Whisper hallucinates on silence); from 2.5 s it may vote, and
    /// `DecodeWindow.apply` turns the language token (restricted to the
    /// policy's candidates) into a switch on one window at p ≥ 0.85 or two
    /// in a row at ≥ 0.7. With `fixedLanguage` (an explicit pin, or a policy
    /// with one candidate) no window votes and the language never changes;
    /// the silence skip still applies. Window boundaries follow Whisper's
    /// own segment ends — a segment cut by the window end is dropped and
    /// re-decoded at the start of the next window — so nothing is split
    /// mid-sentence. One STTResult per window carries that window's
    /// language.
    /// Re-rolls of a window whose first pass decoded to nothing.
    static let maxContentlessRerolls = 2

    private func whisperKitTranscribeChunked(
        audioPath: String,
        model: TranscriptionModel,
        startLanguage: String,
        fixedLanguage: Bool,
        policy: LanguagePolicy,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> [STTResult] {
        let pipe = try await ensureLoaded(model: model)
        let duration = CMTimeGetSeconds(try await AVURLAsset(url: URL(fileURLWithPath: audioPath)).load(.duration))
        let window = DecodeWindow.seconds
        let minTail = 5.0              // fold a very short final remainder into the previous window

        var state = DecodeWindow.State(language: startLanguage, fixed: fixedLanguage)
        var results: [STTResult] = []
        var t = 0.0
        while t < duration - 0.5 {
            var end = min(t + window, duration)
            if duration - end < minTail { end = duration }
            let array: [Float]
            do {
                guard let loaded = try Self.loadWindow(audioPath, start: t, length: end - t) else {
                    // A sub-second tail at the known asset end is normal.
                    // The same short read before that point means the file
                    // disappeared or became unreadable mid-transcription.
                    if end >= duration - 0.01 { break }
                    throw TranscriberError.audioEndedEarly(path: audioPath, start: t, expectedEnd: end)
                }
                let expectedFrames = Int((end - t) * 16_000)
                if end < duration - 0.01, loaded.count + 1_600 < expectedFrames {
                    throw TranscriberError.audioEndedEarly(path: audioPath, start: t, expectedEnd: end)
                }
                array = loaded
            } catch let error as TranscriberError {
                throw error
            } catch {
                throw TranscriberError.audioReadFailed(path: audioPath, start: t, underlying: error)
            }

            // The gates are ACOUSTIC (speechSeconds), see DecodeWindow for
            // why each threshold sits where it does.
            let speech = Self.speechSeconds(array)
            guard case .decode(let votes) = DecodeWindow.plan(speechSeconds: speech, state: state) else {
                traceLine("chunk \(Int(t))–\(Int(end))s skipped (\(String(format: "%.1f", speech)) s of speech)")
                onProgress?(min(1, end / max(duration, 1)))
                t = end
                continue
            }
            var note = ""
            if votes {
                let vote = try await languageVote(pipe, array, candidates: policy.candidates)
                note = " [\(vote.describe)]"
                let applied = DecodeWindow.apply(
                    detectedLanguage: vote.best?.language, probability: vote.best?.probability ?? 0, to: state
                )
                state = applied.0
                switch applied.1 {
                case .stay: break
                case .pending: note += " pending"
                case .switched(let from, let to): note += " \(from)→\(to)"
                }
            }
            let language = state.language

            var pass = try await decodeChunk(pipe, array, language: language, offset: t)
            // WhisperKit occasionally returns an empty/stock pass on audio
            // that has speech (temperature-fallback variance). Every window
            // reaching this point has ≥ DecodeWindow.skipBelowSpeech s of
            // speech-level audio (silent ones were skipped above), so a
            // contentless pass is suspect: re-roll with more fallbacks, up
            // to twice. (The old whole-file pinned path re-rolled up to five
            // times over the whole file; a short recording is one window, so
            // the budget here is what it gets.) Silence never reaches this.
            var rerolls = 0
            while !pass.hasContent, rerolls < Self.maxContentlessRerolls {
                rerolls += 1
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


    private func whisperKitTranscribe(
        audioPath: String,
        model: TranscriptionModel,
        language languageOverride: String?,
        startLanguage: String?,
        policy: LanguagePolicy,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> [STTResult] {
        // An explicit pin (caller, menu, or STT_LANGUAGE) means one
        // language for the whole file; a single candidate is the same
        // thing. Both go through the same windowed decode as detection,
        // with the language fixed, so silent windows are skipped there too.
        // Whisper's own free per-window detection is never used: it flaps
        // to whatever each 30 s window looks like (a window of call audio
        // can come back in an unrelated language).
        if let pin = languageOverride ?? Config.sttLanguage() ?? (policy.candidates.count == 1 ? policy.primary : nil) {
            return try await whisperKitTranscribeChunked(
                audioPath: audioPath, model: model, startLanguage: pin, fixedLanguage: true,
                policy: policy, onProgress: onProgress
            )
        }
        let start: String
        if let startLanguage {
            start = startLanguage
        } else {
            start = (try? await resolveLanguage(forStreams: [URL(fileURLWithPath: audioPath)], model: model, policy: policy)) ?? policy.primary
        }
        return try await whisperKitTranscribeChunked(
            audioPath: audioPath, model: model, startLanguage: start, fixedLanguage: false,
            policy: policy, onProgress: onProgress
        )
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

/// The per-window decisions of `Transcriber`'s windowed decode, as pure
/// functions so they can be tested without a model. Thresholds are in
/// seconds of speech-level audio (`Transcriber.speechSeconds`) and in
/// language-token probability restricted to the policy's candidates.
enum DecodeWindow {
    /// Whisper's natural window; also the length of a language probe.
    static let seconds = 30.0
    /// Below this the window is not decoded at all. Whisper hallucinates on
    /// silence — a quiet mic produces invented sentences, the same short
    /// phrase every 30 s, or one word repeated dozens of times — and the mic
    /// stream is silent whenever "Them" talk, so this is also most of its
    /// decode time saved.
    static let skipBelowSpeech = 0.5
    /// From this much speech a window may vote on the language. On
    /// silence/breath the detector leans "en" at 0.5–0.7, which was enough
    /// to flip a Swedish meeting into a translated window. The gate is
    /// acoustic on purpose: gating on the decoded word count fails when the
    /// current language is the wrong one (pinned to "en", Swedish decodes to
    /// a few translated words, so the window never earned a vote).
    static let minVoteSpeech = 2.5
    /// One window this confident switches. Measured on compressed call
    /// audio: correct-language readings are almost all ≥ 0.9, stray
    /// readings almost all < 0.7.
    static let switchNow: Float = 0.85
    /// Two voting windows in a row at this switch.
    static let switchSoon: Float = 0.7

    struct State: Equatable, Sendable {
        var language: String
        /// A moderate reading of another language, awaiting confirmation.
        var pending: String?
        /// Pinned or single-candidate: never votes, never switches.
        let fixed: Bool

        init(language: String, pending: String? = nil, fixed: Bool = false) {
            self.language = language
            self.pending = pending
            self.fixed = fixed
        }
    }

    enum Plan: Equatable, Sendable {
        case skip
        case decode(vote: Bool)
    }

    enum Outcome: Equatable, Sendable {
        case stay
        case pending(String)
        case switched(from: String, to: String)
    }

    /// Decode this window? And does it vote on the language?
    static func plan(speechSeconds: Double, state: State) -> Plan {
        guard speechSeconds >= skipBelowSpeech else { return .skip }
        return .decode(vote: !state.fixed && speechSeconds >= minVoteSpeech)
    }

    /// Applies one voting window's detection (the best candidate and its
    /// probability; nil when no candidate has any mass). Any vote that does
    /// not confirm the pending language clears it; windows that do not
    /// vote never reach here, so they leave it as it was.
    static func apply(detectedLanguage: String?, probability: Float, to state: State) -> (State, Outcome) {
        guard !state.fixed else { return (state, .stay) }
        var next = state
        guard let detected = detectedLanguage, probability > 0, detected != state.language else {
            next.pending = nil
            return (next, .stay)
        }
        if probability >= switchNow || (state.pending == detected && probability >= switchSoon) {
            next.language = detected
            next.pending = nil
            return (next, .switched(from: state.language, to: detected))
        }
        if probability >= switchSoon {
            next.pending = detected
            return (next, .pending(detected))
        }
        next.pending = nil
        return (next, .stay)
    }
}
