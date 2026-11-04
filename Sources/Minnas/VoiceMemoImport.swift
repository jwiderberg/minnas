//
// Importing iPhone Voice Memos into the outbox.
//
// Two halves:
//   VoiceMemoImporter — the headless core (shared by the menubar window and
//     the --import-memo CLI harness): copies the memo's audio into a fresh
//     outbox slot as the single "system" stream, writes meta with the
//     user's title, and leaves it for the normal STT engines (the caller
//     runs TranscriptionJob on it, exactly like a Mac recording). With
//     VOICE_MEMO_TRANSCRIPT=apple and a memo that carries Apple's on-device
//     transcript, it writes transcript.md straight away from that instead.
//   VoiceMemoImportWindowController — the picker: recent memos, a checkbox
//     per row, an editable title (iOS defaults the title to the nearby
//     location, which is useless as a note title), and an Import button.
//     The list is live: a poll of the library's fingerprint
//     (VoiceMemoLibrary.changeSignature, every few seconds and whenever the
//     window regains focus) reloads it on change — a memo recorded on the
//     phone shows up a few seconds after it syncs, and a "not synced" one
//     turns importable when its file lands — and the Refresh button
//     reloads unconditionally. The Mac pulls memos from iCloud only while
//     Voice Memos.app is running (CloudKit sync is driven by the app — a
//     memo recorded on the phone hours ago is simply absent until then), so
//     "Sync from iCloud" launches Voice Memos hidden in the background and
//     the poll shows arrivals. Ticks and edited titles survive a reload
//     (matched by memo id); a reload never interrupts a title edit in
//     progress. AppDelegate drops the controller when the
//     window closes (Cancel included), so reopening never shows an old list.
//
// The imported slot behaves like any other recording afterwards: it shows
// in the Recordings menu, can be re-transcribed with another model (the
// cloud diarize model splits speakers as "Speaker (A)" / "Speaker (B)"),
// and is written to the transcripts folder like any meeting.
//

import AppKit
import Foundation
import os.log

private let importLog = Logger(subsystem: "com.jwiderberg.minnas", category: "VoiceMemoImport")

enum VoiceMemoImporter {
    /// Provenance recorded when Apple's embedded transcript is used verbatim.
    static let appleEngine = "apple-voicememos"
    static let appleModel = "ios-on-device"

    struct Result {
        let slot: OutboxSlot
        let meta: RecordingMeta
        /// True when Apple's transcript was present and has been written as
        /// the transcript. False means the caller must run STT on the slot.
        let usedAppleTranscript: Bool
    }

    enum ImportError: Error, CustomStringConvertible {
        case notDownloaded(String)
        var description: String {
            switch self {
            case .notDownloaded(let title):
                return "\"\(title)\" hasn't finished syncing from iCloud yet. Open it once in Voice Memos on this Mac, then import again."
            }
        }
    }

    /// Creates the outbox slot for `memo` under `title`. Audio is copied
    /// (m4a) or transcoded (qta → m4a) into the slot's compressed system
    /// stream, so nothing in the Voice Memos library is ever touched.
    static func prepare(memo: VoiceMemo, title: String) async throws -> Result {
        guard memo.isDownloaded else { throw ImportError.notDownloaded(memo.displayTitle) }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = cleanTitle.isEmpty ? memo.displayTitle : cleanTitle

        let slot = try Outbox.makeSlot(title: finalTitle, startedAt: memo.recordedAt)
        let fm = FileManager.default
        do {
            if memo.fileURL.pathExtension.lowercased() == "m4a" {
                try fm.copyItem(at: memo.fileURL, to: slot.systemCompressedURL)
            } else {
                // .qta: AAC stereo + a disabled APAC track + metadata tracks.
                // AppleM4A export keeps the enabled AAC track only.
                try await AudioExport.transcodeToM4A(source: memo.fileURL, destination: slot.systemCompressedURL)
            }
        } catch {
            try? fm.removeItem(at: slot.dirURL)
            throw error
        }

        var meta = RecordingMeta(
            title: finalTitle,
            started_at: memo.recordedAt,
            ended_at: memo.recordedAt.addingTimeInterval(max(1, memo.duration)),
            device: AppInfo.voiceMemoDevice,
            client_version: AppInfo.version
        )
        meta.capture_kind = RecordingMeta.voiceMemoCaptureKind
        try Outbox.writeMeta(meta, to: slot.metaURL)

        // Default: leave the slot for the STT engines (Large v3), exactly
        // like a Mac recording — Apple's on-device transcript is quick but
        // too loose with names. VOICE_MEMO_TRANSCRIPT=apple opts back in.
        guard Config.voiceMemoUsesAppleTranscript() else {
            importLog.notice("imported \(slot.slug, privacy: .public) — Apple transcript not wanted, needs STT")
            return Result(slot: slot, meta: meta, usedAppleTranscript: false)
        }

        // Apple's transcript is read from the ORIGINAL file — the export
        // drops the metadata tracks.
        let apple: STTResult?
        do { apple = try await VoiceMemoLibrary.appleTranscript(for: memo.fileURL) } catch {
            importLog.error("apple transcript read failed for \(memo.id, privacy: .public): \(String(describing: error), privacy: .public); falling back to STT")
            apple = nil
        }
        guard let apple, !apple.segments.isEmpty else {
            importLog.notice("imported \(slot.slug, privacy: .public) — no Apple transcript, needs STT")
            return Result(slot: slot, meta: meta, usedAppleTranscript: false)
        }
        try TranscriptionJob.finish(
            slot: slot, meta: meta, micResults: [], systemResults: [apple],
            provenance: TranscriptionProvenance(engine: appleEngine, model: appleModel, transcribed_at: Date())
        )
        importLog.notice("imported \(slot.slug, privacy: .public) with Apple transcript (\(apple.segments.count, privacy: .public) segments)")
        return Result(slot: slot, meta: meta, usedAppleTranscript: true)
    }
}

