//
// Builds transcript.md from the per-stream transcriptions (mic + system,
// or the one stream of an import) and aggregates per-language audio
// fractions.
//
// Each STTResult carries its own language; one audio file produces several
// results (one per 30 s decode window locally, one per chunk in the cloud).
// We interleave all segments by start time and group consecutive
// same-speaker segments into one paragraph.
//
// Timestamp alignment caveat: each .caf has its own t=0. The mic stream
// starts within milliseconds of session.start(); ScreenCaptureKit warms
// up over ~0.5–7s before its first sample, so its t=0 is offset later.
// That offset is not tracked, so the very first few segments of a meeting
// may interleave in slightly the wrong order; the rest of the transcript
// is unaffected.
//

import Foundation
import os.log

private let transcriptLog = Logger(subsystem: "com.jwiderberg.minnas", category: "Transcript")

/// One structured transcript row. `speaker` is the rendered label
/// ("Me", "Them", "Them (A)"); timestamps are seconds from recording start.
struct TranscriptSegment: Codable, Sendable {
    var speaker: String
    var start: Float
    var end: Float
    var text: String
    var language: String
}

enum TranscriptBuilder {
    struct Output {
        let markdown: String
        let languages: [DetectedLanguage]
        let segments: [TranscriptSegment]
    }

