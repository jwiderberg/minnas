//
// The resolver for every setting. Config stores nothing itself: the home
// of a setting is Settings (UserDefaults) or, for a secret, the login
// keychain (KeychainStore) — both UI-manageable. The .env file is demoted
// to a developer fallback.
//
// Resolution order for a key (first hit wins):
//   1. The process environment — a developer override, e.g.
//      `TRANSCRIPTS_DIR=/tmp/t swift run minnas …`.
//   2. Settings (UserDefaults), or the keychain for a secret.
//   3. A `.env` file. Two locations are merged, app-support winning:
//        - ~/Library/Application Support/minnas/.env  (the .app
//          launches with CWD=/, so this is the practical prod location)
//        - ./.env in the current directory (dev convenience for
//          `swift run` from the repo root; .env is gitignored)
//   4. The built-in default (SettingDefaults).
//
// The keychain is consulted ONLY inside the app bundle (bundle id ==
// AppInfo.bundleID), for reads and writes alike. A bare `swift run`
// binary gets a new code signature on every build, so each keychain read
// would raise an ACL prompt; for it, secrets keep coming from env / .env
// exactly as before. Its UserDefaults domain is also its own (named after
// the executable), not the app's.
//
// On first use inside the bundle, the app-support .env is copied once into
// Settings / the keychain (migrateDotEnvIntoSettingsIfNeeded), so the
// values the app runs with today become editable in the UI. The file stays
// in place as the fallback layer.
//
// The only secret is the OpenAI key, needed only for cloud STT, so
// resolution is lazy and a missing key throws a path-pointing error rather
// than failing at launch.
//
// .env format: `KEY=value` per line, `#` comments and blank lines ignored,
// an optional `export ` prefix allowed, and surrounding quotes stripped.
//

import Foundation
import os

private let configLog = Logger(subsystem: "com.jwiderberg.minnas", category: "Config")

extension AppInfo {
    /// CFBundleIdentifier from App/Info.plist; also the keychain service.
    static let bundleID = "com.jwiderberg.minnas"

    /// True only for the binary inside the signed .app. A `swift run`
    /// binary has no bundle id (or not this one), and must stay out of
    /// the keychain — see the resolver notes on Config.
    static var isRunningInBundle: Bool { Bundle.main.bundleIdentifier == bundleID }
}

enum ConfigError: Error, CustomStringConvertible, LocalizedError {
    case missingOpenAIKey(envPath: String)

    var description: String {
        switch self {
        case .missingOpenAIKey(let path):
            return """
            No OpenAI API key found. Store it with \
            `minnas --settings set openAIKey -` (run from inside \
            the app bundle), set the OPENAI_API_KEY environment variable, \
            or add this line to a .env file at:

            \(path)

                OPENAI_API_KEY=sk-...
            """
        }
    }

    var errorDescription: String? { description }
}

/// Where a resolved value came from (the --settings harness prints it).
enum SettingSource: String, Sendable {
    case env
    case settings
    case keychain
    case dotEnv = ".env"
    case `default`
}

