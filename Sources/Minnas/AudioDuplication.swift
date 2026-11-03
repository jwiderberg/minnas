//
// Detects when the mic and system streams captured the same audio — the
// "recording on speakers" case, where the mic acoustically picks up the
// remote voices coming out of the speakers, so both streams hold the whole
// conversation. Transcribing both then doubles the work and duplicates the
// Me/Them turns.
//
// Signal: the two streams' short-window RMS energy envelopes. When the mic
// is an acoustic echo of the system output, both go loud/quiet together →
// high positive correlation. When the streams are cleanly separated (AEC
// on: you on the mic, remote on the system, turn-taking) they're
// uncorrelated or anti-correlated. So a high envelope correlation means
// "redundant — transcribe one stream."
//
// Cheap: one RMS value per ~250 ms window, then Pearson over the envelopes
// — milliseconds of math after a sequential read, vs. a full second STT pass.
//

import AVFoundation
import Foundation
import os.log

private let dupLog = Logger(subsystem: "com.jwiderberg.minnas", category: "Dedup")

enum AudioDuplication {
    /// Envelope correlation at/above which the two streams are treated as
    /// the same audio. Calibrated on a real on-speakers recording (0.84);
    /// cleanly AEC-separated streams correlate near zero or negative, so
    /// 0.6 separates the two cases with margin.
    static let duplicateThreshold = 0.6

    /// True when the system stream is redundant with the mic (and dedupe is
    /// enabled) — the caller then transcribes the mic only. Reads both files
    /// once (cheap vs. a second STT pass).
    static func systemDuplicatesMic(mic: URL, system: URL) -> Bool {
        guard Config.dedupeStreams() else { return false }
        guard let correlation = envelopeCorrelation(mic, system) else { return false }
        let duplicate = correlation >= duplicateThreshold
        dupLog.info("mic/system envelope correlation \(correlation, privacy: .public) (threshold \(duplicateThreshold, privacy: .public)) → \(duplicate ? "duplicate, system skipped" : "distinct", privacy: .public)")
        return duplicate
    }

    /// Pearson correlation of the two files' RMS envelopes, or nil if either
    /// can't be read / is effectively silent.
    static func envelopeCorrelation(_ urlA: URL, _ urlB: URL, frameSeconds: Double = 0.25) -> Double? {
        guard let a = rmsEnvelope(urlA, frameSeconds: frameSeconds),
              let b = rmsEnvelope(urlB, frameSeconds: frameSeconds) else { return nil }
        let n = min(a.count, b.count)
        guard n >= 8 else { return nil }
        return pearson(Array(a.prefix(n)), Array(b.prefix(n)))
    }

    private static func rmsEnvelope(_ url: URL, frameSeconds: Double) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let framesPerWindow = AVAudioFrameCount(format.sampleRate * frameSeconds)
        guard framesPerWindow > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerWindow)
        else { return nil }

        var envelope: [Float] = []
        while true {
            buffer.frameLength = 0
            do { try file.read(into: buffer, frameCount: framesPerWindow) } catch { break }
            let count = Int(buffer.frameLength)
            if count == 0 { break }
            guard let channel = buffer.floatChannelData?[0] else { break }
            var sumSquares: Float = 0
            for i in 0..<count { sumSquares += channel[i] * channel[i] }
            envelope.append((sumSquares / Float(count)).squareRoot())
        }
        return envelope.isEmpty ? nil : envelope
    }

    private static func pearson(_ x: [Float], _ y: [Float]) -> Double {
        let n = Double(x.count)
        let meanX = Double(x.reduce(0, +)) / n
        let meanY = Double(y.reduce(0, +)) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<x.count {
            let dx = Double(x[i]) - meanX
            let dy = Double(y[i]) - meanY
            sxy += dx * dy
            sxx += dx * dx
            syy += dy * dy
        }
        guard sxx > 0, syy > 0 else { return 0 }
        return sxy / (sxx.squareRoot() * syy.squareRoot())
    }
}
