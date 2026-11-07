//
// First-run setup: one window, four steps, Back / Next.
//
//   1. Welcome + where transcripts go. A folder is required to continue —
//      a transcript nobody can find is the failure this app exists to
//      prevent. ~/Documents/Minnas Transcripts is suggested and created
//      only when the user moves on with it.
//   2. Microphone. Next waits for the grant: without it a recording has
//      no "Me" side at all.
//   3. System audio. Explains the engine in use and the grant it needs.
//      Next is always enabled: Screen Recording can be preflighted but may
//      lag a grant until relaunch, and the taps grant can't be queried at
//      all — the first recording is the real check.
//   4. Optional: an OpenAI key and the calendar source. Finish.
//
// Runs at launch while Settings.onboardingCompleted is false (AppDelegate
// holds the calendar poll back until Finish sets it) and again from
// Settings › General › Run Setup Again. Closing the window without Finish
// leaves it unfinished: no poll, no completion, and the menu offers
// "Finish setup…" until it is done.
//

import AppKit
import AVFoundation
import CoreGraphics

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let stepCount = 4

    private let onDone: () -> Void
    private var step = 0
    private var statusTimer: Timer?

    private let titleLabel = NSTextField(labelWithString: "")
    private let stepLabel = NSTextField(labelWithString: "")
    private let container = NSView()
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next", target: nil, action: nil)
    private var pages: [NSView] = []

    // Step 1
    private var pendingFolder: URL
    private let folderLabel = NSTextField(labelWithString: "")
    private let folderMessage = SettingsUI.messageLabel(width: 500)

    // Step 2
    private let micStatus = NSTextField(labelWithString: "")
    private let micButton = NSButton(title: "Allow Microphone Access…", target: nil, action: nil)

    // Step 3
    private let systemAudioStatus = NSTextField(labelWithString: "")
    private let systemAudioExplanation = NSTextField(wrappingLabelWithString: "")
    private var screenRecordingRequested = false

    // Step 4
    private let keyField = NSSecureTextField()
    private let keyMessage = SettingsUI.messageLabel(width: 500)
    private let calendarPopup = NSPopUpButton()
    private let calendarStatus = NSTextField(labelWithString: "")
    private let calendarGrantButton = NSButton(title: "Grant Calendar Access…", target: nil, action: nil)

    static var suggestedFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Minnas Transcripts", isDirectory: true)
    }

    /// `onDone` runs once, when the window closes — finished or not.
    init(onDone: @escaping () -> Void) {
        self.onDone = onDone
        self.pendingFolder = Config.transcriptsFolderURL() ?? Self.suggestedFolder
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Set Up \(SettingsUI.appName)"
        super.init(window: window)
        window.delegate = self
        buildUI()
        show(step: 0)
        window.center()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func windowWillClose(_ notification: Notification) {
        statusTimer?.invalidate()
        statusTimer = nil
        onDone()
    }

    // MARK: Layout

    private func buildUI() {
        guard let content = window?.contentView else { return }
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        stepLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stepLabel.textColor = .secondaryLabelColor

        backButton.target = self
        backButton.action = #selector(back)
        backButton.keyEquivalent = "\u{1b}"
        nextButton.target = self
        nextButton.action = #selector(next)
        nextButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [stepLabel, NSView(), backButton, nextButton])
        buttons.orientation = .horizontal

        pages = [buildWelcome(), buildMicrophone(), buildSystemAudio(), buildOptional()]
        for page in pages {
            page.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(page)
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: container.topAnchor),
                page.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                page.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            ])
        }

        for view in [titleLabel, container, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -28),
            container.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            container.bottomAnchor.constraint(lessThanOrEqualTo: buttons.topAnchor, constant: -16),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])
    }

    private func paragraph(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = 520
        return label
    }

    private func buildWelcome() -> NSView {
        let intro = paragraph("\(SettingsUI.appName) records your meetings — your microphone and the other side of the call — and transcribes them on this Mac. It lives in the menu bar; nothing is recorded until you start a recording or accept a calendar prompt.")
        let question = NSTextField(labelWithString: "Where should transcripts go?")
        question.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        let note = SettingsUI.note("Each finished meeting is written there as a Markdown file you can open in any editor. The folder is created if it doesn't exist; change it any time in Settings.", width: 520)
        return SettingsUI.vstack([intro, NSView.spacer(8), question, SettingsUI.hstack([folderLabel, choose]), note, folderMessage], spacing: 8)
    }

    private func buildMicrophone() -> NSView {
        let text = paragraph("Your side of the meeting comes from the microphone. macOS asks once; if you said no before, switch \(SettingsUI.appName) on under Privacy & Security › Microphone.")
        micButton.target = self
        micButton.action = #selector(microphoneButton)
        let status = SettingsUI.hstack([NSTextField(labelWithString: "Status:"), micStatus])
        return SettingsUI.vstack([text, status, micButton], spacing: 12)
    }

    /// The wording depends on the engine, which the user can change in
    /// Settings while this window is open; so it is set each time the step
    /// is shown (refresh), not once when the window is created.
    private func systemAudioExplanationText() -> String {
        let engine = Permissions.systemAudioEngine
        switch engine {
        case .sck:
            return "The other side of the call — any app playing through your speakers or headphones — is captured with \(engine.displayName). macOS files that under Privacy & Security › Screen & System Audio Recording. Only audio is used; no image of your screen is ever saved."
        case .taps:
            return "The other side of the call — any app playing through your speakers or headphones — is captured with a \(engine.displayName). macOS files that under Privacy & Security › Screen & System Audio Recording, as System Audio Recording Only."
        }
    }

    private func buildSystemAudio() -> NSView {
        systemAudioExplanation.preferredMaxLayoutWidth = 520
        systemAudioExplanation.stringValue = systemAudioExplanationText()
        let verify = SettingsUI.note("macOS can't always report this grant until the app relaunches, so you can continue either way: the first recording shows whether the other side was captured (the menubar shows its level meter).", width: 520)
        let open = NSButton(title: "Open System Settings…", target: self, action: #selector(systemAudioButton))
        let status = SettingsUI.hstack([NSTextField(labelWithString: "Status:"), systemAudioStatus])
        return SettingsUI.vstack([systemAudioExplanation, status, open, verify], spacing: 12)
    }

    private func buildOptional() -> NSView {
        let heading = paragraph("Both of these are optional and can be changed later in Settings.")
        let cloudTitle = NSTextField(labelWithString: "Cloud transcription")
        cloudTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        keyField.placeholderString = "OpenAI API key (sk-…)"
        keyField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let cloudNote = SettingsUI.note("With a key, OpenAI's diarizing model is offered next to the local ones. Audio is sent to OpenAI only when a cloud model is chosen. The key is kept in your login Keychain.", width: 520)

        let calendarTitle = NSTextField(labelWithString: "Calendar")
        calendarTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        for source in CalendarSource.allCases {
            calendarPopup.addItem(withTitle: source.displayName)
            calendarPopup.lastItem?.representedObject = source.rawValue
        }
        let current = Settings.shared.calendarSource.rawValue
        if let index = calendarPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == current }) {
            calendarPopup.selectItem(at: index)
        }
        calendarPopup.target = self
        calendarPopup.action = #selector(calendarChanged)
        calendarGrantButton.target = self
        calendarGrantButton.action = #selector(grantCalendar)
        let calendarNote = SettingsUI.note("macOS Calendar reads the accounts in the Calendar app, and offers to record meetings that have a Zoom, Meet or Teams link.", width: 520)
        return SettingsUI.vstack([
            heading, NSView.spacer(4),
            cloudTitle, keyField, cloudNote, keyMessage, NSView.spacer(4),
            calendarTitle, SettingsUI.hstack([calendarPopup, calendarStatus, calendarGrantButton]), calendarNote,
        ], spacing: 8)
    }

    // MARK: Steps

    func show(step newStep: Int) {
        step = max(0, min(Self.stepCount - 1, newStep))
        for (index, page) in pages.enumerated() { page.isHidden = index != step }
        titleLabel.stringValue = ["Welcome to \(SettingsUI.appName)", "Microphone", "The other side of the call", "Extras"][step]
        stepLabel.stringValue = "Step \(step + 1) of \(Self.stepCount)"
        backButton.isHidden = step == 0
        nextButton.title = step == Self.stepCount - 1 ? "Finish" : "Next"
        refresh()
    }

    private func refresh() {
        switch step {
        case 0:
            folderLabel.stringValue = (pendingFolder.path as NSString).abbreviatingWithTildeInPath
            nextButton.isEnabled = true
        case 1:
            let status = Permissions.microphone()
            micStatus.stringValue = status.text
            micStatus.textColor = status.color
            let undetermined = AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
            micButton.title = undetermined ? "Allow Microphone Access…" : "Open System Settings…"
            micButton.isHidden = Permissions.microphoneGranted
            nextButton.isEnabled = Permissions.microphoneGranted
        case 2:
            systemAudioExplanation.stringValue = systemAudioExplanationText()
            let status = Permissions.systemAudioEngine == .sck
                ? Permissions.screenRecording() : Permissions.systemAudioRecording()
            systemAudioStatus.stringValue = status.text
            systemAudioStatus.textColor = status.color
            nextButton.isEnabled = true
        default:
            let isEventKit = (calendarPopup.selectedItem?.representedObject as? String) == CalendarSource.eventkit.rawValue
            let status = Permissions.calendar()
            calendarStatus.stringValue = isEventKit ? status.text : ""
            calendarStatus.textColor = status.color
            calendarGrantButton.isHidden = !isEventKit || EventKitCalendar.isAuthorized
            calendarGrantButton.title = EventKitCalendar.authorizationStatus == .notDetermined
                ? "Grant Calendar Access…" : "Open System Settings…"
            nextButton.isEnabled = true
        }
    }

    @objc private func back() { show(step: step - 1) }

    @objc private func next() {
        switch step {
        case 0:
            guard commitFolder() else { return }
            show(step: 1)
        case Self.stepCount - 1:
            guard revalidateFolder() else { return }
            guard commitKey() else { return }
            Settings.shared.onboardingCompleted = true
            close()
        default:
            show(step: step + 1)
        }
    }

    // MARK: Step actions

    @objc private func chooseFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.directoryURL = FileManager.default.fileExists(atPath: pendingFolder.path)
            ? pendingFolder : pendingFolder.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url, let self else { return }
                self.pendingFolder = url
                SettingsUI.show(self.folderMessage, error: nil)
                self.refresh()
            }
        }
    }

    /// Creates the folder (the suggestion usually doesn't exist yet) and
    /// stores it. False keeps the user on this step with the reason shown.
    private func commitFolder() -> Bool {
        do {
            try FileManager.default.createDirectory(at: pendingFolder, withIntermediateDirectories: true)
            try Settings.shared.setValue(fromString: pendingFolder.path, for: .transcriptsFolderPath)
            return true
        } catch {
            SettingsUI.show(folderMessage, error: "Couldn't use that folder: \(error.localizedDescription)")
            return false
        }
    }

    /// Step 1 stored the folder, but Settings can be open meanwhile and turn
    /// it off (or the directory can vanish) before Finish. Completing setup
    /// with no place for transcripts is the failure step 1 exists to
    /// prevent, so check again here and send the user back if it fails.
    private func revalidateFolder() -> Bool {
        guard let url = Config.transcriptsFolderURL() else {
            SettingsUI.show(folderMessage, error: "The transcripts folder was turned off in Settings. Choose a folder to continue.")
            show(step: 0)
            return false
        }
        pendingFolder = url
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            SettingsUI.show(folderMessage, error: "Couldn't use that folder: \(error.localizedDescription)")
            show(step: 0)
            return false
        }
    }

    private func commitKey() -> Bool {
        let value = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return true }
        do {
            try Settings.shared.setValue(fromString: value, for: .openAIKey)
            // A key typed here means "I want the cloud option".
            Settings.shared.set(Setting.cloudTranscriptionEnabled, true)
            keyField.stringValue = ""
            return true
        } catch {
            SettingsUI.show(keyMessage, error: String(describing: error))
            return false
        }
    }

    @objc private func microphoneButton() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            Permissions.open(.microphone)
            return
        }
        Task { @MainActor in
            _ = await Permissions.requestMicrophone()
            refresh()
        }
    }

    @objc private func systemAudioButton() {
        // ScreenCaptureKit: the first request is what puts the app into the
        // list, so the switch is there to flip when the pane opens.
        if Permissions.systemAudioEngine == .sck && !screenRecordingRequested && !CGPreflightScreenCaptureAccess() {
            screenRecordingRequested = true
            _ = CGRequestScreenCaptureAccess()
        }
        Permissions.open(.screenRecording)
    }

    @objc private func calendarChanged() {
        guard let raw = calendarPopup.selectedItem?.representedObject as? String,
              let source = CalendarSource(rawValue: raw) else { return }
        Settings.shared.calendarSource = source
        refresh()
    }

    @objc private func grantCalendar() {
        guard EventKitCalendar.authorizationStatus == .notDetermined else {
            Permissions.open(.calendars)
            return
        }
        Task { @MainActor in
            _ = try? await EventKitCalendar.requestAccess()
            refresh()
        }
    }
}

private extension NSView {
    static func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }
}
