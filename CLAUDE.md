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
3. `TranscriptionJob` → `EchoCanceller` (two-stream recordings: the mic is
   echo-cancelled against the system track into a temporary 16 kHz file,
   which is what gets transcribed; see "Echo cancellation" below) →
   `Transcriber` (dispatches on `TranscriptionModel.engine`)
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
bash scripts/test.sh              # swift-testing suite; selects the Xcode toolchain when xcode-select points at the CLT
for f in scripts/*.sh; do bash -n "$f"; done   # one file per bash -n: with several, bash parses only the first
```

Tests live in `Tests/MinnasTests` (swift-testing); run them with
`bash scripts/test.sh`, which points `DEVELOPER_DIR` at Xcode when
`xcode-select` names the Command Line Tools (they can't find the Testing
module). CI runs `swift test` directly. Suites: Smoke, Lifecycle,
TranscriptBuilder (fixtures in `TranscriptBuilderFixtures.swift`, shared
with `--cleanup-test`), TranscriberWindow, CaptureSupport, Settings
(+ SettingsParser, serialized because it sets environment variables),
PaddedCAFWriter, MicPadding, EchoCanceller, StatusItemPolicy, MeetingDetails. Add tests with any logic
change.

Requires Swift 6.2+ (Xcode 26, which runs on macOS 15.6+) to build; the app
runs on macOS 15+. The floor is macOS 15 in both `Package.swift` and
`App/Info.plist` (`LSMinimumSystemVersion`; `scripts/install.sh` enforces
it). Nothing in the code needs a newer OS. macOS 14 is excluded on purpose
(a Core ML BNNS crash FluidAudio documents on 14.x). Keep the two floors in
step, and don't add `if #available` branches for anything older than 15.
CI (`macos-15` image, the newest Xcode 26 on it; 26.3 = Swift 6.2.4 at the
time of writing) is the only Swift 6.2 check: Xcode 26.6's Swift 6.3 is
laxer about region isolation (6.2 refused to send a `[weak owner]` capture
box into a `Task { @MainActor }`; bind a strong `let` first), so a green
local build does not prove the CI build.

## Harnesses

No TCC needed (`swift run minnas …`):
`--version`, `--settings [set <name> <value>|unset <name>]` (value `-` reads
stdin), `--transcribe <audio> [--model <id>]`, `--retranscribe <slug> [--model <id>]`
(a cloud `--model` is the consent to send that audio), `--probe-language <slug>`
(per-stream language scores + decision, for calibrating `STT_LANGUAGE_MARGIN`),
`--detect-lang <audio>`, `--dup-check <slug>`, `--diarize <audio>`,
`--echo-cancel <mic-audio> <system-audio> <out.caf>`,
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

`--system-test` run as a bare binary from a terminal shows no signal
(`hasSignal=false` in the stop line) even with audio playing, because the
grant is attributed to the launching process (the terminal). Restart and
padding proof works either way; for a real-signal check of the
ScreenCaptureKit engine launch it like the tap test:

```sh
open -W -n -g --stdout /tmp/sys.log --stderr /tmp/sys.log --env SYSTEM_AUDIO_ENGINE=sck .build/Minnas.app --args --system-test 30 /tmp/sys.caf
```

`--tap-test <seconds> <out.caf>` exercises the process tap (signal, midpoint
kill, output switch, no leaked taps/aggregate devices). The System Audio
Recording grant is charged to the RESPONSIBLE process, so launch it through
LaunchServices or the terminal gets the prompt and the grant:

```sh
open -W -n -g --stdout /tmp/tap.log --stderr /tmp/tap.log .build/Minnas.app --args --tap-test 30 /tmp/tap.caf
```

`TAP_TEST_FAIL_RESTARTS=1` makes every tap restart fail, to check that
restart exhaustion fires `onUnexpectedStop` exactly once. Keep harness runs
at 20–30 s.

CLI harnesses don't take the single-instance lock: don't run
`--retranscribe` or the imports against a slot the app is recording.

## Capture must survive route changes — test it for real

AVAudioEngine stops itself on every hardware configuration change (headphones
connecting, the default output or input switching, the voice-processing
aggregate device being torn down), posts `AVAudioEngineConfigurationChange`,
and never restarts on its own. Unhandled, that silently loses the user's side
of a meeting while the menubar keeps saying "recording". The rules:

- `MicCapture` observes the notification **and** `checkHealth()` runs from the
  10 Hz recording tick (engine not running, or no buffer for the stall
  threshold → re-attach).
  The re-attach pads the mic file with silence for the dead stretch so it
  stays time-aligned with the system track, and resamples if the new input
  runs at another rate.
- The stall threshold and restart bookkeeping come from `RestartBackoff`
  (CaptureSupport.swift) in all three engines: 3 s, doubling per restart that
  never delivered a buffer, capped at 60 s; batches of 20 attempts, 1 s
  apart. Each engine keeps its own restart loop inline, because the loops'
  guards differ.
- **Never enable voice processing on the mic.** macOS voice processing
  works on the input device and attenuates it for every other app reading
  it (measured on the built-in mic: −60.7 dB mean with the recorder's
  voice processing on, against −17.6 dB without), so the people on the
  call can barely hear you. Echo is removed after the call instead
  ("Echo cancellation" below).
- The tap block is built in a `nonisolated static func`. A closure formed
  inside a `@MainActor` method inherits main-actor isolation and SIGTRAPs on
  the audio thread (`dispatch_assert_queue`). Don't inline it.
- Padding is bounded: the mic pad is capped at 300 s (a longer gap pads 300 s
  and logs an error) and gaps ≤ 0.05 s are not padded; the system gap fill
  skips non-finite or > 300 s gaps, waits at most 2 s for the writer per
  1 s chunk and bails when it isn't `.writing`; the system engines' `stop()`
  cancels and awaits any restart in flight (the mic's only cancels it);
  dropped buffers are counted and leave a hole for the next fill. All
  three engines pad in host time: the mic tap records each buffer's end
  host time, `MicCapture.padPlan` turns host-now minus that into the pad
  and the watchdog's `lastBufferAt` derives from the same ticks. Host time
  doesn't advance in sleep, so a sleep is neither padded nor seen as a
  stall, and the awake dead time before a sleep is padded. The
  `NSWorkspace` will-sleep/did-wake observers only log. The clocks are
  injectable (`CaptureClock`, `MachClock` by default) and `MicPaddingTests`
  simulates a sleep with them.
- `PaddedCAFWriter` owns the CAF file for BOTH system engines: the
  AVAssetWriter, the timeline end, the silence fills (a partial fill moves
  the timeline to where it stopped) and the bounded finish below. It is
  queue-confined (SCK: the SCStream sample-handler queue; taps: its write
  queue) and DEBUG builds assert the queue. Its counters live in
  `CAFWriterStats`, which outlives the writer, so capture_health reads them
  after stop. Engine-specific log lines stay in the engines; the four shared
  lines (the two finish-deadline lines, writer failed, gap fill gave up)
  come from the writer through the engine's Logger.
- Both system engines have the same watchdog (no buffer for the stall
  threshold, or the stream reports an error → rebuild on the same writer;
  the next buffer fills the timestamp gap with silence). Only 20 failed restarts end the recording
  (with an alert), and restart exhaustion is terminal (`running = false`
  before `onUnexpectedStop`). A writer refusing data (disk full) raises a
  critical alert — a stream restart can't fix a file.
- `MicCapture`'s 20-attempt restart batch is not terminal, unlike both system
  engines: `running` stays true and the watchdog starts another batch (about
  3 s apart after failed attaches when a buffer had been delivered, since the
  attempt's padding, when there is a gap to pad, resets the stall clock;
  straight away when nothing was ever delivered), because a mic comes back
  when a device is plugged in; a mic that stays dead is reported by the 10 s
  stalled alert.
- The menubar shows `✗` for a track while a restart is pending; a critical
  alert fires if it stays dead 10 s, and another if the mic delivers pure
  digital zeros for 2 min after having had signal.
- `meta.json` is written at recording START (ended_at nil). On launch,
  `recoverInterruptedRecordings` finishes any slot with raw .caf files and no
  ended_at, alerts, and transcribes it. `capture_health` in meta.json records
  restarts, padded seconds and captured seconds per stream.
- Writer shutdown is bounded in both system engines (2026-11-06): the
  writer's `finish` waits at most 10 s for `finishWriting` (the continuation
  races a global-queue deadline, so a wedged writer or write queue can't
  hang Stop), then logs the writer status and abandons the writer. Never `cancelWriting`
  there: per AVAssetWriter.h it blocks and deletes the output file. The stop
  line carries `writerTimedOut=`.
- Quit runs the normal asynchronous stop path before terminating, so capture
  writers are finalized, `ended_at` is persisted, and transcription is
  queued; AppKit waits at most 15 seconds before allowing termination.
- Quitting while only transcription is active asks for confirmation; Quit
  leaves the finished slot to resume on the next launch, while Cancel keeps
  the app running. Launch recovery then queues finished slots with audio but
  no transcript/provenance before pruning, oldest first, and stops
  auto-retrying one after three attempts (`transcription_failures` is counted at job start and cleared on success, so a crash mid-job counts). A finished recording with only one surviving stream is transcribed from that stream instead of failing on the missing one.
- **Test any change to `MicCapture`, `SystemAudioCapture`,
  `SystemAudioTapCapture`, `PaddedCAFWriter` or `AudioRoute` with a real
  run from inside the bundle before relaunching the app**: `--mic-test 30 /tmp/x.caf` / `--system-test` /
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
  never silent. Every key is one typed `SettingSpec` in the `Setting` table
  (kind, env name, storage key, default, parse/format/display), and
  `SettingKey.spec` is the one exhaustive switch from key to spec;
  `Config.resolve` applies the precedence above and `SettingsStorage.store`
  validates through the same parse. The `@MainActor` facade is `allKeys` /
  `set` / `setValue(fromString:)` / `reset` / `calendarSource` /
  `onboardingCompleted`. SettingsTests freeze every storage key, env name and
  default display, so a new key fails the frozen-list test until the literal
  is updated on purpose. Defaults: no transcripts folder until setup,
  calendar off, languages `["en"]`, engine `taps`, nothing excluded, 30 days
  of audio.
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
  `permissionSuspect` flags 10 s of zeros (so it is set before the 15 s
  silence pre-flight reads it) but cannot tell "denied" from "nothing
  playing".
- **Shared capture code.** `CaptureSupport.swift`: `RestartBackoff` (above),
  `Date.epochBits` (a Date published through one `Atomic<UInt64>`),
  `HostClock` (mach ticks per second), `CaptureSignal.epsilon` (the signal
  threshold). `CoreAudioHAL.swift`: the Core Audio property helpers used by
  the taps engine and `AudioRoute` (the default devices, for logs and
  harnesses; any HAL failure → nil).
- **Full meeting details** (`MeetingDetails`, `MARKDOWN_MEETING_DETAILS` /
  `markdownFullMeetingDetails`, default off): the event's location and
  notes are stored in meta (`calendar_location`, `calendar_notes`) whenever a recording is tagged; with the setting on,
  `MarkdownFolderSink` adds attendees and location to the frontmatter and
  the notes as a quoted "Invite notes" section (HTML reduced to text, capped
  at 8,000 characters). transcript.md itself is never changed by it.
- **Menu bar item while recording** (`StatusItemPolicy` in
  GlobalHotKey.swift, `StatusItemPolicyTests`): the counter is drawn in SF
  Mono so it holds its width. The item has no menu of its own while
  recording, so a plain click reaches `statusItemClicked`: it toggles hidden
  mode (counter and bars gone, red dot only; kept until quit), while
  Option-, Control- or secondary click attaches the menu for that one click
  (`performClick`). `GlobalHotKey` registers ⌃⌥⌘R through Carbon
  `RegisterEventHotKey` (no Accessibility grant; logs when another app holds
  it): start "Recording yyyy-MM-dd HH:mm" with no dialog or calendar tag, or
  stop the recording that is on. The menu lists it as Quick Recording.
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
  item; `tccutil reset`s). CI builds, runs `swift test`, `--cleanup-test`,
  `--self-test`, `bash -n` per script and the install/uninstall dry runs.

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

## In-room meetings

When the system track was captured (exists, writer never failed) but
carries no remote speech (fewer than 8 words and under 5 s of speech,
`TranscriptBuilder.hasNoRemoteSpeech`), the meeting happened in the room and
everyone is on the mic: the mic track is diarized instead of the system
track and its voices are labelled "Speaker (A)/(B)" like an import's, only
when at least two distinct voices came back; otherwise "Me". The system
track's few words are "System audio" then. On a call the mic is always
"Me". No per-recording override yet.

## Echo cancellation (after the call, never live)

On speakers the mic hears the far side, and Whisper writes their words under
"Me" (or only theirs, when they are louder than you at the mic). Live
voice processing on the mic is not the answer: it attenuates the device for
every app, including the call (see the mic-capture rules). Instead
`EchoCanceller` runs WebRTC's AEC3 over the saved files before
transcription, with the system track as the reference:

- Alignment first: GCC-PHAT cross-correlation in 30 s blocks wherever the
  system track is above -50 dBFS (eligible blocks); a block is confident
  when its peak (by magnitude, so an inverted path counts) is ≥ 9× the
  correlation RMS over the searched lags. Lags searched: −50 ms to +10 s.
  The mic file starts first and the system file at its engine's first
  buffer (ScreenCaptureKit: up to ~7 s later), so a real echo always lags;
  a negative lag means the system track carries the mic's own voice (a far
  end without AEC, a monitored mic), and cancelling that erased the user
  (−30 dB in review), so it is never searched.
- A line lag = delay + drift·t is fitted through the confident blocks
  (constant median vs Theil–Sen, |drift| ≤ 500 ppm, the one with more
  blocks within 5 ms wins, refined by least squares). Accepted only with a
  majority of the confident blocks, at least two when two blocks had sound,
  and at least a quarter of the eligible blocks. Otherwise no acoustic path
  (headphones, a virtual mic) → skipped, raw mic transcribed. A fixed lag
  rejected a USB-mic-style 21 ppm over 30 min; the line takes it (60/60
  blocks, 44 dB at both ends).
- The reference is read at 16 kHz / (1 − drift) (ExtAudioFile resamples it
  onto the mic's clock) and shifted so the echo trails it by 40 ms: AEC3
  alone tracks only about 300 ms of offset (measured: 40 dB removed at
  0.06–1 s with the shift, 0.5 dB at 1 s without). AEC3's output lags its
  input by 128 samples (`WEBRTC_AEC_LATENCY`); they are dropped from the
  front and flushed at the end, so the cleaned file has the mic's length
  and timeline to the sample.
- The system track's start on the mic timeline is recorded at capture
  (`capture_health.system_start_offset_seconds`: the host time of the mic
  file's first sample, latched only from a valid device timestamp after
  its write succeeded, vs the system file's first sample: ScreenCaptureKit
  PTS converted from `SCStream.synchronizationClock` to the host clock with
  `CMSyncConvertTime`, the tap's `mHostTime` only when flagged valid; no
  valid stamp → no offset; trusted only within -0.5…20 s). Measured on a
  MacBook on speakers: offset 0.107 s, echo at offset + 27 ms. With it the
  search is offset −100 ms…+3 s (jitter and unpadded ≤ 50 ms mic gaps
  before; Bluetooth/AirPlay output latency after), with the mic read ahead
  by the offset so block pairs overlap fully, and the mic's own voice
  coming back (a network round trip, well over 100 ms, before the offset)
  cannot be mistaken for echo. Without it (older recordings) the wide
  window applies, where a returned voice behind a start offset can still
  look like echo (a test shows both sides). Known limits, left on
  purpose: a mid-call jump in the path (switching to AirPlay) is not
  modelled by the drift line (one route's blocks win or neither does); the
  mic's ≤ 50 ms unpadded gaps add up against the 100 ms early allowance
  (carrying the remainder in the mic's padding would fix it); a mic routed
  back into the system output locally within 100 ms (an unexcluded
  monitoring tool) can still be taken for echo, which moves those words to
  "Them" rather than losing them; ScreenCaptureKit restarts keep using the
  new stream's PTS for gaps, verified exact by `--system-test`, assumed to
  share the host timebase. TranscriptBuilder
  moves the later-starting stream by the offset, so no segment is negative.
  `--pair-test <seconds> <dir>` (TCC, run in the bundle) records both
  engines like a session and prints the offset beside the measured lag.
- Output: 16 kHz mono 16-bit CAF in the temp directory, read by both
  engines (local and cloud), deleted after the job. The recording is never
  modified, so re-transcribe always starts from the raw mic. A canceller
  failure is logged and the raw mic is transcribed.
- AEC3 config: the defaults with a 32-block (128 ms) linear filter instead
  of 13. Chosen through Whisper on 12 synthetic double-talk cases (two
  scripts, echo +6/0/−6 dB against the speaker, mild and harsh speaker
  distortion): near-speaker words lost 37% → 18% (3% vs 31% at 0 dB), far
  words leaked 0% either way; 20/24/40/48 blocks did worse. Feeding Whisper
  the linear output, or the suppressor's gain floored at −6/−12 dB (what
  the AEC-for-ASR literature suggests), kept every near word but leaked
  ~60% of the far words: Whisper normalises level and transcribes quiet
  residual echo. Tuning the suppressor itself bought ~2 dB. Weak spot left:
  echo louder than you while both talk (+6 dB: ~50% of your words lost).
  Synthetic only until checked on a real speakers recording.
- About 40× realtime in release (~2 min for a 90-minute call); the vendored
  C++ is built with -O2 in debug too.
- `ECHO_CANCEL` / Settings › Transcription › Echo, default on.
  `EchoCancellerTests` cover the correlator (lags, polarity, unrelated
  tracks), the line fit (constant, drift, a stray block), the reference
  plan, whole-file runs at 0.75 s and 3.5 s offsets (≥ 25 dB removed, near
  speaker within 1.5 dB), 200 ppm drift, sample alignment of the output,
  the mic's own voice coming back (no cancelling) and no echo path.
  A cancelled job cancels the pass and deletes its temp file.
- Vendored: `Sources/CWebRTCAEC` (C interface in `include/webrtc_aec.h`,
  `upstream/` = the files listed in `MANIFEST` from webrtc-audio-processing
  2.1 and abseil-cpp 20240722.0, unedited). `scripts/vendor-webrtc-aec.sh
  [--check] <tarballs>` regenerates or verifies it against the pinned
  sha256s.

## Dependencies

Two external SwiftPM dependencies, plus one vendored library (WebRTC's
AEC3 echo canceller, see above): WhisperKit (local STT on the ANE) and
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
SHA-256, `actions/attest-build-provenance`, `gh release create`, then
deletes every other release (never the tags): only the latest release is
kept on the Releases page, by rule. The tag must
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
