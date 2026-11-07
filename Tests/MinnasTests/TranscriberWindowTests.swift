import Testing
@testable import Minnas

@Suite struct TranscriberWindowTests {
    typealias W = DecodeWindow

    @Test func thresholdsKeepTheirValues() {
        #expect(W.seconds == 30)
        #expect(W.skipBelowSpeech == 0.5)
        #expect(W.minVoteSpeech == 2.5)
        #expect(W.switchNow == 0.85)
        #expect(W.switchSoon == 0.7)
    }

    @Test func silenceIsNotDecoded() {
        let state = W.State(language: "en")
        #expect(W.plan(speechSeconds: 0, state: state) == .skip)
        #expect(W.plan(speechSeconds: 0.4, state: state) == .skip)
        #expect(W.plan(speechSeconds: 0.4, state: W.State(language: "en", fixed: true)) == .skip)
    }

    @Test func shortSpeechDecodesWithoutVoting() {
        let state = W.State(language: "en")
        #expect(W.plan(speechSeconds: 0.5, state: state) == .decode(vote: false))
        #expect(W.plan(speechSeconds: 2.4, state: state) == .decode(vote: false))
        #expect(W.plan(speechSeconds: 2.5, state: state) == .decode(vote: true))
        #expect(W.plan(speechSeconds: 30, state: state) == .decode(vote: true))
    }

    @Test func fixedLanguageNeverVotes() {
        let state = W.State(language: "sv", fixed: true)
        #expect(W.plan(speechSeconds: 0.5, state: state) == .decode(vote: false))
        #expect(W.plan(speechSeconds: 30, state: state) == .decode(vote: false))
    }

    @Test func fixedLanguageNeverSwitches() {
        var state = W.State(language: "sv", fixed: true)
        for _ in 0..<3 {
            let (next, outcome) = W.apply(detectedLanguage: "en", probability: 0.99, to: state)
            #expect(outcome == .stay)
            #expect(next == state)
            state = next
        }
        #expect(state.language == "sv")
        #expect(state.pending == nil)
    }

    @Test func oneConfidentDetectionSwitches() {
        let (next, outcome) = W.apply(detectedLanguage: "sv", probability: 0.85, to: W.State(language: "en"))
        #expect(outcome == .switched(from: "en", to: "sv"))
        #expect(next.language == "sv")
        #expect(next.pending == nil)
    }

    @Test func twoModerateDetectionsInARowSwitch() {
        let first = W.apply(detectedLanguage: "sv", probability: 0.7, to: W.State(language: "en"))
        #expect(first.1 == .pending("sv"))
        #expect(first.0.language == "en")
        #expect(first.0.pending == "sv")
        let second = W.apply(detectedLanguage: "sv", probability: 0.72, to: first.0)
        #expect(second.1 == .switched(from: "en", to: "sv"))
        #expect(second.0.language == "sv")
        #expect(second.0.pending == nil)
    }

    @Test func aVoteForTheCurrentLanguageClearsPending() {
        let pending = W.State(language: "en", pending: "sv")
        let (next, outcome) = W.apply(detectedLanguage: "en", probability: 0.95, to: pending)
        #expect(outcome == .stay)
        #expect(next.pending == nil)
        // So a later moderate reading only starts a new pending run.
        let again = W.apply(detectedLanguage: "sv", probability: 0.75, to: next)
        #expect(again.1 == .pending("sv"))
        #expect(again.0.language == "en")
    }

    @Test func weakDetectionStaysAndClearsPending() {
        let (next, outcome) = W.apply(detectedLanguage: "sv", probability: 0.69, to: W.State(language: "en", pending: "sv"))
        #expect(outcome == .stay)
        #expect(next.language == "en")
        #expect(next.pending == nil)
    }

    @Test func noCandidateMassStays() {
        let state = W.State(language: "en", pending: "sv")
        let none = W.apply(detectedLanguage: nil, probability: 0, to: state)
        #expect(none.1 == .stay)
        #expect(none.0.pending == nil)
        let zero = W.apply(detectedLanguage: "sv", probability: 0, to: state)
        #expect(zero.1 == .stay)
        #expect(zero.0.language == "en")
    }
}
