// Full meeting details in the Markdown file (MARKDOWN_MEETING_DETAILS /
// Settings › General). Off: the file has the title, the times and the event
// link, as it always had. On: the folder sink adds the invite's attendees
// and location to the frontmatter and its notes as a quoted "Invite notes"
// section above the transcript, so a notes app can sort by them and an LLM
// reading the file gets the context.
//
// transcript.md in the slot stays as it is; the sinks that deliver it add
// the details on the way out.

import Foundation

enum MeetingDetails {
    /// Longest invite notes kept. Invites carry dial-in blocks and pasted
    /// agendas; past this they are cut with a marker.
    static let maxNotesCharacters = 8_000

    /// Adds the details to a transcript.md text. Returns it unchanged when
    /// there is nothing to add or the frontmatter is not where it should be.
    static func apply(to markdown: String, meta: RecordingMeta) -> String {
        var lines = markdown.components(separatedBy: "\n")
        guard lines.first == "---",
              let close = lines.indices.dropFirst().first(where: { lines[$0] == "---" })
        else { return markdown }

        var front: [String] = []
        let attendees = (meta.attendees ?? []).compactMap(attendeeLine)
        if !attendees.isEmpty {
            front.append("attendees:")
            front += attendees.map { "  - \(quoted($0))" }
        }
        if let location = clean(meta.calendar_location) {
            front.append("location: \(quoted(oneLine(location)))")
        }
        let notes = clean(meta.calendar_notes)
        guard !front.isEmpty || notes != nil else { return markdown }
        lines.insert(contentsOf: front, at: close)

        if let notes {
            // After the "# title" heading that follows the frontmatter.
            let closeNow = close + front.count
            if let heading = lines.indices.dropFirst(closeNow + 1).first(where: { lines[$0].hasPrefix("# ") }) {
                var section = ["", "## Invite notes", ""]
                section += notes.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> \($0)" }
                section += ["", "## Transcript"]
                lines.insert(contentsOf: section, at: heading + 1)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// "Jane Doe <jane@example.com>", or whichever half exists.
    static func attendeeLine(_ a: Attendee) -> String? {
        let name = a.name.flatMap { clean($0) }.map(oneLine)
        let email = a.email.flatMap { clean($0) }.map(oneLine)
        switch (name, email) {
        case let (n?, e?) where n.lowercased() != e.lowercased(): return "\(n) <\(e)>"
        case let (n?, _): return n
        case let (nil, e?): return e
        default: return nil
        }
    }

    /// Trimmed, HTML reduced to text (some calendars store the description
    /// as HTML), capped; nil when nothing is left.
    static func clean(_ raw: String?) -> String? {
        guard var text = raw else { return nil }
        if text.range(of: "<[a-zA-Z/][^>]*>", options: .regularExpression) != nil {
            text = text.replacingOccurrences(of: "(?i)<br\\s*/?>|</p>|</div>|</li>", with: "\n", options: .regularExpression)
            text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            for (entity, char) in ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&amp;": "&"] {
                text = text.replacingOccurrences(of: entity, with: char)
            }
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // At most one blank line in a row.
        text = text.replacingOccurrences(of: "\n[ \t]*\n([ \t]*\n)+", with: "\n\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.count > maxNotesCharacters {
            text = String(text.prefix(maxNotesCharacters)) + "\n[…cut]"
        }
        return text
    }

    private static func oneLine(_ s: String) -> String {
        s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Always double-quoted, so no YAML reading of the value can surprise.
    private static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
