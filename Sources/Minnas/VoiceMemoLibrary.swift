//
// Read-only access to the iPhone Voice Memos library that iCloud syncs to
// this Mac, so a memo recorded on the phone can be imported like any other
// recording (title of our choosing, transcript, the transcripts folder).
//
// Where things live (macOS 26 / iOS 26):
//   ~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/
//     CloudRecordings.db   — Core Data SQLite; ZCLOUDRECORDING has the
//                            title (ZENCRYPTEDTITLE — plain text despite
//                            the name), date, duration, file name.
//     <date> <time>-<id>.qta / .m4a — the audio. .qta is the iOS 26
//                            container: AAC stereo track + a disabled 4-ch
//                            APAC track + metadata tracks. AVFoundation
//                            reads it directly; AVAssetExportSession picks
//                            the AAC track.
//
// Apple's on-device transcript (iOS 18+) travels INSIDE the .qta as
// track-level QuickTime metadata, key `com.apple.VoiceMemos.tsrp`: a JSON
// blob with every word and its time range. When present we use it as the
// transcript instead of running STT — it's already done, and it's good.
// Older .m4a memos have no transcript; they go through the normal engines.
//
// The database is opened from a private copy (db + -wal + -shm) so we never
// take a lock against the Voice Memos app or read a torn WAL state.
//

import AVFoundation
import Foundation
import SQLite3
import os.log

private let memoLog = Logger(subsystem: "com.jwiderberg.minnas", category: "VoiceMemos")

struct VoiceMemo: Sendable, Identifiable {
    let id: String          // ZUNIQUEID (stable across devices via iCloud)
    let appleTitle: String  // iOS default: usually the nearby location
    let recordedAt: Date
    let duration: TimeInterval
    let fileURL: URL
    /// True when the audio file has synced down from iCloud. A memo that
    /// exists in the database but whose file is absent can't be imported yet.
    let isDownloaded: Bool

    var displayTitle: String {
        let trimmed = appleTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(untitled)" : trimmed
    }
}

enum VoiceMemoLibraryError: Error, CustomStringConvertible {
    case libraryNotFound(URL)
    /// TCC refused to let us read the Voice Memos group container. Since
    /// macOS 15 that folder is gated by Full Disk Access; tccd never prompts
    /// for it — the app silently appears, switched off, in the FDA list.
    case accessDenied
    case sqlite(String)
    case transcriptUnreadable(String)

    var description: String {
        switch self {
        case .libraryNotFound(let url): return "Voice Memos library not found at \(url.path). Is iCloud sync for Voice Memos enabled on this Mac?"
        case .accessDenied: return "macOS is blocking access to the Voice Memos library. Grant Minnas Full Disk Access in System Settings → Privacy & Security, then relaunch."
        case .sqlite(let msg): return "Voice Memos database: \(msg)"
        case .transcriptUnreadable(let msg): return "Apple transcript unreadable: \(msg)"
        }
    }
}

