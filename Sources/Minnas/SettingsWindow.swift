//
// The Settings window: every user-facing setting, so the .env file is only
// ever a developer override. Five tabs — General, Transcription, Cloud,
// Calendar, Permissions.
//
// Controls show the EFFECTIVE value (Config's resolver: env > Settings >
// .env > default) and write through Settings.shared, so what the window
// shows is what the next recording uses. When an environment variable or a
// .env line is what's in force, the row says so — otherwise a value that
// "won't stick" would look like a bug.
//
// Validation happens before the write and is shown inline under the field;
// nothing is stored that the resolver would later have to reject.
//
// AppKit with programmatic NSGridView layout, like the Voice Memos picker.
// The Permissions helpers (status + System Settings deep links) are shared
// with the onboarding window.
//

import AppKit
import AVFoundation
import CoreGraphics
import EventKit
import ServiceManagement
import os.log

private let settingsWindowLog = Logger(subsystem: "com.jwiderberg.minnas", category: "SettingsWindow")

// MARK: - Permissions (shared with Onboarding)

struct PermissionStatus {
    enum Level { case ok, attention, neutral }
    let text: String
    let level: Level

    var color: NSColor {
        switch level {
        case .ok: return .systemGreen
        case .attention: return .systemOrange
        case .neutral: return .secondaryLabelColor
        }
    }
}

/// Each capture engine needs a different grant: ScreenCaptureKit needs
/// Screen Recording, a Core Audio process tap needs System Audio Recording.
extension SystemAudioEngineKind {
    var displayName: String {
        switch self {
        case .sck: return "ScreenCaptureKit (needs Screen Recording)"
        case .taps: return "Core Audio process tap (needs System Audio Recording)"
        }
    }
}

@MainActor
enum Permissions {
    /// The engine the NEXT recording will use; the Permissions tab and the
    /// onboarding step show the grant that engine needs.
    static var systemAudioEngine: SystemAudioEngineKind { Config.systemAudioEngine() }

    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case screenRecording = "Privacy_ScreenCapture"   // also System Audio Recording
        case calendars = "Privacy_Calendars"
        case fullDiskAccess = "Privacy_AllFiles"
    }

    static func open(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }

    static func microphone() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return PermissionStatus(text: "Granted", level: .ok)
        case .notDetermined: return PermissionStatus(text: "Not requested yet", level: .attention)
        case .denied: return PermissionStatus(text: "Denied — switch it on in System Settings", level: .attention)
        case .restricted: return PermissionStatus(text: "Restricted by the system", level: .attention)
        @unknown default: return PermissionStatus(text: "Unknown", level: .neutral)
        }
    }

    static var microphoneGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// Shows the macOS prompt the first time; afterwards macOS answers from
    /// its record without asking, so a denial has to be undone in Settings.
    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func screenRecording() -> PermissionStatus {
        // Preflight can lag a grant made while the app runs (macOS caches it
        // per process); the capture itself is the final word.
        CGPreflightScreenCaptureAccess()
            ? PermissionStatus(text: "Granted", level: .ok)
            : PermissionStatus(text: "Not granted (or granted since launch — relaunch to see it)", level: .attention)
    }

    /// The tap grant has no query API: it shows up the first time a tap
    /// starts, and a denied tap just delivers silence.
    static func systemAudioRecording() -> PermissionStatus {
        PermissionStatus(text: "Unknown until the first recording", level: .neutral)
    }

    static func calendar() -> PermissionStatus {
        let status = EKEventStore.authorizationStatus(for: .event)
        let text = EventKitCalendar.describe(status).prefix(1).uppercased() + EventKitCalendar.describe(status).dropFirst()
        return PermissionStatus(text: text, level: status == .fullAccess ? .ok : .attention)
    }

    /// Full Disk Access has no query API either; listing the Voice Memos
    /// library folder is the cheapest read it gates, and it's the only
    /// thing the app needs FDA for.
    static func fullDiskAccess() -> PermissionStatus {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: VoiceMemoLibrary.recordingsURL.path)
            return PermissionStatus(text: "Granted", level: .ok)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return PermissionStatus(text: "No Voice Memos library on this Mac", level: .neutral)
        } catch {
            return PermissionStatus(text: "Not granted", level: .attention)
        }
    }
}

// MARK: - Small layout helpers (shared with Onboarding)

@MainActor
enum SettingsUI {
    static let controlColumnWidth: CGFloat = 430