    static func build(
        meta: RecordingMeta,
        micResults: [STTResult],
        systemResults: [STTResult]
    ) -> Output {
        // A phone voice memo or an imported file is one stream with everyone
        // in it — "Them" would be wrong (it includes the operator), so label
        // it neutrally.
        let systemLabel = meta.isSingleStream ? "Speaker" : "Them"
        struct Labeled {
            let speaker: String
            let start: Float
            let end: Float
            let text: String
            let language: String
        }

        var all: [Labeled] = []
        for result in micResults {
            for segment in result.segments {
                all.append(
                    Labeled(
                        speaker: "Me",
                        start: segment.start,
                        end: segment.end,
                        text: segment.text,
                        language: result.language
                    )
                )
            }
        }
        // 1:1 meetings: if exactly one attendee isn't the operator, the
        // system stream IS that person — name them instead of "Them" (no
        // voice-ID needed). Multi-person meetings keep "Them (A)".
        let themName = Self.soleOtherAttendeeName(meta.attendees)
        for result in systemResults {
            for segment in result.segments {
                // The system stream is everyone-but-me. When the engine
                // diarized it (cloud), label distinct remote voices "Them
                // (A)" etc.; otherwise just "Them". Caveat: diarize speaker
                // ids are per-API-request, so for a meeting long enough to
                // be chunked (>15 min) the same letter across chunks isn't
                // guaranteed to be the same person.
                let speaker: String
                if let themName, !meta.isSingleStream {
                    speaker = themName
                } else if let id = segment.speaker?.trimmingCharacters(in: .whitespaces), !id.isEmpty {
                    speaker = "\(systemLabel) (\(id))"
                } else {
                    speaker = systemLabel
                }
                all.append(
                    Labeled(
                        speaker: speaker,
                        start: segment.start,
                        end: segment.end,
                        text: segment.text,
                        language: result.language
                    )
                )
            }
        }
        all.sort { $0.start < $1.start }

        // Whisper hallucinates a well-known set of stock phrases on
        // silence ("you", "Thank you.", "Thanks for watching.", etc.).
        // A no-speech probability filter would be the principled fix, but
        // WhisperKit returns noSpeechProb=0 under default decoding, so it's
        // useless here. Instead we drop any segment whose entire content
        // exactly matches the blocklist (after normalization).
        //
        // False-positive risk: a real meeting where someone says only
        // "Thank you." at the end loses that. Accepted trade-off for
        // clean output; the drop count is logged so the blocklist can be
        // tuned if it ever eats real speech.
        let beforeFilter = all.count
        // Besides the stock phrases: repetition loops ("*Penis" × 30, one
        // word over and over) and the same segment text repeated window
        // after window on silence ("All right." every 30 s) — keep the
        // first two of a run, drop the rest. Two, not one: the run key is
        // the text alone, across speakers, so a real exchange ("Yes." from
        // Me, "Yes." from Them) must not lose its second half; a silence
        // loop runs to many copies, so two left over is still clean.
        let maxRepeats = 2
        var filtered: [Labeled] = []
        var runText: String?
        var runLength = 0
        for item in all where !Self.isKnownHallucination(item.text) && !Self.isRepetitionLoop(item.text) {
            let key = cleanText(item.text, language: item.language).lowercased()
            if key == runText {
                runLength += 1
                if runLength > maxRepeats { continue }
            } else {
                runText = key
                runLength = 1
            }
            filtered.append(item)
        }
        let dropped = beforeFilter - filtered.count
        // Safety net: never let the blocklist empty an otherwise non-empty
        // transcript. If every segment matched (degraded/very short
        // recording), keep the raw segments — a stray "Thank you." beats
        // losing the whole meeting.
        if filtered.isEmpty && beforeFilter > 0 {
            transcriptLog.error("Hallucination filter would empty the transcript (\(beforeFilter, privacy: .public) segment(s)); keeping raw.")
        } else {
            all = filtered
            if dropped > 0 {
                transcriptLog.info("Dropped \(dropped, privacy: .public) silence-hallucination segment(s).")
            }
        }

        // Per-language audio fractions, by summed segment duration.
        var perLanguageSeconds: [String: Double] = [:]
        for seg in all {
            let dur = Double(max(0, seg.end - seg.start))
            perLanguageSeconds[seg.language, default: 0] += dur
        }
        let totalSeconds = perLanguageSeconds.values.reduce(0, +)
        let languages: [DetectedLanguage] = perLanguageSeconds
            // Drop blank codes: some engines (OpenAI diarize) don't report a
            // language at all, which would otherwise emit a `code:` "" entry.
            // The caller preserves the prior pass's languages in that case.
            .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { code, seconds in
                DetectedLanguage(
                    code: code,
                    fraction: totalSeconds > 0 ? seconds / totalSeconds : 0
                )
            }
            .sorted { $0.fraction > $1.fraction }

        // Markdown body. Frontmatter first.
        var lines: [String] = []
        lines.append("---")
        lines.append("title: \(yamlQuoted(meta.title))")
        lines.append("started_at: \(iso8601(meta.started_at))")
        if let ended = meta.ended_at {
            lines.append("ended_at: \(iso8601(ended))")
        }
        if let eventId = meta.calendar_event_id {
            lines.append("calendar_event_id: \(yamlQuoted(eventId))")
        }
        if let eventUrl = meta.calendar_event_url {
            lines.append("calendar_event_url: \(yamlQuoted(eventUrl))")
        }
        lines.append("device: \(yamlQuoted(meta.device))")
        lines.append("client_version: \(yamlQuoted(meta.client_version))")
        if !languages.isEmpty {
            lines.append("languages_detected:")
            for lang in languages {
                lines.append("  - code: \(lang.code)")
                lines.append("    fraction: \(String(format: "%.3f", lang.fraction))")
            }
        }
        lines.append("---")
        lines.append("")
        lines.append("# \(meta.title)")
        lines.append("")

        var currentSpeaker: String? = nil
        var currentParagraph: [String] = []
        var currentParagraphLength = 0
        var previousEnd: Float? = nil
        // Same-speaker paragraphs break on a pause or on length, else a
        // single-stream recording (a Voice Memo, a monologue) turns into one
        // 16-minute wall of text under one header.
        let pauseBreak: Float = 2.0
        let lengthBreak = 800
        // Structured rows (the harnesses print them; TranscriptionJob checks
        // their times), built from the same normalized text as the markdown
        // so the two stay in sync.
        var segments: [TranscriptSegment] = []
        for seg in all {
            let text = cleanText(seg.text, language: seg.language)
            guard !text.isEmpty else { continue }
            segments.append(
                TranscriptSegment(
                    speaker: seg.speaker,
                    start: seg.start,
                    end: seg.end,
                    text: text,
                    language: seg.language
                )
            )
            let speakerChanged = seg.speaker != currentSpeaker
            let paused = previousEnd.map { seg.start - $0 > pauseBreak } ?? false
            if speakerChanged || paused || currentParagraphLength > lengthBreak {
                if !currentParagraph.isEmpty {
                    lines.append(currentParagraph.joined(separator: " "))
                    lines.append("")
                    currentParagraph.removeAll()
                    currentParagraphLength = 0
                }
                if speakerChanged {
                    lines.append("**\(seg.speaker):**")
                    currentSpeaker = seg.speaker
                }
            }
            currentParagraph.append(text)
            currentParagraphLength += text.count + 1
            previousEnd = seg.end
        }
        if !currentParagraph.isEmpty {
            lines.append(currentParagraph.joined(separator: " "))
        }
        lines.append("")

        return Output(
            markdown: lines.joined(separator: "\n"),
            languages: languages,
            segments: segments
        )
    }

