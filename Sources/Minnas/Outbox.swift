//
// Disk layout for in-progress and completed recordings.
//
// Layout (per recording):
//   outbox/<slug>/
//     system.caf     — system audio capture (process tap or ScreenCaptureKit)
//     mic.caf        — microphone capture (AVAudioEngine)
//     mic.m4a / system.m4a — the compressed audio, once transcribed
//     meta.json      — recording metadata + per-sink delivery state
//     transcript.md  — the transcript, with YAML frontmatter
//
// `slug` is `<YYYY-MM-DD>-<HHMM>-<sanitized-title>`. The date/time prefix
// makes alphabetical sort = chronological sort; the title suffix is just
// for human eyeballing of outbox/.
//

import AVFoundation
import Foundation
import os.log

private let outboxLog = Logger(subsystem: "com.jwiderberg.minnas", category: "Outbox")

struct OutboxSlot: Sendable {
    let dirURL: URL
    let slug: String
    let systemAudioURL: URL
    let micAudioURL: URL
    let metaURL: URL
    let transcriptURL: URL
}

extension OutboxSlot {
    // Compressed (retained) audio. After transcription the raw .caf is
    // transcoded to these and deleted, shrinking ~1 GB/meeting ~10–20×.
    var micCompressedURL: URL { dirURL.appendingPathComponent("mic.m4a") }
    var systemCompressedURL: URL { dirURL.appendingPathComponent("system.m4a") }

    /// Best audio to read for transcription / analysis: the compressed m4a
    /// once it exists, else the raw .caf. (Capture always writes the .caf.)
    var micAudioReadURL: URL { Self.preferCompressed(raw: micAudioURL, compressed: micCompressedURL) }
    var systemAudioReadURL: URL { Self.preferCompressed(raw: systemAudioURL, compressed: systemCompressedURL) }

    private static func preferCompressed(raw: URL, compressed: URL) -> URL {
        FileManager.default.fileExists(atPath: compressed.path) ? compressed : raw
    }

    /// Every audio file the slot can hold, raw and compressed.
    var audioURLs: [URL] { [micAudioURL, systemAudioURL, micCompressedURL, systemCompressedURL] }

    /// Whether any audio is left. A slot past the retention window keeps
    /// only its transcript, so it can no longer be re-transcribed.
    var hasAudio: Bool { audioURLs.contains { FileManager.default.fileExists(atPath: $0.path) } }
}

/// A meeting participant, from the calendar event the recording was
/// tagged with (EventKit). Stored in meta.json; the transcript itself only
/// ever shows a name (the "Them" speaker of a 1:1).
struct Attendee: Codable, Sendable {
    var name: String?
    var email: String?
}

struct DetectedLanguage: Codable, Sendable {
    var code: String
    var fraction: Double
}

/// How a transcript was produced. Recorded on every transcription run so
/// a re-transcribe with a different model is self-describing.
struct TranscriptionProvenance: Codable, Sendable {
    var engine: String          // e.g. "whisperkit"
    var model: String           // TranscriptionModel.rawValue
    var transcribed_at: Date
}

