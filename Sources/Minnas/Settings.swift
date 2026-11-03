//
// The persistent home of every user-facing setting: UserDefaults for plain
// values, the login keychain (KeychainStore) for secrets. Config resolves
// from here — this file stores and validates, it does not decide
// precedence (env var > Settings > .env > default; see Config.swift).
//
// Two layers:
//   - SettingsStorage: nonisolated, stateless functions over
//     UserDefaults.standard (itself thread-safe) and the keychain. Config's
//     accessors run on background threads (transcription, delivery), so the
//     resolver reads through this layer and never touches the MainActor.
//   - Settings: the @MainActor typed facade for UI code (the menubar and
//     the Settings window). Same storage, typed properties.
//
// Keys are namespaced `settings.<name>`, except `sttLanguage`, which is
// written by the menubar's Language submenu under its own short key.
//
// The stored form is typed (Int, Bool, Double, [String], String), but the
// resolver consumes everything as the same string syntax the .env file
// uses (`storedRaw`), so Config's existing parsers handle all three layers
// identically.
//

import Foundation
import os.log

private let settingsLog = Logger(subsystem: "com.jwiderberg.minnas", category: "Settings")

enum SettingKind: Sendable, Equatable {
    case path        // absolute folder path; `~` expanded on write
    case email
    case int         // non-negative; negatives clamp to 0, as Config always did
    case float
    case bool
    case stringList  // comma-separated in .env syntax
    case choice([String])
    case model       // a TranscriptionModel raw value
    case secret      // keychain, never UserDefaults

    var label: String {
        switch self {
        case .path: return "path"
        case .email: return "email"
        case .int: return "int"
        case .float: return "float"
        case .bool: return "bool"
        case .stringList: return "list"
        case .choice(let options): return options.joined(separator: "|")
        case .model: return TranscriptionModel.allCases.map(\.rawValue).joined(separator: "|")
        case .secret: return "secret"
        }
    }
}

/// Every setting, in display order. `name` is what the harness and the
/// UI address it by; `envKey` is the .env / environment-variable name
/// (nil for settings that only ever lived in the UI).
enum SettingKey: String, CaseIterable, Sendable {
    case transcriptsFolderPath
    case recordingsKeepDays
    case autoStopSilenceMinutes
    case defaultModel
    case sttLanguage
    case sttLanguages
    case sttLanguageMargin
    case cloudTranscriptionEnabled
    case calendarSource
    case systemAudioExcludedBundleIDs
    case systemAudioEngine
    case diarizeEnabled
    case voiceMemoUsesAppleTranscript
    case micVoiceProcessingMode
    case dedupeStreams
    case ownerEmail
    case onboardingCompleted
    case openAIKey

    var name: String { rawValue }

    var kind: SettingKind {
        switch self {
        case .transcriptsFolderPath: return .path
        case .recordingsKeepDays, .autoStopSilenceMinutes: return .int
        case .defaultModel: return .model
        case .sttLanguage: return .choice(["auto", "en", "sv"])
        case .sttLanguages, .systemAudioExcludedBundleIDs: return .stringList
        case .sttLanguageMargin: return .float
        case .cloudTranscriptionEnabled, .diarizeEnabled,
             .voiceMemoUsesAppleTranscript, .dedupeStreams, .onboardingCompleted: return .bool
        case .calendarSource: return .choice(CalendarSource.allCases.map(\.rawValue))
        case .micVoiceProcessingMode: return .choice(["auto", "on", "off"])
        case .systemAudioEngine: return .choice(SystemAudioEngineKind.allCases.map(\.rawValue))
        case .ownerEmail: return .email
        case .openAIKey: return .secret
        }
    }

    var isSecret: Bool { kind == .secret }

    var envKey: String? {
        switch self {
        case .transcriptsFolderPath: return "TRANSCRIPTS_DIR"
        case .recordingsKeepDays: return "RECORDINGS_KEEP_DAYS"
        case .autoStopSilenceMinutes: return "AUTO_STOP_SILENCE_MINUTES"
        case .defaultModel, .cloudTranscriptionEnabled,
             .calendarSource, .onboardingCompleted: return nil
        case .sttLanguage: return "STT_LANGUAGE"
        case .sttLanguages: return "STT_LANGUAGES"
        case .sttLanguageMargin: return "STT_LANGUAGE_MARGIN"
        case .systemAudioExcludedBundleIDs: return "SYSTEM_AUDIO_EXCLUDE_BUNDLES"
        case .systemAudioEngine: return "SYSTEM_AUDIO_ENGINE"
        case .diarizeEnabled: return "DIARIZE"
        case .voiceMemoUsesAppleTranscript: return "VOICE_MEMO_TRANSCRIPT"
        case .micVoiceProcessingMode: return "MIC_VOICE_PROCESSING"
        case .dedupeStreams: return "STT_DEDUPE_STREAMS"
        case .ownerEmail: return "OWNER_EMAIL"
        case .openAIKey: return "OPENAI_API_KEY"
        }
    }

