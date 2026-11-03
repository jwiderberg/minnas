//
// Coordinates the two capture streams and the outbox slot for one
// recording. The session is owned by AppDelegate; only one is alive
// at a time (the menu enforces this).
//

import Foundation

enum RecordingSessionError: Error {
    case alreadyRunning
    case notRunning
}

/// Calendar context attached to a recording when it was started from a
/// meeting prompt or picked from the calendar in the start dialog.
struct CalendarTag: Sendable {
    let eventId: String
    let url: String?
    let attendees: [Attendee]
}

@MainActor
final class RecordingSession {
    private(set) var slot: OutboxSlot?
    private(set) var meta: RecordingMeta?
    private var systemAudio: (any SystemAudioEngine)?
    private var mic: MicCapture?

    // Called when SCStream stops outside of our control (system "Stop
    // Share", revoked Screen Recording permission, etc.). The handler
    // is expected to call stop() to flush the mic + write meta.json.
    var onUnexpectedStop: (@MainActor () -> Void)?

    var isRunning: Bool { slot != nil }

    /// Live mic peak amplitude since last query (0.0 — 1.0). Used by the
    /// menubar level meter to confirm input is actually flowing. Returns
    /// 0 when no recording is in progress.
    func micPeak() -> Float {
        mic?.snapshotPeak() ?? 0
    }

    /// Live system-audio peak amplitude since last query (0.0 — 1.0).
    /// Same UX purpose as micPeak — confirms ScreenCaptureKit is
    /// actually delivering audio samples.
    func systemPeak() -> Float {
        systemAudio?.snapshotPeak() ?? 0
    }

    /// Whether each stream has captured any real (non-silent) audio so far.
    /// The pre-flight check warns when one stays false — the broken-capture
    /// signature (a stream of pure digital silence).
    func micHasSignal() -> Bool { mic?.hasSignal ?? false }

    /// Watchdog hook from the recording tick: re-attaches the mic when the
    /// engine stopped on a route change (AirPods in, output switched) and
    /// isn't delivering buffers. See MicCapture.checkHealth.
    func micHealthCheck() { mic?.checkHealth() }

    /// When the mic stopped delivering audio and hasn't come back yet; nil
    /// while healthy. Surfaced in the menubar + a one-time alert.
    func micStalledSince() -> Date? { mic?.stalledSince }
    func micRestartCount() -> Int { mic?.restartCount ?? 0 }
    /// Last moment the mic delivered a non-zero sample (digital-silence alert).
    func micLastSignalAt() -> Date? { mic?.lastSignalAt }

    /// Same watchdog for the system stream: re-creates the SCStream when it
    /// stops delivering (the OS stopped it, a display change, …).
    func systemHealthCheck() { systemAudio?.checkHealth() }
    func systemStalledSince() -> Date? { systemAudio?.stalledSince }
    /// The system-audio file writer failed; a stream restart can't fix it.
    func systemWriterFailed() -> Bool { systemAudio?.hasWriterFailed ?? false }
    /// Long run of pure digital zeros with buffers flowing — on the tap
    /// engine, the likely sign of a missing System Audio Recording grant
    /// (or simply nothing playing). Always false on ScreenCaptureKit.
    func systemPermissionSuspect() -> Bool { systemAudio?.permissionSuspect ?? false }
    /// Mic file write errors so far (disk full, format trouble).
    func micWriteErrors() -> UInt64 { mic?.writeErrorCount ?? 0 }

    private func captureHealth() -> CaptureHealth? {
        guard let mic, let systemAudio else { return nil }
        return CaptureHealth(
            mic_restarts: mic.restartCount,
            mic_padded_seconds: mic.paddedSecondsTotal,
            mic_seconds_captured: mic.secondsCaptured,
            mic_had_signal: mic.hasSignal,
            system_restarts: systemAudio.restartCount,
            system_padded_seconds: systemAudio.paddedSecondsTotal,
            system_buffers: Int(systemAudio.buffersDelivered),
            system_had_signal: systemAudio.hasSignal,
            system_writer_failed: systemAudio.hasWriterFailed
        )
    }
    func systemHasSignal() -> Bool { systemAudio?.hasSignal ?? false }

