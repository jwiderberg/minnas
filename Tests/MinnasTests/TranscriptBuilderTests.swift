import Testing
@testable import Minnas

@Suite struct TranscriptBuilderTests {
    @Test(arguments: TranscriptBuilderFixtures.mustDrop)
    func dropsInventedLine(_ line: String) {
        #expect(TranscriptBuilder.isKnownHallucination(line), "should drop: \(line)")
    }

    @Test(arguments: TranscriptBuilderFixtures.mustKeep)
    func keepsRealSpeech(_ line: String) {
        #expect(!TranscriptBuilder.isKnownHallucination(line), "should keep: \(line)")
    }

    @Test(arguments: TranscriptBuilderFixtures.cleaned.indices)
    func cleansText(_ index: Int) {
        let item = TranscriptBuilderFixtures.cleaned[index]
        #expect(TranscriptBuilder.cleanText(item.input, language: item.language) == item.expected)
    }

    /// The credit rule runs on the text with its case: Whisper's control
    /// tokens and surrounding whitespace do not hide a credit.
    @Test func creditInsideWhisperTokensStillDrops() {
        #expect(TranscriptBuilder.isKnownHallucination("<|sv|><|0.00|> Undertexter av Lisa Larsson<|2.00|>"))
    }

    /// The watermark rule counts the tokens around the domain: three is
    /// still a watermark, four is a sentence.
    @Test func watermarkAllowsThreeOtherTokens() {
        #expect(TranscriptBuilder.isKnownHallucination("Mer info på textning.nu"))
        #expect(!TranscriptBuilder.isKnownHallucination("Det finns mer info på textning.nu"))
    }

    /// A credit followed by more of a sentence is speech.
    @Test func creditPrefixOfSentenceKeeps() {
        #expect(TranscriptBuilder.isKnownHallucination("Translated by Google"))
        #expect(!TranscriptBuilder.isKnownHallucination("Translated by Google, it reads badly."))
    }
}
