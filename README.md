# Minnas

Total recall for your meetings.

Minnas is a Mac menubar app. It records your meetings, turns the speech into text on your Mac, and saves the result as Markdown in a folder you choose. "Minnas" is Swedish for "to remember".

## Why

I built Minnas because three things about meeting notes wore me down.

**Bots joining calls.** Note-taking services kept adding a bot to my meetings. Other people's bots kept showing up too. Now there is pushback from many sides. Otter.ai was hit with a class action in August 2025. The person who sued never had an account. Another attendee's bot recorded them ([NPR](https://www.npr.org/2025/08/15/g-s1-83087/otter-ai-transcription-class-action-lawsuit)). The University of Washington blocked Read AI from its Zoom and Teams. The bot joined meetings that its own users were not in ([UW-IT](https://it.uw.edu/guides/security-authentication/read-ai-deactivation/)). Microsoft Teams now puts unregistered bots in a "Suspected threats" lobby. The organizer must confirm before one gets in ([SecurityWeek](https://www.securityweek.com/microsoft-adds-new-teams-controls-to-block-unauthorized-ai-bots-from-meetings/)). Google Meet also tags third-party bots when they try to join ([UC Today](https://www.uctoday.com/security-compliance-risk/google-meet-launches-update-to-better-screen-suspicious-bots/)). A bot is a stranger in the room. The audio is already on my Mac. I wanted to record it there.

**Hardware tied to subscriptions.** AI recorders avoid the bot problem. They sell you a device, then charge for transcription. A Plaud device includes 300 transcription minutes a month on the free plan. After that it costs $8.33 a month for Pro or $20 a month for Unlimited, billed yearly. Monthly rates cost more ([Plaud pricing](https://www.plaud.ai/pages/plaud-ai-plan-pricing)). The minutes are what you pay for. Your audio lives on their servers. The device is just a way into the plan. An Apple silicon Mac already runs Whisper well. It should not need a subscription for that.

**Work spread across Teams, Zoom and Meet.** Each client uses a different platform. Okta's Businesses at Work data shows how much they overlap. In the 2022 report, 45% of its Microsoft 365 customers also used Zoom ([Zoom's summary of the report](https://www.zoom.com/en/blog/zoom-okta-2022-businesses-at-work-report/)). Each platform's built-in notes need their own license and stay in their own silo. Teams intelligent recap needs a Teams Premium or Microsoft 365 Copilot license ([Microsoft Learn](https://learn.microsoft.com/en-us/microsoftteams/intelligent-recap-calls-meetings)). Meet's "Take notes for me" needs a Gemini or AI Meetings add-on on the organizer's account. As a guest, you get nothing ([Google Meet help](https://support.google.com/meet/answer/14754931)). I wanted one folder of Markdown files, with one file per meeting, no matter which app the meeting used.

So Minnas is a menubar app. It records what your Mac plays and what your microphone hears. It transcribes on the Neural Engine and writes plain files. No bot. No device. No plan.

## What it does

- **No bot joins your call.** It captures the audio your Mac plays and the audio your microphone hears. It works with Zoom, Teams, Meet, or anything else that makes sound.
- **Local first.** Transcription runs on the Apple Neural Engine using [WhisperKit](https://github.com/argmaxinc/WhisperKit). It also tells speakers apart on the device, using a diarization model from [FluidAudio](https://github.com/FluidInference/FluidAudio).
- **Two tracks.** Your microphone and the other people are recorded and transcribed separately. So "Me" and "Them" are known, not guessed. When several people on the remote side speak, that side is split into "Them (A)" and "Them (B)".
- **Plain files.** Each meeting becomes a Markdown file. You pick the folder. It can be a notes vault, a synced folder, or anywhere else.
- **Optional cloud transcription** with your own OpenAI key. Use it if you want better accuracy. The audio is uploaded for that recording.
- **Calendar prompts** a few minutes before a meeting that has an online meeting link. It uses Apple's calendar framework (EventKit), so any calendar account set up on the Mac works. It is off until you turn it on.
- **Voice Memos import** for iPhone memos synced through iCloud. The list updates as memos arrive. The Mac gets them only while Voice Memos is running. So the import window's "Sync from iCloud" button opens Voice Memos in the background. **Transcribe Audio File…** works on any recording made somewhere else.
- **Language detection** happens for each recording. It picks from the languages you list. English is the default. You can add others, such as Swedish, in Settings. If the language changes during a meeting, it switches.

## Requirements

- macOS 15 or newer, on Apple silicon.
- Xcode 26 (Swift 6.2 or newer) to build. The Command Line Tools alone work only if they are the 26 release. Check with `swift --version`.
- About 3 GB of free disk space for the speech models, plus space for your audio.

## Install

### Download

Each [release](https://github.com/jwiderberg/minnas/releases) includes a `Minnas-<version>.zip`. GitHub Actions builds it from the tagged commit. It is signed with a Developer ID certificate and notarized by Apple, so it opens without a Gatekeeper warning. Unzip it, move Minnas.app to /Applications, and open it. [Verify a download](#verify-a-download) explains how to check what you got.

### Build from source

Or build it yourself from a clone you can read:

```sh
git clone https://github.com/jwiderberg/minnas.git
cd minnas
bash scripts/install.sh
```

Add `--dry-run` first to see every step without changing anything. Other flags: `--no-identity`, `--dest <dir>`, `--no-launch`.

What the script does, in order:

1. Checks the macOS version (against `LSMinimumSystemVersion` in `App/Info.plist`, currently 15.0) and Apple silicon.
2. Checks that Swift 6.2 or newer is installed. If not, it tells you what to install.
3. Runs `swift build -c release`. The first build downloads dependencies through SwiftPM.
4. Offers to create a local code-signing identity (see below). It asks `Create the local signing identity? [y/N]`.
5. Runs `scripts/make-app.sh` to build and sign `Minnas.app`.
6. Copies it to `/Applications`. If that is not writable, it uses `~/Applications`. You can also pass a folder with `--dest`. It asks before replacing an existing copy.
7. Launches it, unless you pass `--no-launch`.
8. Prints the permission prompts to expect. It quotes the explanation each one shows, taken from the usage strings in `App/Info.plist`.

It never uses `sudo`. It makes no network requests of its own.

**The signing identity.** macOS remembers your microphone and recording permissions by the app's code signature. A build without a stable signature gets a new one each time. So macOS asks again after every rebuild. The identity ("Minnas Dev") is one self-signed certificate and key in your login keychain. Nobody else trusts it. It only signs builds made on this Mac. Say no, or pass `--no-identity`, if you prefer not to create it. In that case, expect to grant permissions again after each rebuild.

A source build and a downloaded release are signed by different certificates. So macOS keeps separate permission grants for each. Use one or the other. If you switch, you must grant permissions again.

### Verify a download

Each check proves one thing. The first two need the [GitHub CLI](https://cli.github.com). The last two come built into macOS.

```sh
shasum -a 256 -c Minnas-<version>.zip.sha256         # the file is intact
gh attestation verify Minnas-<version>.zip --repo jwiderberg/minnas
     # this exact file was produced by this repository's release workflow
     # from the tagged commit (a Sigstore-signed statement from GitHub)
spctl --assess --type execute -vv Minnas.app          # "accepted source=Notarized Developer ID"
codesign -dvv Minnas.app 2>&1 | grep TeamIdentifier   # the Team ID shown in the release notes
```

The attestation links the binary to public source code. Notarization means Apple scanned the app and the signer holds a Developer ID. Neither one proves the source is harmless. Read the code yourself. Read `Package.resolved` to see what it pulls in. The release notes list the SHA-256 and the Team ID. See [SECURITY.md](SECURITY.md#releases) for how releases are built and what a compromise would look like.

## Uninstall

```sh
bash scripts/uninstall.sh --dry-run   # preview
bash scripts/uninstall.sh
```

It removes the app. Then it asks separately, with the default set to no, before deleting the working data in Application Support (your recorded audio), the keychain item, the signing identity, and the permission grants. It never touches your transcripts folder.

## First run and permissions

Minnas lives in the menu bar. It has no Dock icon. On first launch, a setup window asks where transcripts should go. It suggests `~/Documents/Minnas Transcripts`. It then walks you through the microphone and system-audio permissions. It also offers optional extras: an OpenAI key and the calendar. These are all the permissions it can ask for.

| Permission | Why | When it is asked | Without it |
| --- | --- | --- | --- |
| Microphone | Your side of the meeting. | During setup, or the first time you start a recording. | Nothing can be recorded. |
| System Audio Recording (the default capture engine) | The other participants' side, through a Core Audio process tap. Audio only. | The first time you start a recording. | Your microphone is still captured. The other side is empty, because the tap delivers silence. The app warns you when a track has been silent for 15 seconds. |
| Screen Recording (only if you switch to the ScreenCaptureKit engine) | The same job, through ScreenCaptureKit. macOS files this under Screen Recording. Audio only. The screen is never captured. | The first recording after you switch. | As above. The app also alerts you if the stream cannot restart. |
| Calendars (optional) | Prompts you before meetings. Names the other person in a 1:1. | When you choose "macOS Calendar" as the calendar source and press Grant Calendar Access (in setup, or in Settings > Calendar). | No prompts. You start recordings from the menu. |
| Full Disk Access (optional) | Reads iPhone memos in the Voice Memos library. macOS never prompts for it. | The app appears, switched off, under System Settings > Privacy & Security > Full Disk Access after the first import attempt. | "Import Voice Memos" cannot read the library. Recording and file import still work. |

Grant them in System Settings > Privacy & Security. Then relaunch the app. Settings > Permissions shows the status of each one.

**Which capture engine.** The default engine (`systemAudioEngine` = `taps`) is a Core Audio process tap. It needs only the System Audio Recording permission. You can exclude apps by process. It does not trigger macOS's "is recording your screen" reminders. ScreenCaptureKit (`sck`) is the other option. You choose it in Settings > Transcription. Switch to it if the other side stays silent with the tap, even though System Audio Recording is granted. macOS cannot report that grant, so a silent tap is the only sign. You might also switch if you already granted Screen Recording and prefer it. ScreenCaptureKit needs Screen Recording.

## Where files live

- **Transcripts folder.** The Markdown files go to the folder you pick in setup or in Settings > General (setting `transcriptsFolderPath`). Files are named `<yyyy-MM-dd HHmm> <title>.md`. Minnas only adds or updates files there. It never deletes anything in that folder. Neither does `scripts/uninstall.sh`. Until you choose a folder, transcripts stay in the working data below. After you choose one, every existing transcript is written to the folder within five minutes.
- **Working data.** Audio, per-recording metadata (`meta.json`), and a local copy of each transcript live in `~/Library/Application Support/minnas/outbox/`. Each recording gets its own folder.
- **Retention.** Recorded audio is deleted after 30 days by default (`recordingsKeepDays`). Set it to `0` to keep audio forever. The 30 days count from when the recording arrived. Until then, you can transcribe again with another model. Transcripts in your transcripts folder are never touched. When the audio is deleted, the outbox copy of a transcript that is already in your folder is removed too, along with its recording folder. A transcript that never reached a folder (because none was chosen) stays in the outbox. A recording whose transcript is still waiting to be written to the folder is kept whole. Raw captures are compressed to AAC after transcription.
- **Models.** Speech models are cached in `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml`. Speaker models are cached in `~/Library/Application Support/FluidAudio/Models`.
- **Secrets.** If you add an OpenAI key, it is stored in your login keychain. It is not stored in a file.

## Settings

Change settings in the app (menu bar > Settings…). You can also reach every setting from the shell. Use the binary inside the app bundle. That way it reads the app's own settings and keychain:

```sh
MINNAS=/Applications/Minnas.app/Contents/MacOS/minnas
$MINNAS --settings                          # all settings, with value and source
$MINNAS --settings set recordingsKeepDays 90
$MINNAS --settings set openAIKey -          # "-" reads the value from stdin
$MINNAS --settings unset recordingsKeepDays
```

An environment variable with the same name beats a stored setting. A stored setting beats a `.env` file. A `.env` file beats the default. `.env.example` lists every key. You do not need to set server addresses. The only network endpoint the app talks to is OpenAI's, fixed at `https://api.openai.com`.

## Privacy

- Audio and transcripts stay on your Mac. Nothing leaves unless you turn on cloud transcription (Settings > Cloud, with your own key). It also needs a cloud model for a recording. That model can be the default, or you can pick it in Re-transcribe. Then that recording's audio goes to OpenAI. "Test Key" in Settings > Cloud sends only the key, to OpenAI's model list.
- There is no telemetry, no analytics, and no account.
- The first time you use a model, it downloads from Hugging Face. Speech recognition uses `argmaxinc/whisperkit-coreml`. Speaker separation uses `FluidInference/speaker-diarization-coreml`. After that, the speaker models load from disk. The speech library (WhisperKit) also asks Hugging Face for the model's file list each time it loads a model. That happens once per app launch. It checks the cached files and fetches any that are missing. These requests carry no audio, no transcripts, and no personal data.
- The calendar is read on the Mac through EventKit. It is not sent anywhere. For a recording tied to a calendar event, the attendees' names and email addresses are stored in that recording's `meta.json`. That file is in the working data, not in the transcript. The transcript's frontmatter holds the event's identifier and link. In a 1:1, the other attendee's name labels their side of the conversation.
- Recording other people can be regulated where you live. Tell participants when the law or good manners call for it.

See [SECURITY.md](SECURITY.md) for the threat model.

## Troubleshooting

- **The other side is silent, or a track goes quiet after you plug in headphones.** Switching output or input devices during a call restarts the capture. Both tracks recover within a few seconds. The gap is padded with silence so the tracks stay in sync. If a track stays dead, the menu shows a cross for it and an alert appears. If it keeps failing, check the audio permissions above. You can also try the other capture engine.
- **"Minnas is already running."** Only one copy can run. A second copy would treat a live recording as interrupted. Find the first copy in the menu bar. Or quit it with Activity Monitor. Then launch again.
- **Asked for permission again after switching between a download and a source build.** They are signed by different certificates. macOS treats them as different apps for permissions. Stick with one.
- **Asked for permission again after a rebuild.** You built without the signing identity, so the signature changed. Run `bash scripts/setup-signing-identity.sh` once, then rebuild. If an old entry remains, remove the app from the list in System Settings > Privacy & Security with the minus button. Then grant it on the next launch.
- **The microphone records pure silence.** Check the default input in System Settings > Sound. If it is your iPhone through Continuity, pick another input.
- **Logs.** Run `/usr/bin/log show --predicate 'subsystem == "com.jwiderberg.minnas"'`. The subsystem is the `CFBundleIdentifier` from `App/Info.plist`. In zsh, plain `log` is a shell builtin, so use the full path. Only notices and errors are kept.

## Development

```sh
swift build                       # compile check, no bundle
bash scripts/make-app.sh          # build and assemble .build/Minnas.app
swift run minnas --cleanup-test   # transcript-cleanup self-check, no models, no permissions
swift run minnas --self-test      # delivery backoff and pruning rules
bash -n scripts/*.sh              # shell syntax check
```

Run command-line tools with `swift run minnas <flag>`. They need no permissions: `--transcribe <audio>`, `--retranscribe <slug>`, `--diarize <audio>`, `--probe-language <slug>`, `--import-file <path>`, `--deliver <slug> [--run]`, `--settings`, `--version`. `--list-memos` and `--import-memo <id>` read the Voice Memos library. So the process needs Full Disk Access. That is your terminal's, or the app's when run from the bundle.

The capture tests `--mic-test <seconds> <out.caf>` and `--system-test <seconds> <out.caf>` need the microphone and recording grants. Run them from inside the built app (`.build/Minnas.app/Contents/MacOS/minnas`). The same goes for `--calendar` (needs the Calendars grant) and the `--settings-window`, `--onboarding`, and `--memo-window` window tests. The process-tap test charges its grant to the app that launched it. So start it through LaunchServices:
`open -W -n -g --stdout /tmp/tap.log --stderr /tmp/tap.log .build/Minnas.app --args --tap-test 30 /tmp/tap.caf`.
Test any change to the capture code with a real run. Switch the default input or output device during the run. `CLAUDE.md` holds the engineering rules.

Continuous integration (`.github/workflows/ci.yml`) builds the package. It runs `--cleanup-test` and `--self-test`, and it checks the shell scripts (syntax and dry runs). It downloads no models and needs no permissions. It runs on the `macos-15` image, using that image's Xcode 26 install (Swift 6.2). This is the oldest toolchain the package supports. It is also stricter than Xcode 26.6's Swift 6.3 about concurrency. So a build that passes on a newer Xcode locally can still fail in CI.

`Package.resolved` is committed. A build of a given commit uses exactly the dependency versions it names. Update it on purpose with `swift package update`, and read the diff.

**Releases** (`.github/workflows/release.yml`): Bump `CFBundleShortVersionString` in `App/Info.plist`. Commit. Tag that commit `v<version>` and push the tag. The workflow builds on the same image as CI. It signs with the Developer ID certificate, notarizes and staples, zips the app, writes the SHA-256, attests the build's provenance, and creates the GitHub release with verification instructions. You load the five secrets it needs once, with `scripts/release-secrets.sh`. To run everything except the release, and upload the zip as a workflow artifact, use `gh workflow run release.yml -f publish=false`.

## Licence

MIT. See `LICENSE`.
