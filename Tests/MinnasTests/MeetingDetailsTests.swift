import Foundation
import Testing
@testable import Minnas

/// Full meeting details in the Markdown file: what is added, where, and
/// that the transcript itself is untouched.
@Suite struct MeetingDetailsTests {
    static let transcript = """
    ---
    title: "Q3 planning"
    started_at: 2026-11-17T09:00:00Z
    device: "mac"
    ---

    # Q3 planning

    **Me:** Hello.

    **Them:** Hi.
    """

    static func meta(attendees: [Attendee]? = nil, location: String? = nil, notes: String? = nil) -> RecordingMeta {
        var m = RecordingMeta(title: "Q3 planning", started_at: Date(timeIntervalSince1970: 0), device: "mac", client_version: "1")
        m.attendees = attendees
        m.calendar_location = location
        m.calendar_notes = notes
        return m
    }

    @Test func nothingToAddLeavesTheFileAlone() {
        #expect(MeetingDetails.apply(to: Self.transcript, meta: Self.meta()) == Self.transcript)
    }

    @Test func attendeesAndLocationGoIntoTheFrontmatter() {
        let out = MeetingDetails.apply(to: Self.transcript, meta: Self.meta(
            attendees: [Attendee(name: "Jane Doe", email: "jane@example.com"),
                        Attendee(name: nil, email: "bob@example.com"),
                        Attendee(name: "Sam \"Q\" Lee", email: nil)],
            location: "Room 4: \"Fjord\"\nLevel 2"))
        #expect(out.contains("""
        device: "mac"
        attendees:
          - "Jane Doe <jane@example.com>"
          - "bob@example.com"
          - "Sam \\"Q\\" Lee"
        location: "Room 4: \\"Fjord\\" Level 2"
        ---
        """))
        #expect(!out.contains("## Invite notes"))
        #expect(out.hasSuffix("**Them:** Hi."))
    }

    @Test func notesBecomeAQuotedSectionAboveTheTranscript() {
        let out = MeetingDetails.apply(to: Self.transcript, meta: Self.meta(notes: "Agenda\n\n# not a heading\n- budget"))
        #expect(out.contains("""
        # Q3 planning

        ## Invite notes

        > Agenda
        >
        > # not a heading
        > - budget

        ## Transcript

        **Me:** Hello.
        """))
        // The frontmatter is unchanged when only notes are added.
        #expect(out.hasPrefix("---\ntitle: \"Q3 planning\"\nstarted_at: 2026-11-17T09:00:00Z\ndevice: \"mac\"\n---\n"))
    }

    @Test func htmlNotesAreReducedToText() {
        #expect(MeetingDetails.clean("<p>Join&nbsp;here</p><br/><b>ID</b>: 123 &amp; more") == "Join here\n\nID: 123 & more")
    }

    @Test func blankAndOverlongNotes() throws {
        #expect(MeetingDetails.clean("  \n\n ") == nil)
        #expect(MeetingDetails.clean(nil) == nil)
        let long = try #require(MeetingDetails.clean(String(repeating: "a", count: 9_000)))
        #expect(long.hasSuffix("\n[…cut]"))
        #expect(long.count == MeetingDetails.maxNotesCharacters + "\n[…cut]".count)
    }

    @Test func noFrontmatterMeansNoChange() {
        let plain = "# Title\n\nText"
        #expect(MeetingDetails.apply(to: plain, meta: Self.meta(location: "Here")) == plain)
    }

    @Test func attendeeWhoseNameIsTheirEmailIsListedOnce() {
        #expect(MeetingDetails.attendeeLine(Attendee(name: "Bob@Example.com", email: "bob@example.com")) == "Bob@Example.com")
        #expect(MeetingDetails.attendeeLine(Attendee(name: " ", email: nil)) == nil)
    }
}
