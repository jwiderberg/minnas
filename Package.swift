// swift-tools-version:6.2
//
// Minnas — native Mac menubar app for local-first meeting transcription.
// Floor is macOS 15: everything the app uses (ScreenCaptureKit audio, Core
// Audio process taps, WhisperKit, FluidAudio, EventKit full access) exists
// there, and Xcode 26 / Swift 6.2 — needed to BUILD it — itself runs on
// 15.6+. macOS 14 is excluded on purpose (a Core ML BNNS crash FluidAudio
// documents on 14.x).
//
import PackageDescription

let package = Package(
    name: "minnas",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "minnas", targets: ["Minnas"]),
    ],
    dependencies: [
        // WhisperKit: on-device transcription via Whisper models running
        // on the Apple Neural Engine. Pinned to the 0.x line — versions
        // before 1.0 still revise API shape; lift the upper bound once
        // 1.0 ships and the contract stabilizes.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.10.0"),
        // FluidAudio: on-device speaker diarization (pyannote community-1
        // segmentation + WeSpeaker embeddings + VBx, as Core ML). Splits the
        // "Them" stream into distinct remote voices without the cloud tier.
        // Only the Diarizer trait is pulled in — the package also ships
        // ASR/TTS/VAD engines we don't use.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.18.2", traits: ["Diarizer"]),
    ],
    targets: [
        .executableTarget(
            name: "Minnas",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Minnas"
        ),
        // No XCTest target yet: the pure-logic checks run as CLI harnesses
        // (`minnas --cleanup-test`, `minnas --self-test`), which build with
        // the Command Line Tools alone.
    ]
)