    static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "Minnas"
    }

    static func note(_ text: String, width: CGFloat = controlColumnWidth) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = width
        return label
    }

    /// An inline message under a field: red for a rejected value, grey for
    /// "this value comes from somewhere else". Hidden while empty.
    static func messageLabel(width: CGFloat = controlColumnWidth) -> NSTextField {
        let label = note("", width: width)
        label.isHidden = true
        return label
    }

    static func show(_ label: NSTextField, error: String?) {
        label.stringValue = error ?? ""
        label.textColor = .systemRed
        setHidden(label, (error ?? "").isEmpty)
    }

    /// Hides a view and, when it sits in a grid, its whole row — a hidden
    /// view alone still leaves the row's spacing behind as a gap.
    static func setHidden(_ view: NSView, _ hidden: Bool) {
        view.isHidden = hidden
        if let grid = view.superview as? NSGridView {
            grid.cell(for: view)?.row?.isHidden = hidden
        }
    }

    static func show(_ label: NSTextField, info: String?) {
        label.stringValue = info ?? ""
        label.textColor = .secondaryLabelColor
        setHidden(label, (info ?? "").isEmpty)
    }

    static func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = spacing
        return stack
    }

    static func vstack(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    static func numberField(width: CGFloat = 60) -> NSTextField {
        let field = NSTextField()
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        // Commit on focus loss too, not only on Return — otherwise a value
        // typed before switching tabs silently doesn't save.
        field.cell?.sendsActionOnEndEditing = true
        return field
    }

    static func textField(width: CGFloat) -> NSTextField {
        let field = NSTextField()
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        field.cell?.sendsActionOnEndEditing = true
        return field
    }

    /// Where a key's value comes from, when that isn't this window.
    static func overrideNote(for key: SettingKey) -> String? {
        switch Config.resolve(key)?.source {
        case .env?:
            return "Overridden by the \(key.envKey ?? key.name) environment variable while it is set."
        case .dotEnv?:
            return "Currently read from the .env file (developer override); a value set here takes over."
        default:
            return nil
        }
    }

    /// A tab page: the grid pinned to the top-left with standard margins,
    /// so short tabs don't float in the middle of the window.
    static func page(_ content: NSView) -> NSView {
        let page = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: page.topAnchor, constant: 18),
            content.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(lessThanOrEqualTo: page.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(lessThanOrEqualTo: page.bottomAnchor, constant: -18),
        ])
        return page
    }
}

/// Two-column form: right-aligned labels, controls with notes under them.
@MainActor
private final class FormGrid {
    let grid = NSGridView(numberOfColumns: 2, rows: 0)

    init() {
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = SettingsUI.controlColumnWidth
        grid.rowAlignment = .firstBaseline
    }

    func row(_ title: String?, _ view: NSView) {
        let label: NSView = title.map { NSTextField(labelWithString: $0) } ?? NSGridCell.emptyContentView
        grid.addRow(with: [label, view])
    }

    func row(_ title: String?, _ views: [NSView]) {
        row(title, SettingsUI.hstack(views))
    }

    /// A note or message under the control of the row above.
    func under(_ view: NSView) {
        // Read before adding: NSGridView un-hides a view placed in a
        // visible row (it drives row hiding through its views' isHidden).
        let hidden = view.isHidden
        let row = grid.addRow(with: [NSGridCell.emptyContentView, view])
        row.topPadding = -2
        row.isHidden = hidden
    }

    func gap(_ height: CGFloat = 10) {
        let row = grid.addRow(with: [NSGridCell.emptyContentView, NSGridCell.emptyContentView])
        row.height = height
    }
}