    /// UserDefaults key; for a secret, the keychain account.
    var storageKey: String {
        switch self {
        case .sttLanguage: return "sttLanguage"
        case .openAIKey: return envKey!
        default: return "settings.\(rawValue)"
        }
    }

    /// The .env spelling of true/false for a bool setting, so a stored Bool
    /// reads back through the same parser as the env var (DIARIZE=off,
    /// VOICE_MEMO_TRANSCRIPT=apple).
    var boolTokens: (on: String, off: String) {
        switch self {
        case .diarizeEnabled: return ("on", "off")
        case .voiceMemoUsesAppleTranscript: return ("apple", "whisper")
        default: return ("true", "false")
        }
    }

    var description: String {
        switch self {
        case .transcriptsFolderPath:
            return "Folder that finished transcripts are written to as Markdown. Unset = transcripts stay in the app's outbox."
        case .recordingsKeepDays:
            return "Days to keep recorded audio (0 = keep forever). A transcript not yet written to the folder is never pruned."
        case .autoStopSilenceMinutes:
            return "Stop a recording after this many minutes of silence on both streams (0 = never)."
        case .defaultModel:
            return "Model new recordings are transcribed with."
        case .sttLanguage:
            return "Transcription language: auto (detect among sttLanguages) or a pinned code."
        case .sttLanguages:
            return "Candidate languages for auto detection, primary first."
        case .sttLanguageMargin:
            return "How much a non-primary language must out-score the primary in detection (0 disables)."
        case .cloudTranscriptionEnabled:
            return "Offer the cloud (OpenAI) models. Needs an OpenAI key as well."
        case .calendarSource:
            return "Where upcoming meetings come from: off, or eventkit (the macOS Calendar app's accounts)."
        case .systemAudioExcludedBundleIDs:
            return "Apps whose audio is kept out of the system (\"Them\") track."
        case .systemAudioEngine:
            return "System-audio capture: taps (Core Audio process tap, needs only System Audio Recording) or sck (ScreenCaptureKit, needs Screen Recording)."
        case .diarizeEnabled:
            return "Split the \"Them\" stream into distinct speakers with the local diarizer."
        case .voiceMemoUsesAppleTranscript:
            return "Keep the iPhone's own transcript for imported Voice Memos instead of the default model."
        case .micVoiceProcessingMode:
            return "Mic echo cancellation: auto (built-in speakers + non-Bluetooth mic only), on or off."
        case .dedupeStreams:
            return "Transcribe only the mic when both streams are near-duplicates (loses Me/Them)."
        case .ownerEmail:
            return "Your email, so a 1:1's other attendee can name the \"Them\" speaker."
        case .onboardingCompleted:
            return "Whether the first-run setup has been finished (false = it runs at the next launch)."
        case .openAIKey:
            return "OpenAI API key for the cloud transcription model."
        }
    }
}

/// Built-in defaults, shared by Config's resolver and the Settings facade
/// so the two can't drift.
enum SettingDefaults {
    static let recordingsKeepDays = 30
    static let autoStopSilenceMinutes = 10
    static let defaultModel = TranscriptionModel.default
    static let sttLanguage = "auto"
    static let sttLanguages = ["en"]
    static let sttLanguageMargin: Float = 0.2
    static let cloudTranscriptionEnabled = false
    static let systemAudioExcludedBundleIDs: [String] = []
    static let systemAudioEngine = SystemAudioEngineKind.taps
    static let diarizeEnabled = true
    static let voiceMemoUsesAppleTranscript = false
    static let micVoiceProcessingMode = Config.VoiceProcessingMode.auto
    static let dedupeStreams = false
    static let onboardingCompleted = false
    /// No calendar until the user picks one (setup step 4 or Settings ›
    /// Calendar): the macOS prompt for calendar access should follow a
    /// choice, not a launch.
    static let calendarSource = CalendarSource.off
}

