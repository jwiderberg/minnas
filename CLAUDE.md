# CLAUDE.md

Engineering rules for working on Minnas (for people and for coding agents).
README.md is the user-facing description; SECURITY.md is the threat model.

## What it is

A macOS menubar app (Swift 6.2, AppKit, strict concurrency) that records a
meeting as two tracks — the microphone ("Me") and the audio the Mac plays
("Them") — transcribes them on device (WhisperKit, plus FluidAudio speaker
diarization for "Them (A)/(B)"), or optionally with OpenAI's
`gpt-4o-transcribe-diarize`, and writes each transcript as Markdown into a
folder the user picks.

Pipeline:
1. Optional calendar poll (`CalendarEventKit`, EventKit) → a few minutes
   before a meeting with a Zoom/Meet/Teams link (`AppDelegate.isRecordableMeeting`),
   offer to record it.
2. Capture: `RecordingSession` runs `MicCapture` (AVAudioEngine) and a
   `SystemAudioEngine` (`SystemAudioTapCapture` or `SystemAudioCapture`) into
   `~/Library/Application Support/minnas/outbox/<slug>/`.
3. `TranscriptionJob` → `Transcriber` (dispatches on `TranscriptionModel.engine`)
   → `TranscriptBuilder` (transcript.md with frontmatter; hallucination and
   caption filters; language per 30 s window via `LanguagePolicy`).
4. `SinkDispatcher` delivers to every active `TranscriptSink`
   (`MarkdownFolderSink`), with per-sink retry state in meta.json.
5. Audio is compressed to m4a after transcription and pruned after
   `recordingsKeepDays`.

## Commands

```sh
swift build                       # compile check (no bundle); look for "Build complete"
bash scripts/make-app.sh          # build + assemble + sign .build/Minnas.app
open .build/Minnas.app            # launch the menubar app
swift run minnas --cleanup-test   # transcript text filters; run after touching TranscriptBuilder
swift run minnas --self-test      # RetrySchedule + pruning rule
bash -n scripts/*.sh
```

Requires Swift 6.2+ (Xcode 26, which runs on macOS 15.6+) to build; the app
runs on macOS 15+. The floor is macOS 15 in both `Package.swift` and
`App/Info.plist` (`LSMinimumSystemVersion`; `scripts/install.sh` enforces
it). Nothing in the code needs a newer OS. macOS 14 is excluded on purpose
(a Core ML BNNS crash FluidAudio documents on 14.x). Keep the two floors in
step, and don't add `if #available` branches for anything older than 15.

## Harnesses

No TCC needed (`swift run minnas …`):
`--version`, `--settings [set <name> <value>|unset <name>]` (value `-` reads
stdin), `--transcribe <audio> [--model <id>]`, `--retranscribe <slug> [--model <id>]`
(a cloud `--model` is the consent to send that audio), `--probe-language <slug>`
(per-stream language scores + decision, for calibrating `STT_LANGUAGE_MARGIN`),
`--detect-lang <audio>`, `--dup-check <slug>`, `--diarize <audio>`,
`--import-file <path> [--title T] [--model <id>]`, `--deliver <slug> [--run]`
(the delivery plan, or one attempt per pending sink), `--cleanup-test`,
`--self-test`. `--list-memos [N]` / `--import-memo <id> [--title T] [--model <id>]`
read the Voice Memos library, which needs Full Disk Access for the process
running them (a terminal that has it, or the app bundle).

Need TCC, so run the binary inside the built bundle
(`.build/Minnas.app/Contents/MacOS/minnas …`): `--mic-test <seconds> <out.caf>`,
`--system-test <seconds> <out.caf>` (the configured engine; kills its stream
at the midpoint), `--audio-test`, `--calendar [within_minutes]` (EventKit),
`--settings-window [tab] [--test-key] [--grant-calendar] [--snapshot <dir>]`,
`--onboarding [1-4] [--snapshot <dir>]`, `--memo-window` (the Voice Memos picker on its own).

`--tap-test <seconds> <out.caf>` exercises the process tap (signal, midpoint
kill, output switch, no leaked taps/aggregate devices). The System Audio
Recording grant is charged to the RESPONSIBLE process, so launch it through
LaunchServices or the terminal gets the prompt and the grant:

```sh
open -W -n -g --stdout /tmp/tap.log --stderr /tmp/tap.log .build/Minnas.app --args --tap-test 30 /tmp/tap.caf
```