enum Config {
    /// `~/Library/Application Support/minnas/.env`, alongside the
    /// outbox directory. The path referenced in the missing-key error.
    static var envFileURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return base
            .appendingPathComponent("minnas", isDirectory: true)
            .appendingPathComponent(".env")
    }

    /// Language to transcribe in. Returns a Whisper language code to pin
    /// (e.g. "en", "sv"), or nil to free-detect. Default is pinned English:
    /// free per-chunk detection mis-fires on compressed call audio
    /// (windows come back in unrelated languages),
    /// and the wrong-language churn also makes transcription far slower.
    /// Set STT_LANGUAGE=auto to opt back into detection, or =sv etc.
    ///
    /// Raw language selection: "auto", "en", "sv". A menubar choice
    /// (Settings) wins over STT_LANGUAGE in .env, which wins over the
    /// "auto" default; an STT_LANGUAGE environment variable beats both.
    static func sttLanguageRaw() -> String {
        (value(for: .sttLanguage) ?? SettingDefaults.sttLanguage).lowercased()
    }

    /// Resolved pin: a language code, or nil for "auto" (detect).
    static func sttLanguage() -> String? {
        let value = sttLanguageRaw()
        return value == "auto" ? nil : value
    }

    /// Persist a menubar language choice ("auto"/"en"/"sv").
    static func setSTTLanguage(_ value: String) {
        // Unvalidated, as before: the menubar only offers valid choices
        // and the string is lowercased on read.
        UserDefaults.standard.set(value, forKey: SettingKey.sttLanguage.storageKey)
    }

    /// Candidate languages for "auto" detection: the languages the user
    /// actually speaks, primary first. Detection is constrained to these, so
    /// it can never mis-fire to a third language. Default English only (the
    /// Transcription settings add more). Override via STT_LANGUAGES.
    static func sttCandidateLanguages() -> [String] {
        let raw = value(for: .sttLanguages) ?? SettingDefaults.sttLanguages.joined(separator: ",")
        let list = raw.lowercased().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return list.isEmpty ? SettingDefaults.sttLanguages : list
    }

    /// How much better a non-primary language must score than the first
    /// STT_LANGUAGES entry to be chosen (language-token probability votes
    /// summed over probe windows; 0.2 ≈ a fifth of one confident window) —
    /// the English prior for near-ties. See LanguagePolicy.
    /// STT_LANGUAGE_MARGIN, default 0.2; 0 disables.
    static func sttLanguageMargin() -> Float {
        Float(value(for: .sttLanguageMargin) ?? "") ?? SettingDefaults.sttLanguageMargin
    }

    enum VoiceProcessingMode: String, Sendable { case auto, on, off }

    /// Mic acoustic echo cancellation mode (MIC_VOICE_PROCESSING).
    /// - off: never (raw mic).
    /// - on: always (force; risky over Bluetooth — silences the mic).
    /// - auto (default): enable only when it helps AND works — built-in
    ///   speakers output (room bleed) with a non-Bluetooth mic. This keeps
    ///   AEC off for Bluetooth/headset (no bleed, and VPIO+BT = silence) and
    ///   on for speaker recordings (clean Me/Them).
    static func micVoiceProcessingMode() -> VoiceProcessingMode {
        switch (value(for: .micVoiceProcessingMode) ?? "auto").lowercased() {
        case "true", "1", "on", "yes": return .on
        case "false", "0", "off", "no": return .off
        default: return .auto
        }
    }

    /// Whether to enable AEC for the current audio route, per the mode.
    static func shouldEnableMicVoiceProcessing() -> Bool {
        switch micVoiceProcessingMode() {
        case .on: return true
        case .off: return false
        case .auto:
            return AudioRoute.defaultOutputIsBuiltInSpeakers() && !AudioRoute.defaultInputIsBluetooth()
        }
    }

    /// Whether to skip transcribing the system stream when it's a near-
    /// duplicate of the mic (recording on speakers, where the mic catches
    /// everything acoustically). **Default OFF.** It only ever fires on
    /// speaker recordings, and there it collapses the transcript to all
    /// "Me" — losing the clean "Them" — which is worse than the duplication
    /// it avoids. On headsets the streams are
    /// distinct so it never fired anyway. Opt in with STT_DEDUPE_STREAMS=true.
    static func dedupeStreams() -> Bool {
        let value = (value(for: .dedupeStreams) ?? "false").lowercased()
        return ["true", "1", "on", "yes"].contains(value)
    }

    /// Bundle identifiers whose audio is excluded from the system-audio
    /// ("Them") capture. Both engines capture every app's output, including
    /// audio-processing tools that monitor your own mic back out (a mic
    /// routed through filters into a virtual device for the call app) —
    /// without this, your processed voice lands in "Them" and gets
    /// transcribed twice. Default: nothing excluded. Comma-separated; an
    /// empty list in Settings excludes nothing (a blank env / .env value
    /// reads as unset and keeps the default).
    static func systemAudioExcludedBundleIDs() -> [String] {
        guard let raw = value(for: .systemAudioExcludedBundleIDs) else {
            return SettingDefaults.systemAudioExcludedBundleIDs
        }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Which engine captures the system ("Them") track for new recordings
    /// (SYSTEM_AUDIO_ENGINE=taps|sck). Default taps: the Core Audio process
    /// tap, which needs only the System Audio Recording grant; sck is
    /// ScreenCaptureKit, which needs Screen Recording. An unknown value falls
    /// back to the default.
    static func systemAudioEngine() -> SystemAudioEngineKind {
        value(for: .systemAudioEngine).flatMap { SystemAudioEngineKind(rawValue: $0.lowercased()) }
            ?? SettingDefaults.systemAudioEngine
    }

    /// Whether an imported Voice Memo keeps Apple's on-device transcript
    /// (VOICE_MEMO_TRANSCRIPT=apple) instead of being transcribed with the
    /// default model. Default is the model: the iPhone transcript is
    /// instant but mangles names badly enough that Large v3's few minutes
    /// on the ANE are worth it.
    static func voiceMemoUsesAppleTranscript() -> Bool {
        (value(for: .voiceMemoUsesAppleTranscript) ?? "whisper").lowercased() == "apple"
    }

    /// Whether the local engines diarize the "Them" stream (DIARIZE=off to
    /// disable). Default on. The cloud model diarizes on its own.
    static func diarizationEnabled() -> Bool {
        let raw = (value(for: .diarizeEnabled) ?? "on").lowercased()
        return !["off", "0", "false", "no"].contains(raw)
    }

    /// Days to keep recordings on disk before pruning. 0 disables pruning.
    /// Default 30. A transcript still owed to the folder is never pruned,
    /// whatever its age (see Outbox.pruneOldRecordings).
    static func recordingsKeepDays() -> Int {
        guard let raw = value(for: .recordingsKeepDays), let days = Int(raw) else {
            return SettingDefaults.recordingsKeepDays
        }
        return max(0, days)
    }

    /// Auto-stop a recording after this many minutes with both streams
    /// silent (meeting ended / walked away). 0 disables. Default 10.
    static func autoStopSilenceMinutes() -> Int {
        guard let raw = value(for: .autoStopSilenceMinutes), let mins = Int(raw) else {
            return SettingDefaults.autoStopSilenceMinutes
        }
        return max(0, mins)
    }

    /// The operator's own email — used to identify "self" among a meeting's
    /// attendees so a 1:1's other party can name the "Them" speaker. Set
    /// OWNER_EMAIL in .env; without it, speaker naming stays "Them".
    static func ownerEmail() -> String? {
        value(for: .ownerEmail)?.lowercased()
    }

    static func openAIKey() throws -> String {
        if let value = value(for: .openAIKey) { return value }
        throw ConfigError.missingOpenAIKey(envPath: envFileURL.path)
    }

    /// Folder that finished transcripts are exported to, or nil when none
    /// is chosen yet (first-run setup asks for one). TRANSCRIPTS_DIR
    /// overrides.
    static func transcriptsFolderURL() -> URL? {
        guard let raw = value(for: .transcriptsFolderPath) else { return nil }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The model new recordings are transcribed with. Settings-only. A
    /// cloud choice resolves to the local default while cloud transcription
    /// isn't available, so a stale pick can never send audio off-device.
    static func defaultModel() -> TranscriptionModel {
        let chosen = value(for: .defaultModel).flatMap(TranscriptionModel.init(rawValue:))
            ?? SettingDefaults.defaultModel
        if chosen.engine == .openAI && !cloudTranscriptionAvailable() { return SettingDefaults.defaultModel }
        return chosen
    }

    /// The user's switch for offering cloud models. Settings-only.
    static func cloudTranscriptionEnabled() -> Bool {
        guard let raw = value(for: .cloudTranscriptionEnabled) else {
            return SettingDefaults.cloudTranscriptionEnabled
        }
        return raw == SettingKey.cloudTranscriptionEnabled.boolTokens.on
    }

    /// Cloud models are offered only when the user switched them on AND an
    /// OpenAI key resolves from some layer.
    static func cloudTranscriptionAvailable() -> Bool {
        cloudTranscriptionEnabled() && value(for: .openAIKey) != nil
    }

    // MARK: - Resolver

    /// The raw value (in .env syntax) and the layer it came from, or nil
    /// when only the built-in default applies. Blank env / .env values
    /// count as unset, as they always have.
    static func resolve(_ key: SettingKey) -> (value: String, source: SettingSource)? {
        _ = migrationOnce
        if let envKey = key.envKey, let value = trimmedNonEmpty(ProcessInfo.processInfo.environment[envKey]) {
            return (value, .env)
        }
        if let value = SettingsStorage.storedRaw(key) {
            return (value, key.isSecret ? .keychain : .settings)
        }
        if let envKey = key.envKey, let value = trimmedNonEmpty(dotEnv[envKey]) {
            return (value, .dotEnv)
        }
        return nil
    }

    static func value(for key: SettingKey) -> String? { resolve(key)?.value }

    /// A config value by env-var name. Known keys go through the full
    /// resolver; anything else is environment, then the merged .env.
    static func value(for envKey: String) -> String? {
        if let key = SettingKey.allCases.first(where: { $0.envKey == envKey }) { return value(for: key) }
        return trimmedNonEmpty(ProcessInfo.processInfo.environment[envKey]) ?? trimmedNonEmpty(dotEnv[envKey])
    }

    /// The effective value as the --settings harness shows it. Secrets are
    /// masked — this must never return one.
    static func displayValue(for key: SettingKey) -> String {
        switch key {
        case .transcriptsFolderPath: return transcriptsFolderURL()?.path ?? "(off)"
        case .recordingsKeepDays: return String(recordingsKeepDays())
        case .autoStopSilenceMinutes: return String(autoStopSilenceMinutes())
        case .defaultModel: return defaultModel().rawValue
        case .sttLanguage: return sttLanguageRaw()
        case .sttLanguages: return sttCandidateLanguages().joined(separator: ",")
        case .sttLanguageMargin: return String(sttLanguageMargin())
        case .cloudTranscriptionEnabled: return String(cloudTranscriptionEnabled())
        case .calendarSource:
            return (value(for: .calendarSource).flatMap(CalendarSource.init(rawValue:)) ?? SettingDefaults.calendarSource).rawValue
        case .onboardingCompleted: return String(value(for: .onboardingCompleted) == "true")
        case .systemAudioExcludedBundleIDs:
            let ids = systemAudioExcludedBundleIDs()
            return ids.isEmpty ? "(none)" : ids.joined(separator: ",")
        case .systemAudioEngine: return systemAudioEngine().rawValue
        case .diarizeEnabled: return String(diarizationEnabled())
        case .voiceMemoUsesAppleTranscript: return String(voiceMemoUsesAppleTranscript())
        case .micVoiceProcessingMode: return micVoiceProcessingMode().rawValue
        case .dedupeStreams: return String(dedupeStreams())
        case .ownerEmail: return ownerEmail() ?? "(unset)"
        case .openAIKey: return value(for: key) == nil ? "(unset)" : "••• (set)"
        }
    }

    // MARK: - One-time .env → Settings migration

    static let migratedFlagKey = "settings.migrated_v1"

    // Touched by every resolve(), so the first Config read in the app runs
    // the migration without AppDelegate knowing about it. The migration
    // must never call resolve() itself — that would re-enter this token.
    private static let migrationOnce: Void = { migrateDotEnvIntoSettingsIfNeeded() }()
    private static let migrationLock = NSLock()

    /// Copies every key of the app-support .env (not ./.env, which is a
    /// repo dev convenience) whose Settings value is still unset into
    /// Settings, secrets into the keychain. Once per user, bundle only.
    /// Returns the migrated key names, or nil when it didn't run. A keychain
    /// failure leaves the flag unset so the next launch retries; a value
    /// that doesn't validate is skipped for good (.env still serves it as
    /// the fallback layer). Logs names only — never values.
    @discardableResult
    static func migrateDotEnvIntoSettingsIfNeeded() -> [String]? {
        guard AppInfo.isRunningInBundle else { return nil }
        migrationLock.lock()
        defer { migrationLock.unlock() }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedFlagKey) else { return nil }

        let file = parseEnvFile(at: envFileURL)
        var migrated: [String] = []
        var skipped: [String] = []
        var failed: [String] = []
        for key in SettingKey.allCases {
            guard let envKey = key.envKey, trimmedNonEmpty(file[envKey]) != nil, !SettingsStorage.isSet(key) else {
                continue
            }
            do {
                try SettingsStorage.store(key, raw: file[envKey]!)
                migrated.append(envKey)
            } catch is SettingsError {
                skipped.append(envKey)
            } catch {
                failed.append(envKey)
                configLog.error("migrating \(envKey, privacy: .public) into the keychain failed: \(String(describing: error), privacy: .public)")
            }
        }
        if failed.isEmpty { defaults.set(true, forKey: migratedFlagKey) }
        let names = migrated.isEmpty ? "(none)" : migrated.joined(separator: ", ")
        let notes = (skipped.isEmpty ? "" : "; skipped invalid: \(skipped.joined(separator: ", "))")
            + (failed.isEmpty ? "" : "; failed, will retry: \(failed.joined(separator: ", "))")
        configLog.notice("migrated .env into settings: \(names, privacy: .public)\(notes, privacy: .public)")
        return migrated
    }

    // MARK: - .env

    // Merged .env values, loaded once. CWD first so the app-support file
    // overrides it.
    private static let dotEnv: [String: String] = {
        var merged: [String: String] = [:]
        let cwdEnv = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".env")
        for (key, value) in parseEnvFile(at: cwdEnv) { merged[key] = value }
        for (key, value) in parseEnvFile(at: envFileURL) { merged[key] = value }
        return merged
    }()

    private static func parseEnvFile(at url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Trim newlines too, not just spaces/tabs — otherwise a CRLF file
            // leaves a trailing \r on the value, defeating the quote-strip
            // below (a quoted secret would keep its quotes and 401).
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