struct RecordingMeta: Codable, Sendable {
    var source: String = "meeting"
    var title: String
    var started_at: Date
    var ended_at: Date?
    var calendar_event_id: String?
    var calendar_event_url: String?
    // From the calendar event when one is attached (nil otherwise). Used to
    // name the other person in a 1:1 and to steer language detection.
    var attendees: [Attendee]?
    var languages_detected: [DetectedLanguage]?
    var device: String
    var client_version: String
    // Audio is kept on this Mac until the retention window prunes it
    // (Outbox.pruneOldRecordings).
    var audio_retained: Bool = true
    // Set after each (re-)transcription.
    var transcription: TranscriptionProvenance?
    // When TranscriptionJob.finish began writing this generation's
    // transcript.md (stamped before it is written, saved in meta.json only
    // after it is). SinkDispatcher refuses to deliver a file older than
    // this, so a stale transcript can never go out as the current
    // generation. nil = no check.
    var transcript_written_at: Date?
    // Per-sink delivery state (TranscriptSink), keyed by sink id. Persisted
    // so the retry backoff survives app restarts.
    var deliveries: [String: SinkDelivery]?
    var delivery_attempts: [String: DeliveryAttempt]?
    // Where each sink put the PREVIOUS transcript, kept when a re-transcribe
    // clears `deliveries`, so the folder sink overwrites its old file
    // instead of leaving a stale copy next to a " (2)".
    var previous_locations: [String: String]?
    // How the audio was captured. nil = the normal two-stream capture (mic +
    // system). "voice_memo" = a single-stream phone recording imported from
    // the Voice Memos library: everyone is in one stream, so the transcript
    // labels speakers "Speaker" / "Speaker (A)" instead of Me/Them.
    var capture_kind: String?
    // For capture_kind "file_import": the original file's name, for the
    // record.
    var import_source: String?
    // Post-mortem evidence for the capture layer, written at stop. How many times each stream had to be re-attached after the OS
    // stopped it (route change, stream death), how much silence was padded
    // in to keep the streams aligned, and how much audio actually arrived.
    var capture_health: CaptureHealth?
}

struct CaptureHealth: Codable, Sendable {
    var mic_restarts: Int
    var mic_padded_seconds: Double
    var mic_seconds_captured: Double
    var mic_had_signal: Bool
    var system_restarts: Int
    var system_padded_seconds: Double
    var system_buffers: Int
    var system_had_signal: Bool
    var system_writer_failed: Bool
}

extension RecordingMeta {
    static let voiceMemoCaptureKind = "voice_memo"
    // A recording file from somewhere else (a Teams/Zoom cloud recording,
    // a dictaphone, a podcast) transcribed via "Transcribe Audio File…".
    // Like a voice memo it is ONE stream with everyone in it.
    static let fileImportCaptureKind = "file_import"
    var isVoiceMemo: Bool { capture_kind == Self.voiceMemoCaptureKind }
    var isFileImport: Bool { capture_kind == Self.fileImportCaptureKind }
    /// One audio stream holding every participant (no Me/Them split): a
    /// voice memo or an imported file. Stored in the slot's system stream.
    var isSingleStream: Bool { isVoiceMemo || isFileImport }
}

extension RecordingMeta {
    func isDelivered(to sinkID: String) -> Bool {
        deliveries?[sinkID] != nil
    }

    /// Backoff state for a sink (zero attempts when it never tried).
    func attempt(for sinkID: String) -> DeliveryAttempt {
        delivery_attempts?[sinkID] ?? DeliveryAttempt(attempt_count: 0, last_attempt_at: nil)
    }

    mutating func recordDelivery(_ delivery: SinkDelivery, for sinkID: String) {
        var all = deliveries ?? [:]
        all[sinkID] = delivery
        deliveries = all
        // A success clears backoff, so a later re-delivery (re-transcribe)
        // starts from a clean schedule; the recorded location supersedes
        // any previous one.
        delivery_attempts?[sinkID] = nil
        if delivery_attempts?.isEmpty == true { delivery_attempts = nil }
        previous_locations?[sinkID] = nil
        if previous_locations?.isEmpty == true { previous_locations = nil }
    }

    mutating func recordAttempt(for sinkID: String, at date: Date = Date()) {
        var next = attempt(for: sinkID)
        next.attempt_count += 1
        next.last_attempt_at = date
        var all = delivery_attempts ?? [:]
        all[sinkID] = next
        delivery_attempts = all
    }

    /// New transcript content supersedes every delivery: each sink must
    /// re-deliver, and its old location is remembered (previous_locations)
    /// so a file sink can overwrite rather than duplicate.
    mutating func resetDeliveries() {
        var previous = previous_locations ?? [:]
        for (sinkID, delivery) in deliveries ?? [:] {
            if let location = delivery.location { previous[sinkID] = location }
        }
        previous_locations = previous.isEmpty ? nil : previous
        deliveries = nil
        delivery_attempts = nil
    }
}