`TAP_TEST_FAIL_RESTARTS=1` makes every tap restart fail, to check that
restart exhaustion fires `onUnexpectedStop` exactly once.

CLI harnesses don't take the single-instance lock: don't run
`--retranscribe` or the imports against a slot the app is recording.

## Capture must survive route changes — test it for real

AVAudioEngine stops itself on every hardware configuration change (headphones
connecting, the default output or input switching, the voice-processing
aggregate device being torn down), posts `AVAudioEngineConfigurationChange`,
and never restarts on its own. Unhandled, that silently loses the user's side
of a meeting while the menubar keeps saying "recording". The rules:

- `MicCapture` observes the notification **and** `checkHealth()` runs from the
  10 Hz recording tick (engine not running, or no buffer for 3 s → re-attach).
  The re-attach pads the mic file with silence for the dead stretch so it
  stays time-aligned with the system track, re-decides AEC for the new route,
  and resamples if the new input runs at another rate.
- The tap block is built in a `nonisolated static func`. A closure formed
  inside a `@MainActor` method inherits main-actor isolation and SIGTRAPs on
  the audio thread (`dispatch_assert_queue`). Don't inline it.
- Padding is bounded: the mic pad is capped at 300 s and never covers a system
  sleep (`NSWorkspace` will-sleep/did-wake reset the stall clock); the system
  gap fill skips non-finite or > 300 s gaps, waits at most 2 s for the writer
  and bails when it isn't `.writing`; `stop()` cancels and awaits any restart
  in flight; dropped buffers are counted and leave a hole for the next fill.
- Both system engines have the same watchdog (no buffer for 3 s, or the
  stream reports an error → rebuild on the same writer; the next buffer fills
  the timestamp gap with silence). Only 20 failed restarts end the recording
  (with an alert), and restart exhaustion is terminal (`running = false`
  before `onUnexpectedStop`). A writer refusing data (disk full) raises a
  critical alert — a stream restart can't fix a file.
- The menubar shows `✗` for a track while a restart is pending; a critical
  alert fires if it stays dead 10 s, and another if the mic delivers pure
  digital zeros for 2 min after having had signal.
- `meta.json` is written at recording START (ended_at nil). On launch,
  `recoverInterruptedRecordings` finishes any slot with raw .caf files and no
  ended_at, alerts, and transcribes it. `capture_health` in meta.json records
  restarts, padded seconds and captured seconds per stream.
- Quit runs the normal asynchronous stop path before terminating, so capture
  writers are finalized, `ended_at` is persisted, and transcription is
  queued; AppKit waits at most 15 seconds before allowing termination.
- **Test any change to `MicCapture`, `SystemAudioCapture` or
  `SystemAudioTapCapture` with a real run from inside the bundle before
  relaunching the app**: `--mic-test 30 /tmp/x.caf` / `--system-test` /
  `--tap-test` (via `open -n`), and flip the default input and output device
  mid-run (a CoreAudio one-liner that sets
  `kAudioHardwarePropertyDefault{Input,Output}Device` does it). Expect the
  engine back in about a second and the file duration to match wall clock.
- Reading the app's log from zsh: `log` is a zsh builtin — use
  `/usr/bin/log show --predicate 'subsystem == "com.jwiderberg.minnas"'`.
  Only `.notice`/`.error` lines persist; `.info` doesn't.

## Safety rails — keep them

- **Single instance.** `applicationDidFinishLaunching` takes `flock` on
  `outbox/.lock` before anything touches the outbox and fails CLOSED
  (contention → "already running" alert; any other failure → a distinct
  alert). A second instance would otherwise "recover" the live recording and
  `compressAudio` would unlink the .caf being written.
- **Recovery before pruning**, and recovery skips slots whose newest .caf is
  < 60 s old. Skipped slots get one recovery re-check after 65 seconds,
  unless that slug is the current live session.
- **Compression stays on the serialized transcription queue**, validates
  before removing raw audio, exports through same-directory `.m4a.part`
  files followed by rename, and launch removes stale sidecars. Quit waits up
  to its 15-second deadline for compression already in flight.
- **Pruning** (`Outbox.pruneOldRecordings` / `pruneAction`) ages by the slot
  directory's creation date (then `transcribed_at`, then `started_at`), never
  removes a slot an active sink still owes, never removes audio that hasn't
  been transcribed, removes the whole slot only once it was delivered
  somewhere, and otherwise removes audio only. It never touches the
  transcripts folder. `listSlots` therefore lists transcript-only slots;
  Re-transcribe is offered only when audio exists.
