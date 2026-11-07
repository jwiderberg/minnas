import Foundation
import Testing
@testable import Minnas

/// Pins what a stored setting is called and how it reads, so a refactor of
/// the settings code can't silently orphan a value someone already saved
/// (UserDefaults key, keychain account, env-var name) or change a default.
@Suite struct SettingsTests {
    /// name|storageKey|envKey|kind. Changing a line here strands the value
    /// people already stored under the old name: don't, unless you also
    /// migrate it.
    static let frozen = """
    transcriptsFolderPath|settings.transcriptsFolderPath|TRANSCRIPTS_DIR|path
    recordingsKeepDays|settings.recordingsKeepDays|RECORDINGS_KEEP_DAYS|int
    autoStopSilenceMinutes|settings.autoStopSilenceMinutes|AUTO_STOP_SILENCE_MINUTES|int
    defaultModel|settings.defaultModel|-|model
    sttLanguage|sttLanguage|STT_LANGUAGE|choice(auto,en,sv)
    sttLanguages|settings.sttLanguages|STT_LANGUAGES|list
    sttLanguageMargin|settings.sttLanguageMargin|STT_LANGUAGE_MARGIN|float
    cloudTranscriptionEnabled|settings.cloudTranscriptionEnabled|-|bool
    calendarSource|settings.calendarSource|-|choice(off,eventkit)
    systemAudioExcludedBundleIDs|settings.systemAudioExcludedBundleIDs|SYSTEM_AUDIO_EXCLUDE_BUNDLES|list
    systemAudioEngine|settings.systemAudioEngine|SYSTEM_AUDIO_ENGINE|choice(taps,sck)
    diarizeEnabled|settings.diarizeEnabled|DIARIZE|bool
    voiceMemoUsesAppleTranscript|settings.voiceMemoUsesAppleTranscript|VOICE_MEMO_TRANSCRIPT|bool
    micVoiceProcessingMode|settings.micVoiceProcessingMode|MIC_VOICE_PROCESSING|choice(auto,on,off)
    dedupeStreams|settings.dedupeStreams|STT_DEDUPE_STREAMS|bool
    ownerEmail|settings.ownerEmail|OWNER_EMAIL|email
    onboardingCompleted|settings.onboardingCompleted|-|bool
    openAIKey|OPENAI_API_KEY|OPENAI_API_KEY|secret
    """

    static func kindTag(_ kind: SettingKind) -> String {
        switch kind {
        case .path: return "path"
        case .email: return "email"
        case .int: return "int"
        case .float: return "float"
        case .bool: return "bool"
        case .stringList: return "list"
        case .choice(let options): return "choice(\(options.joined(separator: ",")))"
        case .model: return "model"
        case .secret: return "secret"
        }
    }

    @Test func storageKeysAndEnvNamesAreFrozen() {
        let actual = SettingKey.allCases
            .map { "\($0.name)|\($0.storageKey)|\($0.envKey ?? "-")|\(Self.kindTag($0.kind))" }
            .joined(separator: "\n")
        #expect(actual == Self.frozen)
        #expect(Config.migratedFlagKey == "settings.migrated_v1")
    }

    /// The display of each key's built-in default, as `--settings` prints
    /// it when no layer sets the key — from the spec's default alone, never
    /// through the resolver (this machine's .env must not leak in).
    static func defaultDisplay(_ key: SettingKey) -> String { key.spec.displayDefault() }

    @Test func defaultDisplayIsFrozen() {
        let golden = [
            "(off)", "30", "10", "large-v3", "auto", "en", "0.2", "false", "off",
            "(none)", "taps", "true", "false", "auto", "false", "(unset)",
            "false", "(unset)",
        ]
        #expect(SettingKey.allCases.map(Self.defaultDisplay) == golden)
    }

    @Test(arguments: SettingKey.allCases)
    func everyKeyRoundTripsItsDefault(_ key: SettingKey) {
        let spec = key.spec
        #expect(spec.key == key)
        #expect(spec.defaultRoundTrips() != false)
        for raw in ["", "x", "0", "-3", "1.5", "true", "off", "apple", "EN, sv", "~/t", "/tmp/a/../b", "a@B.se", "https://h/x", "auto", "taps", "large-v3"] {
            if let canonical = spec.canonicalize(raw) {
                #expect(spec.canonicalize(canonical) == canonical, "\(key.name): \(raw) → \(canonical)")
            }
        }
    }

