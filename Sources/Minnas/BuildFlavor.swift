//
// What makes this build this build: the handful of values in which the
// open-source build differs from the private tree it is exported from.
//

enum BuildFlavor {
    /// The build's own transcript destinations, beside the Markdown folder
    /// every build has (SinkDispatcher adds that one when a folder is set).
    /// None here: the folder is the only destination.
    static let sinks: [any TranscriptSink] = []

    /// Whether pruning a delivered 🔒 local-only recording keeps its outbox
    /// transcript. No recording is local-only here, and a delivered slot
    /// goes whole (the folder holds the copy).
    static let keepsOutboxTranscriptForLocalOnly = false

    /// Candidate languages for auto detection, primary first. The
    /// Transcription settings add more.
    static let defaultSTTLanguages = ["en"]
    /// Apps kept out of the system ("Them") track. Nothing by default.
    static let defaultExcludedBundleIDs: [String] = []
    /// The Core Audio process tap: needs only the System Audio Recording
    /// grant.
    static let defaultSystemAudioEngine: SystemAudioEngineKind = .taps
    /// What captured the audio, written to meta.json and the transcript's
    /// frontmatter, for a recording made on this Mac.
    static let device = "mac"
    /// The version a binary outside the bundle reports.
    static let fallbackVersion = "0.1.2"
    /// The folder under ~/Documents first-run setup suggests.
    static let suggestedTranscriptsFolderName = "Minnas Transcripts"
    /// Placeholder of Settings › Transcription › Languages.
    static let languagesPlaceholder = "en, sv, de"
}