    /// Most recent non-silent moment across either stream — nil if neither
    /// has had signal yet. Drives the sustained-silence auto-stop.
    func lastActivityAt() -> Date? {
        switch (mic?.lastSignalAt, systemAudio?.lastSignalAt) {
        case let (m?, s?): return max(m, s)
        case let (m?, nil): return m
        case let (nil, s?): return s
        case (nil, nil): return nil
        }
    }

    func start(title: String, calendar: CalendarTag? = nil) async throws {
        guard !isRunning else { throw RecordingSessionError.alreadyRunning }

        // Calendar titles are whatever the organiser typed; bound them here
        // so meta, the menu and the transcript all carry the same one line.
        let title = Outbox.normalizeTitle(title)
        let startedAt = Date()
        let slot = try Outbox.makeSlot(title: title, startedAt: startedAt)
        self.slot = slot
        var meta = RecordingMeta(
            title: title,
            started_at: startedAt,
            device: AppInfo.device,
            client_version: AppInfo.version
        )
        if let calendar {
            meta.calendar_event_id = calendar.eventId
            meta.calendar_event_url = calendar.url
            meta.attendees = calendar.attendees
        }
        self.meta = meta
        // Write meta.json NOW (ended_at nil), not only at stop: if the app
        // dies mid-recording, the launch-time recovery finds the title and
        // calendar tag next to the capture files and finishes the slot.
        try Outbox.writeMeta(meta, to: slot.metaURL)

        let systemAudio = SystemAudioEngines.make(outputURL: slot.systemAudioURL)
        let mic = MicCapture(outputURL: slot.micAudioURL)
        systemAudio.onUnexpectedStop = { [weak self] in
            Task { @MainActor [weak self] in
                self?.onUnexpectedStop?()
            }
        }
        self.systemAudio = systemAudio
        self.mic = mic

        do {
            // Sequential start. Concurrent start via async let would be
            // marginally faster but the two captures hold non-Sendable
            // AVFoundation state, and the OS serializes TCC prompts
            // anyway. The cost is two prompt round-trips first launch.
            try await mic.start()
            try await systemAudio.start()
        } catch {
            await cleanupAfterFailure()
            throw error
        }
    }

    func stop() async throws -> OutboxSlot {
        guard let slot, var meta else { throw RecordingSessionError.notRunning }

        if let systemAudio { await systemAudio.stop() }
        if let mic { mic.stop() }
        meta.capture_health = captureHealth()

        // Clear session state regardless of whether writeMeta succeeds — the
        // captures are already torn down, so leaving state set would wedge
        // isRunning at true until relaunch. A writeMeta failure is surfaced,
        // but the session is no longer "running" either way.
        self.systemAudio = nil
        self.mic = nil
        self.slot = nil
        self.meta = nil

        // Only the fields stop() owns are written, under the meta lock: the
        // dispatcher or a re-transcribe may have changed delivery state on
        // disk while the recording ran, and a whole-object overwrite from the
        // in-memory copy would silently drop that.
        let endedAt = Date()
        let health = meta.capture_health
        try Outbox.mutateMeta(slot, ifUnreadable: meta) { onDisk in
            onDisk.ended_at = endedAt
            onDisk.capture_health = health
        }
        return slot
    }

    private func cleanupAfterFailure() async {
        if let systemAudio { await systemAudio.stop() }
        if let mic { mic.stop() }
        // Leave the outbox dir on disk — useful for debugging which
        // permission was denied. A future cleanup task can reap empty
        // dirs older than N hours.
        systemAudio = nil
        mic = nil
        slot = nil
        meta = nil
    }
}
