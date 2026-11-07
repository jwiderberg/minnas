//
// "Transcribe Audio File…": any recording made elsewhere (a Teams/Zoom
// cloud recording, a dictaphone file, a podcast) goes through the same
// transcribe → deliver path as a Mac recording.
//
// The file is transcoded to AAC-in-m4a into a fresh outbox slot as the
// single "system" stream (the original is never touched), meta is written
// with capture_kind "file_import", and the caller runs TranscriptionJob on
// the slot. Anything AVFoundation can open is accepted — audio (wav, mp3,
// m4a, aac, flac, aiff, caf, ogg/opus where the OS decodes it) and video
// containers (mp4, mov, m4v), from which only the audio track is kept.
//
// Shared by the menubar item and the --import-file CLI harness.
//

import AVFoundation
import Foundation
import UniformTypeIdentifiers
import os.log

private let fileImportLog = Logger(subsystem: "com.jwiderberg.minnas", category: "FileImport")

enum AudioFileImporter {
    struct Result {
        let slot: OutboxSlot
        let meta: RecordingMeta
    }

    enum ImportError: Error, CustomStringConvertible {
        case noAudioTrack(String)
        case unreadable(String)
        var description: String {
            switch self {
            case .noAudioTrack(let name): return "\"\(name)\" has no audio track."
            case .unreadable(let name): return "\"\(name)\" couldn't be opened as audio."
            }
        }
    }

    /// Content types the open panel offers.
    static let allowedContentTypes: [UTType] = [.audio, .movie]

    /// Default title: the file's name without extension, underscores and
    /// dashes turned into spaces ("2026-01-15 Team_sync" → "2026-01-15 Team
    /// sync").
    static func defaultTitle(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Default start time: the file's creation date — for a downloaded
    /// cloud recording that is the download time, not the meeting, so the
    /// menubar flow lets the user correct it.
    static func defaultStartedAt(for url: URL) -> Date {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date) ?? Date()
    }

    static func prepare(fileURL: URL, title: String, startedAt: Date) async throws -> Result {
        let name = fileURL.lastPathComponent
        let asset = AVURLAsset(url: fileURL)
        let tracks: [AVAssetTrack]
        let seconds: Double
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            seconds = CMTimeGetSeconds(try await asset.load(.duration))
        } catch {
            throw ImportError.unreadable(name)
        }
        guard !tracks.isEmpty else { throw ImportError.noAudioTrack(name) }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = cleanTitle.isEmpty ? defaultTitle(for: fileURL) : cleanTitle
        let slot = try Outbox.makeSlot(title: finalTitle, startedAt: startedAt)
        do {
            // Always transcode (even m4a): it normalises odd containers and
            // drops video tracks, and AAC at this size is cheap.
            try await AudioExport.transcodeToM4A(source: fileURL, destination: slot.systemCompressedURL)
        } catch {
            try? FileManager.default.removeItem(at: slot.dirURL)
            throw error
        }

        var meta = RecordingMeta(
            title: finalTitle,
            started_at: startedAt,
            ended_at: startedAt.addingTimeInterval(max(1, seconds.isFinite ? seconds : 1)),
            device: AppInfo.fileImportDevice,
            client_version: AppInfo.version
        )
        meta.capture_kind = RecordingMeta.fileImportCaptureKind
        meta.import_source = name
        try Outbox.writeMeta(meta, to: slot.metaURL)
        fileImportLog.notice("imported \(name, privacy: .public) → \(slot.slug, privacy: .public) (\(Int(min(max(seconds.isFinite ? seconds : 0, 0), 1e9)), privacy: .public)s)")
        return Result(slot: slot, meta: meta)
    }
}