- **Cloud only by explicit choice.** `Config.defaultModel()` resolves a cloud
  pick to the local default while cloud transcription is off or has no key;
  the Re-transcribe menu offers the cloud model only when
  `Config.cloudTranscriptionAvailable()`.
- **HTTP goes through `HTTP.session`** (HTTPSession.swift): ephemeral, no URL
  cache, no cookies, refuses redirects. `URLSession.shared` persists request
  headers and bodies in `~/Library/Caches/<bundle id>/Cache.db` — that would
  be the API key and meeting audio. **Never add a `URLSession.shared` call.**
  The only endpoints are OpenAI's, hard-coded https; there are no URL
  settings.
- **Hardened runtime.** `make-app.sh` signs with `--options runtime` and
  `App/Minnas.entitlements` (audio-input + personal-information.calendars)
  and refuses a binary that links NemoTextProcessing (FluidAudio's prebuilt
  Rust library; the `Diarizer` trait must keep it out).
- **Untrusted text.** Slugs are byte-capped (100 UTF-8 bytes), diacritic-folded
  and stripped of combining marks; `makeSlot` retries with `untitled`. Titles
  are normalised at meta creation and again in `TranscriptionJob.finish`
  (`Outbox.normalizeTitle`: one line, ≤ 200 chars, empty → "Meeting"); the
  folder file name goes through `MarkdownFolderSink.fileSafeTitle`; an
  attendee name used as a speaker label is normalised the same way.
  `TranscriptionJob.checkSegments` refuses non-finite, negative or reversed
  segment times before anything is written.
- **Logs:** error bodies and paths are `.private`. Titles/slugs stay `.public`
  on purpose (post-mortems need them; the unified log is per-user).

## Settings, delivery sinks, capture engines, UI

- **Settings are app state, `.env` is a developer override.** `Settings`
  (UserDefaults under `settings.<name>`) + `KeychainStore` (login keychain,
  service = bundle id) hold everything; `Config` only RESOLVES: process env →
  Settings/Keychain → `.env` → default. The Keychain is touched only from
  inside the `.app` bundle (a `swift run` binary has a new signature every
  build and would prompt). The bundle migrates the app-support `.env` into
  Settings once (`settings.migrated_v1`). A failed Keychain read is logged,
  never silent. Defaults: no transcripts folder until setup, calendar off,
  languages `["en"]`, engine `taps`, nothing excluded, 30 days of audio.
- **Delivery is a sink.** `TranscriptSink` (`MarkdownFolderSink`:
  `<yyyy-MM-dd HHmm> <title>.md` into `transcriptsFolderPath`) behind
  `SinkDispatcher`, which owns per-sink pending/retry state in meta
  (`deliveries`, `delivery_attempts`, `previous_locations`) with the
  `RetrySchedule` backoff (5 → 10 → 30 → 60 min). A second destination is one
  new sink type plus a line in `SinkDispatcher.activeSinks()`. Invariants:
  `TranscriptionJob.finish` writes transcript.md BEFORE the meta reset and
  stamps `transcript_written_at`; sinks are ready only when their required
  files are at least that new; every meta read-modify-write goes through
  `Outbox.mutateMeta` (one process-wide lock — a CLI beside the app can still
  race it); the folder sink owns a file only via the slot's recorded
  location, refuses symlinks/out-of-folder paths, and writes temp + rename.
  Choosing a folder backfills every existing slot on the next 5-minute tick.
- **Two system-audio engines** behind `SystemAudioEngine`: `taps` (default;
  `SystemAudioTapCapture`: Core Audio process tap on a private aggregate
  device, needs the "System Audio Recording" grant, excludes apps natively by
  PID, re-resolved on every restart; tap auto-start is OFF on purpose so IO
  runs during silence) and `sck` (`SystemAudioCapture`: ScreenCaptureKit,
  needs Screen Recording). Chosen by `settings.systemAudioEngine` /
  `SYSTEM_AUDIO_ENGINE`. Without the grant the tap delivers silence;
  `permissionSuspect` flags 15 s of zeros but cannot tell "denied" from
  "nothing playing".