    private static let knownHallucinations: Set<String> = [
        "you", "you you", "you you you",
        "thank you", "thank you.",
        "thanks for watching", "thanks for watching.", "thanks for watching!",
        "bye", "bye.", "bye!", "goodbye.",
        "subscribe", "subscribe.", "please subscribe.",
        "like and subscribe.", "don't forget to subscribe.",
        "music", "[music]", "♪ music ♪", "♪♪♪",
        "subtitles by the amara.org community",
        // Swedish subtitle-credit watermarks Whisper hallucinates on silence
        // (the sv equivalent of "subtitles by …"), seen on a mostly-silent
        // mic track.
        "textning.nu", "svensktextning.nu", "undertextning.nu",
        "tack för att du tittade", "tack för att ni tittade",
        "tack för att du tittade.", "tack för att ni tittade.",
        // Swedish-pinned silence: "Tack för mig. Tack." lines fill every
        // quiet stretch of a Swedish-pinned recording.
        "tack", "tack tack", "tack för mig", "tack så mycket", "hej då",
    ]

    /// A Whisper repetition loop: six or more words of which fewer than a
    /// third are distinct ("*Penis *Penis *Penis …", "the the the …").
    static func isRepetitionLoop(_ rawText: String) -> Bool {
        let words = stripWhisperTokens(rawText).lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard words.count >= 6 else { return false }
        return Double(Set(words).count) / Double(words.count) < 0.34
    }

    /// In a 1:1 (exactly one attendee other than the operator, identified by
    /// OWNER_EMAIL), returns that person's name to label the system speaker.
    /// nil when there are 0 or 2+ others, no name, or OWNER_EMAIL is unset.
    static func soleOtherAttendeeName(_ attendees: [Attendee]?) -> String? {
        guard let attendees, let owner = Config.ownerEmail() else { return nil }
        let others = attendees.filter { ($0.email?.lowercased() ?? "") != owner }
        // The name comes from whoever sent the invite and becomes a speaker
        // label line ("**Name:**"): one line, bounded, like a title.
        guard others.count == 1,
              let raw = others.first?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return String(Outbox.normalizeTitle(raw).prefix(100))
    }

