//
// The persistent home of every user-facing setting: UserDefaults for plain
// values, the login keychain (KeychainStore) for secrets. Config resolves
// from here — this file stores and validates, it does not decide
// precedence (env var > Settings > .env > default; see Config.swift).
//
// Every key is described once, by a typed SettingSpec in `enum Setting`:
// its kind, env-var name, storage key, default, and how its .env-syntax
// text parses, formats and displays. `SettingKey.spec` is the one switch
// that maps a key to its spec; everything else (Config's accessors, the
// --settings harness, validation on store) goes through that.
//
// Two layers:
//   - SettingsStorage: nonisolated, stateless functions over
//     UserDefaults.standard (itself thread-safe) and the keychain. Config's
//     accessors run on background threads (transcription, delivery), so the
//     resolver reads through this layer and never touches the MainActor.
//   - Settings: the @MainActor facade for UI code (the menubar and the
//     Settings window). Writes go through the same validation.
//
// Keys are namespaced `settings.<name>`, except `sttLanguage`, which is
// written by the menubar's Language submenu under its own short key.
//
// The stored form is typed (Int, Bool, Double, [String], String), but the
// resolver consumes everything as the same string syntax the .env file
// uses (`storedRaw`), so one parser per key handles all three layers.
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

    /// The one place a key meets its description. A key whose effective
    /// value is more than "resolved, else default" says so here.
    var spec: AnySettingSpec {
        switch self {
        case .transcriptsFolderPath: return AnySettingSpec(Setting.transcriptsFolderPath)
        case .recordingsKeepDays: return AnySettingSpec(Setting.recordingsKeepDays)
        case .autoStopSilenceMinutes: return AnySettingSpec(Setting.autoStopSilenceMinutes)
        case .defaultModel:
            // A cloud pick resolves to the local default while cloud is off.
            return AnySettingSpec(Setting.defaultModel, resolved: { Config.defaultModel() })
        case .sttLanguage: return AnySettingSpec(Setting.sttLanguage)
        case .sttLanguages: return AnySettingSpec(Setting.sttLanguages)
        case .sttLanguageMargin: return AnySettingSpec(Setting.sttLanguageMargin)
        case .cloudTranscriptionEnabled: return AnySettingSpec(Setting.cloudTranscriptionEnabled)
        case .calendarSource: return AnySettingSpec(Setting.calendarSource)
        case .systemAudioExcludedBundleIDs: return AnySettingSpec(Setting.systemAudioExcludedBundleIDs)
        case .systemAudioEngine: return AnySettingSpec(Setting.systemAudioEngine)
        case .diarizeEnabled: return AnySettingSpec(Setting.diarizeEnabled)
        case .voiceMemoUsesAppleTranscript: return AnySettingSpec(Setting.voiceMemoUsesAppleTranscript)
        case .micVoiceProcessingMode: return AnySettingSpec(Setting.micVoiceProcessingMode)
        case .dedupeStreams: return AnySettingSpec(Setting.dedupeStreams)
        case .ownerEmail: return AnySettingSpec(Setting.ownerEmail)
        case .onboardingCompleted: return AnySettingSpec(Setting.onboardingCompleted)
        case .openAIKey: return AnySettingSpec(Setting.openAIKey)
        }
    }

    var kind: SettingKind { spec.kind }
    var isSecret: Bool { kind == .secret }
    var envKey: String? { spec.envKey }
    /// UserDefaults key; for a secret, the keychain account.
    var storageKey: String { spec.storageKey }
    var description: String { spec.description }
}

/// One setting, typed. `parse` reads the .env syntax that every layer is
/// consumed as (nil = not a valid value: a read falls back to the default,
/// a store is refused); `format` is the canonical stored form (nil = nothing
/// to store, i.e. an unset optional); `display` is what --settings prints,
/// and never a secret.
struct SettingSpec<Value: Sendable & Equatable>: Sendable {
    let key: SettingKey
    let kind: SettingKind
    let envKey: String?
    let storageKey: String
    let description: String
    let defaultValue: @Sendable () -> Value
    let parse: @Sendable (String) -> Value?
    let format: @Sendable (Value) -> String?
    let display: @Sendable (Value) -> String