/// Where the calendar poll reads upcoming meetings from.
enum CalendarSource: String, CaseIterable, Sendable {
    case off
    case eventkit   // EKEventStore: whatever accounts the Calendar app has

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .eventkit: return "macOS Calendar"
        }
    }
}

extension Notification.Name {
    /// Posted (main thread) when Settings.calendarSource is written, so the
    /// running poll switches source without a relaunch.
    static let calendarSourceDidChange = Notification.Name("com.jwiderberg.minnas.calendarSourceDidChange")
}

enum SettingsError: Error, CustomStringConvertible, LocalizedError {
    case invalidValue(name: String, expected: String)
    case keychainUnavailable(name: String)

    var description: String {
        switch self {
        case .invalidValue(let name, let expected):
            return "invalid value for \(name): expected \(expected)"
        case .keychainUnavailable(let name):
            return """
            \(name) is a secret, and secrets are stored in the login Keychain \
            only from inside the app bundle. A `swift run` binary is re-signed \
            on every build, so the Keychain would prompt on every read; the \
            CLI keeps reading secrets from .env (./.env or \
            ~/Library/Application Support/minnas/.env). Run \
            .build/Minnas.app/Contents/MacOS/minnas instead.
            """
        }
    }

    var errorDescription: String? { description }
}

enum SettingsStorage {
    private static var defaults: UserDefaults { .standard }

    /// The keychain is only touched from the signed bundle — see Config.
    static var keychainAvailable: Bool { AppInfo.isRunningInBundle }

    static func isSet(_ key: SettingKey) -> Bool { storedRaw(key) != nil }

    /// The stored value in .env syntax, or nil when unset. A keychain read
    /// failure counts as unset so resolution falls through to .env — but it
    /// is logged, because a silent fall-through would hide a broken keychain
    /// ACL (the symptom would be "works with .env, not without").
    static func storedRaw(_ key: SettingKey) -> String? {
        let k = key.storageKey
        switch key.kind {
        case .secret:
            guard keychainAvailable else { return nil }
            do {
                guard let value = try KeychainStore.get(k), !value.isEmpty else { return nil }
                return value
            } catch {
                settingsLog.error("keychain read failed for \(k, privacy: .public): \(String(describing: error), privacy: .public)")
                return nil
            }
        case .int:
            return (defaults.object(forKey: k) as? Int).map(String.init)
        case .float:
            return (defaults.object(forKey: k) as? Double).map { String($0) }
        case .bool:
            guard let value = defaults.object(forKey: k) as? Bool else { return nil }
            return value ? key.boolTokens.on : key.boolTokens.off
        case .stringList:
            // An empty stored list is a real choice ("exclude nothing"),
            // so it comes back as "" rather than as unset.
            return (defaults.object(forKey: k) as? [String])?.joined(separator: ",")
        case .path, .email, .choice, .model:
            return defaults.string(forKey: k)
        }
    }

