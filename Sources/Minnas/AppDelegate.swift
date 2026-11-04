//
// Menubar UI for Minnas.
//
// NSStatusItem with three states:
//   Idle         → mic icon, no label
//   Recording    → red circle + elapsed mm:ss
//   Transcribing → waveform icon, menu shows "Transcribing: <title>…"
//
// State is held by AppDelegate (recording in RecordingSession, transcription
// status in `transcribingTitle`). Only one transcription runs at a time —
// the Transcriber actor serializes calls, but we also keep the menu
// pointing at the most recent in-flight job.
//

import AppKit
import Foundation
import os.log

private let appLog = Logger(subsystem: "com.jwiderberg.minnas", category: "App")
private let calendarLog = Logger(subsystem: "com.jwiderberg.minnas", category: "Calendar")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let session = RecordingSession()
    private var recordingTimer: Timer?

    // Calendar prompt loop. Polls the calendar (EventKit) for soon-to-start
    // meetings and offers to record them. promptedEventIDs keeps us from re-prompting
    // the same event every poll.
    private var calendarTimer: Timer?
    private var promptedEventIDs: Set<String> = []

    // Guards the sustained-silence auto-stop from re-firing during the
    // async stop. Reset when a new recording starts.
    private var isAutoStopping = false

    // One "microphone stopped" alert per recording. The mic restarts itself
    // on route changes; the alert fires only if it stays dead for 10 s.
    private var micStallAlerted = false
    // One "mic is delivering digital silence" alert per recording: buffers
    // keep arriving but every sample is zero for 2 min after the mic had
    // signal — the dead-but-alive signature (Continuity mic on a call, a
    // VPIO-over-Bluetooth input). A quiet room still has a noise floor.
    private var micZeroAlerted = false
    private static let micZeroAlertSeconds: TimeInterval = 120
    private var systemStallAlerted = false
    private var writerFailureAlerted = false

    // Guards against two stop paths (manual Stop + external SCStream stop)
    // both calling session.stop() on the same recording, which would
    // double-transcribe. Set on MainActor before the stop's first await.
    private var isStopping = false

    // Cached count of recordings with a pending delivery, for the menu
    // badge. The menu is rebuilt every second during recording
    // (refreshStatusItem), so scanning the outbox from disk each time is
    // wasteful. Invalidated (→ nil) whenever the pending set changes: a new
    // transcript is written, or a sink delivers. nil = recompute.
    private var cachedPendingDeliveryCount: Int?

    // Auto-retry timer for pending deliveries. 5 min cadence;
    // SinkDispatcher + RetrySchedule decide which sinks are due based on
    // each one's persisted attempt count + last-attempt timestamp.
    private var deliveryRetryTimer: Timer?
    private static let deliveryRetryTickInterval: TimeInterval = 5 * 60

    // Non-nil while a transcription is running. Drives the "Transcribing"
    // menubar state. Transcription never blocks recording: back-to-back
    // meetings mean the next recording starts while the previous one is
    // still on the ANE. Jobs are serialized through `transcribeChain`
    // (one at a time, in order) and `queuedTranscriptions` counts the
    // ones waiting behind the running job, for the menu header.
    private var transcribingTitle: String?
    private var isTranscribing: Bool { transcribingTitle != nil }
    private var transcribeChain: Task<Void, Never>?
    private var queuedTranscriptions = 0

    // Live transcription progress (0–100). Updated from the Transcriber's
    // progress callback; shown in the "Transcribing…" menu header and the
    // menubar button. We hold a weak ref to the header item so progress
    // ticks update it in place instead of rebuilding the whole menu.
    private var transcribeProgressPct: Int = 0
    private weak var transcribingHeaderItem: NSMenuItem?

    // The Voice Memos picker, retained while open (a window controller
    // with no owner is deallocated and its window vanishes).
    private var voiceMemoImportWindow: VoiceMemoImportWindowController?
    private var settingsWindow: SettingsWindowController?
    private var onboardingWindow: OnboardingWindowController?

    // fd holding the single-instance flock on outbox/.lock. Never closed:
    // the kernel drops the lock when the process exits, however it exits.
    private var instanceLockFD: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second instance would "recover" the first one's live recording
        // (no ended_at, raw .caf files), transcribe it, and compressAudio
        // would unlink the .caf the first instance is still writing. So the
        // lock comes before anything touches the outbox.
        // Fails closed: if the lock cannot even be created, running unlocked
        // would reintroduce the exact loss the lock prevents.
        if case .acquired = acquireInstanceLock() {} else {
            let alert = NSAlert()
            switch acquireInstanceLockResult {
            case .failed(let reason):
                alert.messageText = "Minnas can't lock its outbox folder."
                alert.informativeText = reason
            default:
                alert.messageText = "Minnas is already running."
            }
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.idleIcon()
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.toolTip = Self.appName
        }
        item.menu = makeMenu()
        statusItem = item
        session.onUnexpectedStop = { [weak self] in
            self?.handleExternalStop()
        }
        // First run: setup comes before the calendar poll, so the first
        // thing a new user sees isn't a record prompt for a source they
        // haven't chosen yet. The poll starts from Finish (the window's
        // close handler), never from launch or a source change before then.
        if Settings.shared.onboardingCompleted {
            startCalendarPollingIfConfigured()
        } else {
            showOnboarding()
        }
        NotificationCenter.default.addObserver(forName: .calendarSourceDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartCalendarPolling() }
        }
        startDeliveryRetryTimer()
        // Recovery before pruning: an interrupted recording has no
        // transcript yet, and pruning must see it as the finished slot it
        // is about to become, not as stale audio.
        recoverInterruptedRecordings()
        Outbox.pruneOldRecordings(keepDays: Config.recordingsKeepDays())
    }

    /// Takes an exclusive, non-blocking flock on outbox/.lock. .heldByOther
    /// when another instance holds it; .failed when the directory or file
    /// can't be created or locked. Both stop the launch: an unlocked instance
    /// could still destroy a live recording, and an outbox it can't write
    /// couldn't hold a recording anyway.
    enum InstanceLockResult { case acquired, heldByOther, failed(String) }
    private var acquireInstanceLockResult: InstanceLockResult = .failed("not attempted")

    private func acquireInstanceLock() -> InstanceLockResult {
        let result = tryAcquireInstanceLock()
        acquireInstanceLockResult = result
        return result
    }

    private func tryAcquireInstanceLock() -> InstanceLockResult {
        do {
            try FileManager.default.createDirectory(at: Outbox.rootURL, withIntermediateDirectories: true)
        } catch {
            appLog.error("instance lock: couldn't create outbox: \(error.localizedDescription, privacy: .public)")
            return .failed("Couldn't create \(Outbox.rootURL.path): \(error.localizedDescription)")
        }
        let path = Outbox.rootURL.appendingPathComponent(".lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            let err = errno
            appLog.error("instance lock: open failed (errno \(err, privacy: .public))")
            return .failed("Couldn't open \(path) (errno \(err)).")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let err = errno
            close(fd)
            if err == EWOULDBLOCK {
                appLog.notice("instance lock held by another Minnas; exiting")
                return .heldByOther
            }
            appLog.error("instance lock: flock failed (errno \(err, privacy: .public))")
            return .failed("flock on \(path) failed (errno \(err)).")
        }
        instanceLockFD = fd
        appLog.notice("instance lock acquired (pid \(getpid(), privacy: .public))")
        return .acquired
    }

    /// A recording the app died in the middle of (crash, force-quit, power
    /// loss) leaves raw .caf captures and a meta.json with no ended_at. The
    /// partial CAFs are readable as-is, so finish the slot: stamp ended_at
    /// from the capture files' modification time and transcribe + deliver
    /// it like any other recording. Nothing recorded is ever left to rot.
    private func recoverInterruptedRecordings() {
        let fm = FileManager.default
        for slot in Outbox.listSlots() {
            guard let meta = try? Outbox.readMeta(from: slot.metaURL), meta.ended_at == nil,
                  !meta.isSingleStream else { continue }
            let captures = [slot.micAudioURL, slot.systemAudioURL].filter { fm.fileExists(atPath: $0.path) }
            guard !captures.isEmpty else { continue }
            let endedAt = captures.compactMap {
                (try? fm.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
            }.max() ?? Date()
            // A capture written in the last minute is probably still live
            // (another process recording into it despite the lock): leave it.
            let idle = Date().timeIntervalSince(endedAt)
            if idle < 60 {
                appLog.notice("recovery: skipping \(slot.slug, privacy: .public), capture modified \(Int(idle), privacy: .public)s ago")
                continue
            }
            do {
                try Outbox.mutateMeta(slot) { $0.ended_at = endedAt }
            } catch {
                appLog.error("recovery: couldn't write meta for \(slot.slug, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            let minutes = Int(endedAt.timeIntervalSince(meta.started_at) / 60)
            appLog.error("recovered interrupted recording \(slot.slug, privacy: .public) (\(minutes, privacy: .public) min); transcribing")
            let alert = NSAlert()
            alert.messageText = "Recovered an interrupted recording"
            alert.informativeText = "\"\(meta.title)\" (\(minutes) min) was still recording when the app last quit. Its audio was saved; transcribing it now."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            startTranscription(slot: slot, title: meta.title)
        }
    }

    // MARK: Calendar prompt loop

    /// The source the poll reads: the user's choice.
    private var activeCalendarSource: CalendarSource {
        Settings.shared.calendarSource
    }

    private func restartCalendarPolling() {
        calendarTimer?.invalidate()
        calendarTimer = nil
        startCalendarPollingIfConfigured()
    }

    private func startCalendarPollingIfConfigured() {
        // Single choke point for every start/restart (launch, source change
        // while onboarding is open, the window closing): until setup is
        // finished the poll must not run, or a half-configured source would
        // prompt to record before the user has chosen anything.
        guard Settings.shared.onboardingCompleted else { return }
        guard activeCalendarSource != .off, calendarTimer == nil else { return }
        // Poll a touch more often than the lead time so a meeting can't slip
        // through between ticks.
        pollCalendar()
        calendarTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollCalendar() }
        }
    }

    private func pollCalendar() {
        switch activeCalendarSource {
        case .eventkit: pollEventKitCalendar()
        case .off: return
        }
    }

    private func pollEventKitCalendar() {
        // Not granted (yet): nothing to read, and nothing to nag about —
        // Settings › Calendar shows the status. The timer keeps ticking so a
        // grant made while the app runs is picked up within a minute.
        guard EventKitCalendar.isAuthorized else { return }
        Task { @MainActor in
            let events: [UpcomingEvent]
            do {
                events = try await EventKitCalendar.upcoming(withinMinutes: 5)
            } catch {
                calendarLog.error("eventkit calendar poll failed: \(String(describing: error), privacy: .public)")
                return
            }
            self.offerToRecord(from: events)
        }
    }

    /// Prompts for the first not-yet-seen recordable event, whichever
    /// source the events came from.
    private func offerToRecord(from events: [UpcomingEvent]) {
        // Don't interrupt an in-progress recording. A running
        // transcription is fine — the new recording queues behind it.
        guard !session.isRunning else { return }
        // Drop remembered IDs no longer in the window so the set can't
        // grow without bound over a multi-day run. An event that has
        // started drops out of this future-only window and won't return,
        // so pruning it can't cause a re-prompt.
        promptedEventIDs.formIntersection(events.compactMap(\.calendar_event_id))
        for event in events {
            guard let id = event.calendar_event_id, !promptedEventIDs.contains(id) else { continue }
            // Only auto-prompt for events with an online meeting link
            // (a conferencing tag). Skips in-person meetings, lunches,
            // link-less 1:1s, reminders, birthdays — see
            // isRecordableMeeting. Mark seen either way so it isn't
            // re-evaluated every tick.
            promptedEventIDs.insert(id)
            guard Self.isRecordableMeeting(event) else { continue }
            promptToRecord(event)
            break   // one prompt per tick
        }
    }

    private func promptToRecord(_ event: UpcomingEvent) {
        NSApp.activate(ignoringOtherApps: true)
        let title = event.title ?? "Meeting"
        let mins = max(0, Int(event.start.timeIntervalSinceNow / 60))
        let alert = NSAlert()
        alert.messageText = "\(title) starts in \(mins) min"
        alert.informativeText = "Start recording this meeting?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Start Recording")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard !session.isRunning else { return }
        let tag = event.calendar_event_id.map {
            CalendarTag(eventId: $0, url: event.url, attendees: event.attendees ?? [])
        }
        // Route through startSession (not session.start directly) so the
        // calendar-prompt flow gets the same isAutoStopping reset + preflight
        // silence check as a manual start.
        Task { @MainActor in await startSession(title: title, tag: tag) }
    }

    private func handleExternalStop() {
        // SCStream stopped outside our control (system "Stop Share" or
        // revoked permission). Flush mic, write meta.json, alert the
        // user, then transcribe the partial anyway — they'll at least
        // get something for what was captured.
        guard session.isRunning else { return }
        Task { @MainActor in
            guard !isStopping else { return }
            isStopping = true
            defer { isStopping = false }
            let title = session.meta?.title ?? "untitled"
            do {
                let slot = try await session.stop()
                refreshStatusItem()
                let alert = NSAlert()
                alert.messageText = "Recording stopped: system audio is gone."
                alert.informativeText = "The system-audio stream stopped and could not be restarted in 20 attempts — most likely the \(Self.systemAudioPermissionName) permission was revoked. Transcribing what was captured. Re-grant the permission and start a new recording."
                alert.alertStyle = .critical
                alert.addButton(withTitle: "OK")
                alert.runModal()
                startTranscription(slot: slot, title: title)
            } catch {
                refreshStatusItem()
                presentError("Couldn't clean up after external stop.", error: error)
            }
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        // Recording stays available during setup (it is the core feature
        // and has its own prompts); this is the way back into the window
        // after closing it early.
        if !Settings.shared.onboardingCompleted {
            menu.addItem(NSMenuItem(title: "Finish setup…", action: #selector(finishSetup), keyEquivalent: ""))
            menu.addItem(NSMenuItem.separator())
        }
        if session.isRunning {
            let title = session.meta?.title ?? "recording"
            let header = NSMenuItem(title: "Recording: \(title)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(
                NSMenuItem(
                    title: "Stop Recording",
                    action: #selector(stopRecording),
                    keyEquivalent: "s"
                )
            )
        } else {
            menu.addItem(
                NSMenuItem(
                    title: "Start Recording…",
                    action: #selector(startRecording),
                    keyEquivalent: "r"
                )
            )
            if let recordings = makeRecordingsMenuItem() {
                menu.addItem(recordings)
            }
            menu.addItem(
                NSMenuItem(
                    title: "Import Voice Memos…",
                    action: #selector(importVoiceMemos),
                    keyEquivalent: "i"
                )
            )
            menu.addItem(
                NSMenuItem(
                    title: "Transcribe Audio File…",
                    action: #selector(importAudioFiles),
                    keyEquivalent: "t"
                )
            )
            menu.addItem(
                NSMenuItem(
                    title: "Settings…",
                    action: #selector(showSettings),
                    keyEquivalent: ","
                )
            )
            menu.addItem(makeLanguageMenuItem())
            let pending = pendingDeliveryCount()
            if pending > 0 {
                menu.addItem(
                    NSMenuItem(
                        title: "Retry \(pending) Pending Deliver\(pending == 1 ? "y" : "ies")",
                        action: #selector(retryPendingDeliveries),
                        keyEquivalent: "u"
                    )
                )
            }
        }
        // Transcription runs alongside either state above (a recording can
        // start while the previous meeting is still being transcribed), so
        // its header is appended rather than being a state of its own.
        if let transcribingTitle {
            menu.addItem(NSMenuItem.separator())
            let header = NSMenuItem(title: transcribingHeaderTitle(transcribingTitle), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            transcribingHeaderItem = header
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(
                title: "Show Outbox in Finder",
                action: #selector(showOutbox),
                keyEquivalent: "o"
            )
        )
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit Minnas",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        for item in menu.items where item.action != nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        return menu
    }

    private func refreshStatusItem() {
        statusItem.menu = makeMenu()
        guard let button = statusItem.button else { return }

        if session.isRunning, let startedAt = session.meta?.started_at {
            let image = Self.recordingIcon()
            image?.isTemplate = false
            button.image = image
            let micBar = Self.levelBar(for: session.micPeak())
            let sysBar = Self.levelBar(for: session.systemPeak())
            button.title = " \(Self.elapsedString(since: startedAt)) \(micBar) \(sysBar)"
            startRecordingTimer()
        } else if isTranscribing {
            let image = Self.transcribingIcon()
            image?.isTemplate = true
            button.image = image
            button.title = transcribeProgressPct > 0 ? " \(transcribeProgressPct)%" : ""
            stopRecordingTimer()
        } else {
            let image = Self.idleIcon()
            image?.isTemplate = true
            button.image = image
            button.title = ""
            stopRecordingTimer()
        }
    }

    private func startRecordingTimer() {
        guard recordingTimer == nil else { return }
        // 10 Hz tick: drives both the elapsed mm:ss (only changes once a
        // second visually) and the mic level meter, which needs the
        // higher refresh rate to feel responsive. The closure is
        // non-isolated; hop to MainActor before touching UI.
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickRecordingIndicator()
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    private func tickRecordingIndicator() {
        guard session.isRunning, let startedAt = session.meta?.started_at else {
            stopRecordingTimer()
            return
        }
        // Route changes (AirPods connecting, default output switching) stop
        // the mic engine; this re-attaches it if the notification path
        // didn't. Cheap at 10 Hz.
        session.micHealthCheck()
        session.systemHealthCheck()
        let stalled = session.micStalledSince()
        let sysStalled = session.systemStalledSince()
        let micBar = stalled == nil ? Self.levelBar(for: session.micPeak()) : "✗"
        let sysBar = sysStalled == nil ? Self.levelBar(for: session.systemPeak()) : "✗"
        // Format: " 0:42 ▇ ▁" — mic level, then space, then system level.
        statusItem.button?.title = " \(Self.elapsedString(since: startedAt)) \(micBar) \(sysBar)"
        if let stalled, !micStallAlerted, Date().timeIntervalSince(stalled) > 10 {
            micStallAlerted = true
            alertMicStalled()
        }
        if let sysStalled, !systemStallAlerted, Date().timeIntervalSince(sysStalled) > 10 {
            systemStallAlerted = true
            alertStreamStalled(stream: "system audio")
        }
        if !writerFailureAlerted, session.systemWriterFailed() || session.micWriteErrors() > 0 {
            writerFailureAlerted = true
            alertWriterFailure(stream: session.systemWriterFailed() ? "system audio" : "microphone")
        }
        if stalled == nil, !micZeroAlerted, session.micHasSignal(),
           let lastSignal = session.micLastSignalAt(),
           Date().timeIntervalSince(lastSignal) > Self.micZeroAlertSeconds {
            micZeroAlerted = true
            alertMicDigitalSilence(since: lastSignal)
        }

        // Auto-stop after sustained silence on both streams (meeting over /
        // walked away). Measured from the last activity, or start if none yet.
        let silenceMinutes = Config.autoStopSilenceMinutes()
        if silenceMinutes > 0, !isAutoStopping {
            let lastActive = session.lastActivityAt() ?? startedAt
            if Date().timeIntervalSince(lastActive) > Double(silenceMinutes) * 60 {
                autoStopForSilence(minutes: silenceMinutes)
            }
        }
    }

    /// The mic engine died (usually an audio route change) and the restart
    /// loop hasn't brought it back in 10 s. Say so loudly — a recording
    /// that silently loses the user's side is the worst failure this app
    /// has.
    private func alertMicStalled() { alertStreamStalled(stream: "microphone") }

    private func alertStreamStalled(stream: String) {
        let device = AudioRoute.defaultInputDeviceName() ?? "unknown"
        let other = stream == "microphone" ? "System audio is" : "The microphone is"
        let hint = stream == "microphone"
            ? "The input is \"\(device)\". Check System Settings → Sound → Input,"
            : "Check System Settings → Privacy & Security → \(Self.systemAudioPermissionName),"
        let alert = NSAlert()
        alert.messageText = "\(stream.capitalized) stopped"
        alert.informativeText = "The \(stream) stream stopped delivering audio and hasn't come back after 10 s. The recorder keeps retrying every second; \(other) still being captured. \(hint) or stop and start a new recording."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Keep Recording")
        alert.addButton(withTitle: "Stop")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            stopRecording()
        }
    }

    /// The mic engine is running and delivering buffers, but every sample
    /// has been exactly zero for a while after it had real signal. Real mics
    /// have a noise floor even in a silent room; a flat zero stream means
    /// the device behind the input is not actually capturing.
    /// A capture file refused data (disk full, writer error). Restarting the
    /// stream can't fix the file; the user has to stop and start again.
    private func alertWriterFailure(stream: String) {
        let alert = NSAlert()
        alert.messageText = "Recording file error"
        alert.informativeText = "The \(stream) capture file is refusing data (disk full, or a writer error — see Console). Audio from now on is NOT being saved for that stream. Stop this recording and start a new one; check free disk space first."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Keep Going")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            stopRecording()
        }
    }

    private func alertMicDigitalSilence(since: Date) {
        let device = AudioRoute.defaultInputDeviceName() ?? "unknown"
        let minutes = Int(Date().timeIntervalSince(since) / 60)
        let alert = NSAlert()
        alert.messageText = "Microphone has gone silent"
        alert.informativeText = "The mic input \"\(device)\" has delivered pure digital silence for \(minutes) min — not a quiet room, a dead input. Your side of the meeting is not being captured. Check System Settings → Sound → Input (switch to the built-in mic if in doubt); the recorder picks the change up automatically. System audio is still being captured."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Keep Recording")
        alert.addButton(withTitle: "Stop")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            stopRecording()
        }
    }

    private func autoStopForSilence(minutes: Int) {
        isAutoStopping = true
        appLog.info("auto-stopping after \(minutes, privacy: .public) min of silence on both streams")
        stopRecording()
    }

    private static func elapsedString(since startedAt: Date) -> String {
        let elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
        let mm = elapsed / 60
        let ss = elapsed % 60
        return String(format: "%d:%02d", mm, ss)
    }

    /// Maps a 0.0–1.0 peak amplitude to a single Unicode block character
    /// covering ~five visually-distinct levels. The thresholds are log-
    /// flavored — typical voice peaks around 0.05–0.3, so we want
    /// granularity in that band rather than at the extremes.
    private static func levelBar(for peak: Float) -> String {
        if peak < 0.002 { return "▁" }      // basically silent
        if peak < 0.02  { return "▂" }      // very quiet
        if peak < 0.08  { return "▄" }      // soft voice
        if peak < 0.25  { return "▆" }      // normal voice
        return "█"                           // loud
    }

    @objc private func startRecording() {
        Task { @MainActor in
            guard !session.isRunning else { return }
            // Tag the recording with a calendar event (title, attendees).
            // Best-effort: no calendar / fetch fails → title-only.
            let events = await fetchEventsForPicker()
            // Silent auto-tag: when exactly one event is happening now (or
            // imminent), start immediately — named + tagged from it, no
            // prompt.
            if let current = Self.singleActiveEvent(events) {
                calendarLog.info("auto-tagging recording with event \(current.calendar_event_id ?? "?", privacy: .public)")
                await startSession(title: current.title ?? "Meeting", tag: Self.tag(for: current))
                return
            }
            // 0 or 2+ candidate events → let the user pick.
            guard let choice = promptForStart(events: events) else { return }
            await startSession(title: choice.title, tag: choice.tag)
        }
    }

    private func startSession(title: String, tag: CalendarTag?) async {
        // If the default mic input looks like a device that tends to deliver
        // silence (an iPhone Continuity mic while you're on a call, a virtual
        // device), warn before committing the whole recording — the usual
        // cause of a fully-silent capture.
        guard confirmMicInputOrCancel() else { return }
        do {
            try await session.start(title: title, calendar: tag)
            isAutoStopping = false
            micStallAlerted = false
            micZeroAlerted = false
            systemStallAlerted = false
            writerFailureAlerted = false
            refreshStatusItem()
            schedulePreflightCheck()
        } catch {
            presentError("Couldn't start recording.", error: error)
        }
    }

    /// Returns true to proceed with recording. When the default input looks
    /// risky, shows a warning naming the device; false means the user chose to
    /// cancel and fix the input first.
    private func confirmMicInputOrCancel() -> Bool {
        guard AudioRoute.defaultInputLooksRisky(),
              let device = AudioRoute.defaultInputDeviceName() else { return true }
        let alert = NSAlert()
        alert.messageText = "Mic input is \"\(device)\""
        alert.informativeText = "That's likely to capture silence — an iPhone Continuity mic is busy while you're on a call, and virtual devices route nothing to the recorder. Switch the input to your built-in mic in System Settings → Sound, then record. Record anyway?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Record Anyway")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// A few seconds into a recording, warn if a stream has captured only
    /// silence — the broken-capture signature (e.g. the 36-min meeting whose
    /// system stream was 396 MB of zeros). Catches it in seconds instead of
    /// after the meeting; recording keeps going unless the user stops.
    private func schedulePreflightCheck() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
            guard session.isRunning else { return }
            var silent: [String] = []
            let micSilent = !session.micHasSignal()
            if micSilent { silent.append("microphone") }
            if !session.systemHasSignal() { silent.append("system audio") }
            guard !silent.isEmpty else { return }

            let which = silent.joined(separator: " and ")
            let verb = silent.count > 1 ? "streams have" : "stream has"
            // When the MIC is the silent one, name the input device — the
            // usual cause is the default input having switched to a device
            // that delivers silence (an iPhone Continuity mic while you're on
            // a call, a virtual device), which the user can fix in Sound prefs.
            var micHint = ""
            if micSilent, let device = AudioRoute.defaultInputDeviceName() {
                micHint = " The mic input is \"\(device)\""
                    + (AudioRoute.defaultInputLooksRisky()
                       ? " — that's likely capturing silence; switch the input to your built-in mic in System Settings → Sound and re-record."
                       : ".")
            }
            let alert = NSAlert()
            alert.messageText = "No \(which) detected"
            alert.informativeText = "15s in, the \(which) \(verb) captured only silence. Recording continues, but check the \(Self.systemAudioPermissionName) permission (for system audio) and that audio is playing / your mic is live — a stream that stays silent won't appear in the transcript.\(micHint)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Keep Recording")
            alert.addButton(withTitle: "Stop")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn {
                stopRecording()
            }
        }
    }

    private static func tag(for event: UpcomingEvent) -> CalendarTag? {
        guard let id = event.calendar_event_id else { return nil }
        return CalendarTag(eventId: id, url: event.url, attendees: event.attendees ?? [])
    }

    /// Whether an upcoming event should auto-prompt to record. The rule is
    /// simply: does it have an online meeting link (a `conferencing` tag of
    /// zoom/meet/teams)?
    ///
    /// EventKitCalendar derives `conferencing` by sniffing the event's URL,
    /// location and notes for a meeting link. Everything with no detected
    /// link is left alone — in-person meetings, lunches, link-less 1:1s,
    /// reminders, birthdays, focus-time. Record those by hand from the menu
    /// if you ever want to.
    private static func isRecordableMeeting(_ event: UpcomingEvent) -> Bool {
        event.conferencing?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// The single event happening now (or starting within ~5 min and not
    /// yet ended). Returns nil when zero or multiple qualify, so the caller
    /// falls back to the picker rather than guess.
    private static func singleActiveEvent(_ events: [UpcomingEvent]) -> UpcomingEvent? {
        let now = Date()
        let active = events.filter { event in
            event.start <= now.addingTimeInterval(5 * 60) && (event.end.map { $0 > now } ?? true)
        }
        return active.count == 1 ? active.first : nil
    }

    private func fetchEventsForPicker() async -> [UpcomingEvent] {
        switch activeCalendarSource {
        case .off: return []
        case .eventkit:
            guard EventKitCalendar.isAuthorized else { return [] }
            do {
                // Look back 60 min too, so a meeting already in progress when
                // you hit record shows up (and silent auto-tag can match it).
                return try await EventKitCalendar.upcoming(withinMinutes: 30, lookbackMinutes: 60)
            } catch {
                calendarLog.error("manual-start eventkit fetch failed: \(String(describing: error), privacy: .public)")
                return []
            }
        }
    }

    @objc private func stopRecording() {
        Task { @MainActor in
            guard !isStopping else { return }
            isStopping = true
            defer { isStopping = false }
            // Capture title before stop() clears session.meta.
            let title = session.meta?.title ?? "untitled"
            do {
                let slot = try await session.stop()
                refreshStatusItem()
                startTranscription(slot: slot, title: title)
            } catch {
                presentError("Couldn't stop recording cleanly.", error: error)
                refreshStatusItem()
            }
        }
    }

    private static func transcribingLabel(_ title: String, pct: Int) -> String {
        "Transcribing: \(title) (\(pct)%)"
    }

    private func transcribingHeaderTitle(_ title: String) -> String {
        let base = Self.transcribingLabel(title, pct: transcribeProgressPct)
        return queuedTranscriptions > 0 ? "\(base) · \(queuedTranscriptions) queued" : base
    }

    /// Updates live transcription progress. Only does work when the integer
    /// percentage changes, so the frequent callback doesn't thrash the UI;
    /// updates the menu header in place + the menubar button.
    private func setTranscribeProgress(_ fraction: Double) {
        let pct = max(0, min(100, Int(fraction * 100)))
        guard pct != transcribeProgressPct, let title = transcribingTitle else { return }
        transcribeProgressPct = pct
        transcribingHeaderItem?.title = transcribingHeaderTitle(title)
        // The menubar shows the recording timer while a recording is live;
        // progress is only in the menu header then.
        if !session.isRunning { statusItem?.button?.title = " \(pct)%" }
    }

    /// `model` nil = the Default model setting (Config.defaultModel, which
    /// falls back to the local default while cloud transcription is off).
    private func startTranscription(
        slot: OutboxSlot,
        title: String,
        model: TranscriptionModel? = nil
    ) {
        Task { @MainActor in
            await transcribeAndDeliver(slot: slot, title: title, model: model)
        }
    }

    /// Transcribe → open transcript → deliver → compress. Jobs are queued
    /// behind whatever is already transcribing (one at a time, in order)
    /// and this returns when THIS job is done, so callers that process
    /// several recordings (the Voice Memos import) can await each.
    private func transcribeAndDeliver(
        slot: OutboxSlot,
        title: String,
        model: TranscriptionModel? = nil
    ) async {
        // Resolved when the job is queued, so a settings change while it
        // waits doesn't switch engines under it.
        let model = model ?? Config.defaultModel()
        let previous = transcribeChain
        if previous != nil {
            queuedTranscriptions += 1
            refreshStatusItem()
        }
        let job = Task { @MainActor in
            await previous?.value
            if previous != nil { queuedTranscriptions -= 1 }
            await runTranscription(slot: slot, title: title, model: model)
        }
        transcribeChain = job
        await job.value
        if transcribeChain == job { transcribeChain = nil }
    }

    /// One job: drives the "Transcribing" menubar state for its duration.
    /// Only ever called from the chain, so it never overlaps another job.
    private func runTranscription(
        slot: OutboxSlot,
        title: String,
        model: TranscriptionModel
    ) async {
        transcribingTitle = title
        transcribeProgressPct = 0
        refreshStatusItem()
        defer {
            transcribingTitle = nil
            transcribeProgressPct = 0
            refreshStatusItem()
        }
        do {
            // Shared transcribe → build → persist core (see
            // TranscriptionJob). Progress arrives as a whole-job 0…1
            // fraction; forward it to the menu header.
            try await TranscriptionJob.run(
                slot: slot, model: model,
                onProgress: { [weak self] f in
                    Task { @MainActor in self?.setTranscribeProgress(f) }
                }
            )
            // A fresh pending transcript now exists — refresh the badge count.
            invalidatePendingDeliveryCache()

            // Don't pop the previous meeting's transcript over the
            // current one — it stays in the Recordings menu.
            if !session.isRunning { NSWorkspace.shared.open(slot.transcriptURL) }
            await deliverPending(slot: slot)
            // Audio is no longer needed losslessly — compress the raw
            // .caf to m4a (and drop the originals) in the background so
            // the UI returns to idle promptly. Re-transcription reads the
            // compressed file transparently.
            Task.detached { await Outbox.compressAudio(slot) }
        } catch {
            presentError("Transcription failed.", error: error)
            // .caf files remain on disk for a manual retry. Future
            // commit: add "Retry transcription" menu entry that
            // re-runs against the most recent slot lacking a
            // transcript.md.
        }
    }

    // MARK: Settings + first-run setup

    @objc private func showSettings() {
        let controller = settingsWindow ?? SettingsWindowController(
            onRunSetup: { [weak self] in self?.showOnboarding() },
            onClose: { [weak self] in
                self?.settingsWindow = nil
                self?.refreshStatusItem()
            }
        )
        settingsWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func finishSetup() { showOnboarding() }

    private func showOnboarding() {
        let controller = onboardingWindow ?? OnboardingWindowController { [weak self] in
            // Finish sets onboardingCompleted before closing, so this starts
            // the poll exactly then; closed early, the guard in
            // startCalendarPollingIfConfigured keeps it off and the menu
            // keeps offering "Finish setup…" (and it returns at launch).
            self?.onboardingWindow = nil
            self?.startCalendarPollingIfConfigured()
            self?.refreshStatusItem()
        }
        onboardingWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Voice Memos import

    @objc private func importVoiceMemos() {
        guard !session.isRunning else { return }
        if let existing = voiceMemoImportWindow {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = VoiceMemoImportWindowController(onImport: { [weak self] picked in
            guard let self else { return }
            self.voiceMemoImportWindow = nil
            Task { @MainActor in await self.runVoiceMemoImport(picked) }
        }, onClose: { [weak self] in
            // Cancel / the close button: drop the controller so the next
            // "Import Voice Memos…" reads the library afresh instead of
            // re-showing a list captured at first open.
            self?.voiceMemoImportWindow = nil
        })
        voiceMemoImportWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Imports the picked memos one at a time. A memo with Apple's
    /// transcript is complete after `prepare` (transcript written) and goes
    /// straight to delivery; one without goes through the same
    /// transcribe-and-deliver path as a Mac recording.
    private func runVoiceMemoImport(_ picked: [VoiceMemoImportWindowController.Selection]) async {
        var failures: [String] = []
        for item in picked {
            do {
                let result = try await VoiceMemoImporter.prepare(memo: item.memo, title: item.title)
                if result.usedAppleTranscript {
                    invalidatePendingDeliveryCache()
                    NSWorkspace.shared.open(result.slot.transcriptURL)
                    await deliverPending(slot: result.slot)
                } else {
                    await transcribeAndDeliver(slot: result.slot, title: result.meta.title)
                }
            } catch {
                failures.append("\(item.title): \(error)")
            }
        }
        refreshStatusItem()
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = failures.count == picked.count ? "Import failed." : "Some memos could not be imported."
            alert.informativeText = failures.joined(separator: "\n")
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: Audio file import

    /// "Transcribe Audio File…": pick one or more recordings made elsewhere
    /// (a Teams/Zoom cloud recording, a dictaphone file), confirm a title
    /// and the time the meeting actually happened, then transcribe and
    /// deliver them exactly like a Mac recording.
    @objc private func importAudioFiles() {
        guard !session.isRunning else { return }
        let panel = NSOpenPanel()
        panel.title = "Transcribe Audio File"
        panel.message = "Pick a recording (audio, or a video whose audio track to transcribe)."
        panel.allowedContentTypes = AudioFileImporter.allowedContentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        var picked: [(url: URL, title: String, startedAt: Date)] = []
        for url in panel.urls {
            guard let details = askImportDetails(for: url) else { continue }
            picked.append((url, details.title, details.startedAt))
        }
        guard !picked.isEmpty else { return }
        Task { @MainActor in await runFileImport(picked) }
    }

    /// One small dialog per file: the transcript title (defaults to the file
    /// name) and when the meeting happened (defaults to the file's creation
    /// time, which for a downloaded cloud recording is the download, not the
    /// meeting — hence the picker). nil = skipped.
    private func askImportDetails(for url: URL) -> (title: String, startedAt: Date)? {
        let alert = NSAlert()
        alert.messageText = "Transcribe \"\(url.lastPathComponent)\""
        alert.informativeText = "Title for the transcript, and when the meeting took place."
        alert.addButton(withTitle: "Transcribe")
        alert.addButton(withTitle: "Skip")

        let titleField = NSTextField(string: AudioFileImporter.defaultTitle(for: url))
        titleField.placeholderString = "Title"
        let datePicker = NSDatePicker()
        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = [.yearMonthDay, .hourMinute]
        datePicker.dateValue = AudioFileImporter.defaultStartedAt(for: url)
        let form = NSStackView(views: [
            NSTextField(labelWithString: "Title"), titleField,
            NSTextField(labelWithString: "Started"), datePicker,
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 6
        form.frame = NSRect(x: 0, y: 0, width: 360, height: 110)
        titleField.widthAnchor.constraint(equalToConstant: 360).isActive = true
        alert.accessoryView = form
        alert.window.initialFirstResponder = titleField
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (titleField.stringValue, datePicker.dateValue)
    }

    private func runFileImport(_ picked: [(url: URL, title: String, startedAt: Date)]) async {
        var failures: [String] = []
        for item in picked {
            do {
                let result = try await AudioFileImporter.prepare(
                    fileURL: item.url, title: item.title, startedAt: item.startedAt
                )
                await transcribeAndDeliver(slot: result.slot, title: result.meta.title)
            } catch {
                failures.append("\(item.url.lastPathComponent): \(error)")
            }
        }
        refreshStatusItem()
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = failures.count == picked.count ? "Import failed." : "Some files could not be imported."
            alert.informativeText = failures.joined(separator: "\n")
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // Carried on each re-transcribe menu item so one selector can handle
    // any (recording, model) pair the user picks.
    private struct RetranscribeRequest {
        let slug: String
        let model: TranscriptionModel
    }

    /// Builds the "Recordings" submenu: recent recordings, each a status-
    /// prefixed item expanding to its actions (open transcript,
    /// re-transcribe, retry delivery). nil when there are none.
    private func makeRecordingsMenuItem() -> NSMenuItem? {
        let slots = Outbox.listSlots(limit: 10)
        guard !slots.isEmpty else { return nil }

        let parent = NSMenuItem(title: "Recordings", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for slot in slots {
            let meta = try? Outbox.readMeta(from: slot.metaURL)
            let status = recordingStatus(meta: meta, slot: slot)
            let title = meta?.title ?? slot.slug
            let item = NSMenuItem(title: "\(status.symbol) \(title)", action: nil, keyEquivalent: "")
            item.submenu = makeRecordingSubmenu(slot: slot, meta: meta, statusLabel: status.label)
            menu.addItem(item)
        }
        parent.submenu = menu
        return parent
    }

    /// Status glyph + label for a recording, derived from its files + meta
    /// and the sinks active right now: ✓ every applicable sink delivered,
    /// ◯ nothing to deliver to, ⤴/⚠ something still pending.
    private func recordingStatus(meta: RecordingMeta?, slot: OutboxSlot) -> (symbol: String, label: String) {
        let hasTranscript = FileManager.default.fileExists(atPath: slot.transcriptURL.path)
        guard let meta else { return hasTranscript ? ("◯", "transcribed") : ("●", "recorded") }
        guard hasTranscript || meta.transcription != nil else { return ("●", "recorded") }
        let applicable = SinkDispatcher.activeSinks().filter { $0.applies(to: meta) }
        guard !applicable.isEmpty else { return ("◯", "transcribed") }
        let pending = applicable.filter { !meta.isDelivered(to: $0.id) }
        guard !pending.isEmpty else { return ("✓", "delivered") }
        let names = pending.map(\.displayName).joined(separator: ", ")
        let attempts = pending.map { meta.attempt(for: $0.id).attempt_count }.max() ?? 0
        if attempts > 0 { return ("⚠", "delivery failed: \(names) (\(attempts))") }
        return ("⤴", "pending: \(names)")
    }

    private func makeRecordingSubmenu(slot: OutboxSlot, meta: RecordingMeta?, statusLabel: String) -> NSMenu {
        let menu = NSMenu()
        let fm = FileManager.default

        var headerBits = [statusLabel]
        if let model = meta?.transcription?.model { headerBits.append(model) }
        let header = NSMenuItem(title: headerBits.joined(separator: " · "), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if fm.fileExists(atPath: slot.transcriptURL.path) {
            let item = NSMenuItem(title: "Open Transcript", action: #selector(openTranscript(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = slot.transcriptURL.path
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // A slot past the retention window keeps only its transcript:
        // nothing to re-run.
        if slot.hasAudio {
            let retranscribe = NSMenuItem(title: "Re-transcribe with…", action: nil, keyEquivalent: "")
            let modelMenu = NSMenu()
            let currentModel = meta?.transcription?.model
            // A cloud model sends the audio to OpenAI: offered only while
            // cloud transcription is switched on with a key (Settings ›
            // Cloud), and never for a recording whose meta can't be read.
            let cloudAllowed = meta != nil && Config.cloudTranscriptionAvailable()
            for model in TranscriptionModel.allCases where cloudAllowed || model.engine != .openAI {
                let modelItem = NSMenuItem(title: model.displayName, action: #selector(retranscribeSelected(_:)), keyEquivalent: "")
                modelItem.target = self
                modelItem.representedObject = RetranscribeRequest(slug: slot.slug, model: model)
                modelItem.state = (model.rawValue == currentModel) ? .on : .off
                modelMenu.addItem(modelItem)
            }
            retranscribe.submenu = modelMenu
            menu.addItem(retranscribe)
        }

        if let meta, SinkDispatcher.isReady(slot), !SinkDispatcher.pendingSinks(for: meta).isEmpty {
            let item = NSMenuItem(title: "Retry Delivery", action: #selector(retryDeliveryOne(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = slot.slug
            menu.addItem(item)
        }
        return menu
    }

    /// "Language" submenu — Auto / English / Swedish, ticked at the current
    /// choice. Auto detects per recording; English/Swedish pin it. Applies
    /// to the next (re-)transcription.
    private func makeLanguageMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        let current = Config.sttLanguageRaw()
        for (label, code) in [("Auto (detect)", "auto"), ("English", "en"), ("Swedish", "sv")] {
            let item = NSMenuItem(title: label, action: #selector(setLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = (current == code) ? .on : .off
            menu.addItem(item)
        }
        parent.submenu = menu
        return parent
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        Config.setSTTLanguage(code)
        refreshStatusItem()
    }

    @objc private func openTranscript(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func retryDeliveryOne(_ sender: NSMenuItem) {
        guard let slug = sender.representedObject as? String else { return }
        let slot = Outbox.slot(forDir: Outbox.rootURL.appendingPathComponent(slug, isDirectory: true))
        Task { @MainActor in
            // The user asked: skip the backoff wait, and say what failed.
            let outcomes = await deliverPending(slot: slot, ignoringSchedule: true)
            refreshStatusItem()
            if let failed = outcomes.first(where: { !$0.succeeded }), let error = failed.error {
                presentError("Delivery failed: \(failed.sinkName)", error: error)
            }
        }
    }

    @objc private func retranscribeSelected(_ sender: NSMenuItem) {
        guard let req = sender.representedObject as? RetranscribeRequest else { return }
        let dir = Outbox.rootURL.appendingPathComponent(req.slug, isDirectory: true)
        let slot = Outbox.slot(forDir: dir)
        let title = (try? Outbox.readMeta(from: slot.metaURL))?.title ?? req.slug
        startTranscription(slot: slot, title: title, model: req.model)
    }

    // MARK: Delivery

    /// One attempt for every pending, due sink (SinkDispatcher).
    /// Best-effort: a failure leaves the recording pending with its per-sink
    /// retry counters bumped so the auto-retry timer backs off. Shared by
    /// the post-transcribe path, recovery and imports (via
    /// transcribeAndDeliver), the retry timer, and the manual retries.
    @discardableResult
    private func deliverPending(
        slot: OutboxSlot,
        ignoringSchedule: Bool = false
    ) async -> [DeliveryOutcome] {
        let outcomes = await SinkDispatcher.deliverPending(slot: slot, ignoringSchedule: ignoringSchedule)
        if !outcomes.isEmpty { invalidatePendingDeliveryCache() }
        return outcomes
    }

    /// Pending-delivery count for the menu badge, memoized so the per-second
    /// menu rebuild during recording doesn't rescan the outbox from disk.
    private func pendingDeliveryCount() -> Int {
        if let cached = cachedPendingDeliveryCount { return cached }
        let count = SinkDispatcher.pendingCount()
        cachedPendingDeliveryCount = count
        return count
    }

    /// Drop the memoized pending count so the next read rescans. Call after
    /// any change to the pending set (new transcript written, sink delivered).
    private func invalidatePendingDeliveryCache() {
        cachedPendingDeliveryCount = nil
    }

    // MARK: Auto-retry timer

    /// Always runs: which sinks are active can change in Settings while the
    /// app is up, and a tick with nothing pending costs one outbox scan.
    private func startDeliveryRetryTimer() {
        guard deliveryRetryTimer == nil else { return }
        // First tick happens after the interval — by then the
        // post-transcription delivery has had a chance to either
        // succeed or land in the retry queue with attempt count >= 1.
        deliveryRetryTimer = Timer.scheduledTimer(
            withTimeInterval: Self.deliveryRetryTickInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickDeliveryRetry() }
        }
    }

    private func tickDeliveryRetry() {
        let slots = SinkDispatcher.pendingSlots()
        guard !slots.isEmpty else { return }
        Task { @MainActor in
            for slot in slots {
                await self.deliverPending(slot: slot)
            }
            self.refreshStatusItem()
        }
    }

    @objc private func retryPendingDeliveries() {
        Task { @MainActor in
            let slots = SinkDispatcher.pendingSlots()
            guard !slots.isEmpty else { return }
            var delivered = 0
            var failures: [String] = []
            for slot in slots {
                let outcomes = await self.deliverPending(slot: slot, ignoringSchedule: true)
                let failed = outcomes.filter { !$0.succeeded }
                if !outcomes.isEmpty && failed.isEmpty { delivered += 1 }
                let meta = try? Outbox.readMeta(from: slot.metaURL)
                for outcome in failed {
                    let attempt = meta?.attempt(for: outcome.sinkID).attempt_count ?? 0
                    failures.append("\(slot.slug) → \(outcome.sinkName) (attempt \(attempt))")
                }
            }
            refreshStatusItem()
            let alert = NSAlert()
            alert.messageText = "Delivery retry complete"
            alert.informativeText = "Delivered \(delivered) of \(slots.count)."
                + (failures.isEmpty ? "" : "\n\nFailed:\n" + failures.prefix(5).joined(separator: "\n"))
            alert.alertStyle = failures.isEmpty ? .informational : .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func showOutbox() {
        let url = Outbox.rootURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    /// The grant the configured system-audio engine needs, as System
    /// Settings › Privacy & Security names it.
    private static var systemAudioPermissionName: String {
        Config.systemAudioEngine() == .sck ? "Screen Recording" : "System Audio Recording"
    }

    private static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "Minnas"
    }

    private struct StartChoice {
        let title: String
        let tag: CalendarTag?
    }

    /// Prompts for the recording title and, when calendar events are
    /// available, lets the user attach one (→ calendar_event_id +
    /// attendees on the recording). A typed title wins; otherwise the
    /// chosen event's title is used.
    private func promptForStart(events: [UpcomingEvent]) -> StartChoice? {
        let alert = NSAlert()
        alert.messageText = "New Recording"
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")

        let width: CGFloat = 300
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        field.placeholderString = "Q3 planning sync"

        guard !events.isEmpty else {
            alert.informativeText = "Title for this meeting (used for the outbox folder name):"
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return StartChoice(title: title.isEmpty ? "untitled" : title, tag: nil)
        }

        alert.informativeText = "Attach a calendar event (or leave as manual), and/or set a title:"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        popup.addItem(withTitle: "No calendar event (manual)")
        for event in events {
            let mins = Int(event.start.timeIntervalSinceNow / 60)
            let when = mins >= 0 ? "in \(mins)m" : "\(-mins)m ago"
            let item = NSMenuItem(title: "\(event.title ?? "(untitled)") — \(when)", action: nil, keyEquivalent: "")
            item.representedObject = event
            popup.menu?.addItem(item)
        }

        let stack = NSStackView(views: [popup, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: width, height: 62)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = popup

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let event = popup.selectedItem?.representedObject as? UpcomingEvent
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = !typed.isEmpty ? typed : (event?.title ?? "untitled")
        return StartChoice(title: title, tag: event.flatMap(Self.tag(for:)))
    }

    private func presentError(_ message: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = String(describing: error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: Icons

    /// Idle icon: plain `mic` (template, takes on the system menubar tint).
    private static func idleIcon() -> NSImage? {
        NSImage(systemSymbolName: "mic", accessibilityDescription: "Minnas idle")
    }

    private static func recordingIcon() -> NSImage? {
        // Red filled circle, palette-tinted. isTemplate must be false at
        // the call site or the status bar strips color back to monochrome.
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        return NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Minnas recording")?
            .withSymbolConfiguration(config)
    }

    private static func transcribingIcon() -> NSImage? {
        NSImage(systemSymbolName: "waveform", accessibilityDescription: "Minnas transcribing")
    }
}