- **UI:** `SettingsWindow` (General / Transcription / Cloud / Calendar /
  Permissions; AppKit; every control writes through `Settings.shared`),
  `Onboarding` (4 steps on first launch, `settings.onboardingCompleted`;
  step 1 requires a transcripts folder and suggests
  `~/Documents/Minnas Transcripts`; "Run Setup Again" in General; the
  calendar poll starts only after Finish), `CalendarEventKit`
  (`settings.calendarSource` off|eventkit).
- **Distribution:** `scripts/install.sh` (build from source, local signing
  identity after an explicit yes, copy to /Applications, prints the usage
  strings from Info.plist; `--dry-run`) and `scripts/uninstall.sh` (asks per
  item; `tccutil reset`s). CI builds, runs `--cleanup-test` and
  `--self-test`, and dry-runs both scripts.

## App bundle, TCC and the signing identity

TCC permissions (microphone, system audio, screen recording, calendars) attach
to a `CFBundleIdentifier` (`com.jwiderberg.minnas`). A bare `swift run`
binary has none, so anything that calls AVAudioEngine, a process tap,
ScreenCaptureKit or EventKit must run from inside the `.app`.
`App/Info.plist` is the editable source of truth; `make-app.sh` copies it into
the bundle on every build. Don't edit the built copy.

- **Import Voice Memos… needs Full Disk Access.** Since macOS 15 another app's
  `~/Library/Group Containers/` is gated by `kTCCServiceSystemPolicyAllFiles`,
  and tccd never prompts for it: on first access the bundle appears, switched
  off, under System Settings → Privacy & Security → Full Disk Access (the
  import window offers "Open Full Disk Access…"). Grant it and relaunch.
  The import list is live: the picker polls `VoiceMemoLibrary.changeSignature`
  (a stat of every file in the Recordings folder) every 3 s off the main
  thread and on focus, reloads only on change, keeps ticks and edited titles
  by memo id, and never reloads mid title-edit; Cancel releases the controller
  so reopening reads afresh. **The Mac pulls memos from iCloud only while
  Voice Memos.app is running** — a memo recorded on the phone is simply absent
  here until then — so the picker's "Sync from iCloud" button launches Voice
  Memos hidden (`NSWorkspace.OpenConfiguration`, activates=false, hides=true)
  and the poll shows arrivals. `--memo-window` opens the picker standalone.
- **Stable signing identity.** TCC keys grants off the code signature. Ad-hoc
  signatures change on every rebuild, which macOS treats as a new app, so the
  grants reset. `bash scripts/setup-signing-identity.sh` (one-time) creates a
  "Minnas Dev" identity in the login keychain (10-year self-signed cert with
  `codeSigning` extKeyUsage, key imported non-extractable with a
  codesign-only ACL). `make-app.sh` auto-detects it; without it, it signs
  ad-hoc and prints a warning. Re-running the setup script is a no-op.
- If a grant seems stuck (System Settings still lists an old signature),
  remove the entry with the `–` button and grant it again on next launch.

## Dependencies

Two external SwiftPM dependencies: WhisperKit (local STT on the ANE) and
FluidAudio (local speaker diarization, pulled in with only its `Diarizer`
trait). Audio capture, EventKit and the cloud/HTTP path use only system
frameworks; the cloud tier talks to the OpenAI transcriptions API directly
over HTTPS — no SDK. Keep new dependencies out unless there is no other way.

## Local-only directories

`.gitignore` reserves `outbox/`, `recordings/` and `models/`. Never commit
recordings, transcripts, model files or a `.env`.

## Releases

`.github/workflows/release.yml` runs on a `v*` tag: build on `macos-15` with
the image's Xcode 26, sign with the "Developer ID Application" certificate
(`CODESIGN_IDENTITY` env to `scripts/make-app.sh`, which then signs with a
secure timestamp), notarize with `notarytool` (App Store Connect API key),
staple, `spctl --assess` must say `Notarized Developer ID`, zip with `ditto`,
SHA-256, `actions/attest-build-provenance`, `gh release create`. The tag must
equal `v` + `CFBundleShortVersionString` in `App/Info.plist`, or the job fails
before building. Secrets: `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`,
`NOTARY_KEY_P8_BASE64`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`, loaded with
`scripts/release-secrets.sh` (asks for the .p12 password, never prints a
value). Dry run without publishing: `gh workflow run release.yml -f publish=false`
(zip lands as a workflow artifact). The Developer ID intermediate CA is
fetched from apple.com and checked against a pinned SHA-256 in the workflow.
Source builds keep the local "Minnas Dev" identity; a user who switches
between a download and a source build re-grants TCC, because the signatures
differ.
