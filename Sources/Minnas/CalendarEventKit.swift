//
// The calendar source: EventKit reads whatever accounts are set up in the
// macOS Calendar app (iCloud, Google, Exchange, CalDAV), on the Mac, with
// no server of its own.
//
// It returns UpcomingEvent values for the poll, the record prompt
// (isRecordableMeeting) and the manual-start picker. `conferencing` is
// derived by sniffing the event's URL, location and notes for a Zoom /
// Meet / Teams link, because EventKit has no conferenceData of its own.
//
// Access is "full access" (read), granted once by the user through the
// macOS prompt (NSCalendarsFullAccessUsageDescription in Info.plist; the
// hardened runtime also needs the com.apple.security.personal-information.
// calendars entitlement or the request is silently denied).
//

import EventKit
import Foundation

/// One soon-to-start (or just-started) meeting, as the poll and the picker
/// see it. Codable so a server calendar source can decode it as is.
struct UpcomingEvent: Codable, Sendable {
    let calendar_event_id: String?
    let ical_uid: String?
    let title: String?
    let start: Date
    let end: Date?
    let url: String?
    let location: String?
    let conferencing: String?   // "zoom" | "meet" | "teams" | nil
    let attendees: [Attendee]?
}

enum EventKitCalendarError: Error, CustomStringConvertible {
    case notAuthorized(EKAuthorizationStatus)

    var description: String {
        switch self {
        case .notAuthorized(let status):
            return "Calendar access not granted (\(EventKitCalendar.describe(status))). Grant it in Settings › Calendar."
        }
    }
}

@MainActor
enum EventKitCalendar {
    // One store for the app's lifetime: creating an EKEventStore loads every
    // account, which is far too heavy for a 60 s poll.
    private static let store = EKEventStore()

    static var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    static var isAuthorized: Bool { authorizationStatus == .fullAccess }

    /// Shows the macOS Calendar prompt (only the first time — after a
    /// decision the system answers from TCC without asking again).
    static func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    /// Events starting within the next `withinMinutes`, soonest first,
    /// across every calendar. `lookbackMinutes` > 0 also returns events
    /// that started up to that long ago and haven't ended, for the manual
    /// picker. All-day and cancelled events are skipped.
    static func upcoming(withinMinutes: Int = 5, lookbackMinutes: Int = 0) async throws -> [UpcomingEvent] {
        guard isAuthorized else { throw EventKitCalendarError.notAuthorized(authorizationStatus) }
        let now = Date()
        let windowStart = now.addingTimeInterval(-Double(max(0, lookbackMinutes)) * 60)
        let windowEnd = now.addingTimeInterval(Double(max(0, withinMinutes)) * 60)
        // The predicate matches events OVERLAPPING the range; narrow to the
        // start window ourselves so a meeting that began an hour ago doesn't
        // count as "upcoming".
        let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)
        return store.events(matching: predicate)
            .filter { event in
                !event.isAllDay && event.status != .canceled
                    && event.startDate >= windowStart && event.startDate <= windowEnd
                    && (lookbackMinutes == 0 ? event.startDate >= now : event.endDate > now)
            }
            .sorted { $0.startDate < $1.startDate }
            .map(makeUpcomingEvent)
    }

    private static func makeUpcomingEvent(_ event: EKEvent) -> UpcomingEvent {
        let attendees: [Attendee] = (event.attendees ?? []).compactMap { participant in
            let email = participant.url.absoluteString.lowercased().hasPrefix("mailto:")
                ? String(participant.url.absoluteString.dropFirst("mailto:".count)).removingPercentEncoding
                : nil
            guard participant.name != nil || email != nil else { return nil }
            return Attendee(name: participant.name, email: email?.lowercased())
        }
        return UpcomingEvent(
            calendar_event_id: stableID(for: event),
            ical_uid: event.calendarItemExternalIdentifier,
            title: event.title,
            start: event.startDate,
            end: event.endDate,
            url: event.url?.absoluteString,
            location: event.location,
            conferencing: conferencing(in: [event.url?.absoluteString, event.location, event.notes]),
            attendees: attendees.isEmpty ? nil : attendees
        )
    }

    /// eventIdentifier is shared by every occurrence of a recurring event,
    /// so the occurrence's start is appended: the poll's "already prompted"
    /// set needs one id per meeting, not per series. Stable across polls and
    /// relaunches for the same occurrence.
    private static func stableID(for event: EKEvent) -> String {
        let base = event.eventIdentifier ?? event.calendarItemIdentifier
        return "eventkit:\(base)@\(Int(event.startDate.timeIntervalSince1970))"
    }

    /// "zoom" | "meet" | "teams" | nil, from the first meeting link found.
    nonisolated static func conferencing(in fields: [String?]) -> String? {
        let text = fields.compactMap { $0 }.joined(separator: "\n").lowercased()
        guard !text.isEmpty else { return nil }
        if text.contains("zoom.us/") || text.contains("zoomgov.com/") { return "zoom" }
        if text.contains("meet.google.com/") { return "meet" }
        if text.contains("teams.microsoft.com/") || text.contains("teams.live.com/") { return "teams" }
        return nil
    }

    nonisolated static func describe(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess: return "granted"
        case .writeOnly: return "add-only — needs full access"
        case .denied: return "denied"
        case .restricted: return "restricted by the system"
        case .notDetermined: return "not requested yet"
        @unknown default: return "unknown"
        }
    }
}