    /// Parses `raw` (.env syntax, as typed on the command line or found in
    /// a .env file), validates it and stores the typed value.
    static func store(_ key: SettingKey, raw: String) throws {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = key.storageKey
        func invalid() -> SettingsError { .invalidValue(name: key.name, expected: key.kind.label) }
        switch key.kind {
        case .secret:
            guard !value.isEmpty, !value.contains(where: \.isNewline) else { throw invalid() }
            guard keychainAvailable else { throw SettingsError.keychainUnavailable(name: key.name) }
            try KeychainStore.set(k, value)
        case .int:
            guard let n = Int(value) else { throw invalid() }
            defaults.set(max(0, n), forKey: k)
        case .float:
            guard let f = Double(value), f.isFinite else { throw invalid() }
            defaults.set(f, forKey: k)
        case .bool:
            guard let b = parseBool(value, key: key) else { throw invalid() }
            defaults.set(b, forKey: k)
        case .stringList:
            let list = value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            defaults.set(key == .sttLanguages ? list.map { $0.lowercased() } : list, forKey: k)
        case .path:
            let expanded = (value as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else {
                throw SettingsError.invalidValue(name: key.name, expected: "an absolute path")
            }
            defaults.set((expanded as NSString).standardizingPath, forKey: k)
        case .email:
            guard value.contains("@"), !value.contains(where: \.isWhitespace) else { throw invalid() }
            defaults.set(value.lowercased(), forKey: k)
        case .choice(let options):
            let lowered = value.lowercased()
            let canonical: String?
            if key == .micVoiceProcessingMode {
                // The same synonyms MIC_VOICE_PROCESSING has always taken.
                switch lowered {
                case "true", "1", "on", "yes": canonical = "on"
                case "false", "0", "off", "no": canonical = "off"
                case "auto": canonical = "auto"
                default: canonical = nil
                }
            } else if key == .sttLanguage {
                // STT_LANGUAGE has always accepted any Whisper code, not
                // just the menubar's three.
                let isCode = (2...3).contains(lowered.count) && lowered.allSatisfy { $0.isASCII && $0.isLetter }
                canonical = lowered == "auto" || isCode ? lowered : nil
            } else {
                canonical = options.contains(lowered) ? lowered : nil
            }
            guard let canonical else { throw invalid() }
            defaults.set(canonical, forKey: k)
        case .model:
            guard let model = TranscriptionModel(rawValue: value) else { throw invalid() }
            defaults.set(model.rawValue, forKey: k)
        }
    }

    static func remove(_ key: SettingKey) throws {
        if key.isSecret {
            guard keychainAvailable else { throw SettingsError.keychainUnavailable(name: key.name) }
            try KeychainStore.delete(key.storageKey)
        } else {
            defaults.removeObject(forKey: key.storageKey)
        }
    }

    // Typed writes for the facade, which has already-typed values.
    fileprivate static func write(_ value: Any?, for key: SettingKey) {
        precondition(!key.isSecret, "secrets go through the keychain")
        if let value { defaults.set(value, forKey: key.storageKey) } else { defaults.removeObject(forKey: key.storageKey) }
    }

    fileprivate static func object<T>(_ key: SettingKey, as type: T.Type) -> T? {
        defaults.object(forKey: key.storageKey) as? T
    }

    private static func parseBool(_ raw: String, key: SettingKey) -> Bool? {
        let lowered = raw.lowercased()
        if lowered == key.boolTokens.on { return true }
        if lowered == key.boolTokens.off { return false }
        switch lowered {
        case "true", "1", "on", "yes": return true
        case "false", "0", "off", "no": return false
        default: return nil
        }
    }
}

/// Typed, MainActor-bound view of the stored settings for UI code. A getter
/// returns the stored value or the built-in default — NOT the resolved
/// value (an env var or .env line may still override it; ask Config).
@MainActor
final class Settings {
    static let shared = Settings()

    nonisolated static let allKeys: [SettingKey] = SettingKey.allCases

    private init() {}

    var transcriptsFolderPath: String? {
        get { SettingsStorage.object(.transcriptsFolderPath, as: String.self) }
        set {
            if let newValue { try? SettingsStorage.store(.transcriptsFolderPath, raw: newValue) }
            else { SettingsStorage.write(nil, for: .transcriptsFolderPath) }
        }
    }

    var recordingsKeepDays: Int {
        get { SettingsStorage.object(.recordingsKeepDays, as: Int.self) ?? SettingDefaults.recordingsKeepDays }
        set { SettingsStorage.write(max(0, newValue), for: .recordingsKeepDays) }
    }

    var autoStopSilenceMinutes: Int {
        get { SettingsStorage.object(.autoStopSilenceMinutes, as: Int.self) ?? SettingDefaults.autoStopSilenceMinutes }
        set { SettingsStorage.write(max(0, newValue), for: .autoStopSilenceMinutes) }
    }

    var defaultModel: TranscriptionModel {
        get {
            SettingsStorage.object(.defaultModel, as: String.self).flatMap(TranscriptionModel.init(rawValue:))
                ?? SettingDefaults.defaultModel
        }
        set { SettingsStorage.write(newValue.rawValue, for: .defaultModel) }
    }

    var sttLanguage: String {
        get { SettingsStorage.object(.sttLanguage, as: String.self) ?? SettingDefaults.sttLanguage }
        set { SettingsStorage.write(newValue, for: .sttLanguage) }
    }

    var sttLanguages: [String] {
        get { SettingsStorage.object(.sttLanguages, as: [String].self) ?? SettingDefaults.sttLanguages }
        set { SettingsStorage.write(newValue.map { $0.lowercased() }, for: .sttLanguages) }
    }