    /// Detects Whisper's stock-phrase hallucinations on silence.
    /// Normalization: strip Whisper tokens, trim, lowercase, drop
    /// trailing/leading punctuation so "Thank you." == "thank you" ==
    /// "Thank you!". Then the shape rules in `isInventedCaption`, which see
    /// the text with its case (a credit names someone, and names are
    /// capitalised).
    static func isKnownHallucination(_ rawText: String) -> Bool {
        let stripped = stripWhisperTokens(rawText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let punct = CharacterSet.punctuationCharacters
        let normalized = stripped
            .lowercased()
            .trimmingCharacters(in: punct)
            .trimmingCharacters(in: .whitespaces)
        if knownHallucinations.contains(normalized) { return true }
        return isInventedCaption(stripped)
    }

    // Whisper was trained on subtitle files, so on silence it emits the
    // credits those files end with — in whatever form, not just the exact
    // lines in the blocklist above. Two shapes catch the rest, and both
    // describe a WHOLE line, because real speech opens with the same words
    // ("Translation from Swedish takes longer", "Sync from main before you
    // push", "I read it on textning.nu yesterday"):
    //   • a credit line: nothing but one or more credits. A credit is a
    //     credit word, at most two filler words, by/av/från/from and a name
    //     of one to three name-like tokens ("Subtitles by Jane Doe",
    //     "Undertexter av Lisa Larsson", "Sync and corrections by n17t01"),
    //     or the colon form with a name-like value ("Översättning: Kalle
    //     Anka"). Credits may be chained with , ; & / and/och ("Transcribed
    //     by ESO, translated by —"). A name-like token starts with a capital
    //     or a digit, contains a digit, is a domain or handle, is a dash, or
    //     is a connector ("the", "van", "och", "community", …) — so "from
    //     Swedish takes longer" is not a name and the line stays.
    //   • a watermark: a line that is essentially just a web domain — at
    //     most three other tokens ("www.zeoranger.co.uk", "Mer på
    //     textning.nu") — not a sentence that mentions a site.
    // plus the bracketed sound tags some models produce on silence
    // ("[BLANK_AUDIO]", "(upbeat music)", "[Music]").
    //
    // The credit pattern is case-SENSITIVE on purpose (names are
    // capitalised); the words around the name are matched with (?i:…).
    private static let creditLineRegex: NSRegularExpression = {
        let creditWord = #"(?i:subtitles?|subtitled|captions?|captioned|captioning|closed\s+captions?|transcri(?:bed|ption|pt)|translat(?:ed|ion|ions)|text(?:ning|at|ad|ning\.nu)?|undertext(?:er|ning|ad|ade)?|övers(?:ättning|att)|sync(?:ed|ing)?|corrected|edited)"#
        let colonWord = #"(?i:subtitles?|captions?|transcri(?:ption|pt)|translat(?:ion|ed)|undertext(?:er|ning)?|översättning|textning|sync|credits?)"#
        let nameToken = #"(?:[\p{Lu}\p{N}@][^\s,;]*|[^\s,;]*\p{N}[^\s,;]*|[^\s,;]*\.[\p{L}\p{N}][^\s,;]*|(?i:the|de|van|von|der|den|la|le|och|and|&|community|team)|\p{Pd}+)"#
        let name = "\(nameToken)(?:\\s+\(nameToken)){0,2}"
        let byCredit = #"\#(creditWord)(?:\s+[^\s.,;:]+){0,2}?\s+(?i:by|av|från|from)\s+\#(name)"#
        let colonCredit = #"\#(colonWord)\s*:\s*\#(name)"#
        let credit = "(?:\(byCredit)|\(colonCredit))"
        let separator = #"(?:\s*[,;&/]\s*|\s+(?i:and|och)\s+)"#
        let pattern = #"^[\s\p{P}\p{S}]*\#(credit)(?:\#(separator)\#(credit))*[\s\p{P}\p{S}]*$"#
        return try! NSRegularExpression(pattern: pattern)
    }()
    private static let domainRegex = try! NSRegularExpression(
        pattern: #"(^|\s|\()(www\.)?[a-z0-9-]+(\.[a-z0-9-]+)*\.(com|org|net|co\.uk|nu|se|io|tv|info|dk|no|fi|de)\b"#,
        options: [.caseInsensitive]
    )
    /// One whitespace token that is a domain (with optional surrounding punctuation).
    private static let domainTokenRegex = try! NSRegularExpression(
        pattern: #"^[\p{P}\p{S}]*(www\.)?[a-z0-9-]+(\.[a-z0-9-]+)*\.(com|org|net|co\.uk|nu|se|io|tv|info|dk|no|fi|de)\b[^\s]*$"#,
        options: [.caseInsensitive]
    )
    private static let maxWatermarkOtherTokens = 3
    private static let soundTagRegex = try! NSRegularExpression(pattern: #"^\s*[\[(][^\])]{1,40}[\])]\s*$"#)

    /// A subtitle credit, watermark or sound tag invented on silence. Takes
    /// the token-stripped, trimmed segment text with its case intact.
    static func isInventedCaption(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if creditLineRegex.firstMatch(in: text, range: range) != nil { return true }
        if soundTagRegex.firstMatch(in: text, range: range) != nil { return true }
        if domainRegex.firstMatch(in: text, range: range) != nil {
            let others = text.split(whereSeparator: { $0.isWhitespace }).filter { token in
                let t = String(token)
                return domainTokenRegex.firstMatch(in: t, range: NSRange(t.startIndex..<t.endIndex, in: t)) == nil
            }
            if others.count <= maxWatermarkOtherTokens { return true }
        }
        return false
    }

    // Whisper sometimes invents speaker labels inline ("SPEAKER 1: …",
    // "Talare 2: …", "- Speaker: …") when it has seen them in training
    // subtitles. They are never real — our speakers come from the two
    // streams and the diarizer — so strip the prefix.
    private static let inventedSpeakerRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:[-–—]\s*)?(?:speaker|talare|person|interviewer|interviewee|host|guest|man|woman|kvinna)(?:\s*\d{1,2}|\s+[a-z])?\s*:\s*"#,
        options: [.caseInsensitive]
    )