enum Outbox {
    static let rootURL: URL = {
        // ~/Library/Application Support/minnas/outbox/.
        // Using FileManager.default.currentDirectoryPath here would break
        // launches via `open .build/Minnas.app`, where the CWD
        // is `/` (read-only). Application Support is the standard macOS
        // location for app-managed user data and doesn't depend on how
        // the app was launched.
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return base
            .appendingPathComponent("minnas", isDirectory: true)
            .appendingPathComponent("outbox", isDirectory: true)
    }()

    static func makeSlot(title: String, startedAt: Date) throws -> OutboxSlot {
        let fm = FileManager.default
        // The slug has minute resolution, so two recordings started in the
        // same minute with the same title would collide on one directory and
        // the second would overwrite the first's meta and audio. Append -2, -3…
        // until the path is free.
        func create(base: String) throws -> URL {
            var slug = base
            var n = 2
            while fm.fileExists(atPath: rootURL.appendingPathComponent(slug, isDirectory: true).path) {
                slug = "\(base)-\(n)"
                n += 1
            }
            let dir = rootURL.appendingPathComponent(slug, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = Self.slug(title: normalizeTitle(title), startedAt: startedAt)
        do {
            return slot(forDir: try create(base: base))
        } catch {
            // The title comes from whoever sent the invite; a name the
            // filesystem rejects must not stop the recording.
            outboxLog.error("couldn't create slot dir from title (\(error.localizedDescription, privacy: .public)); using untitled")
            return slot(forDir: try create(base: Self.slug(title: "", startedAt: startedAt)))
        }
    }

    /// One-line, bounded title for meta and the transcript: every run of
    /// whitespace or control characters (tabs, newlines, NEL, U+2028/2029)
    /// becomes one space, the ends are trimmed, and the result is capped at
    /// 200 Characters — a title comes from whoever sent the invite, and it
    /// ends up in a YAML frontmatter line, a heading and a file name.
    /// Empty → "Meeting".
    static func normalizeTitle(_ title: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in title.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .spaceSeparator, .lineSeparator, .paragraphSeparator:
                scalars.append(" ")
            default:
                scalars.append(scalar)
            }
        }
        let collapsed = String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let capped = String(collapsed.prefix(200)).trimmingCharacters(in: .whitespaces)
        return capped.isEmpty ? "Meeting" : capped
    }

    /// Builds the file-path bundle for an outbox directory without creating
    /// it. Used both by makeSlot and by re-transcribe, which reopens a
    /// recording that already exists on disk.
    static func slot(forDir dir: URL) -> OutboxSlot {
        OutboxSlot(
            dirURL: dir,
            slug: dir.lastPathComponent,
            systemAudioURL: dir.appendingPathComponent("system.caf"),
            micAudioURL: dir.appendingPathComponent("mic.caf"),
            metaURL: dir.appendingPathComponent("meta.json"),
            transcriptURL: dir.appendingPathComponent("transcript.md")
        )
    }