    init(
        _ key: SettingKey, _ kind: SettingKind, env: String?, storage: String? = nil,
        default defaultValue: @escaping @Sendable () -> Value,
        parse: @escaping @Sendable (String) -> Value?,
        format: @escaping @Sendable (Value) -> String?,
        display: @escaping @Sendable (Value) -> String,
        _ description: String
    ) {
        self.key = key
        self.kind = kind
        self.envKey = env
        self.storageKey = storage ?? "settings.\(key.rawValue)"
        self.description = description
        self.defaultValue = defaultValue
        self.parse = parse
        self.format = format
        self.display = display
    }
}

extension SettingSpec where Value == Bool {
    /// true/1/on/yes and false/0/off/no, case-insensitive, plus a key's own
    /// spellings (VOICE_MEMO_TRANSCRIPT=apple). Stored as a Bool.
    static func bool(
        _ key: SettingKey, env: String?, storage: String? = nil, default value: Bool,
        alsoTrue: [String] = [], alsoFalse: [String] = [], _ description: String
    ) -> Self {
        Self(key, .bool, env: env, storage: storage, default: { value },
             parse: { Setting.parseBool($0, alsoTrue: alsoTrue, alsoFalse: alsoFalse) },
             format: { String($0) }, display: { String($0) }, description)
    }
}

extension SettingSpec where Value == Int {
    /// A non-negative count; negatives clamp to 0, as Config always did.
    static func count(_ key: SettingKey, env: String?, default value: Int, _ description: String) -> Self {
        Self(key, .int, env: env, default: { value },
             parse: { Int($0).map { max(0, $0) } },
             format: { String($0) }, display: { String($0) }, description)
    }
}

extension SettingSpec where Value == Float {
    static func float(_ key: SettingKey, env: String?, default value: Float, _ description: String) -> Self {
        Self(key, .float, env: env, default: { value },
             parse: { raw in Float(raw).flatMap { $0.isFinite ? $0 : nil } },
             format: { String($0) }, display: { String($0) }, description)
    }
}

extension SettingSpec where Value: RawRepresentable & CaseIterable, Value.RawValue == String {
    /// One of an enum's raw values, case-insensitive, or a synonym.
    static func choice(
        _ key: SettingKey, env: String?, default value: Value,
        synonyms: [String: Value] = [:], _ description: String
    ) -> Self {
        Self(key, .choice(Value.allCases.map(\.rawValue)), env: env, default: { value },
             parse: { raw in
                 let lowered = raw.lowercased()
                 return synonyms[lowered] ?? Value(rawValue: lowered)
             },
             format: { $0.rawValue }, display: { $0.rawValue }, description)
    }
}

extension SettingSpec where Value == [String] {
    /// Comma-separated; blanks dropped. With `emptyIsDefault` an empty list
    /// means the default; without it, it is a real choice ("none").
    static func list(
        _ key: SettingKey, env: String?, default value: [String], lowercase: Bool, emptyIsDefault: Bool,
        display: @escaping @Sendable ([String]) -> String = { $0.joined(separator: ",") },
        _ description: String
    ) -> Self {
        Self(key, .stringList, env: env, default: { value },
             parse: { raw in
                 let items = raw.split(separator: ",")
                     .map { $0.trimmingCharacters(in: .whitespaces) }
                     .filter { !$0.isEmpty }
                     .map { lowercase ? $0.lowercased() : $0 }
                 return items.isEmpty && emptyIsDefault ? value : items
             },
             format: { $0.joined(separator: ",") }, display: display, description)
    }
}

