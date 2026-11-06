# Minnas

Total recall for your meetings.

Minnas is a Mac menubar app that records your meetings, transcribes them on
the Mac itself, and drops the result as a Markdown file into a folder you
pick. "Minnas" is Swedish for "to remember".

## Why

I work across many platforms: Teams, Zoom, Meet... Each platform's own notes
feature covers that platform only and needs its own licence: Teams'
intelligent recap wants Teams Premium or a Microsoft 365 Copilot seat
([Microsoft Learn](https://learn.microsoft.com/en-us/microsoftteams/intelligent-recap-calls-meetings)),
Meet's "Take notes for me" wants a Gemini or AI Meetings add-on on the
organiser's account, so a guest gets nothing
([Google Meet help](https://support.google.com/meet/answer/14754931)).

Then there's the bots in calls, with note-taking services joining the
meeting as a participant, and other people's bots joining yours (sometimes
for meetings their owner isn't attending).

In August 2025 Otter.ai was sued by a man who had never had an Otter
account; another attendee's bot had recorded him on a Zoom call
([NPR](https://www.npr.org/2025/08/15/g-s1-83087/otter-ai-transcription-class-action-lawsuit)).
The University of Washington blocked Read AI from its Zoom and Teams because
the bot was sitting in meetings its own users had skipped
([UW-IT](https://it.uw.edu/guides/security-authentication/read-ai-deactivation/)).
Teams now puts unregistered bots in a lobby bucket labelled "Suspected
threats" and makes the organiser confirm each one
([SecurityWeek](https://www.securityweek.com/microsoft-adds-new-teams-controls-to-block-unauthorized-ai-bots-from-meetings/)),
and Meet tags third-party bots at the door
([UC Today](https://www.uctoday.com/security-compliance-risk/google-meet-launches-update-to-better-screen-suspicious-bots/)).

More recently there's hardware with a plan attached. The AI recorders avoid
the bot by selling you a device, then charge for the transcription. A Plaud
comes with 300 minutes a month; after that it's $8.33 a month for Pro or $20
for Unlimited, billed yearly, more if monthly
([Plaud pricing](https://www.plaud.ai/pages/plaud-ai-plan-pricing)).
The audio goes to their servers and, like Whoop, the device is just a key to
the subscription.

Either way, you're likely to end up with a multitude of services holding
your transcripts, offering no integration or standard formats (at best
tedious manual workarounds) across services, bots and hardware. Which all
sucks if you, like me, work across many platforms.

At the same time, all the audio is already coming out of your MacBook with
Apple silicon, which runs Whisper on its own Neural Engine. And your old
iPhone has excellent microphones, ample storage with iCloud sync, and the
Voice Memos app.

Minnas came about as a solution to cut through the platform lock-in
nonsense, reuse your phone as the hardware for physical meetings, and keep
all your transcriptions, regardless of platform, local and in an open format
(Markdown) you can dump in Obsidian, Claude Desktop, etc.

## What it does

- Minnas captures the audio your Mac plays and the audio your microphone
  hears, so Zoom, Teams, Meet, FaceTime and a browser tab all look the same
  to it. It never joins the call.
- Transcription runs on the Apple Neural Engine with
  [WhisperKit](https://github.com/argmaxinc/WhisperKit). Speakers are told
  apart on the device too, with an on-device diarization model from
  [FluidAudio](https://github.com/FluidInference/FluidAudio).
- Your microphone and the other participants are recorded and transcribed as
  separate tracks, so the transcript always knows which side is "Me" and
  which is "Them". When several people speak on the far side it's split
  further into "Them (A)", "Them (B)" and so on.
- Each meeting becomes a Markdown file in a folder of your choice. A notes
  vault, a synced folder, wherever.
- If you want higher accuracy and don't mind that one recording's audio is
  uploaded, you can add your own OpenAI key and transcribe in the cloud.
- A calendar prompt a few minutes before any meeting that has an online
  meeting link. It uses Apple's EventKit, so whatever calendar accounts the
  Mac already has will work. Off until you turn it on.
- Import of iPhone Voice Memos synced through iCloud. The list updates as
  memos arrive. The Mac only receives them while Voice Memos is running, so
  the import window's "Sync from iCloud" button opens it in the background.
  There's also "Transcribe Audio File…" for a recording made somewhere else.
- The language is detected per recording from the languages you list
  (English by default; add Swedish, or whatever else you speak, in
  Settings), and it switches mid-meeting when the language does.

## Requirements

- macOS 15 or newer on Apple silicon.
- Xcode 26 (Swift 6.2 or newer) to build. The Command Line Tools on their
  own are enough only if they're the 26 release. `swift --version` tells you.
- About 3 GB of free disk for the speech models, plus room for your audio.

## Install

### Download

Each [release](https://github.com/jwiderberg/minnas/releases) carries a
`Minnas-<version>.zip` that GitHub Actions built from the tagged commit,
signed with a Developer ID certificate and notarized by Apple, so it opens
without a Gatekeeper warning. Unzip it, move Minnas.app to /Applications,
open it. [Verify a download](#verify-a-download) explains how to check what
you got.

### Build from source

Or build it yourself, from a clone you can read:

```sh
git clone https://github.com/jwiderberg/minnas.git
cd minnas
bash scripts/install.sh
```

Add `--dry-run` first if you want to see every step before anything changes.
Other flags: `--no-identity`, `--dest <dir>`, `--no-launch`.

What the script does, in order:

1. Checks the macOS version (against `LSMinimumSystemVersion` in
   `App/Info.plist`, currently 15.0) and that this is Apple silicon.
2. Checks that Swift 6.2 or newer is installed, and tells you what to install
   if not.
3. Runs `swift build -c release`. The first build downloads dependencies
   through SwiftPM.
4. Offers to create a local code-signing identity (see below), asking
   `Create the local signing identity? [y/N]`.
5. Runs `scripts/make-app.sh` to assemble and sign `Minnas.app`.
6. Copies it to `/Applications` (or `~/Applications` if that isn't writable,
   or wherever you said with `--dest`). It asks before replacing an existing
   copy.
7. Launches it, unless you passed `--no-launch`.
8. Prints the permission prompts to expect, quoting the explanation each one
   shows (the usage strings in `App/Info.plist`).

It never uses `sudo` and makes no network requests of its own.

About the signing identity: macOS remembers your microphone and recording
permissions by the app's code signature. A build without a stable signature
gets a new one each time, so macOS asks you again after every rebuild, which
gets old fast. The identity ("Minnas Dev") is a single self-signed
certificate and key in your login keychain. Nobody else trusts it and it
only signs builds made on this Mac. Say no, or pass `--no-identity`, if
you'd rather not have it, and expect to re-grant permissions after each
rebuild.

A source build and a downloaded release are signed by different
certificates, so macOS keeps separate permission grants for them. Pick one.
If you switch, you'll be granting again.

### Verify a download

Each check proves one thing. Only the attestation check needs the
[GitHub CLI](https://cli.github.com); the others are built into macOS.

```sh
shasum -a 256 -c Minnas-<version>.zip.sha256         # the file is intact
gh attestation verify Minnas-<version>.zip --repo jwiderberg/minnas \
     --source-ref refs/tags/v<version> \
     --signer-workflow jwiderberg/minnas/.github/workflows/release.yml
     # this exact file was produced by this repository's release workflow
     # from the tagged commit (a Sigstore-signed statement from GitHub)
spctl --assess --type execute -vv Minnas.app          # "accepted source=Notarized Developer ID"
codesign -dvv Minnas.app 2>&1 | grep TeamIdentifier   # the Team ID shown in the release notes
```

`--source-ref` and `--signer-workflow` rule out a file built from a branch or
by some other workflow. Without them the check passes for any build this
repository's workflows made.

The attestation ties the binary to public source. Notarization says Apple
scanned it and that the signer holds a Developer ID. Judging the source
itself is on you: read it, and read `Package.resolved` for what it pulls
in. The release notes carry the SHA-256 and the Team ID.
[SECURITY.md](SECURITY.md#releases) describes how releases are built and what
a compromise would look like.

## Uninstall

```sh
bash scripts/uninstall.sh --dry-run   # preview
bash scripts/uninstall.sh
```

It asks before each step, and the default is no: removing the app, deleting
the working data in Application Support (your recorded audio), deleting the
keychain item, deleting the signing identity, and resetting the permission
grants. It stops if Minnas is running, so quit it first. It never touches your
transcripts folder.

## First run and permissions

Minnas lives in the menu bar and has no Dock icon. On first launch a setup
window asks where transcripts should go (it suggests
`~/Documents/Minnas Transcripts`), walks through the microphone and
system-audio permissions, and offers the optional extras (an OpenAI key, the
calendar). The table below is every permission it can ask for.

| Permission | Why | When it is asked | Without it |
| --- | --- | --- | --- |
| Microphone | Your side of the meeting. | During setup, or the first time you start a recording. | Nothing can be recorded. |
| System Audio Recording (the default capture engine) | The other participants' side, through a Core Audio process tap. Audio only. | The first time you start a recording. | Your microphone is still captured, but the other side is empty (the tap delivers silence). The app warns when a track is silent after 15 seconds. |
| Screen Recording (only if you switch to the ScreenCaptureKit engine) | The same, through ScreenCaptureKit, which macOS files under Screen & System Audio Recording. Audio only; the screen is never captured. | The first recording after you switch. | The recording does not start and the app says "Couldn't start recording." Only the default engine carries on with your microphone and an empty other side. The app also alerts if the stream cannot be restarted. |
| Calendars (optional) | Prompt you before meetings and name the other person in a 1:1. | When you choose "macOS Calendar" as the calendar source and press Grant Calendar Access (setup, or Settings > Calendar). | No prompts. You start recordings from the menu. |
| Full Disk Access (optional) | Read iPhone memos in the Voice Memos library. macOS never prompts for it. | The app appears, switched off, under System Settings > Privacy & Security > Full Disk Access after the first import attempt. | "Import Voice Memos" cannot read the library. Recording and file import are unaffected. |

Grant them in System Settings > Privacy & Security, then relaunch the app.
The two audio permissions are both listed under Screen & System Audio
Recording. Settings > Permissions shows where each one stands.

On the choice of capture engine: the default (`systemAudioEngine` = `taps`)
is a Core Audio process tap. It needs only the System Audio Recording
permission, can exclude apps you list by process, and doesn't set off the
"is recording your screen" reminders macOS shows for screen capture.
ScreenCaptureKit (`sck`) is the alternative, chosen in Settings >
Transcription. Switch to it if the other side keeps coming out silent with
the tap even though System Audio Recording is granted (macOS has no way to
report that grant, so a silent tap is the only symptom you'll get), or if
you've already granted Screen Recording and would rather keep using that.
It needs Screen Recording.

## Where files live

- Transcripts. The Markdown files go to the folder you choose in setup or in
  Settings > General (setting `transcriptsFolderPath`), named
  `<yyyy-MM-dd HHmm> <title>.md`. Minnas adds and updates files there and
  never deletes anything in that folder; `scripts/uninstall.sh` leaves it
  alone too. Until you've chosen a folder, transcripts stay in
  the working data below; once you choose one, every existing transcript is
  written out within five minutes.
- Working data. Audio, the per-recording metadata (`meta.json`) and a local
  copy of each transcript live in
  `~/Library/Application Support/minnas/outbox/`, one folder per recording.
- Retention. Recorded audio is deleted at the next launch after it is 30 days
  old by default (`recordingsKeepDays`; `0` keeps it forever), counted from
  when the recording arrived. Until then you can re-transcribe it with another model.
  Transcripts in your transcripts folder are never touched. When the audio
  goes, the outbox copy of a transcript that's already in your folder goes
  with it; a transcript that never reached a folder (because none was
  chosen) stays in the outbox. A recording whose transcript is still waiting
  to be written to the folder is kept whole. Raw captures are compressed to
  AAC after transcription.
- Models. Speech models are cached under
  `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml`, speaker
  models under `~/Library/Application Support/FluidAudio/Models`.
- Secrets. An OpenAI key, if you add one, is stored in your login keychain.

## Settings

Change settings in the app (menu bar > Settings…). Every setting is also
reachable from the shell through the binary inside the app bundle, which
reads the app's own settings and keychain:

```sh
MINNAS=/Applications/Minnas.app/Contents/MacOS/minnas
$MINNAS --settings                          # all settings, with value and source
$MINNAS --settings set recordingsKeepDays 90
$MINNAS --settings set openAIKey -          # "-" reads the value from stdin
$MINNAS --settings unset recordingsKeepDays
```

An environment variable wins over a stored setting, which wins over a `.env`
file, which wins over the default. The variable names are in capitals
(`RECORDINGS_KEEP_DAYS` for `recordingsKeepDays`) and `.env.example` lists
them. `defaultModel`, `cloudTranscriptionEnabled`, `calendarSource` and
`onboardingCompleted` have no variable. The app's own code talks to one network endpoint, OpenAI's, fixed
to `https://api.openai.com`, and only when cloud transcription is on, so there
are no server addresses to configure. The model libraries download their
models from Hugging Face; see Privacy below.

## Privacy

- Audio and transcripts stay on your Mac. No audio, transcripts or personal
  data are sent anywhere unless you turn on cloud transcription (Settings >
  Cloud, with your own key) and a cloud model is used for a recording, either
  as the default model or picked in Re-transcribe. Then that recording's audio
  goes to OpenAI. "Test Key" in Settings > Cloud sends only the key, to
  OpenAI's model list.
- There's no telemetry, no analytics, and no account to create.
- The first time you use a model it's downloaded from Hugging Face:
  `argmaxinc/whisperkit-coreml` for speech recognition and
  `FluidInference/speaker-diarization-coreml` for speaker separation. The
  speaker models are loaded from disk after that. The speech library
  (WhisperKit) also asks Hugging Face for the model's file list each time it
  loads a model, once per app launch, to check the cached files and fetch
  any that are missing. None of these requests carry audio, transcripts or
  personal data.
- The calendar is read on the Mac through EventKit and isn't sent anywhere.
  For a recording tagged with a calendar event, the attendees' names and
  email addresses are stored in that recording's `meta.json` in the working
  data. The transcript's frontmatter carries the event's identifier and
  link, and in a 1:1 the other attendee's name labels their side of the
  conversation.
- Recording other people may be regulated where you live. Tell participants
  when the law, or ordinary manners, calls for it.

See [SECURITY.md](SECURITY.md) for the threat model.

## Troubleshooting

- The other side is silent, or a track goes quiet after you plug in
  headphones. Switching output or input devices mid-call restarts the
  capture. Both tracks recover within a few seconds and the gap is padded
  with silence so they stay in sync. If a track stays dead, the menu shows a
  cross next to it and an alert appears. If it keeps failing, check the
  audio permissions above, or try the other capture engine.
- "Minnas is already running." Only one copy may run, because a second one
  would treat the live recording as interrupted. Find the first copy in the
  menu bar, or quit it from Activity Monitor, and launch again.
- Asked for permission again after switching between a download and a source
  build. They're signed by different certificates and macOS treats them as
  different apps for permissions. Stick with one.
- Asked for permission again after a rebuild. You built without the signing
  identity, so the signature changed. Run
  `bash scripts/setup-signing-identity.sh` once and rebuild. If a stale entry
  remains, remove the app from the list in System Settings > Privacy &
  Security with the minus button and grant it on the next launch.
- The microphone records pure silence. Check the default input in System
  Settings > Sound. If it's your iPhone through Continuity, pick another
  input.
- Logs: `/usr/bin/log show --predicate 'subsystem == "com.jwiderberg.minnas"'`
  (the `CFBundleIdentifier` from `App/Info.plist`). In zsh, plain `log` is a
  shell builtin, hence the full path. Only notices and errors are kept.

## Development

```sh
swift build                       # compile check, no bundle
bash scripts/make-app.sh          # build and assemble .build/Minnas.app
swift run minnas --cleanup-test   # transcript-cleanup self-check, no models, no permissions
swift run minnas --self-test      # delivery backoff and pruning rules
bash -n scripts/*.sh              # shell syntax check
```

The command-line harnesses run with `swift run minnas <flag>` and need no
permissions: `--transcribe <audio>`, `--retranscribe <slug>`, `--diarize
<audio>`, `--probe-language <slug>`, `--import-file <path>`, `--deliver
<slug> [--run]`, `--settings`, `--version`. `--list-memos` and
`--import-memo <id>` read the Voice Memos library, so the process needs Full
Disk Access (your terminal's, or the app's when run from the bundle).

The capture harnesses `--mic-test <seconds> <out.caf>` and `--system-test
<seconds> <out.caf>` need the microphone and recording grants, so run them
from inside the built app (`.build/Minnas.app/Contents/MacOS/minnas`). The
same goes for `--calendar` (Calendars grant) and the `--settings-window`,
`--onboarding` and `--memo-window` window harnesses. The process-tap test
charges its grant to whichever app launched it, so start it through
LaunchServices:
`open -W -n -g --stdout /tmp/tap.log --stderr /tmp/tap.log .build/Minnas.app --args --tap-test 30 /tmp/tap.caf`.
Test any change to the capture code with a real run while you switch the
default input or output device. `CLAUDE.md` holds the engineering rules.

Continuous integration (`.github/workflows/ci.yml`) builds the package, runs
`--cleanup-test` and `--self-test`, and checks the shell scripts (syntax and
dry runs). It downloads no models and needs no permissions. It runs on the
`macos-15` image and selects that image's Xcode 26 install, failing if there
is none. That is Swift 6.2, the oldest toolchain the package supports and
stricter about concurrency than Xcode 26.6's Swift 6.3, so a build that
passes locally on a newer Xcode can still fail there.

`Package.resolved` is committed: a build of a given commit uses exactly the
dependency versions it names. Update it on purpose with
`swift package update`, and read the diff.

Releases (`.github/workflows/release.yml`): bump `CFBundleShortVersionString`
in `App/Info.plist`, commit, tag that commit `v<version>` and push the tag.
The workflow builds on the same image as CI, signs with the Developer ID
certificate, notarizes and staples, zips, writes the SHA-256, attests the
build's provenance and creates the GitHub release with verification
instructions. The five secrets it needs are loaded once with
`scripts/release-secrets.sh`. `gh workflow run release.yml -f publish=false`
runs everything except the attestation and the release itself and uploads the
zip as a workflow artifact.

## Licence

MIT. See `LICENSE`.
