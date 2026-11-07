//
// Minnas entry point.
//
// With no harness flag it launches as a menubar-only AppKit app
// (AppDelegate): captures system audio (Core Audio process tap or
// ScreenCaptureKit) and mic audio (AVAudioEngine) to outbox/<slug>/,
// transcribes, and writes the transcript to the transcripts folder.
// The flags below are developer harnesses; each one exits when done.
//
// Launch the app via the .app bundle from scripts/make-app.sh — running
// this binary directly (e.g., via `swift run`) bypasses the bundle's
// Info.plist so TCC has no CFBundleIdentifier to attach grants to.
//

import AppKit
import Foundation

if CommandLine.arguments.contains("--version") {
    print("minnas \(AppInfo.version)")
    exit(0)
}

// Settings harness (no TCC):
//   minnas --settings                      every setting, value + source
//   minnas --settings set <name> <value>   (<value> "-" reads stdin,
//                                                     which keeps a secret out of
//                                                     shell history)
//   minnas --settings unset <name>
// Run from inside the bundle to reach the app's own UserDefaults domain and
// the keychain; from `swift run` it sees the CLI's domain and .env only.
if let idx = CommandLine.arguments.firstIndex(of: "--settings") {
    let args = Array(CommandLine.arguments[(idx + 1)...])
    func fail(_ message: String, code: Int32 = 2) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }
    func key(named name: String) -> SettingKey {
        guard let key = SettingKey(rawValue: name) else {
            fail("unknown setting '\(name)'. known: \(Settings.allKeys.map(\.name).joined(separator: ", "))")
        }
        return key
    }
    func refuseSecretOutsideBundle(_ key: SettingKey) {
        if key.isSecret && !AppInfo.isRunningInBundle {
            fail("refused: " + SettingsError.keychainUnavailable(name: key.name).description, code: 1)
        }
    }

    if let migrated = Config.migrateDotEnvIntoSettingsIfNeeded() {
        print("migrated .env into settings: \(migrated.isEmpty ? "(none)" : migrated.joined(separator: ", "))")
    }

    switch args.first {
    case nil:
        print("keychain: \(AppInfo.isRunningInBundle ? "on (app bundle)" : "off (not the app bundle)")")
        let width = Settings.allKeys.map(\.name.count).max() ?? 0
        for key in Settings.allKeys {
            let source = Config.resolve(key)?.source ?? .default
            let name = key.name.padding(toLength: width, withPad: " ", startingAt: 0)
            print("\(name) = \(Config.displayValue(for: key))   [source: \(source.rawValue)]")
        }
    case "set":
        guard args.count == 3 else { fail("usage: --settings set <name> <value|->") }
        let key = key(named: args[1])
        refuseSecretOutsideBundle(key)
        var raw = args[2]
        if raw == "-" {
            raw = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }
        do {
            try Settings.shared.setValue(fromString: raw, for: key)
        } catch {
            fail("\(error)", code: 1)
        }
        print("\(key.name) = \(key.isSecret ? "••• (set)" : Config.displayValue(for: key))   [source: \((Config.resolve(key)?.source ?? .default).rawValue)]")
    case "unset":
        guard args.count == 2 else { fail("usage: --settings unset <name>") }
        let key = key(named: args[1])
        refuseSecretOutsideBundle(key)
        do {
            try Settings.shared.reset(key)
        } catch {
            fail("\(error)", code: 1)
        }
        print("\(key.name) = \(Config.displayValue(for: key))   [source: \((Config.resolve(key)?.source ?? .default).rawValue)]")
    default:
        fail("usage: --settings [set <name> <value|-> | unset <name>]")
    }
    exit(0)
}

