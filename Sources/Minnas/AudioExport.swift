//
// Prepares captured audio for cloud STT upload.
//
// Two constraints from the OpenAI transcription API:
//   1. It rejects .caf — we must transcode to a supported container.
//      AAC-in-m4a is small and accepted.
//   2. Each upload is capped at 25 MB. A long meeting's single file blows
//      past that, so we split into time chunks and transcribe each, then
//      the cloud engine offsets per-chunk timestamps back to absolute time.
//
// The AppleM4A export preset emits ~128 kbps AAC, so a 15-minute chunk is
// ~14 MB — comfortably under the cap with margin for higher-bitrate inputs.
//

import AVFoundation
import Foundation

struct AudioChunk: Sendable {
    let url: URL            // temp .m4a file (caller deletes via cleanup)
    let startOffset: Double // seconds into the original file where this chunk begins
}

enum AudioExportError: Error {
    case durationUnavailable
    case sessionCreationFailed
    case exportFailed(underlying: Error)
}

enum AudioExport {
    /// Chunk length in seconds. See the bitrate math in the file header for
    /// why 15 minutes stays safely under the 25 MB upload cap.
    static let chunkSeconds: Double = 15 * 60

    /// Transcodes `sourceURL` (.caf) into one or more temp .m4a chunks,
    /// each at most `chunkSeconds` long, returned in order with their
    /// absolute start offset. The caller must `cleanup(_:)` the result.
    static func exportChunks(from sourceURL: URL) async throws -> [AudioChunk] {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)
        guard totalSeconds.isFinite, totalSeconds > 0 else {
            throw AudioExportError.durationUnavailable
        }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("minnas-stt", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        var chunks: [AudioChunk] = []
        var start = 0.0
        var index = 0
        do {
            while start < totalSeconds {
                let length = min(chunkSeconds, totalSeconds - start)
                let outURL = tmpDir.appendingPathComponent("\(UUID().uuidString)-\(index).m4a")
                try await export(asset: asset, to: outURL, start: start, length: length)
                chunks.append(AudioChunk(url: outURL, startOffset: start))
                start += chunkSeconds
                index += 1
            }
        } catch {
            // On a mid-export failure the caller never receives the array and
            // so can't cleanup() it — reap the already-written chunks here
            // before rethrowing, or they leak in the temp dir.
            cleanup(chunks)
            throw error
        }
        return chunks
    }

    static func cleanup(_ chunks: [AudioChunk]) {
        for chunk in chunks {
            try? FileManager.default.removeItem(at: chunk.url)
        }
    }

    /// Transcode a whole file to AAC-in-m4a — used to compress retained
    /// captures (.caf → .m4a, ~10–20× smaller) once they're no longer needed
    /// in lossless form. The export lands in a same-directory .part file and
    /// is renamed only after AVFoundation reports success, so interruption
    /// can never leave a truncated destination shadowing the raw capture.
    static func transcodeToM4A(source: URL, destination: URL) async throws {
        try await export(asset: AVURLAsset(url: source), to: destination, timeRange: nil)
    }

    private static func export(
        asset: AVURLAsset,
        to outURL: URL,
        start: Double,
        length: Double
    ) async throws {
        let timescale: CMTimeScale = 600
        try await export(asset: asset, to: outURL, timeRange: CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: timescale),
            duration: CMTime(seconds: length, preferredTimescale: timescale)
        ))
    }

    /// Shared AAC-in-m4a export core. A nil `timeRange` exports the whole
    /// asset; a set range exports just that slice (chunking). Overwrites the
    /// destination.
    private static func export(
        asset: AVURLAsset,
        to outURL: URL,
        timeRange: CMTimeRange?
    ) async throws {
        let fm = FileManager.default
        let partURL = outURL.appendingPathExtension("part")
        try? fm.removeItem(at: partURL)
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw AudioExportError.sessionCreationFailed
        }
        if let timeRange { session.timeRange = timeRange }
        do {
            try await session.export(to: partURL, as: .m4a)
            if fm.fileExists(atPath: outURL.path) {
                _ = try fm.replaceItemAt(outURL, withItemAt: partURL)
            } else {
                try fm.moveItem(at: partURL, to: outURL)
            }
        } catch {
            try? fm.removeItem(at: partURL)
            throw AudioExportError.exportFailed(underlying: error)
        }
    }
}
