import Foundation
import Testing
@testable import Minnas

/// The menu bar item's rules: hidden mode, which click opens the menu, and
/// the quick recording's title.
@Suite struct StatusItemPolicyTests {
    @Test func counterShowsTimeAndBars() {
        #expect(StatusItemPolicy.recordingTitle(elapsed: "0:42", micBar: "▆", systemBar: "▁", hidden: false) == " 0:42 ▆ ▁")
    }

    @Test func hiddenModeShowsNothingBesideTheDot() {
        #expect(StatusItemPolicy.recordingTitle(elapsed: "12:07", micBar: "✗", systemBar: "█", hidden: true) == "")
    }

    @Test func plainClickTogglesAndModifiedClickOpensMenu() {
        #expect(!StatusItemPolicy.clickOpensMenu(isRightClick: false, option: false, control: false))
        #expect(StatusItemPolicy.clickOpensMenu(isRightClick: false, option: true, control: false))
        #expect(StatusItemPolicy.clickOpensMenu(isRightClick: false, option: false, control: true))
        #expect(StatusItemPolicy.clickOpensMenu(isRightClick: true, option: false, control: false))
    }

    @Test func quickTitleIsTheLocalDateAndTime() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-11-17T09:05:30Z"))
        let dubai = try #require(TimeZone(identifier: "Asia/Dubai"))
        #expect(StatusItemPolicy.quickRecordingTitle(at: date, timeZone: dubai) == "Recording 2026-11-17 13:05")
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(StatusItemPolicy.quickRecordingTitle(at: date, timeZone: utc) == "Recording 2026-11-17 09:05")
    }
}