// MARK: - Window

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSMenuDelegate {
    enum Tab: String, CaseIterable {
        case general, transcription, cloud, calendar, permissions

        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    private let onRunSetup: () -> Void
    private let onClose: () -> Void
    private let tabView = NSTabView()
    private var refreshTimer: Timer?

    // General
    private let folderPathLabel = NSTextField(labelWithString: "")
    private let folderRevealButton = NSButton(title: "Reveal in Finder", target: nil, action: nil)
    private let folderOffButton = NSButton(title: "Turn Off", target: nil, action: nil)
    private let folderMessage = SettingsUI.messageLabel()
    private let keepDaysField = SettingsUI.numberField()
    private let keepDaysMessage = SettingsUI.messageLabel()
    private let autoStopField = SettingsUI.numberField()
    private let autoStopMessage = SettingsUI.messageLabel()
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Open at login", target: nil, action: nil)
    private let launchAtLoginStatus = SettingsUI.note("")
    private let launchAtLoginMessage = SettingsUI.messageLabel()

    // Transcription
    private let modelPopup = NSPopUpButton()
    private let enginePopup = NSPopUpButton()
    private let languagesField = SettingsUI.textField(width: 140)
    private let languagesMessage = SettingsUI.messageLabel()
    private let marginField = SettingsUI.numberField()
    private let marginMessage = SettingsUI.messageLabel()
    private let diarizeCheckbox = NSButton(checkboxWithTitle: "Separate the other speakers (local diarizer)", target: nil, action: nil)
    private let voiceMemoPopup = NSPopUpButton()
    private let excludedTable = NSTableView()
    private var excludedIDs: [String] = []
    private let addRunningAppPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let removeExcludedButton = NSButton(title: "Remove", target: nil, action: nil)
    private let excludedMessage = SettingsUI.messageLabel()

    // Cloud
    private let cloudCheckbox = NSButton(checkboxWithTitle: "Enable cloud transcription", target: nil, action: nil)
    private let keyField = NSSecureTextField()
    private let keyStatusLabel = SettingsUI.note("")
    private let keyMessage = SettingsUI.messageLabel()
    private let testKeyButton = NSButton(title: "Test Key", target: nil, action: nil)

    // Calendar
    private let calendarSourcePopup = NSPopUpButton()
    private let calendarStatusLabel = NSTextField(labelWithString: "")
    private let calendarGrantButton = NSButton(title: "Grant Calendar Access…", target: nil, action: nil)
    private let calendarMessage = SettingsUI.messageLabel()
    private var eventKitViews: [NSView] = []

    // Permissions
    private struct PermissionRow {
        let status: NSTextField
        let button: NSButton
    }
    private var micRow: PermissionRow?
    private var screenRow: PermissionRow?
    private var systemAudioRow: PermissionRow?
    private var calendarRow: PermissionRow?
    private var fdaRow: PermissionRow?
    private var screenRecordingRequested = false

    init(onRunSetup: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onRunSetup = onRunSetup
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 590),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "\(SettingsUI.appName) Settings"
        super.init(window: window)
        window.delegate = self
        buildUI()
        reloadAll()
        window.center()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatuses() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // No field pre-focused: a focus ring on "Keep recordings" reads as
        // "this needs your attention".
        window?.makeFirstResponder(nil)
    }

    func select(_ tab: Tab) {
        tabView.selectTabViewItem(withIdentifier: tab.rawValue)
        refreshStatuses()
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        onClose()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.delegate = self
        for tab in Tab.allCases {
            let item = NSTabViewItem(identifier: tab.rawValue)
            item.label = tab.title
            switch tab {
            case .general: item.view = SettingsUI.page(buildGeneral())
            case .transcription: item.view = SettingsUI.page(buildTranscription())
            case .cloud: item.view = SettingsUI.page(buildCloud())
            case .calendar: item.view = SettingsUI.page(buildCalendar())
            case .permissions: item.view = SettingsUI.page(buildPermissions())
            }
            tabView.addTabViewItem(item)
        }
        content.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    private func reloadAll() {
        reloadGeneral()
        reloadTranscription()
        reloadCloud()
        reloadCalendar()
        refreshStatuses()
    }

    // MARK: General

    private func buildGeneral() -> NSView {
        let form = FormGrid()

        folderPathLabel.lineBreakMode = .byTruncatingMiddle
        folderPathLabel.isSelectable = true
        folderPathLabel.widthAnchor.constraint(lessThanOrEqualToConstant: SettingsUI.controlColumnWidth).isActive = true
        form.row("Transcripts folder:", folderPathLabel)
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        folderRevealButton.target = self
        folderRevealButton.action = #selector(revealFolder)
        folderOffButton.target = self
        folderOffButton.action = #selector(turnFolderOff)
        form.row(nil, [choose, folderRevealButton, folderOffButton])
        form.under(SettingsUI.note("Each finished transcript is written there as a Markdown file. \(SettingsUI.appName) only adds or updates files there, never deletes. Off = transcripts stay in the app's outbox only."))
        form.under(folderMessage)
        form.gap()

        keepDaysField.target = self
        keepDaysField.action = #selector(keepDaysChanged)
        form.row("Keep audio:", [keepDaysField, NSTextField(labelWithString: "days (0 = forever)")])
        form.under(SettingsUI.note("Then the audio is deleted. Transcripts in the folder are never touched; the outbox copy of a transcript goes with its audio once it is in the folder."))
        form.under(keepDaysMessage)

        autoStopField.target = self
        autoStopField.action = #selector(autoStopChanged)
        form.row("Auto-stop after:", [autoStopField, NSTextField(labelWithString: "minutes of silence (0 = never)")])
        form.under(autoStopMessage)
        form.gap()

        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(launchAtLoginToggled)
        form.row("Startup:", [launchAtLoginCheckbox, launchAtLoginStatus])
        form.under(launchAtLoginMessage)
        form.gap()

        let rerun = NSButton(title: "Run Setup Again…", target: self, action: #selector(runSetupAgain))
        form.row("Setup:", rerun)
        return form.grid
    }

    private func reloadGeneral() {
        let folder = Config.transcriptsFolderURL()
        folderPathLabel.stringValue = folder?.path ?? "(off)"
        folderPathLabel.textColor = folder == nil ? .secondaryLabelColor : .labelColor
        folderRevealButton.isEnabled = folder != nil
        folderOffButton.isEnabled = folder != nil && SettingsStorage.isSet(.transcriptsFolderPath)
        SettingsUI.show(folderMessage, info: SettingsUI.overrideNote(for: .transcriptsFolderPath))

        keepDaysField.stringValue = String(Config.recordingsKeepDays())
        SettingsUI.show(keepDaysMessage, info: SettingsUI.overrideNote(for: .recordingsKeepDays))
        autoStopField.stringValue = String(Config.autoStopSilenceMinutes())
        SettingsUI.show(autoStopMessage, info: SettingsUI.overrideNote(for: .autoStopSilenceMinutes))
        reloadLaunchAtLogin()
    }

    /// SMAppService is the source of truth — the user can also flip it in
    /// System Settings › General › Login Items, so nothing is cached here.
    private func reloadLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLoginCheckbox.state = (status == .enabled || status == .requiresApproval) ? .on : .off
        switch status {
        case .enabled: launchAtLoginStatus.stringValue = "On"
        case .notRegistered: launchAtLoginStatus.stringValue = "Off"
        case .requiresApproval: launchAtLoginStatus.stringValue = "Waiting for approval in System Settings › Login Items"
        // What macOS reports for a copy it hasn't registered as an app yet
        // (e.g. run straight from a build folder); registering may fix it.
        case .notFound: launchAtLoginStatus.stringValue = "Off (macOS doesn't know this copy of the app yet)"
        @unknown default: launchAtLoginStatus.stringValue = "Unknown"
        }
    }

    @objc private func chooseFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Finished transcripts are written to this folder."
        if let current = Config.transcriptsFolderURL() { panel.directoryURL = current }
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url, let self else { return }
                do {
                    try Settings.shared.setValue(fromString: url.path, for: .transcriptsFolderPath)
                    self.reloadGeneral()
                } catch {
                    SettingsUI.show(self.folderMessage, error: String(describing: error))
                }
            }
        }
    }

    @objc private func revealFolder() {
        guard let url = Config.transcriptsFolderURL() else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            SettingsUI.show(folderMessage, error: "The folder doesn't exist yet; it is created with the first transcript.")
        }
    }

    @objc private func turnFolderOff() {
        Settings.shared.transcriptsFolderPath = nil
        reloadGeneral()
    }

    @objc private func keepDaysChanged() {
        commitCount(keepDaysField, key: .recordingsKeepDays, message: keepDaysMessage, unit: "days")
    }

    @objc private func autoStopChanged() {
        commitCount(autoStopField, key: .autoStopSilenceMinutes, message: autoStopMessage, unit: "minutes")
    }

    /// Whole numbers ≥ 0. The store layer would clamp a negative to 0, but
    /// silently turning "-5" into "keep forever" is worse than saying no.
    private func commitCount(_ field: NSTextField, key: SettingKey, message: NSTextField, unit: String) {
        let raw = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard let n = Int(raw), n >= 0 else {
            SettingsUI.show(message, error: "Enter a whole number of \(unit), 0 or more.")
            return
        }
        // The field also fires when it merely loses focus; an unchanged
        // value must not turn a default into a stored setting.
        guard String(n) != Config.displayValue(for: key) else {
            reloadGeneral()
            return
        }
        do {
            try Settings.shared.setValue(fromString: String(n), for: key)
            reloadGeneral()
        } catch {
            SettingsUI.show(message, error: String(describing: error))
        }
    }

    @objc private func launchAtLoginToggled() {
        do {
            if launchAtLoginCheckbox.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            SettingsUI.show(launchAtLoginMessage, error: nil)
        } catch {
            SettingsUI.show(launchAtLoginMessage, error: "Couldn't change the login item: \(error.localizedDescription)")
        }
        reloadLaunchAtLogin()
    }

    @objc private func runSetupAgain() {
        onRunSetup()
    }

    // MARK: Transcription

    private func buildTranscription() -> NSView {
        let form = FormGrid()

        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)
        form.row("Default model:", modelPopup)
        form.under(SettingsUI.note("New recordings are transcribed with this. Cloud models are listed once cloud transcription is enabled with a key (Cloud tab)."))

        enginePopup.target = self
        enginePopup.action = #selector(engineChanged)
        form.row("System audio engine:", enginePopup)
        form.under(SettingsUI.note("How the other side of a call is captured. The process tap needs only the System Audio Recording grant; ScreenCaptureKit needs Screen Recording. Takes effect on the next recording."))
        form.gap(6)

        languagesField.target = self
        languagesField.action = #selector(languagesChanged)
        languagesField.placeholderString = "en, sv, de"
        form.row("Languages:", [languagesField, NSTextField(labelWithString: "primary first")])
        form.under(SettingsUI.note("Auto-detection picks among these. Use the menubar's Language menu to pin one."))
        form.under(languagesMessage)

        marginField.target = self
        marginField.action = #selector(marginChanged)
        form.row("Language margin:", [marginField, NSTextField(labelWithString: "(0 disables)")])
        form.under(SettingsUI.note("How clearly another language must win before the primary one is dropped for a recording."))
        form.under(marginMessage)
        form.gap(6)

        diarizeCheckbox.target = self
        diarizeCheckbox.action = #selector(diarizeToggled)
        form.row("Speakers:", diarizeCheckbox)

        voiceMemoPopup.addItems(withTitles: ["Transcribe with the default model", "Use the iPhone's own transcript"])
        voiceMemoPopup.target = self
        voiceMemoPopup.action = #selector(voiceMemoChanged)
        form.row("Voice Memos:", voiceMemoPopup)
        form.under(SettingsUI.note("The iPhone transcript is instant but often mangles names."))
        form.gap(6)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bundleID"))
        column.title = "Bundle ID"
        column.isEditable = true
        column.width = SettingsUI.controlColumnWidth - 20
        excludedTable.addTableColumn(column)
        excludedTable.headerView = nil
        excludedTable.dataSource = self
        excludedTable.usesAlternatingRowBackgroundColors = true
        excludedTable.rowHeight = 18
        let scroll = NSScrollView()
        scroll.documentView = excludedTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: SettingsUI.controlColumnWidth).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 76).isActive = true
        form.row("Excluded apps:", scroll)

        addRunningAppPopup.addItem(withTitle: "Add Running App…")
        addRunningAppPopup.menu?.delegate = self
        addRunningAppPopup.target = self
        addRunningAppPopup.action = #selector(addRunningApp(_:))
        let addManual = NSButton(title: "Add…", target: self, action: #selector(addExcludedManually))
        removeExcludedButton.target = self
        removeExcludedButton.action = #selector(removeExcluded)
        form.row(nil, [addRunningAppPopup, addManual, removeExcludedButton])
        form.under(SettingsUI.note("Their audio is kept out of the other side's track — e.g. an audio tool that plays your own mic back out. Applies from the next recording; double-click a row to edit it."))
        form.under(excludedMessage)
        return form.grid
    }

    private func reloadTranscription() {
        reloadModelPopup()
        reloadEnginePopup()
        languagesField.stringValue = Config.sttCandidateLanguages().joined(separator: ", ")
        SettingsUI.show(languagesMessage, info: SettingsUI.overrideNote(for: .sttLanguages))
        marginField.stringValue = String(format: "%g", Config.sttLanguageMargin())
        SettingsUI.show(marginMessage, info: SettingsUI.overrideNote(for: .sttLanguageMargin))
        diarizeCheckbox.state = Config.diarizationEnabled() ? .on : .off
        voiceMemoPopup.selectItem(at: Config.voiceMemoUsesAppleTranscript() ? 1 : 0)
        excludedIDs = Config.systemAudioExcludedBundleIDs()
        excludedTable.reloadData()
        removeExcludedButton.isEnabled = !excludedIDs.isEmpty
        SettingsUI.show(excludedMessage, info: SettingsUI.overrideNote(for: .systemAudioExcludedBundleIDs))
    }

    /// Local models always; the cloud model only while it is actually
    /// usable, so the popup can never offer a choice that resolves to
    /// something else (Config.defaultModel falls back to local).
    private func reloadEnginePopup() {
        enginePopup.removeAllItems()
        for kind in SystemAudioEngineKind.allCases {
            enginePopup.addItem(withTitle: kind.displayName)
            enginePopup.lastItem?.representedObject = kind.rawValue
        }
        let current = Config.systemAudioEngine().rawValue
        if let index = enginePopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == current }) {
            enginePopup.selectItem(at: index)
        }
    }

    @objc private func engineChanged() {
        guard let raw = enginePopup.selectedItem?.representedObject as? String,
              let kind = SystemAudioEngineKind(rawValue: raw) else { return }
        Settings.shared.systemAudioEngine = kind
        rebuildPermissions()
    }

    /// The Permissions rows depend on the engine (Screen Recording for
    /// ScreenCaptureKit, System Audio Recording for taps), and they are
    /// built once; rebuild so the tab matches the choice without reopening
    /// the window. Re-reads the effective engine, so an environment
    /// override that wins over the popup is still reflected truthfully.
    private func rebuildPermissions() {
        guard let index = tabView.tabViewItems.firstIndex(where: { ($0.identifier as? String) == Tab.permissions.rawValue }) else { return }
        tabView.tabViewItem(at: index).view = SettingsUI.page(buildPermissions())
        refreshStatuses()
    }

    private func reloadModelPopup() {
        modelPopup.removeAllItems()
        let cloud = Config.cloudTranscriptionAvailable()
        for model in TranscriptionModel.allCases where model.engine == .whisperKit || cloud {
            modelPopup.addItem(withTitle: model.displayName)
            modelPopup.lastItem?.representedObject = model.rawValue
        }
        let current = Config.defaultModel().rawValue
        if let index = modelPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == current }) {
            modelPopup.selectItem(at: index)
        }
    }

    @objc private func modelChanged() {
        guard let raw = modelPopup.selectedItem?.representedObject as? String,
              let model = TranscriptionModel(rawValue: raw) else { return }
        Settings.shared.defaultModel = model
    }

    @objc private func languagesChanged() {
        let codes = languagesField.stringValue.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !codes.isEmpty else {
            SettingsUI.show(languagesMessage, error: "List at least one language code, e.g. en, sv.")
            return
        }
        if let bad = codes.first(where: { !(2...3).contains($0.count) || !$0.allSatisfy({ $0.isASCII && $0.isLetter }) }) {
            SettingsUI.show(languagesMessage, error: "\"\(bad)\" isn't a language code — use two or three letters like en or sv.")
            return
        }
        guard codes != Config.sttCandidateLanguages() else {
            reloadTranscription()
            return
        }
        do {
            try Settings.shared.setValue(fromString: codes.joined(separator: ","), for: .sttLanguages)
            reloadTranscription()
        } catch {
            SettingsUI.show(languagesMessage, error: String(describing: error))
        }
    }

    @objc private func marginChanged() {
        let raw = marginField.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(raw), value.isFinite, value >= 0 else {
            SettingsUI.show(marginMessage, error: "Enter a number, 0 or more (default 0.2).")
            return
        }
        guard Float(value) != Config.sttLanguageMargin() else {
            reloadTranscription()
            return
        }
        do {
            try Settings.shared.setValue(fromString: String(value), for: .sttLanguageMargin)
            reloadTranscription()
        } catch {
            SettingsUI.show(marginMessage, error: String(describing: error))
        }
    }

    @objc private func diarizeToggled() {
        Settings.shared.diarizeEnabled = diarizeCheckbox.state == .on
    }

    @objc private func voiceMemoChanged() {
        Settings.shared.voiceMemoUsesAppleTranscript = voiceMemoPopup.indexOfSelectedItem == 1
    }

    private func saveExcluded() {
        // Duplicates and blanks out; order kept as the user arranged it.
        var seen = Set<String>()
        excludedIDs = excludedIDs
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        Settings.shared.systemAudioExcludedBundleIDs = excludedIDs
        reloadTranscription()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu == addRunningAppPopup.menu else { return }
        // Item 0 is the pull-down's title.
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        let own = Bundle.main.bundleIdentifier
        var seen = Set(excludedIDs)
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }
            .compactMap { app -> (String, String)? in
                guard let id = app.bundleIdentifier, id != own else { return nil }
                return (app.localizedName ?? id, id)
            }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
        for (name, id) in apps where seen.insert(id).inserted {
            let item = NSMenuItem(title: "\(name) — \(id)", action: nil, keyEquivalent: "")
            item.representedObject = id
            menu.addItem(item)
        }
        if menu.items.count == 1 {
            let none = NSMenuItem(title: "No other running apps", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
    }

    @objc private func addRunningApp(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        excludedIDs.append(id)
        saveExcluded()
    }

    @objc private func addExcludedManually() {
        excludedIDs.append("com.example.app")
        excludedTable.reloadData()
        let row = excludedIDs.count - 1
        excludedTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        excludedTable.editColumn(0, row: row, with: nil, select: true)
        removeExcludedButton.isEnabled = true
    }

    @objc private func removeExcluded() {
        let row = excludedTable.selectedRow >= 0 ? excludedTable.selectedRow : excludedIDs.count - 1
        guard excludedIDs.indices.contains(row) else { return }
        excludedIDs.remove(at: row)
        saveExcluded()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { excludedIDs.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        excludedIDs.indices.contains(row) ? excludedIDs[row] : nil
    }

    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard excludedIDs.indices.contains(row), let value = object as? String else { return }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty && (trimmed.contains(where: \.isWhitespace) || trimmed.contains(",")) {
            SettingsUI.show(excludedMessage, error: "A bundle ID has no spaces or commas, e.g. com.example.audio-tool.")
            return
        }
        excludedIDs[row] = trimmed
        saveExcluded()
    }

    // MARK: Cloud

    private func buildCloud() -> NSView {
        let form = FormGrid()
        cloudCheckbox.target = self
        cloudCheckbox.action = #selector(cloudToggled)
        form.row("Cloud:", cloudCheckbox)
        form.under(SettingsUI.note("Offers OpenAI's gpt-4o-transcribe-diarize as a model (default or Re-transcribe). Audio is sent to OpenAI only when a cloud model is chosen; the local models never leave this Mac."))
        form.gap()

        keyField.placeholderString = "sk-…"
        keyField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        form.row("OpenAI API key:", keyField)
        let save = NSButton(title: "Save", target: self, action: #selector(saveKey))
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeKey))
        testKeyButton.target = self
        testKeyButton.action = #selector(testKeyClicked)
        form.row(nil, [save, remove, testKeyButton])
        form.under(keyStatusLabel)
        form.under(keyMessage)
        form.under(SettingsUI.note("The key is stored in your login Keychain, never in a file. Test Key makes one request to api.openai.com/v1/models with it."))
        return form.grid
    }

    private func reloadCloud() {
        cloudCheckbox.state = Config.cloudTranscriptionEnabled() ? .on : .off
        let source = Config.resolve(.openAIKey)?.source
        switch source {
        case .keychain?: keyStatusLabel.stringValue = "A key is saved in the Keychain."
        case .env?: keyStatusLabel.stringValue = "Using the OPENAI_API_KEY environment variable (developer override)."
        case .dotEnv?: keyStatusLabel.stringValue = "Using the key from the .env file (developer override). Save one here to move it to the Keychain."
        default: keyStatusLabel.stringValue = "No key saved."
        }
        testKeyButton.isEnabled = source != nil || !keyField.stringValue.isEmpty
        if Config.cloudTranscriptionEnabled() && source == nil {
            SettingsUI.show(keyMessage, info: "Cloud models stay hidden until a key is saved.")
        }
        reloadModelPopup()
        reloadEnginePopup()
    }

    @objc private func cloudToggled() {
        Settings.shared.cloudTranscriptionEnabled = cloudCheckbox.state == .on
        SettingsUI.show(keyMessage, error: nil)
        reloadCloud()
    }

    @objc private func saveKey() {
        let value = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            SettingsUI.show(keyMessage, error: "Paste a key first.")
            return
        }
        do {
            try Settings.shared.setOpenAIKey(value)
            keyField.stringValue = ""
            SettingsUI.show(keyMessage, info: "Saved.")
        } catch {
            SettingsUI.show(keyMessage, error: String(describing: error))
        }
        reloadCloud()
    }

    @objc private func removeKey() {
        do {
            try Settings.shared.deleteOpenAIKey()
            SettingsUI.show(keyMessage, info: Config.resolve(.openAIKey) == nil
                ? "Removed."
                : "Removed from the Keychain; a developer override still supplies one.")
        } catch {
            SettingsUI.show(keyMessage, error: String(describing: error))
        }
        reloadCloud()
    }

    /// The last Test Key outcome's HTTP status (nil inside = no response),
    /// for the --settings-window harness, which must not print the key.
    private(set) var lastKeyTestStatus: Int??

    @objc func testKeyClicked() {
        testKeyButton.isEnabled = false
        SettingsUI.show(keyMessage, info: "Testing…")
        Task { @MainActor in
            let result = await testOpenAIKey()
            lastKeyTestStatus = .some(result.status)
            SettingsUI.show(keyMessage, error: nil)
            if result.ok {
                SettingsUI.show(keyMessage, info: result.message)
            } else {
                SettingsUI.show(keyMessage, error: result.message)
            }
            testKeyButton.isEnabled = true
        }
    }

    /// One GET /v1/models with the typed key (or the saved one). Only the
    /// status is reported — the response lists models, nothing secret, but
    /// there's no reason to show it.
    func testOpenAIKey() async -> (ok: Bool, status: Int?, message: String) {
        let typed = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typed.isEmpty ? (try? Config.openAIKey()) : typed
        guard let key, let url = URL(string: "https://api.openai.com/v1/models") else {
            return (false, nil, "No key to test.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        do {
            let (_, response) = try await HTTP.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            settingsWindowLog.notice("openai key test: HTTP \(status, privacy: .public)")
            switch status {
            case 200: return (true, status, "OK — the key works (HTTP 200).")
            case 401: return (false, status, "Rejected: the key is invalid or revoked (HTTP 401).")
            case 429: return (false, status, "The key works but is rate-limited or out of credit (HTTP 429).")
            default: return (false, status, "OpenAI answered HTTP \(status).")
            }
        } catch {
            return (false, nil, "Couldn't reach OpenAI: \(error.localizedDescription)")
        }
    }

    // MARK: Calendar

    private func buildCalendar() -> NSView {
        let form = FormGrid()
        calendarSourcePopup.target = self
        calendarSourcePopup.action = #selector(calendarSourceChanged)
        form.row("Meetings from:", calendarSourcePopup)
        form.under(SettingsUI.note("A few minutes before a meeting with a Zoom, Meet or Teams link, \(SettingsUI.appName) offers to record it and names the transcript after the event."))
        form.gap()

        calendarGrantButton.target = self
        calendarGrantButton.action = #selector(grantCalendarAccess)
        let accessLabel = NSTextField(labelWithString: "Access:")
        let accessRow = SettingsUI.hstack([calendarStatusLabel, calendarGrantButton])
        form.grid.addRow(with: [accessLabel, accessRow])
        let eventKitNote = SettingsUI.note("macOS Calendar reads the accounts set up in the Calendar app (iCloud, Google, Exchange, CalDAV) — add or remove them in Calendar › Settings › Accounts. Nothing leaves this Mac.")
        form.under(eventKitNote)
        eventKitViews = [accessLabel, accessRow, eventKitNote]
        form.under(calendarMessage)
        return form.grid
    }

    private func reloadCalendar() {
        let current = Settings.shared.calendarSource
        calendarSourcePopup.removeAllItems()
        for source in CalendarSource.allCases {
            calendarSourcePopup.addItem(withTitle: source.displayName)
            calendarSourcePopup.lastItem?.representedObject = source.rawValue
        }
        if let index = calendarSourcePopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == current.rawValue }) {
            calendarSourcePopup.selectItem(at: index)
        }
        eventKitViews.forEach { SettingsUI.setHidden($0, current != .eventkit) }
        refreshCalendarStatus()
    }

    private func refreshCalendarStatus() {
        let status = Permissions.calendar()
        calendarStatusLabel.stringValue = status.text
        calendarStatusLabel.textColor = status.color
        let determined = EventKitCalendar.authorizationStatus != .notDetermined
        calendarGrantButton.title = determined ? "Open System Settings…" : "Grant Calendar Access…"
        calendarGrantButton.isHidden = EventKitCalendar.isAuthorized
    }

    @objc private func calendarSourceChanged() {
        guard let raw = calendarSourcePopup.selectedItem?.representedObject as? String,
              let source = CalendarSource(rawValue: raw) else { return }
        Settings.shared.calendarSource = source
        SettingsUI.show(calendarMessage, error: nil)
        reloadCalendar()
    }

    /// Asks once; after a decision macOS won't show the prompt again, so a
    /// denial is undone in System Settings.
    @objc func grantCalendarAccess() {
        guard EventKitCalendar.authorizationStatus == .notDetermined else {
            Permissions.open(.calendars)
            return
        }
        Task { @MainActor in
            do {
                _ = try await EventKitCalendar.requestAccess()
            } catch {
                SettingsUI.show(calendarMessage, error: "Calendar access request failed: \(error.localizedDescription)")
            }
            refreshStatuses()
        }
    }

    // MARK: Permissions

    private func buildPermissions() -> NSView {
        // Rebuilt on engine changes: drop the previous engine's row.
        screenRow = nil
        systemAudioRow = nil
        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.rowSpacing = 4
        grid.columnSpacing = 12
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).width = 190
        grid.column(at: 1).width = 220

        func add(_ name: String, why: String, button: String, action: Selector) -> PermissionRow {
            if grid.numberOfRows > 0 {
                grid.addRow(with: [NSGridCell.emptyContentView]).height = 10
            }
            let title = NSTextField(labelWithString: name)
            title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            let status = NSTextField(wrappingLabelWithString: "")
            status.preferredMaxLayoutWidth = 220
            let button = NSButton(title: button, target: self, action: action)
            grid.addRow(with: [title, status, button])
            let note = SettingsUI.note(why, width: 560)
            let row = grid.addRow(with: [note])
            row.mergeCells(in: NSRange(location: 0, length: 3))
            return PermissionRow(status: status, button: button)
        }

        micRow = add("Microphone", why: "Records your side of the meeting.",
                     button: "Request Access…", action: #selector(microphoneButton))
        switch Permissions.systemAudioEngine {
        case .sck:
            screenRow = add("Screen Recording", why: "The other side of the call is captured with ScreenCaptureKit, which macOS files under Screen & System Audio Recording. Only audio is used; no screen image is ever saved.",
                            button: "Request Access…", action: #selector(screenRecordingButton))
        case .taps:
            systemAudioRow = add("System Audio Recording", why: "The other side of the call is captured with a Core Audio process tap. macOS has no way to ask whether it's granted; the first recording shows it (a denied tap records silence).",
                                 button: "Open System Settings…", action: #selector(systemAudioButton))
        }
        calendarRow = add("Calendar", why: "Only for the macOS Calendar source: reads upcoming meetings so you're offered to record them.",
                          button: "Grant Access…", action: #selector(grantCalendarAccess))
        fdaRow = add("Full Disk Access", why: "Needed only for Import Voice Memos…: the iPhone memos synced through iCloud live in another app's protected folder. macOS never prompts for this — switch \(SettingsUI.appName) on in the list, then relaunch it.",
                     button: "Open System Settings…", action: #selector(fullDiskAccessButton))
        let footer = SettingsUI.note("Statuses refresh every two seconds while this window is open.", width: 560)
        grid.addRow(with: [NSGridCell.emptyContentView]).height = 8
        grid.addRow(with: [footer]).mergeCells(in: NSRange(location: 0, length: 3))
        return grid
    }

    /// Cheap reads only (TCC lookups, one directory listing), so a 2 s
    /// cadence costs nothing; the FDA probe runs only while its tab shows.
    private func refreshStatuses() {
        refreshCalendarStatus()
        guard tabView.selectedTabViewItem?.identifier as? String == Tab.permissions.rawValue else { return }

        func apply(_ row: PermissionRow?, _ status: PermissionStatus) {
            row?.status.stringValue = status.text
            row?.status.textColor = status.color
        }
        apply(micRow, Permissions.microphone())
        let micUndetermined = AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        micRow?.button.title = micUndetermined ? "Request Access…" : "Open System Settings…"

        if let screenRow {
            apply(screenRow, Permissions.screenRecording())
            screenRow.button.title = screenRecordingRequested || CGPreflightScreenCaptureAccess()
                ? "Open System Settings…" : "Request Access…"
        }
        apply(systemAudioRow, Permissions.systemAudioRecording())

        apply(calendarRow, Permissions.calendar())
        calendarRow?.button.title = EventKitCalendar.authorizationStatus == .notDetermined ? "Grant Access…" : "Open System Settings…"

        apply(fdaRow, Permissions.fullDiskAccess())
    }

    @objc private func microphoneButton() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            Permissions.open(.microphone)
            return
        }
        Task { @MainActor in
            _ = await Permissions.requestMicrophone()
            refreshStatuses()
        }
    }

    /// The first request adds the app to the Screen Recording list (macOS
    /// shows its own alert); after that the switch lives in System Settings.
    @objc private func screenRecordingButton() {
        if !screenRecordingRequested && !CGPreflightScreenCaptureAccess() {
            screenRecordingRequested = true
            _ = CGRequestScreenCaptureAccess()
        } else {
            Permissions.open(.screenRecording)
        }
        refreshStatuses()
    }

    @objc private func systemAudioButton() {
        Permissions.open(.screenRecording)
    }

    @objc private func fullDiskAccessButton() {
        Permissions.open(.fullDiskAccess)
    }
}

// Tab switches refresh the permission rows at once instead of on the next
// timer tick.
extension SettingsWindowController: NSTabViewDelegate {
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        refreshStatuses()
    }
}