// MARK: - Picker window

@MainActor
final class VoiceMemoImportWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    struct Selection {
        let memo: VoiceMemo
        let title: String
    }

    private final class Row {
        let memo: VoiceMemo
        var title: String
        var selected = false
        var transcriptLabel: String
        /// Stamp of the audio file when the row was built; a probed label
        /// is carried across reloads only while this is unchanged.
        let fileStamp: String?
        init(memo: VoiceMemo) {
            self.memo = memo
            self.title = memo.displayTitle
            self.transcriptLabel = memo.isDownloaded ? "checking…" : "not synced"
            self.fileStamp = memo.isDownloaded ? VoiceMemoLibrary.fileStamp(memo.fileURL) : nil
        }
    }

    private var rows: [Row] = []
    private let table = NSTableView()
    private let importButton = NSButton(title: "Import Selected", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    /// Shown only when the library is TCC-blocked; opens the Full Disk
    /// Access pane, where the app is already listed (switched off).
    private let grantAccessButton = NSButton(title: "Open Full Disk Access…", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let syncButton = NSButton(title: "Sync from iCloud", target: nil, action: nil)
    private static let voiceMemosBundleID = "com.apple.VoiceMemos"
    /// The two halves of the status line: what the last load found, and
    /// what the Sync button is up to. Kept apart so a reload never erases
    /// the sync message and a late sync callback never erases the count.
    private var loadStatus = ""
    private var syncStatus: String?
    private let onImport: ([Selection]) -> Void
    private let onClose: () -> Void
    /// Fingerprint of the library at the last SUCCESSFUL load (nil after a
    /// failed one, so the next tick retries); the poll compares against it
    /// so an unchanged library costs a round of stats, never a DB copy.
    private var loadedSignature: String?
    private var pollTimer: Timer?
    /// A fingerprint is in flight off the main thread; ticks don't stack.
    private var polling = false
    private static let pollInterval: TimeInterval = 3

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    init(onImport: @escaping ([Selection]) -> Void, onClose: @escaping () -> Void = {}) {
        self.onImport = onImport
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Import Voice Memos"
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        load(reason: "open")
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollLibrary() }
        }
    }

    // MARK: NSWindowDelegate

    /// Coming back to the window (from Voice Memos on the Mac, say, after
    /// opening a memo there to force its download) checks the library at
    /// once rather than waiting for the next poll tick.
    func windowDidBecomeKey(_ notification: Notification) {
        pollLibrary()
    }

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        onClose()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        func column(_ id: String, _ title: String, width: CGFloat, editable: Bool = false) -> NSTableColumn {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.isEditable = editable
            return c
        }
        let check = column("import", "", width: 24)
        check.dataCell = {
            let cell = NSButtonCell()
            cell.setButtonType(.switch)
            cell.title = ""
            return cell
        }()
        table.addTableColumn(check)
        table.addTableColumn(column("title", "Title (edit before importing)", width: 320, editable: true))
        table.addTableColumn(column("recorded", "Recorded", width: 150))
        table.addTableColumn(column("length", "Length", width: 60))
        table.addTableColumn(column("transcript", "Transcript", width: 110))
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.rowHeight = 20

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(wrappingLabelWithString:
            "Tick the memos to import and fix their titles — iOS names a memo after wherever you were standing. " +
            (Config.voiceMemoUsesAppleTranscript()
                ? "Memos recorded on iOS 26 bring Apple's own transcript; older ones are transcribed with the current model."
                : "Each memo is transcribed with the default model (\(Config.defaultModel().rawValue)), like a Mac recording."))
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        grantAccessButton.target = self
        grantAccessButton.action = #selector(openFullDiskAccess)
        grantAccessButton.isHidden = true

        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.toolTip = "The list updates on its own as memos sync; this forces it."

        syncButton.target = self
        syncButton.action = #selector(syncTapped)
        syncButton.toolTip = "Memos reach this Mac only while Voice Memos is running. Launches it in the background; new memos appear here as they arrive."

        importButton.target = self
        importButton.action = #selector(importTapped)
        importButton.keyEquivalent = "\r"
        importButton.isEnabled = false
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [statusLabel, grantAccessButton, syncButton, refreshButton, NSView(), cancel, importButton])
        buttons.orientation = .horizontal
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(hint)
        content.addSubview(scroll)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    /// (Re)reads the library. Existing rows keep their tick, an edited
    /// title and an already-probed transcript label; a row whose file has
    /// since synced is rebuilt so it becomes tickable and gets probed.
    private func load(reason: String) {
        importLog.notice("picker load (\(reason, privacy: .public))")
        // Taken BEFORE the read, so a change that lands mid-read makes the
        // next poll re-read; accepted only AFTER a successful read, so a
        // transient failure (torn WAL copy, say) is retried on the next
        // tick instead of being masked by an already-recorded signature.
        let signature = VoiceMemoLibrary.changeSignature()
        let previous = Dictionary(rows.map { ($0.memo.id, $0) }, uniquingKeysWith: { a, _ in a })
        do {
            let fresh = try VoiceMemoLibrary.list(limit: 50)
            loadedSignature = signature
            rows = fresh.map { memo in
                let row = Row(memo: memo)
                guard let old = previous[memo.id] else { return row }
                row.selected = old.selected && memo.isDownloaded
                // Keep a title the user typed; otherwise follow a rename
                // made in Voice Memos itself.
                if old.title != old.memo.displayTitle { row.title = old.title }
                if old.fileStamp != nil && old.fileStamp == row.fileStamp { row.transcriptLabel = old.transcriptLabel }
                return row
            }
            loadStatus = rows.isEmpty ? "No voice memos found." : "\(rows.count) recent memos"
            grantAccessButton.isHidden = true
        } catch {
            // Forget the signature so the next tick with a readable folder
            // retries. A folder that can't even be stat'ed (Full Disk
            // Access missing — fixing that needs a relaunch anyway) stays
            // on the message and the Refresh button rather than retrying
            // every 3 s.
            loadedSignature = nil
            loadStatus = String(describing: error)
            if case VoiceMemoLibraryError.accessDenied? = error as? VoiceMemoLibraryError {
                grantAccessButton.isHidden = false
            }
        }
        updateStatusLabel()
        table.reloadData()
        updateImportButton()
        probeTranscripts()
    }

    /// Reloads unless a title edit is in progress — `reloadData` would
    /// end the field editor and drop what was typed.
    private func reloadIfIdle(reason: String) {
        guard table.editedRow == -1, window?.isVisible == true else { return }
        load(reason: reason)
    }

    /// Timer tick: fingerprint the library off the main thread (a stat per
    /// file in the folder — a few ms for a big library, but not on the UI
    /// thread); a real reload only on change.
    private func pollLibrary() {
        guard !polling else { return }
        polling = true
        Task { @MainActor [weak self] in
            let signature = await Task.detached(priority: .utility) { VoiceMemoLibrary.changeSignature() }.value
            guard let self else { return }
            self.polling = false
            guard signature != self.loadedSignature else { return }
            self.reloadIfIdle(reason: "library changed")
        }
    }

    private func updateStatusLabel() {
        statusLabel.stringValue = [loadStatus, syncStatus].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Launches Voice Memos hidden. macOS syncs the Voice Memos library
    /// from iCloud only while the app runs, so this is the one way to make
    /// a memo recorded on the phone show up here; the poll does the rest.
    @objc private func syncTapped() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.voiceMemosBundleID) else {
            syncStatus = "Voice Memos is not installed on this Mac."
            updateStatusLabel()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        syncButton.isEnabled = false
        syncStatus = "Launching Voice Memos in the background…"
        updateStatusLabel()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncButton.isEnabled = true
                if let error {
                    importLog.error("voice memos launch failed: \(String(describing: error), privacy: .public)")
                    self.syncStatus = "Could not launch Voice Memos: \(error.localizedDescription)"
                } else {
                    importLog.notice("voice memos launched hidden for iCloud sync")
                    self.syncStatus = "Voice Memos is open in the background; new memos appear here as they arrive."
                }
                self.updateStatusLabel()
            }
        }
    }

    @objc private func refreshTapped() {
        if table.editedRow != -1 { window?.makeFirstResponder(nil) }
        load(reason: "refresh button")
    }

    @objc private func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Fills the Transcript column by reading each downloaded memo's
    /// metadata. Cheap (local file headers), but async so the window opens
    /// instantly.
    private func probeTranscripts() {
        for (index, row) in rows.enumerated() where row.memo.isDownloaded && row.transcriptLabel == "checking…" {
            let url = row.memo.fileURL
            let stamp = row.fileStamp
            Task { @MainActor [weak self] in
                // Informational either way: with the default (STT) policy
                // it just tells the user the phone had a transcript too.
                let label: String
                if let r = try? await VoiceMemoLibrary.appleTranscript(for: url), !r.segments.isEmpty {
                    let lang = r.language.isEmpty ? "?" : r.language
                    label = Config.voiceMemoUsesAppleTranscript() ? "Apple (\(lang))" : "STT (Apple \(lang) available)"
                } else {
                    label = Config.voiceMemoUsesAppleTranscript() ? "needs STT" : "STT"
                }
                // The rows may have been rebuilt meanwhile: write only if
                // the row at this index is still the same memo AND the
                // same file version (a rewritten file got its own probe).
                guard let self, index < self.rows.count,
                      self.rows[index].memo.id == row.memo.id,
                      self.rows[index].fileStamp == stamp else { return }
                self.rows[index].transcriptLabel = label
                self.table.reloadData(forRowIndexes: IndexSet(integer: index),
                                      columnIndexes: IndexSet(integer: 4))
            }
        }
    }

    private func updateImportButton() {
        let n = rows.filter(\.selected).count
        importButton.isEnabled = n > 0
        importButton.title = n > 0 ? "Import \(n) Selected" : "Import Selected"
    }

    @objc private func importTapped() {
        let picked = rows.filter(\.selected).map { Selection(memo: $0.memo, title: $0.title) }
        guard !picked.isEmpty else { return }
        close()
        onImport(picked)
    }

    @objc private func cancelTapped() { close() }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row < rows.count, let id = tableColumn?.identifier.rawValue else { return nil }
        let r = rows[row]
        switch id {
        case "import": return r.selected ? NSControl.StateValue.on.rawValue : NSControl.StateValue.off.rawValue
        case "title": return r.title
        case "recorded": return Self.dateFormatter.string(from: r.memo.recordedAt)
        case "length":
            let s = Int(r.memo.duration.rounded())
            return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                             : String(format: "%d:%02d", s / 60, s % 60)
        case "transcript": return r.transcriptLabel
        default: return nil
        }
    }

    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard row < rows.count, let id = tableColumn?.identifier.rawValue else { return }
        switch id {
        case "import":
            guard rows[row].memo.isDownloaded else { return }
            rows[row].selected = (object as? Int) == NSControl.StateValue.on.rawValue
            updateImportButton()
        case "title":
            rows[row].title = (object as? String) ?? rows[row].title
        default:
            break
        }
    }

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool {
        tableColumn?.identifier.rawValue == "title"
    }

    func tableView(_ tableView: NSTableView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, row: Int) {
        guard row < rows.count, let cell = cell as? NSCell else { return }
        let downloaded = rows[row].memo.isDownloaded
        cell.isEnabled = downloaded || tableColumn?.identifier.rawValue != "import"
        if let text = cell as? NSTextFieldCell {
            text.textColor = downloaded ? .labelColor : .tertiaryLabelColor
        }
    }
}