    @Test func specParsers() {
        #expect(Setting.diarizeEnabled.parse("off") == false)
        #expect(Setting.diarizeEnabled.parse("garbage") == nil)
        #expect(Setting.voiceMemoUsesAppleTranscript.parse("apple") == true)
        #expect(Setting.voiceMemoUsesAppleTranscript.parse("whisper") == false)
        #expect(Setting.voiceMemoUsesAppleTranscript.parse("TRUE") == true)
        #expect(Setting.micVoiceProcessingMode.parse("yes") == .on)
        #expect(Setting.micVoiceProcessingMode.parse("no") == .off)
        #expect(Setting.micVoiceProcessingMode.parse("x") == nil)
        #expect(Setting.sttLanguage.parse("DE") == "de")
        #expect(Setting.sttLanguage.parse("auto") == "auto")
        #expect(Setting.sttLanguage.parse("xyz1") == nil)
        #expect(Setting.sttLanguages.parse("EN, sv") == ["en", "sv"])
        #expect(Setting.sttLanguages.parse("") == ["en"])
        #expect(Setting.systemAudioExcludedBundleIDs.parse("") == [])
        #expect(Setting.sttLanguageMargin.parse("abc") == nil)
        #expect(Setting.sttLanguageMargin.parse("inf") == nil)
        #expect(Setting.recordingsKeepDays.parse("-3") == 0)
        // For an optional value, nil is "invalid" and .some(x) a valid x.
        #expect(Setting.transcriptsFolderPath.parse("relative/dir") == nil)
        #expect(Setting.transcriptsFolderPath.parse("/nonexistent-mr/a/") == .some("/nonexistent-mr/a"))
        #expect(Setting.ownerEmail.parse("nobody") == nil)
        #expect(Setting.ownerEmail.parse("A@B.se") == .some("a@b.se"))
        #expect(Setting.openAIKey.parse("sk-1\nx") == nil)
        #expect(Setting.calendarSource.parse("EventKit") == .eventkit)
        #expect(Setting.calendarSource.parse("google") == nil)
        // Bools are stored as true/false whatever spelling came in.
        #expect(Setting.diarizeEnabled.parse("on").flatMap(Setting.diarizeEnabled.format) == "true")
        #expect(SettingKey.voiceMemoUsesAppleTranscript.spec.canonicalize("whisper") == "false")
    }
}

/// How an env value reads, through the real resolver (the env layer wins
/// over Settings and .env, so these hold on any machine). Serialized: the
/// process environment is shared.
@Suite(.serialized) struct SettingsParserTests {
    private func with<T>(_ name: String, _ value: String, _ read: () -> T) -> T {
        let old = ProcessInfo.processInfo.environment[name]
        setenv(name, value, 1)
        defer { if let old { setenv(name, old, 1) } else { unsetenv(name) } }
        return read()
    }

    @Test func diarize() {
        #expect(with("DIARIZE", "off", Config.diarizationEnabled) == false)
        #expect(with("DIARIZE", "garbage", Config.diarizationEnabled) == true)
    }

    @Test func voiceMemoTranscript() {
        #expect(with("VOICE_MEMO_TRANSCRIPT", "apple", Config.voiceMemoUsesAppleTranscript) == true)
        #expect(with("VOICE_MEMO_TRANSCRIPT", "whisper", Config.voiceMemoUsesAppleTranscript) == false)
    }

    @Test func micVoiceProcessing() {
        #expect(with("MIC_VOICE_PROCESSING", "yes", Config.micVoiceProcessingMode) == .on)
        #expect(with("MIC_VOICE_PROCESSING", "no", Config.micVoiceProcessingMode) == .off)
        #expect(with("MIC_VOICE_PROCESSING", "x", Config.micVoiceProcessingMode) == .auto)
    }

    @Test func sttLanguage() {
        #expect(with("STT_LANGUAGE", "DE", Config.sttLanguage) == "de")
        #expect(with("STT_LANGUAGE", "auto", Config.sttLanguage) == nil)
        // Not a language code: store always refused it, and now a read
        // falls back to the default (auto) instead of pinning "xyz1".
        #expect(with("STT_LANGUAGE", "xyz1", Config.sttLanguage) == nil)
    }

    @Test func sttLanguages() {
        #expect(with("STT_LANGUAGES", "EN, sv", Config.sttCandidateLanguages) == ["en", "sv"])
        #expect(with("STT_LANGUAGES", " , ", Config.sttCandidateLanguages) == ["en"])
    }

    @Test func excludedBundleIDs() {
        #expect(with("SYSTEM_AUDIO_EXCLUDE_BUNDLES", "a.b , c.d", Config.systemAudioExcludedBundleIDs) == ["a.b", "c.d"])
        #expect(with("SYSTEM_AUDIO_EXCLUDE_BUNDLES", " , ", Config.systemAudioExcludedBundleIDs) == [])
    }

    @Test func margin() {
        #expect(with("STT_LANGUAGE_MARGIN", "abc", Config.sttLanguageMargin) == 0.2)
        #expect(with("STT_LANGUAGE_MARGIN", "0.5", Config.sttLanguageMargin) == 0.5)
    }

    @Test func keepDays() {
        #expect(with("RECORDINGS_KEEP_DAYS", "-3", Config.recordingsKeepDays) == 0)
        #expect(with("RECORDINGS_KEEP_DAYS", "7", Config.recordingsKeepDays) == 7)
    }
}