    /// The text a segment contributes to the transcript: decoder tokens
    /// stripped, invented speaker prefixes removed, shouting normalised,
    /// trimmed.
    static func cleanText(_ rawText: String, language: String) -> String {
        var text = stripWhisperTokens(rawText).trimmingCharacters(in: .whitespacesAndNewlines)
        text = String(text.prefix(4000))
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        text = inventedSpeakerRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return normalizeShouting(text, language: language).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whisper occasionally emits a whole passage in capitals (it has seen
    /// shouted subtitles). Twelve or more letters of which 90 % are upper
    /// case is not a name or an acronym — rewrite it in sentence case.
    static func normalizeShouting(_ text: String, language: String) -> String {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 12 else { return text }
        let upper = letters.filter { CharacterSet.uppercaseLetters.contains($0) }.count
        guard Double(upper) / Double(letters.count) >= 0.9 else { return text }
        var out = ""
        var capitalizeNext = true
        for ch in text.lowercased() {
            if capitalizeNext, ch.isLetter {
                out.append(contentsOf: String(ch).uppercased())
                capitalizeNext = false
            } else {
                out.append(ch)
            }
            if ".!?".contains(ch) { capitalizeNext = true }
        }
        if language == "en" {
            // The pronoun "I" survives the lowercasing as "i".
            out = out.replacingOccurrences(of: #"\bi\b"#, with: "I", options: .regularExpression)
        }
        return out
    }

    private static let whisperTokenRegex: NSRegularExpression = {
        // Matches Whisper decoder control tokens like <|startoftranscript|>,
        // <|en|>, <|0.00|>, <|endoftext|>. WhisperKit's TranscriptionSegment.text
        // leaves these in by default — useful for debugging, not for human reading.
        return try! NSRegularExpression(pattern: #"<\|[^|]*\|>"#)
    }()

    /// Removes Whisper decoder control tokens (`<|…|>`) from a segment's
    /// text. Shared with Transcriber's degenerate-pass check so the two can't
    /// drift on what "content" means.
    static func stripWhisperTokens(_ text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return whisperTokenRegex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: ""
        )
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func yamlQuoted(_ value: String) -> String {
        // Quote if the string contains anything that could confuse a
        // YAML parser. Cheap heuristic; if any of these are present we
        // double-quote and escape backslash + double-quote.
        let needsQuoting = value.contains(":") || value.contains("\"")
            || value.contains("\\") || value.hasPrefix("-")
            || value.hasPrefix("&") || value.hasPrefix("*")
            || value.hasPrefix("!") || value.hasPrefix("|")
            || value.hasPrefix(">") || value.hasPrefix("#")
            || value.hasPrefix("{") || value.hasPrefix("[")
            || value.contains("\n")
        guard needsQuoting else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
