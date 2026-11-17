// A system-wide keyboard shortcut through Carbon's RegisterEventHotKey.
// Unlike an NSEvent global monitor it needs no Accessibility permission, and
// it swallows the keystroke, so the frontmost app never sees it. Carbon
// delivers the event on the main run loop.

import Carbon.HIToolbox
import Foundation
import os.log

private let hotKeyLog = Logger(subsystem: "com.jwiderberg.minnas", category: "HotKey")

@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: @MainActor () -> Void

    /// `keyCode` is a virtual key (`kVK_ANSI_R`), `modifiers` Carbon flags
    /// (`cmdKey | optionKey | controlKey`). nil when another app already
    /// holds the combination or registration fails; that is logged.
    init?(keyCode: Int, modifiers: Int, label: String, action: @escaping @MainActor () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), globalHotKeyHandler, 1, &spec, me, &handlerRef)
        guard installed == noErr else {
            hotKeyLog.error("hotkey \(label, privacy: .public): InstallEventHandler failed (\(installed))")
            return nil
        }
        let id = EventHotKeyID(signature: OSType(0x4D52_484B), id: 1) // 'MRHK'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            hotKeyLog.error("hotkey \(label, privacy: .public) not registered (\(status)); another app may hold it")
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
        hotKeyLog.notice("hotkey \(label, privacy: .public) registered")
    }

    fileprivate func fire() { action() }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}

/// C callback: a free function, so it carries no actor isolation of its own.
private func globalHotKeyHandler(
    _ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let raw = UInt(bitPattern: userData)
    MainActor.assumeIsolated {
        let pointer = UnsafeMutableRawPointer(bitPattern: raw)!
        Unmanaged<GlobalHotKey>.fromOpaque(pointer).takeUnretainedValue().fire()
    }
    return noErr
}

/// The menu bar item's pure rules, kept out of AppDelegate so they can be
/// tested.
enum StatusItemPolicy {
    /// The text beside the red dot while recording: " 0:42 ▆ ▁", or nothing
    /// in hidden mode, where the dot alone shows that a recording is on.
    static func recordingTitle(elapsed: String, micBar: String, systemBar: String, hidden: Bool) -> String {
        hidden ? "" : " \(elapsed) \(micBar) \(systemBar)"
    }

    /// While recording, a plain click toggles hidden mode; Option- or
    /// Control-click (Control-click is the Mac's secondary click, as is a
    /// two-finger tap) opens the menu.
    static func clickOpensMenu(isRightClick: Bool, option: Bool, control: Bool) -> Bool {
        isRightClick || option || control
    }

    /// Title for a recording started with the shortcut:
    /// "Recording 2026-11-17 13:05", in the given time zone.
    static func quickRecordingTitle(at date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "Recording \(f.string(from: date))"
    }
}