    var sttLanguageMargin: Float {
        get { SettingsStorage.object(.sttLanguageMargin, as: Double.self).map(Float.init) ?? SettingDefaults.sttLanguageMargin }
        set { SettingsStorage.write(Double(newValue), for: .sttLanguageMargin) }
    }

    var cloudTranscriptionEnabled: Bool {
        get { SettingsStorage.object(.cloudTranscriptionEnabled, as: Bool.self) ?? SettingDefaults.cloudTranscriptionEnabled }
        set { SettingsStorage.write(newValue, for: .cloudTranscriptionEnabled) }
    }

    var systemAudioExcludedBundleIDs: [String] {
        get { SettingsStorage.object(.systemAudioExcludedBundleIDs, as: [String].self) ?? SettingDefaults.systemAudioExcludedBundleIDs }
        set { SettingsStorage.write(newValue, for: .systemAudioExcludedBundleIDs) }
    }

    var systemAudioEngine: SystemAudioEngineKind {
        get {
            SettingsStorage.object(.systemAudioEngine, as: String.self).flatMap(SystemAudioEngineKind.init(rawValue:))
                ?? SettingDefaults.systemAudioEngine
        }
        set { SettingsStorage.write(newValue.rawValue, for: .systemAudioEngine) }
    }

    var diarizeEnabled: Bool {
        get { SettingsStorage.object(.diarizeEnabled, as: Bool.self) ?? SettingDefaults.diarizeEnabled }
        set { SettingsStorage.write(newValue, for: .diarizeEnabled) }
    }

    var voiceMemoUsesAppleTranscript: Bool {
        get { SettingsStorage.object(.voiceMemoUsesAppleTranscript, as: Bool.self) ?? SettingDefaults.voiceMemoUsesAppleTranscript }
        set { SettingsStorage.write(newValue, for: .voiceMemoUsesAppleTranscript) }
    }

    var micVoiceProcessingMode: Config.VoiceProcessingMode {
        get {
            SettingsStorage.object(.micVoiceProcessingMode, as: String.self).flatMap(Config.VoiceProcessingMode.init(rawValue:))
                ?? SettingDefaults.micVoiceProcessingMode
        }
        set { SettingsStorage.write(newValue.rawValue, for: .micVoiceProcessingMode) }
    }

    var dedupeStreams: Bool {
        get { SettingsStorage.object(.dedupeStreams, as: Bool.self) ?? SettingDefaults.dedupeStreams }
        set { SettingsStorage.write(newValue, for: .dedupeStreams) }
    }

    var onboardingCompleted: Bool {
        get { SettingsStorage.object(.onboardingCompleted, as: Bool.self) ?? SettingDefaults.onboardingCompleted }
        set { SettingsStorage.write(newValue, for: .onboardingCompleted) }
    }

    var calendarSource: CalendarSource {
        get {
            SettingsStorage.object(.calendarSource, as: String.self).flatMap(CalendarSource.init(rawValue:))
                ?? SettingDefaults.calendarSource
        }
        set {
            SettingsStorage.write(newValue.rawValue, for: .calendarSource)
            NotificationCenter.default.post(name: .calendarSourceDidChange, object: nil)
        }
    }

    var ownerEmail: String? {
        get { SettingsStorage.object(.ownerEmail, as: String.self) }
        set { SettingsStorage.write(newValue?.lowercased(), for: .ownerEmail) }
    }

    // The secret. Throwing accessors rather than plain properties: a keychain
    // failure (or running outside the bundle) must reach the caller, not
    // read as "unset".

    var openAIKey: String? { get throws { try secret(.openAIKey) } }
    func setOpenAIKey(_ value: String) throws { try setSecret(.openAIKey, value) }
    func deleteOpenAIKey() throws { try SettingsStorage.remove(.openAIKey) }

    private func secret(_ key: SettingKey) throws -> String? {
        guard SettingsStorage.keychainAvailable else { throw SettingsError.keychainUnavailable(name: key.name) }
        return try KeychainStore.get(key.storageKey)
    }

    private func setSecret(_ key: SettingKey, _ value: String) throws {
        try SettingsStorage.store(key, raw: value)
    }

    // String-addressed access for the --settings harness and generic UI.

    func setValue(fromString raw: String, for key: SettingKey) throws {
        try SettingsStorage.store(key, raw: raw)
    }

    func reset(_ key: SettingKey) throws {
        try SettingsStorage.remove(key)
    }
}
