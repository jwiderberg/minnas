//
// The seam between RecordingSession (and the capture harnesses) and
// whatever captures the system ("Them") audio. Two engines exist:
//
//   - SystemAudioCapture: ScreenCaptureKit. Needs the Screen Recording
//     grant, and macOS periodically reminds the user the app "is recording
//     your screen".
//   - SystemAudioTapCapture: a Core Audio process tap (macOS 14.2+). Needs
//     only the separate "System Audio Recording" grant and excludes
//     processes natively.
//
// Both write the same CAF format (48 kHz stereo 16-bit interleaved PCM),
// keep the file aligned with wall clock across restarts by padding gaps
// with silence, and expose the same health counters, so transcription,
// AudioDuplication and capture_health don't care which one recorded.
//

import Foundation

/// The `systemAudioEngine` setting (SYSTEM_AUDIO_ENGINE).
enum SystemAudioEngineKind: String, Sendable, CaseIterable {
    /// Core Audio process tap (SystemAudioTapCapture). The default.
    case taps
    /// ScreenCaptureKit (SystemAudioCapture).
    case sck
}

protocol SystemAudioEngine: AnyObject, Sendable {
    func start() async throws
    @MainActor func stop() async
    /// Watchdog hook, called from the recording tick (10 Hz in the app).
    @MainActor func checkHealth()
    /// Peak amplitude since the last call (0.0 — 1.0); resets on read.
    func snapshotPeak() -> Float

    /// Latches true once any non-silent audio arrived.
    var hasSignal: Bool { get }
    /// Last non-silent buffer (auto-stop on sustained silence).
    var lastSignalAt: Date? { get }
    /// Last buffer of any kind (liveness).
    var lastBufferAt: Date? { get }
    var buffersDelivered: UInt64 { get }
    var buffersDropped: UInt64 { get }
    var paddedSecondsTotal: Double { get }
    /// The file writer refused data; a restart can't fix the file.
    var hasWriterFailed: Bool { get }
    var restartCount: Int { get }
    /// When delivery stopped and hasn't come back; nil while healthy.
    var stalledSince: Date? { get }
    /// The engine is delivering buffers but only digital zeros for a long
    /// stretch — the signature of a missing capture grant for engines whose
    /// permission can't be queried (Core Audio taps). Always false for SCK,
    /// which fails loudly on a denial instead.
    var permissionSuspect: Bool { get }

    /// Fired when capture is gone and could not be brought back. Called off
    /// the main actor; the closure hops to whatever actor it needs.
    var onUnexpectedStop: (@Sendable () -> Void)? { get set }

    /// Test hook: kill capture the way the system would, so the watchdog
    /// has to notice and recover (--system-test / --tap-test).
    func simulateStreamDeath() async
}

extension SystemAudioEngine {
    var permissionSuspect: Bool { false }
}

enum SystemAudioEngines {
    /// The engine new recordings use (Config.systemAudioEngine()).
    static func make(outputURL: URL) -> any SystemAudioEngine {
        switch Config.systemAudioEngine() {
        case .sck: return SystemAudioCapture(outputURL: outputURL)
        case .taps: return SystemAudioTapCapture(outputURL: outputURL)
        }
    }
}