extension SettingSpec where Value == String? {
    /// A keychain secret; the account is the env-var name. Never displayed.
    static func secret(_ key: SettingKey, env: String, _ description: String) -> Self {
        Self(key, .secret, env: env, storage: env, default: { nil },
             parse: { raw -> String?? in
                 guard !raw.isEmpty, !raw.contains(where: \.isNewline) else { return nil }
                 return raw
             },
             format: { $0 }, display: { $0 == nil ? "(unset)" : "••• (set)" }, description)
    }

    static func email(_ key: SettingKey, env: String, _ description: String) -> Self {
        Self(key, .email, env: env, default: { nil },
             parse: { raw -> String?? in
                 guard raw.contains("@"), !raw.contains(where: \.isWhitespace) else { return nil }
                 return raw.lowercased()
             },
             format: { $0 }, display: { $0 ?? "(unset)" }, description)
    }

    /// An absolute folder path, `~` expanded and standardized.
    static func path(_ key: SettingKey, env: String, _ description: String) -> Self {
        Self(key, .path, env: env, default: { nil },
             parse: { raw -> String?? in
                 let expanded = (raw as NSString).expandingTildeInPath
                 guard expanded.hasPrefix("/") else { return nil }
                 return (expanded as NSString).standardizingPath
             },
             format: { $0 }, display: { $0 ?? "(off)" }, description)
    }
}

