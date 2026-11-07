//
// Lines the transcript cleanup must put on the right side, shared by the
// `--cleanup-test` harness (main.swift) and the swift-testing suite
// (Tests/MinnasTests/TranscriptBuilderTests.swift), so the two
// cannot drift. Add a line here when Whisper invents a new kind of credit or
// when the filter eats real speech.
//

enum TranscriptBuilderFixtures {
    /// Whisper output on silence: every line must be dropped by
    /// `TranscriptBuilder.isKnownHallucination`.
    static let mustDrop: [String] = [
        "Subtitles by the Amara.org community",
        "Subtitled by Jane Doe",
        "Captioning by CaptionMax",
        "Transcribed by ESO, translated by —",
        "Undertexter av Lisa Larsson",
        "Översättning: Kalle Anka",
        "Textning: Anna Svensson",
        "Svensktextning.nu",
        "www.zeoranger.co.uk",
        "[BLANK_AUDIO]",
        "(upbeat music)",
        "[Music]",
        "Thank you.",
        "Tack för att du tittade.",
        "Sync and corrections by n17t01",
        "Subtitles: Jonas Larsen",
        "Captions by VITAC",
        // Same shapes in other wordings.
        "Subtitled by Jane Doe.",
        "Undertexter från SVT",
        "Översättning: Kalle Anka, Textning: Anna Svensson",
        "Translated by Google Translate",
        "Mer på textning.nu",
        "Visit www.example.com",
        "Translation: DeepL",
        // Known gap, accepted: a credit with an all-lowercase name
        // ("subtitles by jane doe") is kept, because the name's capital is
        // what tells "Text from Anna" apart from "Text from the slide".
        // Whisper writes credits sentence-cased.
    ]

    /// Real speech: every line must survive `isKnownHallucination`.
    static let mustKeep: [String] = [
        "We translated the whole document by Friday and sent it to the client.",
        "The subtitles on that film were terrible.",
        "I'll send you the link to amara.org later so you can see how the community works there.",
        "Thank you so much for taking the time today, Sam, I really appreciate it.",
        "Tack så mycket för att ni kunde komma idag, vi börjar med en kort runda.",
        "(We should probably move on to the next question, don't you think?)",
        // Dropped by the regexes before 2026-11-07 (review D7).
        "Transcription from yesterday is attached",
        "Translation from Swedish takes longer",
        "Text from the slide says revenue is up",
        "Sync from main before you push",
        "I read it on textning.nu yesterday",
        // Sentences that open with a subtitle/translation/text/sync word.
        "Subtitles by default are off in the player we use.",
        "Captions from the webinar were mostly wrong.",
        "Translated by hand it would take a week.",
        "Edited by Maria, the deck looks much better now.",
        "Transcript: we still need to send it to legal before Friday.",
        "Synced from the shared drive this morning, so it's current.",
        "Textning av möten är något vi borde erbjuda.",
        "Översättning: det tar längre tid än vi trodde.",
        "Undertexter av den här kvaliteten går inte att använda.",
        // A web domain inside a sentence.
        "Book it through booking.com, it's cheaper that way.",
        "Kolla svt.se för senaste nytt om valet.",
        "Our docs live at docs.example.com now",
        "Send it to support.example.org and cc me",
    ]

    struct Cleaned: Sendable {
        let input: String
        let language: String
        let expected: String
    }

    /// `TranscriptBuilder.cleanText` input → expected output.
    static let cleaned: [Cleaned] = [
        Cleaned(input: "SPEAKER 1: So what I wanted to ask you about", language: "en", expected: "So what I wanted to ask you about"),
        Cleaned(input: "Talare 2: Vi börjar med det.", language: "sv", expected: "Vi börjar med det."),
        Cleaned(input: "- Speaker: fine", language: "en", expected: "fine"),
        Cleaned(input: "Speakers: Anna", language: "en", expected: "Speakers: Anna"),
        Cleaned(input: "The speaker said: yes", language: "en", expected: "The speaker said: yes"),
        Cleaned(input: "I THINK WE SHOULD GO WITH THE SECOND OPTION. IT'S CHEAPER AND I LIKE IT!", language: "en", expected: "I think we should go with the second option. It's cheaper and I like it!"),
        Cleaned(input: "VI KAN TA DET PÅ MÅNDAG. DET FUNKAR BRA.", language: "sv", expected: "Vi kan ta det på måndag. Det funkar bra."),
        Cleaned(input: "NASA and the EU agreed.", language: "en", expected: "NASA and the EU agreed."),
        Cleaned(input: "OK OK OK", language: "en", expected: "OK OK OK"),
        Cleaned(input: "<|en|><|0.00|> Hello there.<|2.00|>", language: "en", expected: "Hello there."),
    ]
}
