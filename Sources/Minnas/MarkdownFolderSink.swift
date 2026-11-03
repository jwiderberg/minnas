//
// Exports each finished transcript as a Markdown file into a folder the
// user picked (TRANSCRIPTS_DIR / Settings) — where Minnas puts every
// transcript.
//
// File name: "<yyyy-MM-dd HHmm> <title>.md", the meeting's local start time
// so the folder sorts chronologically in Finder. Content: transcript.md
// verbatim (it already carries YAML frontmatter).
//
// One file per recording: a re-delivery (re-transcribe) overwrites the
// path this sink recorded for THIS slot last time (meta's delivery
// location, or previous_locations after a reset) — ownership comes from
// that record only, never from what a file contains, so another slot whose
// transcript happens to be byte-identical gets its own " (2)". Any other
// existing name gets " (2)", " (3)"… so two meetings with the same title in
// the same minute never overwrite each other.
//
// The folder is user-writable and meta.json is hand-editable, so no path is
// trusted: a recorded location is reused only if its parent resolves to the
// configured folder and it is not a symlink, and every write goes to a temp
// file in the folder that is then renamed onto the name (rename replaces a
// directory entry, it never follows a link at the destination; a fresh
// name is claimed with RENAME_EXCL so a file that appeared meanwhile is not
// clobbered).
//

import Darwin
import Foundation
import os

private let folderLog = Logger(subsystem: "com.jwiderberg.minnas", category: "Delivery")

struct MarkdownFolderSink: TranscriptSink {
    static let sinkID = "markdown-folder"

    let folder: URL

    var id: String { Self.sinkID }
    var displayName: String { "Markdown folder" }

    // Local by definition, so every recording is exported.
    func applies(to meta: RecordingMeta) -> Bool { true }

    func deliver(slot: OutboxSlot, meta: RecordingMeta) async throws -> SinkDelivery {
        let content = try Data(contentsOf: slot.transcriptURL)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dir = resolvedFolder
        if let owned = ownedLocation(for: meta) {
            try Self.write(content, to: owned, in: dir, exclusive: false)
            return SinkDelivery(delivered_at: Date(), location: owned.path)
        }
        // A fresh name; if another writer claims it between the check and
        // the rename, take the next one.
        var n = 1
        while true {
            let target = freeName(for: meta, startingAt: n)
            do {
                try Self.write(content, to: target.url, in: dir, exclusive: true)
                return SinkDelivery(delivered_at: Date(), location: target.url.path)
            } catch let error as POSIXError where error.code == .EEXIST {
                n = target.n + 1
            }
        }
    }

    /// The path the next delivery writes to, for the --deliver plan.
    func plannedDestination(slot: OutboxSlot, meta: RecordingMeta) -> URL {
        ownedLocation(for: meta) ?? freeName(for: meta, startingAt: 1).url
    }

    /// The configured folder with symlinks resolved, standardized: the one
    /// directory this sink writes into.
    private var resolvedFolder: URL {
        folder.resolvingSymlinksInPath().standardizedFileURL
    }

    /// This slot's earlier file, if meta records one that is still safe to
    /// overwrite: a .md directly inside the configured folder (parent
    /// compared after resolving symlinks — a folder setting that changed, or
    /// a hand-edited meta pointing elsewhere, is not followed) and not
    /// itself a symlink. A recorded name that is now missing is reused (the
    /// user deleted the file; re-creating it under the same name is right).
    private func ownedLocation(for meta: RecordingMeta) -> URL? {
        guard let recorded = meta.deliveries?[id]?.location ?? meta.previous_locations?[id] else { return nil }
        let url = URL(fileURLWithPath: recorded)
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard url.pathExtension == "md", !name.hasPrefix("."), parent.path == resolvedFolder.path else { return nil }
        let candidate = resolvedFolder.appendingPathComponent(name, isDirectory: false)
        switch Self.entryType(candidate) {
        case .none, .regular?: return candidate
        default:
            // A symlink (or a directory, a socket…) where our file was: not
            // ours any more. Leave it alone and write under a fresh name.
            folderLog.error("folder sink: recorded location is no longer a regular file; writing a new file instead")
            return nil
        }
    }

    /// The first "<base>.md", "<base> (2).md"… from `n` with no directory
    /// entry at all (a dangling symlink counts as taken).
    private func freeName(for meta: RecordingMeta, startingAt start: Int) -> (url: URL, n: Int) {
        let base = "\(Self.timestamp(meta.started_at)) \(Self.fileSafeTitle(meta.title))"
        var n = max(1, start)
        while true {
            let name = n == 1 ? "\(base).md" : "\(base) (\(n)).md"
            let url = resolvedFolder.appendingPathComponent(name, isDirectory: false)
            if Self.entryType(url) == nil { return (url, n) }
            n += 1
        }
    }

    private enum EntryType { case regular, other }

    /// What sits at `url` WITHOUT following a final symlink (lstat), or nil
    /// for no entry. FileManager.fileExists follows links, so a dangling
    /// one would read as free.
    private static func entryType(_ url: URL) -> EntryType? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return (st.st_mode & S_IFMT) == S_IFREG ? .regular : .other
    }

    /// Write `content` to a temp file in `dir`, then rename it onto `target`.
    /// `exclusive` (a fresh name) fails with EEXIST instead of replacing.
    private static func write(_ content: Data, to target: URL, in dir: URL, exclusive: Bool) throws {
        let temp = dir.appendingPathComponent(".\(UUID().uuidString).md.tmp", isDirectory: false)
        // .withoutOverwriting: O_EXCL, so the temp name can't be a planted link.
        try content.write(to: temp, options: .withoutOverwriting)
        let status = temp.path.withCString { from in
            target.path.withCString { to in
                exclusive ? renamex_np(from, to, UInt32(RENAME_EXCL)) : rename(from, to)
            }
        }
        if status != 0 {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(code)
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter.string(from: date)
    }

    /// The title as a file-name fragment: `/` and `:` (the path separator
    /// in POSIX and in Finder) and control characters become spaces,
    /// whitespace runs collapse, and the result is capped at 120 UTF-8
    /// bytes on a Character boundary — the title comes from whoever sent
    /// the invite, and APFS caps a name at 255 bytes.
    static func fileSafeTitle(_ title: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in title.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator:
                scalars.append(" ")
            default:
                scalars.append(scalar == "/" || scalar == ":" ? " " : scalar)
            }
        }
        let collapsed = String(scalars).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var capped = ""
        var bytes = 0
        for char in collapsed {
            let size = String(char).utf8.count
            guard bytes + size <= 120 else { break }
            capped.append(char)
            bytes += size
        }
        let trimmed = capped.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Meeting" : trimmed
    }
}
