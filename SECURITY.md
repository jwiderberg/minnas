# Security

## What Minnas is, for the purpose of a threat model

A single-user Mac app. It runs as you, and macOS has given it the right to
hear your microphone and the audio your Mac plays (the System Audio Recording
grant, or Screen Recording if you switch to the ScreenCaptureKit engine). It
optionally reads your calendar, and, if you allow it, the Voice Memos
library. It writes audio and
transcripts to your own disk. There is no server, no account and no
multi-user mode.

The assets worth protecting are therefore:

- what is said in your meetings (the audio and the transcripts),
- your OpenAI key, if you add one,
- the permission grants macOS has given the app, which are a standing ability
  to listen.

## Who the design defends against

**Other software running as you.** This is the main case. Any process under
your account can already read your files, and Minnas can't hide transcripts
from it. What Minnas can do is stop that process borrowing the app's
microphone and recording permissions, or reading the key:

- **Hardened runtime.** The app is signed with the hardened runtime and a
  minimal entitlements file (`App/Minnas.entitlements`: audio input, and
  calendar access for the optional calendar prompts). Other processes cannot
  inject libraries into it or attach a debugger to read its memory.
- **A signing key that cannot be exported.** The local signing identity that
  `scripts/setup-signing-identity.sh` creates is imported into the login
  keychain as non-extractable, and only `/usr/bin/codesign` is allowed to use it
  without a prompt. The key cannot be copied off the Mac or used from another
  program. A process running as you could still call `codesign` with it to
  re-sign a modified copy, so this makes misuse harder without ruling it out
  (see "What we do not protect against").
- **Secrets in the keychain.** The OpenAI key is stored as a keychain item.
- **A single-instance lock.** A second copy of the app cannot start and treat a
  live recording as abandoned. That would otherwise delete audio that is still
  being written.
- **No HTTP cache.** The app's own network requests (to OpenAI) use an
  ephemeral session with no disk cache, no cookies and no redirects, so the
  key and uploaded audio are not left in `~/Library/Caches`.
- **Bounded inputs.** Titles, speaker names and file names that come from
  calendar invites or imported files are sanitized before they become file
  names or transcript text, and silence padding after a device change is
  capped.

**A person who sends you things.** A hostile calendar invite or a crafted
audio file should not be able to crash the app, write outside its folders, or
inject text into your notes. This is handled by the sanitizing above, and
reports of gaps are welcome.

**Network observers.** Traffic goes only over HTTPS, and only in the cases
below. There are no configurable server addresses; the OpenAI endpoint is
fixed.

## What the app never does

- No telemetry, analytics, crash reporting or update check.
- No network access except:
  1. Hugging Face, for the models: downloading the speech and speaker models
     the first time you use them, and, each time the speech library
     (WhisperKit) loads a speech model (once per launch), a request for the
     model's file list to check the cached copy. No audio, transcripts or
     personal data are part of these requests.
  2. OpenAI, with your own key: the audio of a recording that is transcribed
     with the cloud model (in the app only after you turn on cloud
     transcription; the command-line harnesses take an explicit `--model` as
     the consent), and the key alone when you press "Test Key".
- It never sends audio, transcripts or calendar data anywhere else. Calendar
  attendees (names and email addresses) of a tagged recording are stored in
  that recording's `meta.json` on your Mac.
- It does not run shell commands or load plug-ins, and the build refuses to
  link a prebuilt native text-processing library that an earlier dependency
  version shipped (`scripts/make-app.sh` checks for it).

## What we do not protect against

- **A same-user attacker who calls `codesign` with the local identity.** That
  can produce an app macOS treats as Minnas. Keep the identity only if you
  accept that, or build with `--no-identity` and re-grant permissions per build.
- **Someone with your logged-in session or your Mac unlocked.** They can read
  your recordings and transcripts, which are ordinary files. Use FileVault and a
  lock screen.
- **Malware with root, or a compromised macOS.** It can bypass all of the above.
- **Your own transcripts folder.** If you point it at a folder that syncs to a
  cloud service or is shared, what is in it is exactly as exposed as that
  service.
- **Cloud transcription.** When you turn it on, that audio is handled under
  OpenAI's terms.
- **Model downloads are not pinned by hash.** Models come from Hugging Face over
  HTTPS and are checked only by size. Someone who controls those repositories,
  or your connection to them, could serve a different model. Models are Core
  ML weights, which limits what a swapped model could do, but we haven't
  verified more than that.
- **Supply chain.** The app builds on WhisperKit and FluidAudio. Dependency
  versions are pinned in `Package.resolved`; read what you build.
- **A source build is self-signed.** The local identity gives macOS a stable
  signature to attach permissions to, and that is all it does; nobody but you
  vouches for that build. Downloaded releases are notarized; see Releases.
- **Recording consent.** Whether you may record a conversation depends on where
  you and the other people are. That is your responsibility.

## Releases

A release is produced by `.github/workflows/release.yml` on a hosted GitHub
runner, from the commit the tag points at. The runner signs the app with a
Developer ID Application certificate, submits it to Apple's notary service,
staples the ticket, zips it, and publishes the zip, its SHA-256 and a
Sigstore-signed build-provenance attestation.

What that lets you check (commands in the README under "Verify a download"):

- The SHA-256 says the file you hold is the file that was published.
- `gh attestation verify` says this exact file was produced by this
  repository's release workflow from that commit. The statement is signed by
  GitHub through Sigstore; the repository cannot forge it after the fact.
  Run it with `--source-ref refs/tags/v<version>` and `--signer-workflow
  jwiderberg/minnas/.github/workflows/release.yml`, as the README shows. That
  rules out a file built from a branch or by another workflow.
- `spctl --assess` says Apple's notary service scanned the binary and that it
  is signed by a Developer ID certificate. The Team ID is in the release notes.

Three things are left to you: reading the source, reading `Package.resolved`
for the dependencies, and trusting GitHub's macOS runner image (as everyone
using hosted runners does).

Where the keys are. The Developer ID certificate's private key and the
notarization API key are GitHub repository secrets, readable only by workflow
runs. Someone who takes over the GitHub account, or finds a way to run code in
this repository's Actions, could sign a build. Mitigations: the attestation
would still name the commit and workflow that produced it, so a build that did
not come from a tagged commit on this repository is detectable when you verify
with the options above; Apple can
revoke the certificate; and every notarized build is on record with Apple.
The local "Minnas Dev" identity used for source builds is a separate key that
never leaves your Mac.

## Reporting a vulnerability

Please report privately through a GitHub security advisory on the repository:
<https://github.com/jwiderberg/minnas/security/advisories/new>

Include what you found, how to reproduce it, and the macOS version. Please do
not open a public issue for something that exposes recordings or keys. This is
a one-person project, so expect an acknowledgement within about a week; fixes
are made on a best-effort basis and credited in the release notes unless you
prefer otherwise.

Supported version: the latest release and the `main` branch.
