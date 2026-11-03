//
// Engine-agnostic transcription output.
//
// Both the local WhisperKit engine and the cloud engines produce these,
// so the rest of the app (TranscriptBuilder, the re-transcribe menu)
// never depends on a specific STT library's types. Adding a new engine
// means writing a converter into STTResult — nothing downstream changes.
//
// One audio file can yield multiple results: WhisperKit chunks long audio
// internally, and the cloud path splits a file into pieces to stay under
// the provider's upload limit. Each result carries the language detected
// for its span; timestamps are always seconds from the start of the
// original audio file (the cloud path offsets per-chunk timestamps back
// to absolute time before returning).
//

import Foundation

struct STTSegment: Sendable {
    let start: Float    // seconds from the start of the audio file
    let end: Float
    let text: String
    // Diarized speaker id within this stream (e.g. "A", "B"), when the
    // engine separates speakers; nil when it doesn't (WhisperKit). Used to
    // split the system stream into distinct remote participants.
    let speaker: String?
}

struct STTResult: Sendable {
    let segments: [STTSegment]
    let language: String   // ISO code, or "" when the engine reports none
}