// Dev smoke harness: transcribe an audio file from the shell, no menubar
// UI and no TCC (transcription needs neither). Useful for exercising an
// STT engine end-to-end, especially the cloud path.
//   minnas --transcribe <audio-file> [--model <id>]
if let idx = CommandLine.arguments.firstIndex(of: "--transcribe") {
    let args = CommandLine.arguments
    func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }
    guard idx + 1 < args.count else {
        fail("usage: --transcribe <audio-file> [--model <id>]")
    }
    let path = args[idx + 1]
    var model = TranscriptionModel.default
    if let m = args.firstIndex(of: "--model"), m + 1 < args.count {
        guard let parsed = TranscriptionModel(rawValue: args[m + 1]) else {
            fail("unknown model '\(args[m + 1])'. known: \(TranscriptionModel.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        model = parsed
    }
    Transcriber.shared.trace = { print($0) }
    Task {
        do {
            let results = try await Transcriber.shared.transcribe(audioPath: path, model: model)
            for (ri, result) in results.enumerated() {
                print("# result \(ri): language=\(result.language) segments=\(result.segments.count)")
                for seg in result.segments {
                    let spk = seg.speaker.map { "\($0): " } ?? ""
                    print(String(format: "[%7.2f → %7.2f] %@%@", seg.start, seg.end, spk, seg.text))
                }
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("transcribe failed: \(error)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}

// Batch re-transcribe a stored recording headlessly (no TCC needed):
//   minnas --retranscribe <slug> [--model <id>]
// Mirrors AppDelegate.startTranscription's core: transcribe both streams,
// build, and rewrite transcript.md + meta. Useful for re-processing
// recordings after a transcription fix. A cloud --model sends the audio to
// OpenAI: the flag is the consent.
if let idx = CommandLine.arguments.firstIndex(of: "--retranscribe") {
    let args = CommandLine.arguments
    guard idx + 1 < args.count else {
        FileHandle.standardError.write(Data("usage: --retranscribe <slug> [--model <id>]\n".utf8))
        exit(2)
    }
    let slug = args[idx + 1]
    var model = TranscriptionModel.default
    if let m = args.firstIndex(of: "--model") {
        // A typo (or a missing value) must not silently run a different
        // model than asked for.
        guard m + 1 < args.count, let parsed = TranscriptionModel(rawValue: args[m + 1]) else {
            let given = m + 1 < args.count ? args[m + 1] : "(none)"
            FileHandle.standardError.write(Data("unknown model \(given); known: \(TranscriptionModel.allCases.map(\.rawValue))\n".utf8))
            exit(2)
        }
        model = parsed
    }
    let slot = Outbox.slot(forDir: Outbox.rootURL.appendingPathComponent(slug, isDirectory: true))
    Transcriber.shared.trace = { print($0) }
    Task {
        do {
            // Same transcribe → build → persist core as the menubar flow
            // (TranscriptionJob), minus delivery/compress — a CLI
            // re-transcribe deliberately writes outbox files only.
            let output = try await TranscriptionJob.run(slot: slot, model: model)
            print("re-transcribed \(slug): \(output.segments.count) segments, languages \(output.languages.map(\.code))")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("retranscribe failed: \(error)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}

// Dev harness: capture system audio for N seconds, killing the stream the
// way the OS would at the midpoint (no request flag), so the watchdog has
// to notice and re-create it. Play something (afplay) meanwhile to have
// signal on both sides of the restart. Needs the configured engine's TCC
// grant (Screen Recording for sck, System Audio Recording for taps) → run
// the binary from inside the built .app bundle:
//   .build/Minnas.app/Contents/MacOS/minnas --system-test <seconds> <output.caf>
if let idx = CommandLine.arguments.firstIndex(of: "--system-test") {
    let args = CommandLine.arguments
    guard idx + 2 < args.count, let seconds = Int(args[idx + 1]) else {
        FileHandle.standardError.write(Data("usage: --system-test <seconds> <output.caf>\n".utf8))
        exit(2)
    }
    let url = URL(fileURLWithPath: args[idx + 2])
    Task { @MainActor in
        // The configured engine (SYSTEM_AUDIO_ENGINE=sck|taps).
        let cap = SystemAudioEngines.make(outputURL: url)
        do {
            try await cap.start()
        } catch {
            print("system audio start failed: \(error)")
            exit(1)
        }
        let t0 = Date()
        var lastPrinted = -1
        var killed = false
        while Date().timeIntervalSince(t0) < Double(seconds) {
            cap.checkHealth()
            let elapsed = Int(Date().timeIntervalSince(t0))
            if !killed, elapsed >= seconds / 2 {
                killed = true
                print("--- simulating stream death")
                await cap.simulateStreamDeath()
            }
            if elapsed != lastPrinted {
                lastPrinted = elapsed
                let ago = cap.lastBufferAt.map { Date().timeIntervalSince($0) } ?? -1
                print(String(format: "%3ds peak=%.3f buffers=%llu restarts=%d stalled=%@ lastBuffer=%.2fs ago padded=%.2f",
                             elapsed, cap.snapshotPeak(), cap.buffersDelivered, cap.restartCount,
                             cap.stalledSince == nil ? "no" : "yes", ago, cap.paddedSecondsTotal))
                fflush(stdout)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        await cap.stop()
        print("done: restarts=\(cap.restartCount) padded=\(cap.paddedSecondsTotal) file=\(url.path)")
        exit(0)
    }
    dispatchMain()
}

// Dev harness for the Core Audio process-tap engine, whatever
// SYSTEM_AUDIO_ENGINE says: capture N seconds, kill the tap's IO at the
// midpoint (the watchdog must rebuild it), print health once a second and
// permissionSuspect at the end, plus the live tap / aggregate-device counts
// before and after (a leak shows as a non-zero "after"). Switch the default
// output mid-run to exercise the device-change rebuild. Needs the System
// Audio Recording grant, which TCC charges to the RESPONSIBLE process: run
// straight from a terminal, the prompt and grant go to the terminal app.
// Launch through LaunchServices so they go to Minnas:
//   open -W -n -g --stdout /tmp/tap.log --stderr /tmp/tap.log .build/Minnas.app --args --tap-test <seconds> <output.caf>
if let idx = CommandLine.arguments.firstIndex(of: "--tap-test") {
    let args = CommandLine.arguments
    guard idx + 2 < args.count, let seconds = Int(args[idx + 1]) else {
        FileHandle.standardError.write(Data("usage: --tap-test <seconds> <output.caf>\n".utf8))
        exit(2)
    }
    let url = URL(fileURLWithPath: args[idx + 2])
    Task { @MainActor in
        let before = SystemAudioTapCapture.liveObjectCounts()
        print("before: taps=\(before.taps) aggregates=\(before.aggregates)")
        let cap = SystemAudioTapCapture(outputURL: url)
        // Printed with the time so a TAP_TEST_FAIL_RESTARTS=1 run can show
        // it fires exactly once (and nothing restarts after it).
        let tapT0 = Date()
        cap.onUnexpectedStop = {
            print(String(format: "--- onUnexpectedStop fired at %.1fs", Date().timeIntervalSince(tapT0)))
            fflush(stdout)
        }
        do {
            try await cap.start()
        } catch {
            print("tap start failed: \(error)")
            exit(1)
        }
        let running = SystemAudioTapCapture.liveObjectCounts()
        print("running: taps=\(running.taps) aggregates=\(running.aggregates)")
        let t0 = Date()
        var lastPrinted = -1
        var killed = false
        while Date().timeIntervalSince(t0) < Double(seconds) {
            cap.checkHealth()
            let elapsed = Int(Date().timeIntervalSince(t0))
            if !killed, elapsed >= seconds / 2 {
                killed = true
                print("--- simulating tap death")
                await cap.simulateStreamDeath()
            }
            if elapsed != lastPrinted {
                lastPrinted = elapsed
                let ago = cap.lastBufferAt.map { Date().timeIntervalSince($0) } ?? -1
                let live = SystemAudioTapCapture.liveObjectCounts()
                print(String(format: "%3ds peak=%.3f buffers=%llu restarts=%d stalled=%@ lastBuffer=%.2fs ago padded=%.2f dropped=%llu suspect=%@ taps=%d aggregates=%d",
                             elapsed, cap.snapshotPeak(), cap.buffersDelivered, cap.restartCount,
                             cap.stalledSince == nil ? "no" : "yes", ago, cap.paddedSecondsTotal,
                             cap.buffersDropped, cap.permissionSuspect ? "yes" : "no", live.taps, live.aggregates))
                fflush(stdout)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        await cap.stop()
        // The HAL client's object lists update asynchronously after a
        // destroy; give them a moment before counting.
        try? await Task.sleep(for: .seconds(1))
        let after = SystemAudioTapCapture.liveObjectCounts()
        print("after: taps=\(after.taps) aggregates=\(after.aggregates)")
        print("done: restarts=\(cap.restartCount) padded=\(cap.paddedSecondsTotal) dropped=\(cap.buffersDropped) hasSignal=\(cap.hasSignal) permissionSuspect=\(cap.permissionSuspect) file=\(url.path)")
        exit(0)
    }
    dispatchMain()
}

// Dev harness: record the mic for N seconds to a file, printing health
// once a second, so the route-change restart can be exercised by switching
// the default output device mid-run (which stops AVAudioEngine). Needs mic
// TCC → run the binary from inside the built .app bundle:
//   .build/Minnas.app/Contents/MacOS/minnas --mic-test <seconds> <output.caf>
if let idx = CommandLine.arguments.firstIndex(of: "--mic-test") {
    let args = CommandLine.arguments
    guard idx + 2 < args.count, let seconds = Int(args[idx + 1]) else {
        FileHandle.standardError.write(Data("usage: --mic-test <seconds> <output.caf>\n".utf8))
        exit(2)
    }
    let url = URL(fileURLWithPath: args[idx + 2])
    Task { @MainActor in
        let mic = MicCapture(outputURL: url)
        do {
            try await mic.start()
        } catch {
            print("mic start failed: \(error)")
            exit(1)
        }
        let t0 = Date()
        var lastPrinted = -1
        while Date().timeIntervalSince(t0) < Double(seconds) {
            mic.checkHealth()
            let elapsed = Int(Date().timeIntervalSince(t0))
            if elapsed != lastPrinted {
                lastPrinted = elapsed
                let ago = mic.lastBufferAt.map { Date().timeIntervalSince($0) } ?? -1
                print(String(format: "%3ds peak=%.3f restarts=%d stalled=%@ lastBuffer=%.2fs ago output=%@",
                             elapsed, mic.snapshotPeak(), mic.restartCount,
                             mic.stalledSince == nil ? "no" : "yes", ago,
                             AudioRoute.defaultOutputIsBuiltInSpeakers() ? "speakers" : "other"))
                fflush(stdout)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        mic.stop()
        print("done: restarts=\(mic.restartCount) file=\(url.path)")
        exit(0)
    }
    dispatchMain()
}

// Language-detection probe over a stored recording, per stream, without
// transcribing: prints the per-window detections, the per-stream votes and the
// combined decision under the current LanguagePolicy. For calibrating
// STT_LANGUAGE_MARGIN against recordings that were pinned wrongly.
//   minnas --probe-language <slug> [--model <id>]
if let idx = CommandLine.arguments.firstIndex(of: "--probe-language") {
    let args = CommandLine.arguments
    guard idx + 1 < args.count else {
        FileHandle.standardError.write(Data("usage: --probe-language <slug> [--model <id>]\n".utf8))
        exit(2)
    }
    let slug = args[idx + 1]
    var model = TranscriptionModel.default
    if let m = args.firstIndex(of: "--model"), m + 1 < args.count, let parsed = TranscriptionModel(rawValue: args[m + 1]) {
        model = parsed
    }
    let slot = Outbox.slot(forDir: Outbox.rootURL.appendingPathComponent(slug, isDirectory: true))
    Transcriber.shared.trace = { print($0) }
    Task {
        do {
            let meta = try Outbox.readMeta(from: slot.metaURL)
            let policy = LanguagePolicy.current(attendees: meta.attendees)
            print("# \(slug): \(meta.title) — candidates \(policy.candidates) margin \(policy.margin)")
            let streams = meta.isSingleStream ? [slot.systemAudioReadURL] : [slot.micAudioReadURL, slot.systemAudioReadURL]
            for url in streams where FileManager.default.fileExists(atPath: url.path) {
                print("## \(url.lastPathComponent)")
                let (_, scores) = try await Transcriber.shared.detectLanguageScores(audioPath: url.path, candidates: policy.candidates, model: model)
                let line = scores.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.3f", $0.value))" }.joined(separator: " ")
                print("stream votes: \(line) → \(policy.winner(scores) ?? "?")")
            }
            let combined = try await Transcriber.shared.resolveLanguage(forStreams: streams, model: model, policy: policy)
            print("decision: \(combined ?? "?")")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("probe failed: \(error)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}

// Voice Memos harnesses (no TCC needed — the library is a plain folder):
//   minnas --list-memos [N]
//   minnas --import-memo <unique-id> [--title "<title>"] [--model <id>]
// --import-memo mirrors the menubar import minus delivery: slot + audio +
// meta, then a local STT pass (or Apple's transcript, when
// VOICE_MEMO_TRANSCRIPT=apple and the memo has one). Prints the slug.
if let idx = CommandLine.arguments.firstIndex(of: "--list-memos") {
    let args = CommandLine.arguments
    let limit = idx + 1 < args.count ? Int(args[idx + 1]) ?? 20 : 20
    do {
        let f = ISO8601DateFormatter()
        for memo in try VoiceMemoLibrary.list(limit: limit) {
            let mins = Int(memo.duration / 60), secs = Int(memo.duration) % 60
            print("\(memo.id)  \(f.string(from: memo.recordedAt))  \(String(format: "%3d:%02d", mins, secs))  \(memo.isDownloaded ? "local " : "cloud ")  \(memo.fileURL.pathExtension)  \(memo.displayTitle)")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("list-memos failed: \(error)\n".utf8))
        exit(1)
    }
}

if let idx = CommandLine.arguments.firstIndex(of: "--import-memo") {
    let args = CommandLine.arguments
    guard idx + 1 < args.count else {
        FileHandle.standardError.write(Data("usage: --import-memo <unique-id> [--title \"<title>\"] [--model <id>]\n".utf8))
        exit(2)
    }
    let id = args[idx + 1]
    var title = ""
    if let t = args.firstIndex(of: "--title"), t + 1 < args.count { title = args[t + 1] }
    var model = TranscriptionModel.default
    if let m = args.firstIndex(of: "--model"), m + 1 < args.count, let parsed = TranscriptionModel(rawValue: args[m + 1]) {
        model = parsed
    }
    Task {
        do {
            guard let memo = try VoiceMemoLibrary.memo(withID: id) else {
                FileHandle.standardError.write(Data("no voice memo with id \(id) (see --list-memos)\n".utf8))
                exit(1)
            }
            let result = try await VoiceMemoImporter.prepare(memo: memo, title: title)
            if result.usedAppleTranscript {
                print("imported \(result.slot.slug) using Apple's transcript")
            } else {
                print("imported \(result.slot.slug); no Apple transcript — transcribing with \(model.rawValue)…")
                let output = try await TranscriptionJob.run(slot: result.slot, model: model)
                print("transcribed: \(output.segments.count) segments, languages \(output.languages.map(\.code))")
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("import-memo failed: \(error)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}

// File import harness (no TCC needed):
//   minnas --import-file <path> [--title "<title>"] [--model <id>]
// Mirrors "Transcribe Audio File…" minus delivery: slot + m4a + meta, then
// the STT pass (with diarization). Prints the slug and the speakers found.
if let idx = CommandLine.arguments.firstIndex(of: "--import-file") {
    let args = CommandLine.arguments
    guard idx + 1 < args.count else {
        FileHandle.standardError.write(Data("usage: --import-file <path> [--title \"<title>\"] [--model <id>]\n".utf8))
        exit(2)
    }
    let fileURL = URL(fileURLWithPath: args[idx + 1])
    var title = ""
    if let t = args.firstIndex(of: "--title"), t + 1 < args.count { title = args[t + 1] }
    var model = TranscriptionModel.default
    if let m = args.firstIndex(of: "--model"), m + 1 < args.count, let parsed = TranscriptionModel(rawValue: args[m + 1]) {
        model = parsed
    }
    Transcriber.shared.trace = { print($0) }
    Task {
        do {
            let result = try await AudioFileImporter.prepare(
                fileURL: fileURL, title: title, startedAt: AudioFileImporter.defaultStartedAt(for: fileURL)
            )
            print("imported \(result.slot.slug); transcribing with \(model.rawValue)…")
            let output = try await TranscriptionJob.run(slot: result.slot, model: model)
            let speakers = Set(output.segments.map(\.speaker)).sorted()
            print("transcribed: \(output.segments.count) segments, languages \(output.languages.map(\.code)), speakers \(speakers)")
            print("transcript: \(result.slot.transcriptURL.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("import-file failed: \(error)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}

// Delivery harness (no TCC needed):
//   minnas --deliver <slug> [--run]
// Without --run, prints the plan: the active sinks, which apply to this
// recording, which are pending and due, and the folder sink's target path.
// With --run, makes one attempt per pending sink (ignoring the backoff
// wait, like the menu's Retry Delivery) and prints each outcome.
if let idx = CommandLine.arguments.firstIndex(of: "--deliver") {
    let args = CommandLine.arguments
    guard idx + 1 < args.count, !args[idx + 1].hasPrefix("--") else {
        FileHandle.standardError.write(Data("usage: --deliver <slug> [--run]\n".utf8))
        exit(2)
    }
    let slug = args[idx + 1]
    let run = args.contains("--run")
    let slot = Outbox.slot(forDir: Outbox.rootURL.appendingPathComponent(slug, isDirectory: true))
    let meta: RecordingMeta
    do {
        meta = try Outbox.readMeta(from: slot.metaURL)
    } catch {
        FileHandle.standardError.write(Data("deliver: can't read meta for \(slug): \(error)\n".utf8))
        exit(1)
    }
    let sinks = SinkDispatcher.activeSinks()
    print("recording: \(slug) — \"\(meta.title)\"")
    print("ready: \(SinkDispatcher.isReady(slot)) (a current transcript.md)")
    print("folder: \(Config.transcriptsFolderURL()?.path ?? "(off)")")
    if sinks.isEmpty { print("no active sinks") }
    for sink in sinks {
        var line = "  \(sink.id) (\(sink.displayName)): "
        if !sink.applies(to: meta) {
            line += "not applicable"
        } else if meta.isDelivered(to: sink.id) {
            let location = meta.deliveries?[sink.id]?.location
            line += "delivered\(location.map { " → \($0)" } ?? "")"
        } else {
            let attempt = meta.attempt(for: sink.id)
            line += "pending, \(SinkDispatcher.isDue(sink, meta: meta) ? "due" : "not due") (attempts \(attempt.attempt_count))"
            if let folderSink = sink as? MarkdownFolderSink {
                line += " → \(folderSink.plannedDestination(slot: slot, meta: meta).path)"
            }
        }
        print(line)
    }
    guard run else { exit(0) }
    Task {
        let outcomes = await SinkDispatcher.deliverPending(slot: slot, ignoringSchedule: true)
        if outcomes.isEmpty { print("nothing pending") }
        for outcome in outcomes {
            switch outcome.result {
            case .success(let delivery):
                print("  \(outcome.sinkID): delivered\(delivery.location.map { " → \($0)" } ?? "")")
            case .failure(let error):
                print("  \(outcome.sinkID): FAILED: \(error)")
            }
        }
        exit(outcomes.allSatisfy(\.succeeded) ? 0 : 1)
    }
    dispatchMain()
}

// Settings / setup window harness: the windows alone, without AppDelegate —
// so no instance lock (it runs next to the real menubar app), no recording,
// no calendar poll. Quits when the window closes.
//   minnas --settings-window [general|transcription|cloud|calendar|permissions]
//                    [--test-key] [--grant-calendar] [--snapshot <dir>]
//   minnas --onboarding [1-4] [--snapshot <dir>]
// --test-key presses Test Key and prints only the HTTP status; --grant-calendar
// presses Grant Calendar Access (the macOS prompt is the user's to answer).
// --snapshot renders every tab / step to <dir>/t3-*.png and quits: a layout
// check that needs no Screen Recording grant. Prints "window <number>" for
// `screencapture -l`. Run from inside the bundle for the keychain and TCC.
if CommandLine.arguments.contains("--settings-window") || CommandLine.arguments.contains("--onboarding") {
    let args = CommandLine.arguments
    func value(after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count, !args[i + 1].hasPrefix("--") else { return nil }
        return args[i + 1]
    }
    func say(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
    func render(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        say("snapshot \(url.path)")
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let snapshotDir = value(after: "--snapshot").map { URL(fileURLWithPath: $0, isDirectory: true) }
    var retained: [NSWindowController] = []

    let onboardingOnly = args.contains("--onboarding") && !args.contains("--settings-window")
    if onboardingOnly {
        let controller = OnboardingWindowController { exit(0) }
        retained.append(controller)
        controller.show(step: (Int(value(after: "--onboarding") ?? "1") ?? 1) - 1)
        controller.showWindow(nil)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard let window = controller.window else { return }
            say("window \(window.windowNumber)")
            if let snapshotDir {
                for step in 0..<OnboardingWindowController.stepCount {
                    controller.show(step: step)
                    render(window, to: snapshotDir.appendingPathComponent("t3-onboarding-\(step + 1).png"))
                }
                exit(0)
            }
        }
    } else {
        let controller = SettingsWindowController(
            onRunSetup: {
                let setup = OnboardingWindowController {}
                retained.append(setup)
                setup.showWindow(nil)
            },
            onClose: { exit(0) }
        )
        retained.append(controller)
        let tab = value(after: "--settings-window").flatMap(SettingsWindowController.Tab.init(rawValue:)) ?? .general
        controller.select(tab)
        controller.showWindow(nil)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard let window = controller.window else { return }
            say("window \(window.windowNumber)")
            if let snapshotDir {
                for tab in SettingsWindowController.Tab.allCases {
                    controller.select(tab)
                    render(window, to: snapshotDir.appendingPathComponent("t3-settings-\(tab.rawValue).png"))
                }
                exit(0)
            }
            if args.contains("--test-key") {
                controller.select(.cloud)
                controller.testKeyClicked()
                while controller.lastKeyTestStatus == nil { try? await Task.sleep(for: .milliseconds(100)) }
                say("test-key: HTTP \(controller.lastKeyTestStatus.flatMap { $0 }.map(String.init) ?? "no response")")
            }
            if args.contains("--grant-calendar") {
                controller.select(.calendar)
                controller.grantCalendarAccess()
                say("grant-calendar: requested (status before: \(EventKitCalendar.describe(EventKitCalendar.authorizationStatus)))")
            }
        }
    }
    NSApp.activate(ignoringOtherApps: true)
    app.run()
    exit(0)
}

// Voice Memos picker harness:
//   minnas --memo-window
// Opens the Import Voice Memos picker on its own (no lock, no outbox) so
// the live-refresh behaviour can be watched beside a running app: prints
// "window <number>", then "picked <n>" or "closed" and exits. Reads the
// library, so it needs Full Disk Access (inherited from the terminal).
if CommandLine.arguments.contains("--memo-window") {
    func say(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    var retained: [NSWindowController] = []
    let controller = VoiceMemoImportWindowController(
        onImport: { picked in say("picked \(picked.count)"); exit(0) },
        onClose: { say("closed"); exit(0) }
    )
    retained.append(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(800))
        if let window = controller.window { say("window \(window.windowNumber)") }
    }
    NSApp.activate(ignoringOtherApps: true)
    app.run()
    exit(0)
}

// Transcript text-cleanup harness (no models needed):
//   minnas --cleanup-test
// Runs the hallucination filter and text normaliser over a fixed set of
// lines Whisper has produced on silence or shouting, and over lines that
// must survive, and exits non-zero if any lands on the wrong side.
if CommandLine.arguments.contains("--cleanup-test") {
    // The lines live in TranscriptBuilderFixtures, shared with the
    // swift-testing suite.
    let mustDrop = TranscriptBuilderFixtures.mustDrop
    let mustKeep = TranscriptBuilderFixtures.mustKeep
    let cleaned = TranscriptBuilderFixtures.cleaned
    var failed = false
    for line in mustDrop where !TranscriptBuilder.isKnownHallucination(line) {
        print("KEPT  (should drop): \(line)"); failed = true
    }
    for line in mustKeep where TranscriptBuilder.isKnownHallucination(line) {
        print("DROPPED (should keep): \(line)"); failed = true
    }
    for item in cleaned {
        let got = TranscriptBuilder.cleanText(item.input, language: item.language)
        if got != item.expected { print("CLEAN mismatch: \(item.input) → \(got) (expected \(item.expected))"); failed = true }
    }
    print(failed ? "cleanup-test FAILED" : "cleanup-test OK (\(mustDrop.count) dropped, \(mustKeep.count) kept, \(cleaned.count) cleaned)")
    exit(failed ? 1 : 0)
}

// Diarization harness (no TCC needed):
//   minnas --diarize <audio file>
// Prints every speaker turn and the timing, for checking the diarizer on a
// known recording before trusting its letters in a transcript.
if let idx = CommandLine.arguments.firstIndex(of: "--diarize") {
    let args = CommandLine.arguments
    guard idx + 1 < args.count else {
        FileHandle.standardError.write(Data("usage: --diarize <audio file>\n".utf8))
        exit(2)
    }
    let path = args[idx + 1]
    Transcriber.shared.trace = { print($0) }
    Task {
        do {
            let started = Date()
            let turns = try await Diarizer.shared.diarize(audioPath: path) { f in
                FileHandle.standardError.write(Data("\rdiarizing… \(Int(f * 100))%".utf8))
            }
            FileHandle.standardError.write(Data("\n".utf8))
            guard let turns else {
                print("one speaker (no labels would be applied); \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                exit(0)
            }
            for t in turns {
                print(String(format: "%7.1f – %7.1f  %@", t.start, t.end, t.speaker))
            }
            var perSpeaker: [String: Float] = [:]
            for t in turns { perSpeaker[t.speaker, default: 0] += t.end - t.start }
            print("speech per speaker: " + perSpeaker.sorted { $0.key < $1.key }.map { "\($0.key)=\(Int($0.value))s" }.joined(separator: " "))
            print("total \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("diarize failed: \(error)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}

// Dev: detect the language of an audio file (one WhisperKit pass), to
// verify the detect-once path. minnas --detect-lang <audio-file>
if let idx = CommandLine.arguments.firstIndex(of: "--detect-lang") {
    let args = CommandLine.arguments
    guard idx + 1 < args.count else {
        FileHandle.standardError.write(Data("usage: --detect-lang <audio-file>\n".utf8))
        exit(2)
    }
    let path = args[idx + 1]
    Task {
        do {
            let candidates = Config.sttCandidateLanguages()
            let (lang, scores) = try await Transcriber.shared.detectLanguageScores(audioPath: path, candidates: candidates)
            let breakdown = scores.sorted { $0.value > $1.value }.map { "\($0.key)=\(String(format: "%.2f", $0.value))" }.joined(separator: " ")
            print("dominant language (\(candidates.joined(separator: "/"))): \(lang ?? "n/a")  [\(breakdown)]")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("detect-lang failed: \(error)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}

// Dev: report the mic/system envelope correlation for a stored recording,
// to calibrate the duplicate-stream threshold.
//   minnas --dup-check <slug>
if let idx = CommandLine.arguments.firstIndex(of: "--dup-check") {
    let args = CommandLine.arguments
    guard idx + 1 < args.count else {
        FileHandle.standardError.write(Data("usage: --dup-check <slug>\n".utf8))
        exit(2)
    }
    let slot = Outbox.slot(forDir: Outbox.rootURL.appendingPathComponent(args[idx + 1], isDirectory: true))
    if let corr = AudioDuplication.envelopeCorrelation(slot.micAudioReadURL, slot.systemAudioReadURL) {
        print(String(format: "mic/system envelope correlation: %.3f", corr))
    } else {
        print("envelope correlation: n/a (unreadable or silent stream)")
    }
    exit(0)
}

// Dev check: capture ~6s of system audio and report the peak level, to
// verify ScreenCaptureKit is actually delivering audio (not silence).
// Needs Screen Recording TCC, so run the .app's binary, not `swift run`:
//   .build/Minnas.app/Contents/MacOS/minnas --audio-test
if CommandLine.arguments.contains("--audio-test") {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("minnas-audio-test.caf")
    let capture = SystemAudioCapture(outputURL: url)
    Task {
        do {
            try await capture.start()
            print("Capturing 6s of system audio — play something now…")
            var maxPeak: Float = 0
            for _ in 0..<60 {
                try await Task.sleep(nanoseconds: 100_000_000)
                maxPeak = max(maxPeak, capture.snapshotPeak())
            }
            await capture.stop()
            try? FileManager.default.removeItem(at: url)
            let verdict = maxPeak > 0.001 ? "AUDIO PRESENT ✅" : "SILENT ❌"
            let line = String(format: "max system-audio peak over 6s: %.4f — %@", maxPeak, verdict)
            print(line)
            // Also write to a fixed path so a bundle launch (open -n, no
            // attached terminal) can report its result.
            try? line.write(toFile: "/tmp/minnas-audio-test-result.txt", atomically: true, encoding: .utf8)
            exit(maxPeak > 0.001 ? 0 : 1)
        } catch {
            let msg = "audio-test failed: \(error)"
            FileHandle.standardError.write(Data((msg + "\n").utf8))
            try? msg.write(toFile: "/tmp/minnas-audio-test-result.txt", atomically: true, encoding: .utf8)
            exit(2)
        }
    }
    dispatchMain()
}

// Dev smoke: pure-logic assertions for RetrySchedule (the delivery
// backoff) and the pruning rule. Runs without TCC and without XCTest —
// exits 0 on success, 1 on assertion failure with a message pointing at
// the failing block. Run with: `swift run minnas --self-test`.
if CommandLine.arguments.contains("--self-test") {
    var failed = 0
    func check(_ ok: Bool, _ name: String) {
        if !ok {
            FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8))
            failed += 1
        } else {
            print("ok: \(name)")
        }
    }

    // ─────── RetrySchedule ───────

    // First attempt is always due.
    check(
        RetrySchedule.isDue(attemptCount: 0, lastAttemptAt: nil, now: Date()),
        "retry: never-tried is due"
    )
    // Attempt count 1 needs a 5-minute gap.
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let oneMinAgo = now.addingTimeInterval(-60)
    let sixMinAgo = now.addingTimeInterval(-6 * 60)
    check(
        !RetrySchedule.isDue(attemptCount: 1, lastAttemptAt: oneMinAgo, now: now),
        "retry: 1 min after 1st failure is NOT due"
    )
    check(
        RetrySchedule.isDue(attemptCount: 1, lastAttemptAt: sixMinAgo, now: now),
        "retry: 6 min after 1st failure IS due"
    )
    // Exponential growth.
    let nineMinAgo = now.addingTimeInterval(-9 * 60)
    check(
        !RetrySchedule.isDue(attemptCount: 2, lastAttemptAt: nineMinAgo, now: now),
        "retry: 9 min after 2nd failure is NOT due (needs 10)"
    )
    let elevenMinAgo = now.addingTimeInterval(-11 * 60)
    check(
        RetrySchedule.isDue(attemptCount: 2, lastAttemptAt: elevenMinAgo, now: now),
        "retry: 11 min after 2nd failure IS due"
    )
    // After many failures, capped at 60 min.
    let fiftyNineMinAgo = now.addingTimeInterval(-59 * 60)
    let sixtyOneMinAgo = now.addingTimeInterval(-61 * 60)
    check(
        !RetrySchedule.isDue(attemptCount: 99, lastAttemptAt: fiftyNineMinAgo, now: now),
        "retry: 59 min after 99 failures NOT due (cap is 60)"
    )
    check(
        RetrySchedule.isDue(attemptCount: 99, lastAttemptAt: sixtyOneMinAgo, now: now),
        "retry: 61 min after 99 failures IS due (cap holds)"
    )

    // ─────── Pruning (Outbox.pruneAction) ───────

    let folderSink = MarkdownFolderSink(folder: URL(fileURLWithPath: "/tmp/minnas-self-test", isDirectory: true))
    var untranscribed = RecordingMeta(title: "t", started_at: now, device: AppInfo.device, client_version: AppInfo.version)
    untranscribed.ended_at = now.addingTimeInterval(60)
    var transcribed = untranscribed
    transcribed.transcription = TranscriptionProvenance(engine: "whisperkit", model: "large-v3", transcribed_at: now)
    var delivered = transcribed
    delivered.recordDelivery(SinkDelivery(delivered_at: now, location: "/tmp/minnas-self-test/t.md"), for: MarkdownFolderSink.sinkID)
    check(
        Outbox.pruneAction(meta: untranscribed, hasTranscript: false, activeSinks: []) == .keep,
        "prune: untranscribed slot keeps its audio"
    )
    check(
        Outbox.pruneAction(meta: transcribed, hasTranscript: true, activeSinks: [folderSink]) == .keep,
        "prune: transcript still owed to the folder is kept whole"
    )
    check(
        Outbox.pruneAction(meta: transcribed, hasTranscript: true, activeSinks: []) == .audioOnly,
        "prune: no folder chosen → audio goes, transcript stays"
    )
    check(
        Outbox.pruneAction(meta: delivered, hasTranscript: true, activeSinks: [folderSink]) == .wholeSlot,
        "prune: delivered to the folder → whole slot goes"
    )

    // ─────── Voice Memos transcript parser ───────

    let negativeAttributeIndex = Data(#"""
        {
          "attributedString": {
            "runs": ["Hello", -1, " world.", 0],
            "attributeTable": [{"timeRange": [0.0, 1.0]}]
          },
          "locale": {"identifier": "en_US"}
        }
        """#.utf8)
    do {
        let parsed = try VoiceMemoLibrary.parseAppleTranscript(negativeAttributeIndex)
        check(
            parsed.segments.first?.text == "Hello world.",
            "voice memo: negative attribute index is ignored"
        )
    } catch {
        check(false, "voice memo: negative attribute index is ignored (\(error))")
    }

    if failed > 0 {
        FileHandle.standardError.write(Data("\nSELF-TEST FAILED (\(failed) assertion(s))\n".utf8))
        exit(1)
    }
    print("\nSELF-TEST OK")
    exit(0)
}

// Dev smoke: print upcoming events from the macOS Calendar (EventKit).
//   minnas --calendar [within_minutes]
// Needs the Calendars grant, which belongs to the app bundle: run the
// binary inside the built .app (.build/Minnas.app/Contents/MacOS/minnas).
// Without the grant it prints the authorization status and exits 1.
if let idx = CommandLine.arguments.firstIndex(of: "--calendar") {
    let args = CommandLine.arguments
    let within = (idx + 1 < args.count ? Int(args[idx + 1]) : nil) ?? 60
    Task { @MainActor in
        do {
            let events = try await EventKitCalendar.upcoming(withinMinutes: within)
            print("upcoming (\(events.count)) within \(within)m:")
            for e in events {
                let mins = Int(e.start.timeIntervalSinceNow / 60)
                print("  +\(mins)m  \(e.title ?? "(untitled)")  id=\(e.calendar_event_id ?? "-")  conf=\(e.conferencing ?? "-")  attendees=\(e.attendees?.count ?? 0)")
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("calendar failed: \(error)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