/// Every setting's spec, in SettingKey order.
enum Setting {
    static let transcriptsFolderPath: SettingSpec<String?> = .path(
        .transcriptsFolderPath, env: "TRANSCRIPTS_DIR",
        "Folder that finished transcripts are written to as Markdown. Unset = transcripts stay in the app's outbox.")
    static let recordingsKeepDays: SettingSpec<Int> = .count(
        .recordingsKeepDays, env: "RECORDINGS_KEEP_DAYS", default: 30,
        "Days to keep recorded audio (0 = keep forever). A transcript not yet written to the folder is never pruned.")
    static let autoStopSilenceMinutes: SettingSpec<Int> = .count(
        .autoStopSilenceMinutes, env: "AUTO_STOP_SILENCE_MINUTES", default: 10,
        "Stop a recording after this many minutes of silence on both streams (0 = never).")
    static let defaultModel = SettingSpec<TranscriptionModel>(
        .defaultModel, .model, env: nil, default: { .default },
        parse: { TranscriptionModel(rawValue: $0) },
        format: { $0.rawValue }, display: { $0.rawValue },
        "Model new recordings are transcribed with.")
    /// "auto" or any Whisper code (2–3 letters), not just the menubar's three.
    static let sttLanguage = SettingSpec<String>(
        .sttLanguage, .choice(["auto", "en", "sv"]), env: "STT_LANGUAGE", storage: "sttLanguage",
        default: { "auto" },
        parse: { raw in
            let lowered = raw.lowercased()
            let isCode = (2...3).contains(lowered.count) && lowered.allSatisfy { $0.isASCII && $0.isLetter }
            return lowered == "auto" || isCode ? lowered : nil
        },
        format: { $0 }, display: { $0 },
        "Transcription language: auto (detect among sttLanguages) or a pinned code.")
    static let sttLanguages: SettingSpec<[String]> = .list(
        .sttLanguages, env: "STT_LANGUAGES", default: BuildFlavor.defaultSTTLanguages, lowercase: true, emptyIsDefault: true,
        "Candidate languages for auto detection, primary first.")
    static let sttLanguageMargin: SettingSpec<Float> = .float(
        .sttLanguageMargin, env: "STT_LANGUAGE_MARGIN", default: 0.2,
        "How much a non-primary language must out-score the primary in detection (0 disables).")
    static let cloudTranscriptionEnabled: SettingSpec<Bool> = .bool(
        .cloudTranscriptionEnabled, env: nil, default: false,
        "Offer the cloud (OpenAI) models. Needs an OpenAI key as well.")
    /// No calendar until the user picks one (setup step 4 or Settings ›
    /// Calendar): the macOS prompt for calendar access should follow a
    /// choice, not a launch.
    static let calendarSource: SettingSpec<CalendarSource> = .choice(
        .calendarSource, env: nil, default: .off,
        "Where upcoming meetings come from: off, or eventkit (the macOS Calendar app's accounts).")
    static let systemAudioExcludedBundleIDs: SettingSpec<[String]> = .list(
        .systemAudioExcludedBundleIDs, env: "SYSTEM_AUDIO_EXCLUDE_BUNDLES", default: BuildFlavor.defaultExcludedBundleIDs,
        lowercase: false, emptyIsDefault: false,
        display: { $0.isEmpty ? "(none)" : $0.joined(separator: ",") },
        "Apps whose audio is kept out of the system (\"Them\") track.")
    static let systemAudioEngine: SettingSpec<SystemAudioEngineKind> = .choice(
        .systemAudioEngine, env: "SYSTEM_AUDIO_ENGINE", default: BuildFlavor.defaultSystemAudioEngine,
        "System-audio capture: taps (Core Audio process tap, needs only System Audio Recording) or sck (ScreenCaptureKit, needs Screen Recording).")
    static let diarizeEnabled: SettingSpec<Bool> = .bool(
        .diarizeEnabled, env: "DIARIZE", default: true,
        "Split the \"Them\" stream into distinct speakers with the local diarizer.")
    static let voiceMemoUsesAppleTranscript: SettingSpec<Bool> = .bool(
        .voiceMemoUsesAppleTranscript, env: "VOICE_MEMO_TRANSCRIPT", default: false,
        alsoTrue: ["apple"], alsoFalse: ["whisper"],
        "Keep the iPhone's own transcript for imported Voice Memos instead of the default model.")
    /// Takes the bool spellings MIC_VOICE_PROCESSING always has.
    static let micVoiceProcessingMode: SettingSpec<Config.VoiceProcessingMode> = .choice(
        .micVoiceProcessingMode, env: "MIC_VOICE_PROCESSING", default: .auto,
        synonyms: Dictionary(uniqueKeysWithValues: trueTokens.map { ($0, .on) } + falseTokens.map { ($0, .off) }),
        "Mic echo cancellation: auto (built-in speakers + non-Bluetooth mic only), on or off.")
    static let dedupeStreams: SettingSpec<Bool> = .bool(
        .dedupeStreams, env: "STT_DEDUPE_STREAMS", default: false,
        "Transcribe only the mic when both streams are near-duplicates (loses Me/Them).")
    static let ownerEmail: SettingSpec<String?> = .email(
        .ownerEmail, env: "OWNER_EMAIL",
        "Your email, so a 1:1's other attendee can name the \"Them\" speaker.")
    static let onboardingCompleted: SettingSpec<Bool> = .bool(
        .onboardingCompleted, env: nil, default: false,
        "Whether the first-run setup has been finished (false = it runs at the next launch).")
    static let openAIKey: SettingSpec<String?> = .secret(
        .openAIKey, env: "OPENAI_API_KEY",
        "OpenAI API key for the cloud transcription model.")

    static let trueTokens = ["true", "1", "on", "yes"]
    static let falseTokens = ["false", "0", "off", "no"]

    /// The one bool parser, for every layer.
    static func parseBool(_ raw: String, alsoTrue: [String] = [], alsoFalse: [String] = []) -> Bool? {
        let lowered = raw.lowercased()
        if trueTokens.contains(lowered) || alsoTrue.contains(lowered) { return true }
        if falseTokens.contains(lowered) || alsoFalse.contains(lowered) { return false }
        return nil
    }
}

/// A spec with its value type erased, for code that walks every key.
struct AnySettingSpec: Sendable {
    let key: SettingKey
    let kind: SettingKind
    let envKey: String?
    let storageKey: String
    let description: String
    /// .env-syntax text → its canonical stored form; nil when invalid.
    let canonicalize: @Sendable (String) -> String?
    /// The effective value as --settings shows it.
    let displayResolved: @Sendable () -> String
    /// The built-in default as --settings shows it, without the resolver.
    let displayDefault: @Sendable () -> String
    /// Whether the default survives format → parse; nil when it has no
    /// stored form (an unset optional).
    let defaultRoundTrips: @Sendable () -> Bool?

