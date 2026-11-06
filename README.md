# Minnas

Total recall for your meetings.

Minnas is a Mac menubar app that records your meetings, transcribes them on
your Mac, and saves the result as Markdown in a folder you choose. "Minnas" is
Swedish for "to remember".

## Why

I built Minnas because three things about meeting notes had worn me down.

**Bots joining calls.** Every note-taking service wanted to put a participant
in my meetings, and other people's bots kept showing up in mine. The pushback
is now institutional: Otter.ai was hit with a class action in August 2025 by
someone who never had an account but was recorded by another attendee's bot
([NPR](https://www.npr.org/2025/08/15/g-s1-83087/otter-ai-transcription-class-action-lawsuit)),
the University of Washington blocked Read AI from its Zoom and Teams because
the bot joined meetings its own users were not attending
([UW-IT](https://it.uw.edu/guides/security-authentication/read-ai-deactivation/)),
Microsoft Teams now sorts unregistered bots into a "Suspected threats" lobby
and asks the organizer to confirm before one is admitted
([SecurityWeek](https://www.securityweek.com/microsoft-adds-new-teams-controls-to-block-unauthorized-ai-bots-from-meetings/)),
and Google Meet tags third-party bots on the way in
([UC Today](https://www.uctoday.com/security-compliance-risk/google-meet-launches-update-to-better-screen-suspicious-bots/)).
A bot is a stranger in the room. The audio is already on my Mac; I wanted
to record that.

**Hardware tied to subscriptions.** The AI recorders solve the bot problem
by selling you a device and then metering the transcription. A Plaud device
comes with 300 transcription minutes a month on the free plan; beyond that it
is $8.33 a month for Pro or $20 a month for Unlimited, billed annually, with
higher monthly rates
([Plaud pricing](https://www.plaud.ai/pages/plaud-ai-plan-pricing)).
The minutes are the product, the audio lives on their servers, and the device
is a dongle for the plan. An Apple silicon Mac already runs Whisper well; it
should not need a subscription to do so.

**A work life spread across Teams, Zoom and Meet.** Each client lives on a
different platform. Okta's Businesses at Work data has long shown the overlap:
45% of its Microsoft 365 customers also deployed Zoom in the 2022 report
([Zoom's summary of the report](https://www.zoom.com/en/blog/zoom-okta-2022-businesses-at-work-report/)).
Each platform's built-in notes need their own licence and stay in their own
silo: Teams intelligent recap requires a Teams Premium or Microsoft 365 Copilot
licence
([Microsoft Learn](https://learn.microsoft.com/en-us/microsoftteams/intelligent-recap-calls-meetings)),
and Meet's "Take notes for me" needs a Gemini or AI Meetings add-on on the
organizer's account, so as a guest you get nothing
([Google Meet help](https://support.google.com/meet/answer/14754931)).
I wanted one folder of Markdown files, one per meeting, whatever app the
meeting happened in.

So: a menubar app that records what the Mac plays and what the microphone
hears, transcribes on the Neural Engine, and writes plain files. No bot, no
device, no plan.

## What it does

- **No bot joins your call.** It captures the audio your Mac plays and the
  audio your microphone hears, so it works with Zoom, Teams, Meet, or anything
  else that makes sound.
- **Local first.** Transcription runs on the Apple Neural Engine with
  [WhisperKit](https://github.com/argmaxinc/WhisperKit). Speakers are told
  apart on the device too, with an on-device diarization model from
  [FluidAudio](https://github.com/FluidInference/FluidAudio).
- **Two tracks.** Your microphone and the other participants are recorded and
  transcribed separately, so "Me" and "Them" are known, not guessed. The remote
  side is split further into "Them (A)", "Them (B)" when several people speak.
- **Plain files.** Each meeting becomes a Markdown file in a folder of your
  choice (a notes vault, a synced folder, anywhere).
- **Optional cloud transcription** with your own OpenAI key, if you want
  higher accuracy and accept that the audio is uploaded for that recording.
- **Calendar prompts** a few minutes before a meeting that has an online
  meeting link, using Apple's calendar framework (EventKit), so any calendar
  account you have set up on the Mac works. Off until you turn it on.
- **Voice Memos import** for iPhone memos synced through iCloud (the list
  updates as memos arrive; since the Mac receives them only while Voice Memos
  is running, the import window's "Sync from iCloud" button opens it in the
  background), and **Transcribe Audio File…** for any recording made elsewhere.
- The language is detected per recording among the languages you list
  (English by default; add others such as Swedish in Settings), and switched
  mid-meeting when the language changes.

## Requirements

- macOS 15 or newer on Apple silicon.
- Xcode 26 (Swift 6.2 or newer) to build. The Command Line Tools alone are
  enough only if they are the 26 release. Check with `swift --version`.
- About 3 GB of free disk for the speech models, plus space for your audio.

## Install

### Download

Each [release](https://github.com/jwiderberg/minnas/releases) carries a
`Minnas-<version>.zip` built by GitHub Actions from the tagged commit, signed
with a Developer ID certificate and notarized by Apple, so it opens without a
Gatekeeper warning. Unzip it, move Minnas.app to /Applications, open it.
[Verify a download](#verify-a-download) explains how to check what you got.

### Build from source

Or build it yourself, from a clone you can read:

```sh
git clone https://github.com/jwiderberg/minnas.git
cd minnas
bash scripts/install.sh
```

Add `--dry-run` first to see every step without anything being changed.
Other flags: `--no-identity`, `--dest <dir>`, `--no-launch`.

What the script does, in order:

1. Checks the macOS version (against `LSMinimumSystemVersion` in
   `App/Info.plist`, currently 15.0) and Apple silicon.
2. Checks that Swift 6.2 or newer is installed, and tells you what to install if
   not.
3. Runs `swift build -c release`. The first build downloads dependencies
   through SwiftPM.
4. Offers to create a local code-signing identity (see below), asking
   `Create the local signing identity? [y/N]`.
5. Runs `scripts/make-app.sh` to assemble and sign `Minnas.app`.
6. Copies it to `/Applications` (or `~/Applications` if that is not writable, or
   the folder you gave with `--dest`). It asks before replacing an existing copy.
7. Launches it, unless `--no-launch`.
8. Prints the permission prompts to expect, quoting the explanation each one
   shows (the usage strings in `App/Info.plist`).

It never uses `sudo` and makes no network requests of its own.

**The signing identity.** macOS remembers your microphone and recording
permissions by the app's code signature. A build without a stable signature
gets a new one each time, so macOS asks you again after every rebuild. The
identity ("Minnas Dev") is one self-signed certificate and key in your login
keychain. It is trusted by nobody else and only signs builds made on this Mac.
Say no, or pass `--no-identity`, if you would rather not, and expect to
re-grant permissions after each rebuild.

A source build and a downloaded release are signed by different
certificates, so macOS keeps separate permission grants for them. Use one or
the other; switching means granting again.

### Verify a download

Each check proves one thing. The first two need the
[GitHub CLI](https://cli.github.com); the last two are built into macOS.

```sh
shasum -a 256 -c Minnas-<version>.zip.sha256         # the file is intact
gh attestation verify Minnas-<version>.zip --repo jwiderberg/minnas
     # this exact file was produced by this repository's release workflow
     # from the tagged commit (a Sigstore-signed statement from GitHub)
spctl --assess --type execute -vv Minnas.app          # "accepted source=Notarized Developer ID"
codesign -dvv Minnas.app 2>&1 | grep TeamIdentifier   # the Team ID shown in the release notes
```

The attestation ties the binary to public source; notarization says Apple
scanned it and that the signer holds a Developer ID. Neither proves the source
is harmless: read it, and read `Package.resolved` for what it pulls in. The
release notes carry the SHA-256 and the Team ID. See
[SECURITY.md](SECURITY.md#releases) for how releases are built and what a
compromise would look like.

## Uninstall

```sh
bash scripts/uninstall.sh --dry-run   # preview
bash scripts/uninstall.sh
```

It removes the app, then asks separately (default no) before deleting the
working data in Application Support (your recorded audio), the keychain item,
the signing identity, and the permission grants. It never touches your
transcripts folder.

## First run and permissions

Minnas lives in the menu bar and has no Dock icon. On first launch a setup
window asks where transcripts should go (it suggests
`~/Documents/Minnas Transcripts`), walks through the microphone and
system-audio permissions, and offers the optional extras (an OpenAI key, the
calendar). These are all the permissions it can ask for.

| Permission | Why | When it is asked | Without it |
| --- | --- | --- | --- |
| Microphone | Your side of the meeting. | During setup, or the first time you start a recording. | Nothing can be recorded. |
| System Audio Recording (the default capture engine) | The other participants' side, through a Core Audio process tap. Audio only. | The first time you start a recording. | Your microphone is still captured, but the other side is empty (the tap delivers silence). The app warns when a track is silent after 15 seconds. |
| Screen Recording (only if you switch to the ScreenCaptureKit engine) | The same, through ScreenCaptureKit, which macOS files under Screen Recording. Audio only; the screen is never captured. | The first recording after you switch. | As above; the app also alerts if the stream cannot be restarted. |
| Calendars (optional) | Prompt you before meetings and name the other person in a 1:1. | When you choose "macOS Calendar" as the calendar source and press Grant Calendar Access (setup, or Settings > Calendar). | No prompts. You start recordings from the menu. |
| Full Disk Access (optional) | Read iPhone memos in the Voice Memos library. macOS never prompts for it. | The app appears, switched off, under System Settings > Privacy & Security > Full Disk Access after the first import attempt. | "Import Voice Memos" cannot read the library. Recording and file import are unaffected. |

Grant them in System Settings > Privacy & Security, then relaunch the app.
Settings > Permissions shows the status of each.

**Which capture engine.** The default engine (`systemAudioEngine` = `taps`)
is a Core Audio process tap. It needs only the System Audio Recording
permission, excludes apps you list by process, and does not trigger macOS's
"is recording your screen" reminders. ScreenCaptureKit (`sck`) is the
alternative, chosen in Settings > Transcription. Switch to it if the other
side keeps coming out silent with the tap even though System Audio Recording
is granted (macOS cannot report that grant, so a silent tap is the only
symptom), or if you already granted Screen Recording and prefer that. It
needs Screen Recording.

## Where files live

- **Transcripts folder.** The Markdown files go to the folder you choose in
  setup or in Settings > General (setting `transcriptsFolderPath`), named
  `<yyyy-MM-dd HHmm> <title>.md`. Minnas only ever adds or updates files
  there. It never deletes anything in it, and neither does
  `scripts/uninstall.sh`. Until you choose a folder, transcripts stay in the
  working data below, and every existing transcript is written to the folder
  within five minutes of choosing one.
- **Working data.** Audio, the per-recording metadata (`meta.json`) and a
  local copy of each transcript live in
  `~/Library/Application Support/minnas/outbox/`, one folder per recording.
- **Retention.** Recorded audio is deleted after 30 days by default
  (`recordingsKeepDays`; `0` keeps it forever), counted from when the
  recording arrived. Until then you can re-transcribe with another model.
  Transcripts in your transcripts folder are never touched. When the audio
  goes, the outbox copy of a transcript that is already in your folder is
  removed with its recording folder; a transcript that never reached a folder
  (none chosen) stays in the outbox. A recording whose transcript is still
  waiting to be written to the folder is kept whole. Raw captures are
  compressed to AAC after transcription.
- **Models.** Speech models are cached under
  `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml`, speaker models
  under `~/Library/Application Support/FluidAudio/Models`.
- **Secrets.** An OpenAI key, if you add one, is stored in your login keychain,
  not in a file.

## Settings

Change settings in the app (menu bar > Settings…). Every setting is also
reachable from the shell, using the binary inside the app bundle (so it reads
the app's own settings and keychain):

```sh
MINNAS=/Applications/Minnas.app/Contents/MacOS/minnas
$MINNAS --settings                          # all settings, with value and source
$MINNAS --settings set recordingsKeepDays 90
$MINNAS --settings set openAIKey -          # "-" reads the value from stdin
$MINNAS --settings unset recordingsKeepDays
```

An environment variable of the same name wins over a stored setting, which wins
over a `.env` file, which wins over the default. `.env.example` lists every
key. There are no server addresses to configure: the only network endpoint
the app itself talks to is OpenAI's, fixed to `https://api.openai.com`.

## Privacy

- Audio and transcripts stay on your Mac. Nothing is sent anywhere unless you
  turn on cloud transcription (Settings > Cloud, with your own key) and a
  cloud model is used for a recording, either as the default model or chosen
  in Re-transcribe; then that recording's audio goes to OpenAI. "Test Key" in
  Settings > Cloud sends only the key, to OpenAI's model list.
- There is no telemetry, no analytics and no account.
- The first time you use a model it is downloaded from Hugging Face:
  `argmaxinc/whisperkit-coreml` for speech recognition, and
  `FluidInference/speaker-diarization-coreml` for speaker separation. The
  speaker models are then loaded from disk. The speech library (WhisperKit)
  also asks Hugging Face for the model's file list each time it loads a model,
  once per app launch, to check the cached files and fetch any that are
  missing. These requests carry no audio, transcripts or personal data.
- The calendar is read on the Mac through EventKit and is not sent anywhere.
  For a recording tagged with a calendar event, the attendees' names and
  email addresses are stored in that recording's `meta.json` (in the working
  data, not in the transcript). The transcript's frontmatter carries the
  event's identifier and link, and in a 1:1 the other attendee's name labels
  their side of the conversation.
- Recording other people can be regulated where you live. Tell participants
  when the law or courtesy calls for it.

See [SECURITY.md](SECURITY.md) for the threat model.

## Troubleshooting

- **The other side is silent, or a track goes quiet after plugging in
  headphones.** Switching output or input devices mid-call restarts the
  capture. Both tracks recover within a few seconds and are padded with silence
  for the gap so they stay in sync. If a track stays dead the menu shows a
  cross for it and an alert appears. If it keeps failing, check the audio
  permissions above, or try the other capture engine.
- **"Minnas is already running."** Only one copy may run, because a second one
  would treat a live recording as interrupted. Find the first copy in the menu
  bar, or quit it with Activity Monitor, then launch again.
- **Asked for permission again after switching between a download and a source
  build.** They are signed by different certificates and macOS treats them as
  different apps for permissions. Stick with one.
- **Asked for permission again after a rebuild.** You built without the signing
  identity, so the signature changed. Run `bash scripts/setup-signing-identity.sh`
  once and rebuild. If a stale entry remains, remove the app from the list in
  System Settings > Privacy & Security with the minus button and grant it on the
  next launch.
- **The microphone records pure silence.** Check the default input in System
  Settings > Sound. If it is your iPhone through Continuity, pick another input.
- **Logs.** `/usr/bin/log show --predicate 'subsystem == "com.jwiderberg.minnas"'`
  (the `CFBundleIdentifier` from `App/Info.plist`). In zsh, plain `log` is a
  shell builtin, so use the full path. Only notices and errors are kept.

## Development

```sh
swift build                       # compile check, no bundle
bash scripts/make-app.sh          # build and assemble .build/Minnas.app
swift run minnas --cleanup-test   # transcript-cleanup self-check, no models, no permissions
swift run minnas --self-test      # delivery backoff and pruning rules
bash -n scripts/*.sh              # shell syntax check
```

Command-line harnesses run with `swift run minnas <flag>` and need no
permissions: `--transcribe <audio>`, `--retranscribe <slug>`, `--diarize
<audio>`, `--probe-language <slug>`, `--import-file <path>`, `--deliver
<slug> [--run]`, `--settings`, `--version`. `--list-memos` and
`--import-memo <id>` read the Voice Memos library, so the process needs Full
Disk Access (your terminal's, or the app's when run from the bundle).

The capture harnesses `--mic-test <seconds> <out.caf>` and `--system-test
<seconds> <out.caf>` need the microphone and recording grants, so run them
from inside the built app (`.build/Minnas.app/Contents/MacOS/minnas`), as do
`--calendar` (Calendars grant) and the `--settings-window` / `--onboarding` /
`--memo-window` window harnesses. The process-tap test charges its grant to the app that
launched it, so start it through LaunchServices:
`open -W -n -g --stdout /tmp/tap.log --stderr /tmp/tap.log .build/Minnas.app --args --tap-test 30 /tmp/tap.caf`.
Test any change to the capture code with a real run while switching the
default input or output device. `CLAUDE.md` holds the engineering rules.

Continuous integration (`.github/workflows/ci.yml`) builds the package, runs
`--cleanup-test` and `--self-test`, and checks the shell scripts (syntax and
dry runs). It downloads no models and needs no permissions. It runs on the
`macos-15` image with that image's Xcode 26 install (Swift 6.2), which is the
oldest toolchain the package supports and stricter than Xcode 26.6's Swift
6.3 about concurrency, so a build that passes locally on a newer Xcode can
still fail there.

`Package.resolved` is committed: a build of a given commit uses exactly the
dependency versions it names. Update it on purpose with
`swift package update`, and read the diff.

**Releases** (`.github/workflows/release.yml`): bump `CFBundleShortVersionString`
in `App/Info.plist`, commit, tag that commit `v<version>` and push the tag. The
workflow builds on the same image as CI, signs with the Developer ID
certificate, notarizes and staples, zips, writes the SHA-256, attests the
build's provenance and creates the GitHub release with verification
instructions. The five secrets it needs are loaded once with
`scripts/release-secrets.sh`. `gh workflow run release.yml -f publish=false`
runs everything except the release and uploads the zip as a workflow
artifact.

## Licence

MIT. See `LICENSE`.
