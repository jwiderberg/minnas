//
// Cloud STT via OpenAI's audio transcriptions API.
//
// Pipeline per stream: export the .caf to chunked m4a (AudioExport,
// because the API rejects .caf and caps uploads at 25 MB) → multipart
// POST each chunk to /v1/audio/transcriptions with the
// gpt-4o-transcribe-diarize model and response_format=diarized_json →
// parse the segments and offset their timestamps back to absolute time
// → return one STTResult per chunk.
//
// The stream decides the side (mic = Me, system = Them). diarized_json's
// speaker ids are passed through on each STTSegment, and TranscriptBuilder
// labels the system stream's distinct ids "Them (A)", "Them (B)"; the
// local diarizer is skipped for this model.
//
// NOTE: diarized_json's exact field set isn't fully documented; the
// decoder below is deliberately lenient (all fields optional, with a
// text-only fallback) and may want a tweak once tested against a real
// response — the API key lives on the user's machine, not here.
//

import Foundation
import os.log

private let cloudLog = Logger(subsystem: "com.jwiderberg.minnas", category: "CloudSTT")

enum CloudTranscriberError: Error, CustomStringConvertible {
    case httpError(status: Int, body: String)
    case badResponse

    var description: String {
        switch self {
        case .httpError(let status, let body):
            return "OpenAI transcription failed (HTTP \(status)): \(body)"
        case .badResponse:
            return "OpenAI transcription returned an unreadable response."
        }
    }
}

enum CloudTranscriber {
    private static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    static func transcribe(
        audioPath: String,
        model: TranscriptionModel,
        language: String? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [STTResult] {
        let key = try Config.openAIKey()
        let sourceURL = URL(fileURLWithPath: audioPath)

        let chunks = try await AudioExport.exportChunks(from: sourceURL)
        defer { AudioExport.cleanup(chunks) }

        var results: [STTResult] = []
        for (i, chunk) in chunks.enumerated() {
            cloudLog.info("Transcribing chunk \(i + 1, privacy: .public)/\(chunks.count, privacy: .public) via \(model.rawValue, privacy: .public)")
            let data = try Data(contentsOf: chunk.url)
            let response = try await postChunk(data, model: model, apiKey: key, language: language)
            results.append(makeResult(from: response, offset: chunk.startOffset))
            // Coarse, per-chunk (the API gives no within-request progress).
            onProgress?(Double(i + 1) / Double(chunks.count))
        }
        return results
    }

    // MARK: - HTTP

    private static func postChunk(
        _ fileData: Data,
        model: TranscriptionModel,
        apiKey: String,
        language: String?
    ) async throws -> DiarizedResponse {
        let boundary = "----minnas-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // Cloud STT of a 15-minute chunk can take a while; default 60s is
        // too tight.
        request.timeoutInterval = 600

        var fields = [
            "model": model.rawValue,
            "response_format": "diarized_json",
            // Required by the diarization models (HTTP 400 without it); "auto"
            // lets the server pick its VAD-based segmentation.
            "chunking_strategy": "auto",
        ]
        if let language { fields["language"] = language }   // ISO code hint to OpenAI
        let body = multipartBody(
            boundary: boundary,
            fields: fields,
            fileField: "file",
            filename: "audio.m4a",
            fileContentType: "audio/mp4",
            fileData: fileData
        )

        let (respData, response) = try await HTTP.session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else {
            throw CloudTranscriberError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: respData, encoding: .utf8) ?? "<non-text body>"
            throw CloudTranscriberError.httpError(status: http.statusCode, body: String(bodyText.prefix(500)))
        }
        do {
            return try JSONDecoder().decode(DiarizedResponse.self, from: respData)
        } catch {
            throw CloudTranscriberError.badResponse
        }
    }

    private static func multipartBody(
        boundary: String,
        fields: [String: String],
        fileField: String,
        filename: String,
        fileContentType: String,
        fileData: Data
    ) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        for (name, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(fileContentType)\r\n\r\n")
        body.append(fileData)
        append("\r\n")
        append("--\(boundary)--\r\n")
        return body
    }

    // MARK: - Response mapping

    private static func makeResult(from response: DiarizedResponse, offset: Double) -> STTResult {
        let language = response.language ?? ""

        if let segments = response.segments, !segments.isEmpty {
            let mapped: [STTSegment] = segments.compactMap { seg in
                let text = (seg.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let start = (seg.start ?? 0) + offset
                let end = (seg.end ?? seg.start ?? 0) + offset
                return STTSegment(start: Float(start), end: Float(end), text: text, speaker: seg.speaker)
            }
            return STTResult(segments: mapped, language: language)
        }

        // Fallback: no segments, just a flat transcript for the chunk.
        let text = (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return STTResult(segments: [], language: language) }
        let start = Float(offset)
        let end = Float(offset + (response.duration ?? 0))
        return STTResult(segments: [STTSegment(start: start, end: end, text: text, speaker: nil)], language: language)
    }

    // Lenient decoder: diarized_json's documented shape is an array of
    // segments with speaker/start/end + text, plus a flat `text`. All
    // optional so a schema drift degrades rather than throws.
    private struct DiarizedResponse: Decodable {
        let text: String?
        let language: String?
        let duration: Double?
        let segments: [DiarizedSegment]?
    }

    private struct DiarizedSegment: Decodable {
        let start: Double?
        let end: Double?
        let text: String?
        let speaker: String?
    }
}