    init<V>(_ spec: SettingSpec<V>, resolved: (@Sendable () -> V)? = nil) {
        key = spec.key
        kind = spec.kind
        envKey = spec.envKey
        storageKey = spec.storageKey
        description = spec.description
        canonicalize = { raw in spec.parse(raw).flatMap(spec.format) }
        let effective = resolved ?? { Config.get(spec) }
        displayResolved = { spec.display(effective()) }
        displayDefault = { spec.display(spec.defaultValue()) }
        defaultRoundTrips = { spec.format(spec.defaultValue()).map { spec.parse($0) == spec.defaultValue() } }
    }
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
            return (defaults.object(forKey: k) as? Bool).map { String($0) }
        case .stringList:
            // An empty stored list is a real choice ("exclude nothing"),
            // so it comes back as "" rather than as unset.
            return (defaults.object(forKey: k) as? [String])?.joined(separator: ",")
        case .path, .email, .choice, .model:
            return defaults.string(forKey: k)
        }
    }

    /// Validates `raw` (.env syntax, as typed on the command line or found
    /// in a .env file) through the key's spec and stores its canonical form,
    /// typed.
    static func store(_ key: SettingKey, raw: String) throws {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = key.storageKey
        guard let canonical = key.spec.canonicalize(value) else {
            throw SettingsError.invalidValue(name: key.name, expected: key.kind == .path ? "an absolute path" : key.kind.label)
        }
        switch key.kind {
        case .secret:
            guard keychainAvailable else { throw SettingsError.keychainUnavailable(name: key.name) }
            try KeychainStore.set(k, canonical)
        case .int:
            defaults.set(Int(canonical), forKey: k)
        case .float:
            defaults.set(Double(canonical), forKey: k)
        case .bool:
            defaults.set(canonical == "true", forKey: k)
        case .stringList:
            defaults.set(canonical.isEmpty ? [] : canonical.components(separatedBy: ","), forKey: k)
        case .path, .email, .choice, .model:
            defaults.set(canonical, forKey: k)
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
}

/// MainActor-bound writes for UI code. To read a setting, ask Config: it
/// returns the resolved value (an env var or .env line may override what
/// is stored here). calendarSource and onboardingCompleted are the two
/// reads kept here; writing calendarSource also tells the running poll.
@MainActor
final class Settings {
    static let shared = Settings()

    nonisolated static let allKeys: [SettingKey] = SettingKey.allCases

    private init() {}

    /// Stores a typed value; nil for an optional key unsets it. A value
    /// the spec refuses is a programming error in the caller, so it is
    /// logged as a fault rather than thrown.
    func set<V>(_ spec: SettingSpec<V>, _ value: V) {
        do {
            if let raw = spec.format(value) {
                try SettingsStorage.store(spec.key, raw: raw)
            } else {
                try SettingsStorage.remove(spec.key)
            }
        } catch {
            settingsLog.fault("storing \(spec.key.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// String-addressed access for the --settings harness, generic UI and
    /// secrets (a keychain failure, or running outside the bundle, must
    /// reach the caller).
    func setValue(fromString raw: String, for key: SettingKey) throws {
        try SettingsStorage.store(key, raw: raw)
    }

    func reset(_ key: SettingKey) throws {
        try SettingsStorage.remove(key)
    }

    var calendarSource: CalendarSource {
        get {
            SettingsStorage.storedRaw(.calendarSource).flatMap(Setting.calendarSource.parse)
                ?? Setting.calendarSource.defaultValue()
        }
        set {
            set(Setting.calendarSource, newValue)
            NotificationCenter.default.post(name: .calendarSourceDidChange, object: nil)
        }
    }

    var onboardingCompleted: Bool {
        get { Config.get(Setting.onboardingCompleted) }
        set { set(Setting.onboardingCompleted, newValue) }
    }
}
