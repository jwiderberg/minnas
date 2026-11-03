//
// Which languages a recording may be in, and how much benefit of the doubt
// the primary one gets.
//
// Detection scores each candidate by Whisper's language token over several
// windows (each confident window adds its probability to that language).
// A non-primary candidate must beat the primary by `margin` (in those
// probability units — 0.2 is a fifth of one confident window); a near-tie
// goes to the primary, since the operator's meetings are mostly English.
// The margin is dropped when the calendar invite carries a counterpart
// whose e-mail TLD matches a non-primary language (a .se attendee → no
// English prior).
//

import Foundation

struct LanguagePolicy: Sendable {
    /// Whisper language codes, primary first (STT_LANGUAGES, default en,sv).
    let candidates: [String]
    /// Score handicap (probability-vote units) a non-primary candidate must overcome.
    let margin: Float

    var primary: String { candidates.first ?? "en" }

    /// Country TLDs that signal a candidate language on an attendee e-mail.
    private static let tldForLanguage: [String: String] = ["sv": ".se", "en": ".uk"]

    func adjusted(_ language: String, _ score: Float) -> Float {
        language == primary ? score : score - margin
    }

    /// The candidate with the best handicapped score, or nil when empty.
    func winner(_ scores: [String: Float]) -> String? {
        scores.max { adjusted($0.key, $0.value) < adjusted($1.key, $1.value) }?.key
    }

    static func current(attendees: [Attendee]? = nil) -> LanguagePolicy {
        let candidates = Config.sttCandidateLanguages()
        var margin = Config.sttLanguageMargin()
        let primary = candidates.first ?? "en"
        for attendee in attendees ?? [] {
            let email = (attendee.email ?? "").lowercased()
            for language in candidates where language != primary {
                if let tld = tldForLanguage[language], email.hasSuffix(tld) { margin = 0 }
            }
        }
        return LanguagePolicy(candidates: candidates, margin: margin)
    }
}
