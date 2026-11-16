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

// Build settings for the vendored WebRTC sources: the defines its own
// build passes on macOS, the two include roots, and -O2 in debug builds
// too (unoptimised, the canceller runs slower than realtime).
let webrtcSettings: (c: [CSetting], cxx: [CXXSetting]) = {
    let defines = [("WEBRTC_POSIX", "1"), ("WEBRTC_MAC", "1"), ("WEBRTC_APM_DEBUG_DUMP", "0")]
    let roots = ["upstream/webrtc-audio-processing/webrtc", "upstream/abseil-cpp"]
    return (
        defines.map { CSetting.define($0.0, to: $0.1) } + roots.map { .headerSearchPath($0) }
            + [.define("NDEBUG", .when(configuration: .release)), .unsafeFlags(["-O2"], .when(configuration: .debug))],
        defines.map { CXXSetting.define($0.0, to: $0.1) } + roots.map { .headerSearchPath($0) }
            + [.define("NDEBUG", .when(configuration: .release)), .unsafeFlags(["-O2"], .when(configuration: .debug))]
    )
}()

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
        // WebRTC's AEC3 echo canceller, vendored (Sources/CWebRTCAEC/upstream,
        // see its README), behind a small C interface. It removes the far
        // side's voice from the mic track of a speakers recording before
        // transcription; the recording itself is never processed.
        .target(
            name: "CWebRTCAEC",
            path: "Sources/CWebRTCAEC",
            exclude: [
                "upstream/MANIFEST",
                "upstream/README.md",
                "upstream/webrtc-audio-processing/COPYING",
                "upstream/webrtc-audio-processing/webrtc/LICENSE",
                "upstream/webrtc-audio-processing/webrtc/PATENTS",
                "upstream/abseil-cpp/LICENSE",
            ],
            cSettings: webrtcSettings.c,
            cxxSettings: webrtcSettings.cxx
        ),
        .executableTarget(
            name: "Minnas",
            dependencies: [
                "CWebRTCAEC",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Minnas"
        ),
        // swift-testing (`import Testing`). `swift test` needs the Xcode
        // toolchain selected: with only the Command Line Tools active the
        // Testing module is not found, which is what scripts/test.sh works
        // around. The executable target is imported @testable; SwiftPM
        // renames its entry point.
        .testTarget(
            name: "MinnasTests",
            dependencies: ["Minnas"],
            path: "Tests/MinnasTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