    /// Persisted recordings on disk, newest first. A recording is any
    /// outbox subdirectory with a meta.json and either audio or a
    /// transcript (a slot past the retention window keeps only the
    /// transcript). The
    /// slug's date-time prefix makes a reverse string sort = newest-first.
    static func listSlots(limit: Int? = nil) -> [OutboxSlot] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var slots: [OutboxSlot] = []
        for dir in entries {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let slot = slot(forDir: dir)
            guard fm.fileExists(atPath: slot.metaURL.path) else { continue }
            if slot.hasAudio || fm.fileExists(atPath: slot.transcriptURL.path) { slots.append(slot) }
        }
        slots.sort { $0.slug > $1.slug }
        if let limit { return Array(slots.prefix(limit)) }
        return slots
    }

    /// Reap exports interrupted before their final rename. These sidecars
    /// are never valid read targets; the intact .caf remains authoritative.
    static func removeCompressionTemporaryFiles() {
        let fm = FileManager.default
        let directories = (try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for directory in directories {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let slot = slot(forDir: directory)
            guard fm.fileExists(atPath: slot.metaURL.path) else { continue }
            for compressed in [slot.micCompressedURL, slot.systemCompressedURL] {
                let part = compressed.appendingPathExtension("part")
                guard fm.fileExists(atPath: part.path) else { continue }
                do {
                    try fm.removeItem(at: part)
                    outboxLog.notice("removed interrupted compression \(part.lastPathComponent, privacy: .public) from \(slot.slug, privacy: .public)")
                } catch {
                    outboxLog.error("couldn't remove interrupted compression \(part.lastPathComponent, privacy: .public) from \(slot.slug, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Transcode a slot's raw .caf captures to compressed m4a and delete the
    /// originals. Idempotent (skips a stream already compressed or missing).
    /// Best-effort: a failure leaves the raw .caf in place.
    static func compressAudio(_ slot: OutboxSlot) async {
        let fm = FileManager.default
        let streams = [
            (raw: slot.micAudioURL, compressed: slot.micCompressedURL),
            (raw: slot.systemAudioURL, compressed: slot.systemCompressedURL),
        ]
        for stream in streams {
            guard fm.fileExists(atPath: stream.raw.path) else { continue }
            if fm.fileExists(atPath: stream.compressed.path) {
                guard let validated = validatedCompression(stream.compressed, against: stream.raw) else {
                    try? fm.removeItem(at: stream.compressed)
                    continue
                }
                try? fm.removeItem(at: stream.raw)
                outboxLog.info("validated existing \(stream.compressed.lastPathComponent, privacy: .public) (\(validated.size, privacy: .public) bytes, peak=\(validated.peak, privacy: .public)); raw removed")
                continue
            }
            do {
                try await AudioExport.transcodeToM4A(source: stream.raw, destination: stream.compressed)
                // Only drop the original once the compressed file exists AND
                // is actually readable with audio in it — guards against a
                // truncated/corrupt export silently losing the recording.
                guard let validated = validatedCompression(stream.compressed, against: stream.raw) else {
                    try? fm.removeItem(at: stream.compressed)
                    continue
                }
                try? fm.removeItem(at: stream.raw)
                outboxLog.info("compressed \(stream.raw.lastPathComponent, privacy: .public) → m4a (\(validated.size, privacy: .public) bytes, peak=\(validated.peak, privacy: .public)), raw removed")
            } catch {
                outboxLog.error("compress \(stream.raw.lastPathComponent, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Applies the existing duration/size and peak checks to both newly
    /// exported and pre-existing compressed files.
    private static func validatedCompression(_ compressed: URL, against raw: URL) -> (size: Int, peak: Float)? {
        let fm = FileManager.default
        let readableFrames = (try? AVAudioFile(forReading: compressed))?.length ?? 0
        let size = (try? fm.attributesOfItem(atPath: compressed.path)[.size] as? Int) ?? 0
        guard readableFrames > 0, size > 1024 else {
            outboxLog.error("compressed \(raw.lastPathComponent, privacy: .public) unreadable (frames=\(readableFrames, privacy: .public) size=\(size, privacy: .public)); deleting compressed and keeping raw")
            return nil
        }
        // Never delete the raw .caf if the compressed copy is silent while
        // the raw is NOT — that's audio lost in transcode, and the raw is the
        // only remaining copy. A raw that is itself silent is safe to drop.
        let silenceThreshold: Float = 0.001
        let compressedPeak = Self.peakAmplitude(of: compressed) ?? 0
        if compressedPeak < silenceThreshold,
           let rawPeak = Self.peakAmplitude(of: raw), rawPeak >= silenceThreshold {
            outboxLog.error("compressed \(raw.lastPathComponent, privacy: .public) is SILENT (peak=\(compressedPeak, privacy: .public)) but raw has signal (peak=\(rawPeak, privacy: .public)) — deleting compressed and KEEPING raw to avoid data loss")
            return nil
        }
        return (size, compressedPeak)
    }

    /// Peak absolute sample amplitude (0…~1) of an audio file, or nil if it
    /// can't be read. Reads in blocks to bound memory. Used to verify a
    /// compressed copy actually contains audio before deleting the raw.
    static func peakAmplitude(of url: URL) -> Float? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        guard format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 20) else { return nil }
        var peak: Float = 0
        while true {
            buffer.frameLength = 0
            do { try file.read(into: buffer) } catch { return peak }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let channels = buffer.floatChannelData else { return peak }
            for c in 0..<Int(format.channelCount) {
                let samples = channels[c]
                for i in 0..<n {
                    let v = abs(samples[i])
                    if v > peak { peak = v }
                }
            }
        }
        return peak
    }

    /// Prune recordings older than `keepDays`. keepDays == 0 disables it.
    /// Nothing outside the outbox is ever touched — the transcripts folder
    /// belongs to the user.
    ///   - owed to an ACTIVE sink (the Markdown folder) that applies to it
    ///     and hasn't delivered it: kept whole. The transcript (and for a
    ///     re-transcribe, the audio) must survive until it has gone out.
    ///     Startup runs recovery → prune → first delivery tick, so without
    ///     this a folder export still owed would be deleted before it ever
    ///     ran.
    ///   - not transcribed yet: kept whole — the audio is all there is.
    ///   - delivered somewhere (the folder holds the user's copy): the whole
    ///     slot goes, audio and the outbox copy of the transcript.
    ///   - transcribed but delivered nowhere (no folder chosen): only the
    ///     audio goes. transcript.md here is the only copy, so it and
    ///     meta.json stay.
    static func pruneOldRecordings(keepDays: Int) {
        guard keepDays > 0 else { return }
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86_400)
        let sinks = SinkDispatcher.activeSinks()
        for slot in listSlots() {
            guard let meta = try? readMeta(from: slot.metaURL),
                  addedToOutbox(slot, meta: meta) < cutoff else { continue }
            let hasTranscript = fm.fileExists(atPath: slot.transcriptURL.path)
            switch pruneAction(meta: meta, hasTranscript: hasTranscript, activeSinks: sinks) {
            case .keep:
                continue
            case .audioOnly:
                for url in slot.audioURLs where fm.fileExists(atPath: url.path) {
                    do {
                        try fm.removeItem(at: url)
                        outboxLog.info("pruned audio \(slot.slug, privacy: .public)/\(url.lastPathComponent, privacy: .public) (not delivered anywhere, older than \(keepDays, privacy: .public)d)")
                    } catch {
                        outboxLog.error("prune \(slot.slug, privacy: .public)/\(url.lastPathComponent, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    }
                }
            case .wholeSlot:
                do {
                    try fm.removeItem(at: slot.dirURL)
                    outboxLog.info("pruned \(slot.slug, privacy: .public) (older than \(keepDays, privacy: .public)d)")
                } catch {
                    outboxLog.error("prune \(slot.slug, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    enum PruneAction: Equatable { case keep, audioOnly, wholeSlot }

    /// The pruning rule for one slot already past the cutoff, kept pure so
    /// it can be checked without a real outbox.
    static func pruneAction(meta: RecordingMeta, hasTranscript: Bool, activeSinks: [any TranscriptSink]) -> PruneAction {
        // Owed to a sink that is configured now: keep everything.
        if !SinkDispatcher.pendingSinks(for: meta, among: activeSinks).isEmpty { return .keep }
        let transcribed = meta.transcription != nil || hasTranscript
        guard transcribed else { return .keep }
        if meta.deliveries?.isEmpty == false { return .wholeSlot }
        return .audioOnly
    }

    /// When a slot arrived in the outbox — its directory's creation date —
    /// not when the meeting happened: a voice memo or a file imported with
    /// its real (months-old) meeting date is new here and must not be
    /// pruned at the next launch. Falls back to the transcription time,
    /// then the meeting start, if the filesystem gives no creation date.
    private static func addedToOutbox(_ slot: OutboxSlot, meta: RecordingMeta) -> Date {
        if let created = try? slot.dirURL.resourceValues(forKeys: [.creationDateKey]).creationDate {
            return created
        }
        return meta.transcription?.transcribed_at ?? meta.started_at
    }

    static func writeMeta(_ meta: RecordingMeta, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(meta)
        try data.write(to: url, options: .atomic)
    }

    /// Serialises every read-modify-write of a slot's meta.json in this
    /// process. The delivery dispatcher (retry timer), TranscriptionJob.finish
    /// (a re-transcribe) and launch recovery each read meta, change
    /// some fields and write it back; without one lock two of them racing
    /// would silently drop the other's change (a lost `deliveries` entry
    /// re-delivers, a lost reset leaves a stale transcript marked delivered).
    /// One lock for all slots: the critical section is a small JSON read +
    /// write, so contention is irrelevant. It does NOT cover another process
    /// (the CLI running beside the app).
    private static let metaLock = NSLock()

    /// Read → `body` → write meta.json under `metaLock`. `body` must not
    /// block on anything slow (no network, no awaits — it can't). If `body`
    /// throws, nothing is written. `ifUnreadable` is the meta to start from
    /// when the file is missing or doesn't decode; without it that throws.
    /// First creation of a slot uses plain writeMeta (nobody else can see
    /// the slot yet).
    static func mutateMeta(
        _ slot: OutboxSlot,
        ifUnreadable fallback: RecordingMeta? = nil,
        _ body: (inout RecordingMeta) throws -> Void
    ) throws {
        try metaLock.withLock {
            var meta: RecordingMeta
            do {
                meta = try readMeta(from: slot.metaURL)
            } catch {
                guard let fallback else { throw error }
                meta = fallback
            }
            try body(&meta)
            try writeMeta(meta, to: slot.metaURL)
        }
    }

    static func readMeta(from url: URL) throws -> RecordingMeta {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingMeta.self, from: data)
    }

    private static func slug(title: String, startedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let prefix = formatter.string(from: startedAt)

        // Sanitize: strip combining marks, lowercase, replace runs of
        // non-alphanumerics with '-', trim leading/trailing dashes, clamp
        // length. The marks go first because one Character can carry any
        // number of them: six letters with stacked marks made a 600-byte
        // name that createDirectory refused (APFS caps a name at 255 bytes).
        var unmarked = String.UnicodeScalarView()
        for scalar in title.folding(options: .diacriticInsensitive, locale: nil).unicodeScalars {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: continue
            default: unmarked.append(scalar)
            }
        }
        let lowered = String(unmarked).lowercased()
        var sanitized = ""
        var lastWasDash = false
        for char in lowered {
            if char.isLetter || char.isNumber {
                sanitized.append(char)
                lastWasDash = false
            } else if !lastWasDash {
                sanitized.append("-")
                lastWasDash = true
            }
        }
        // Cap by UTF-8 bytes on a Character boundary: the limit that matters
        // is the filesystem's, and a Character can be many bytes.
        var capped = ""
        var bytes = 0
        for char in sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-")) {
            let size = String(char).utf8.count
            guard bytes + size <= 100 else { break }
            capped.append(char)
            bytes += size
        }
        let trimmed = capped.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let body = trimmed.isEmpty ? "untitled" : trimmed
        return "\(prefix)-\(body)"
    }
}

enum AppInfo {
    static let version = "0.1.0"
    // What captured the audio, written to meta.json and the transcript's
    // frontmatter: a recording made on this Mac, an imported phone memo, or
    // a file transcribed via "Transcribe Audio File…".
    static let device = "mac"
    static let voiceMemoDevice = "iphone-voice-memos"
    static let fileImportDevice = "file-import"
}