enum VoiceMemoLibrary {
    static let recordingsURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings", isDirectory: true)
    }()

    private static let databaseName = "CloudRecordings.db"

    /// Memos newest first. `limit` caps the list (the picker shows recent
    /// ones; nobody imports a 2018 memo from a menubar).
    static func list(limit: Int = 50) throws -> [VoiceMemo] {
        let fm = FileManager.default
        let dbURL = recordingsURL.appendingPathComponent(databaseName)
        guard fm.fileExists(atPath: dbURL.path) else {
            throw VoiceMemoLibraryError.libraryNotFound(dbURL)
        }

        // Private copy of db + WAL + shm: opening the copy applies the WAL,
        // so rows the Voice Memos app hasn't checkpointed yet are visible,
        // and nothing we do can lock or disturb the live library.
        let tmp = fm.temporaryDirectory.appendingPathComponent("minnas-voicememos-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        for suffix in ["", "-wal", "-shm"] {
            let src = recordingsURL.appendingPathComponent(databaseName + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            do {
                try fm.copyItem(at: src, to: tmp.appendingPathComponent(databaseName + suffix))
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && (error.code == NSFileReadNoPermissionError || error.code == NSFileWriteNoPermissionError) {
                // Foundation reports a TCC-denied read of the source as a
                // *write* permission error naming the destination (513) —
                // misleading, so translate it here. The bundle shows up in
                // the Full Disk Access list the first time this fires.
                memoLog.error("voice memos library access denied (cocoa \(error.code, privacy: .public)) — needs Full Disk Access")
                throw VoiceMemoLibraryError.accessDenied
            }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp.appendingPathComponent(databaseName).path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw VoiceMemoLibraryError.sqlite("open failed")
        }
        defer { sqlite3_close(db) }

        // ZDATE is Core Data time: seconds since 2001-01-01 UTC.
        let sql = """
            SELECT ZUNIQUEID, ZENCRYPTEDTITLE, ZCUSTOMLABEL, ZDATE, ZDURATION, ZPATH
            FROM ZCLOUDRECORDING
            WHERE ZPATH IS NOT NULL
            ORDER BY ZDATE DESC
            LIMIT ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VoiceMemoLibraryError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(max(1, limit)))

        var memos: [VoiceMemo] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ col: Int32) -> String? {
                guard let c = sqlite3_column_text(stmt, col) else { return nil }
                return String(cString: c)
            }
            guard let id = text(0), let path = text(5) else { continue }
            // Prefer the encrypted-title column (what the app shows); the
            // custom label is an older field that may lag or be empty.
            let title = text(1) ?? text(2) ?? ""
            let date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3))
            let duration = sqlite3_column_double(stmt, 4)
            let fileURL = recordingsURL.appendingPathComponent(path)
            memos.append(VoiceMemo(
                id: id, appleTitle: title, recordedAt: date, duration: duration,
                fileURL: fileURL, isDownloaded: fm.fileExists(atPath: fileURL.path)
            ))
        }
        memoLog.notice("listed \(memos.count, privacy: .public) voice memos")
        return memos
    }

    /// "mtime:size" of one file, or nil when it can't be stat'ed. Used both
    /// for the library fingerprint and per memo, so the picker can tell an
    /// audio file rewritten in place (iCloud syncing the embedded
    /// transcript into an existing .qta) from an unchanged one.
    static func fileStamp(_ url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return "\(mtime):\(size)"
    }

    /// A cheap fingerprint of the library: the stamp of every entry in the
    /// Recordings folder (database, WAL, each audio file — a finished
    /// iCloud download adds one, a re-synced memo rewrites one in place)
    /// plus the folder's own mtime. A few hundred stats; the picker polls
    /// this instead of re-copying the database every few seconds, and a
    /// change triggers a real `list`. nil when the folder can't be read.
    static func changeSignature() -> String? {
        let fm = FileManager.default
        guard let dirStamp = fileStamp(recordingsURL),
              let names = try? fm.contentsOfDirectory(atPath: recordingsURL.path) else { return nil }
        var parts = [dirStamp]
        for name in names.sorted() {
            parts.append(name + "=" + (fileStamp(recordingsURL.appendingPathComponent(name)) ?? "-"))
        }
        return parts.joined(separator: "|")
    }

    /// Looks a memo up by its unique id (the CLI harness takes ids so a
    /// title with spaces/emoji never has to round-trip through a shell).
    static func memo(withID id: String) throws -> VoiceMemo? {
        try list(limit: 10_000).first { $0.id == id }
    }

    // MARK: Apple transcript

    private static let transcriptKey = "mdta/com.apple.VoiceMemos.tsrp"

    /// Apple's embedded transcript as an STTResult, or nil when the file
    /// carries none (older memos, or transcription hadn't run on the phone
    /// before sync). Word timings are regrouped into sentence-ish segments
    /// so TranscriptBuilder paragraphs them like any other engine's output.
    static func appleTranscript(for fileURL: URL) async throws -> STTResult? {
        let asset = AVURLAsset(url: fileURL)
        var blob: Data?
        for track in try await asset.load(.tracks) {
            for format in try await track.load(.availableMetadataFormats) {
                for item in try await track.loadMetadata(for: format)
                where item.identifier?.rawValue == transcriptKey {
                    blob = try await item.load(.dataValue)
                }
            }
        }
        guard let blob else { return nil }
        return try parseAppleTranscript(blob)
    }

    /// The tsrp JSON: `attributedString.runs` alternates word strings with
    /// integer indexes into `attributedString.attributeTable`, whose entries
    /// carry `timeRange: [start, end]` in seconds. `locale.identifier` is
    /// the language the phone transcribed in (e.g. "en_GB").
    static func parseAppleTranscript(_ data: Data) throws -> STTResult {
        struct TimeRanged: Decodable { let timeRange: [Double]? }
        struct Attributed: Decodable { let runs: [RunItem]; let attributeTable: [TimeRanged] }
        struct Locale: Decodable { let identifier: String? }
        struct Root: Decodable { let attributedString: Attributed; let locale: Locale? }
        enum RunItem: Decodable {
            case word(String), attribute(Int)
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { self = .word(s) }
                else { self = .attribute(try c.decode(Int.self)) }
            }
        }

        let root: Root
        do { root = try JSONDecoder().decode(Root.self, from: data) } catch {
            throw VoiceMemoLibraryError.transcriptUnreadable(String(describing: error))
        }

        // Pair each word with the time range its following attribute index
        // points at.
        var words: [(text: String, start: Double, end: Double)] = []
        var pendingWord: String?
        for item in root.attributedString.runs {
            switch item {
            case .word(let w):
                pendingWord = w
            case .attribute(let idx):
                guard let w = pendingWord else { continue }
                pendingWord = nil
                let table = root.attributedString.attributeTable
                let range = idx < table.count ? (table[idx].timeRange ?? []) : []
                let start = range.count >= 1 ? range[0] : (words.last?.end ?? 0)
                let end = range.count >= 2 ? range[1] : start
                words.append((w, start, end))
            }
        }

        // Regroup into segments: break on sentence-ending punctuation, on a
        // pause longer than 1.5 s, or after ~40 words so one run-on breath
        // doesn't become a wall of text.
        var segments: [STTSegment] = []
        var current: [(text: String, start: Double, end: Double)] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined()
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(STTSegment(start: Float(first.start), end: Float(last.end), text: text, speaker: nil))
            }
            current.removeAll()
        }
        for word in words {
            if let last = current.last, word.start - last.end > 1.5 { flush() }
            current.append(word)
            let trimmed = word.text.trimmingCharacters(in: .whitespaces)
            let endsSentence = trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!")
            if endsSentence || current.count >= 40 { flush() }
        }
        flush()

        let language = (root.locale?.identifier ?? "")
            .split(whereSeparator: { $0 == "_" || $0 == "-" }).first.map(String.init)?.lowercased() ?? ""
        memoLog.info("apple transcript: \(words.count, privacy: .public) words → \(segments.count, privacy: .public) segments, language=\(language, privacy: .public)")
        return STTResult(segments: segments, language: language)
    }
}
