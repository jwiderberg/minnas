#!/usr/bin/env bash
#
# Build the app from source and install it. Run from a clone:
#
#   git clone https://github.com/jwiderberg/minnas.git && cd minnas
#   bash scripts/install.sh
#
# Never pipe this into a shell. Read it first; it is short.
#
# What it does, in order (each step is echoed):
#   1. checks macOS version and Apple silicon
#   2. checks the Swift toolchain (6.2 or newer)
#   3. swift build -c release
#   4. offers to create the local code-signing identity (login keychain)
#   5. scripts/make-app.sh: assembles and signs the .app
#   6. copies the .app to the destination
#   7. launches it
#   8. prints what to expect next
#
# The app name, bundle id, minimum macOS and identity name are read from
# scripts/make-app.sh, scripts/setup-signing-identity.sh and App/Info.plist,
# so this script does not need to change when those are renamed.
#
# Flags:
#   --dry-run      print every step, change nothing
#   --no-identity  skip the signing identity; the app is signed ad-hoc and
#                  macOS asks for permissions again after every rebuild
#   --dest <dir>   install into <dir> (default /Applications, or
#                  ~/Applications when /Applications is not writable)
#   --no-launch    do not open the app when done
#
# No sudo, and no network access of its own (SwiftPM fetches dependencies
# when it builds).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DRY_RUN=0
NO_IDENTITY=0
NO_LAUNCH=0
DEST_ARG=""

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --no-identity) NO_IDENTITY=1 ;;
        --no-launch) NO_LAUNCH=1 ;;
        --dest)
            if [[ $# -lt 2 || -z "${2:-}" ]]; then
                echo "error: --dest needs a directory" >&2
                exit 2
            fi
            DEST_ARG="$2"
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument '$1' (try --help)" >&2; exit 2 ;;
    esac
    shift
done

step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Run a command, or only print it under --dry-run.
run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '    [dry-run]'; printf ' %q' "$@"; printf '\n'
    else
        printf '    $'; printf ' %q' "$@"; printf '\n'
        "$@"
    fi
}

# Ask a yes/no question on the terminal. Returns 0 only for an explicit y/Y.
# Under --dry-run it prints the question and assumes yes, so the command that
# would follow is shown (and still not run). With no terminal on
# stdin it prints a notice and answers no.
ask() {
    local prompt="$1" answer=""
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '    [dry-run] would ask: %s (assuming y, to show the command)\n' "$prompt"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        printf '    stdin is not a terminal, answering N to: %s\n' "$prompt"
        return 1
    fi
    read -r -p "    $prompt " answer </dev/tty || return 1
    [[ "$answer" == "y" || "$answer" == "Y" ]]
}

# Pull NAME="value" out of a shell script without sourcing it.
script_var() {
    sed -nE "s/^$2=\"([^\"]*)\".*/\\1/p" "$1" | head -n 1
}

plist_get() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$ROOT/App/Info.plist" 2>/dev/null || true
}

[[ -f scripts/make-app.sh && -f App/Info.plist ]] || fail "run this from a clone of the repository (scripts/make-app.sh not found)"

APP_NAME="$(script_var scripts/make-app.sh APP_NAME)"
EXECUTABLE_NAME="$(script_var scripts/make-app.sh EXECUTABLE_NAME)"
IDENTITY_NAME="$(script_var scripts/make-app.sh IDENTITY_NAME)"
[[ -n "$APP_NAME" && -n "$EXECUTABLE_NAME" && -n "$IDENTITY_NAME" ]] \
    || fail "could not read APP_NAME / EXECUTABLE_NAME / IDENTITY_NAME from scripts/make-app.sh"
APP_DIR=".build/${APP_NAME}.app"
BUNDLE_ID="$(plist_get CFBundleIdentifier)"
DISPLAY_NAME="$(plist_get CFBundleDisplayName)"
DISPLAY_NAME="${DISPLAY_NAME:-$APP_NAME}"
MIN_MACOS="$(plist_get LSMinimumSystemVersion)"
[[ -n "$MIN_MACOS" ]] || fail "App/Info.plist has no LSMinimumSystemVersion"
MIN_MACOS_MAJOR="${MIN_MACOS%%.*}"
MIN_MACOS_MINOR="$(cut -d. -f2 <<<"$MIN_MACOS.0")"

[[ $DRY_RUN -eq 1 ]] && echo "DRY RUN: nothing below is changed; the commands are only printed."

# ---------------------------------------------------------------- 1. system
step "1/8 Checking macOS and hardware"
MACOS_VERSION="$(sw_vers -productVersion)"
MACOS_MAJOR="${MACOS_VERSION%%.*}"
MACOS_MINOR="$(cut -d. -f2 <<<"$MACOS_VERSION.0")"
note "macOS $MACOS_VERSION (this build needs $MIN_MACOS or newer, from App/Info.plist)"
if (( MACOS_MAJOR < MIN_MACOS_MAJOR || (MACOS_MAJOR == MIN_MACOS_MAJOR && MACOS_MINOR < MIN_MACOS_MINOR) )); then
    fail "macOS $MIN_MACOS or newer is required, found $MACOS_VERSION"
fi
if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != "1" ]]; then
    fail "Apple silicon is required (the transcription models run on the Neural Engine)"
fi
note "Apple silicon: yes"

# ---------------------------------------------------------------- 2. swift
step "2/8 Checking the Swift toolchain"
if ! command -v swift >/dev/null 2>&1; then
    cat >&2 <<'EOF'
error: swift was not found.

Building needs Swift 6.2 or newer, which ships with Xcode 26.
  - Install Xcode 26 from the App Store, then run:
        sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
        sudo xcodebuild -license accept
  - The Command Line Tools alone (xcode-select --install) are not enough
    unless they are the 26 release; check with: swift --version
Then run this script again.
EOF
    exit 1
fi
SWIFT_LINE="$(swift --version 2>&1 | grep -m1 'Swift version' || true)"
note "${SWIFT_LINE:-swift --version printed no version line}"
SWIFT_VER="$(sed -nE 's/.*Swift version ([0-9]+)\.([0-9]+).*/\1 \2/p' <<<"$SWIFT_LINE")"
if [[ -z "$SWIFT_VER" ]]; then
    fail "could not read the Swift version from 'swift --version'"
fi
read -r SWIFT_MAJOR SWIFT_MINOR <<<"$SWIFT_VER"
if (( SWIFT_MAJOR < 6 || (SWIFT_MAJOR == 6 && SWIFT_MINOR < 2) )); then
    cat >&2 <<EOF
error: Swift $SWIFT_MAJOR.$SWIFT_MINOR is too old; 6.2 or newer is required.
Install Xcode 26 from the App Store, then run:
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
    sudo xcodebuild -license accept
or, for the command line tools only:
    xcode-select --install
and check 'swift --version' again.
EOF
    exit 1
fi

# ---------------------------------------------------------------- 3. build
step "3/8 Building (swift build -c release); first build fetches dependencies and takes a few minutes"
run swift build -c release

# ---------------------------------------------------------------- 4. identity
step "4/8 Signing identity"
SIGN_NOTE="ad-hoc (macOS will ask for permissions again after every rebuild)"
if [[ $NO_IDENTITY -eq 1 ]]; then
    note "skipped (--no-identity). The app will be signed ad-hoc."
    note "Caveat: macOS ties microphone and recording permissions to the code"
    note "signature, and an ad-hoc signature changes on every build, so you will"
    note "be asked again after each rebuild."
elif security find-identity -p codesigning -v 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    note "'$IDENTITY_NAME' already exists in your login keychain; it will be used."
    SIGN_NOTE="'$IDENTITY_NAME'"
else
    note "scripts/setup-signing-identity.sh writes one self-signed code-signing certificate"
    note "and its private key, named '$IDENTITY_NAME', into your login keychain (10 years)."
    note "Why: macOS keeps your permission grants only if the app's signature stays the same"
    note "between builds; it is not trusted by anyone else and only signs builds on this Mac."
    if ask "Create the local signing identity? [y/N]"; then
        run bash scripts/setup-signing-identity.sh
        SIGN_NOTE="'$IDENTITY_NAME'"
    else
        note "not created. The app will be signed ad-hoc; permissions reset after each rebuild."
        note "You can create it later with: bash scripts/setup-signing-identity.sh"
    fi
fi

# ---------------------------------------------------------------- 5. bundle
step "5/8 Assembling and signing $APP_DIR (scripts/make-app.sh), signature: $SIGN_NOTE"
run bash scripts/make-app.sh

# ---------------------------------------------------------------- 6. install
step "6/8 Installing"
if [[ -n "$DEST_ARG" ]]; then
    DEST="${DEST_ARG/#\~/$HOME}"
    if [[ ! -d "$DEST" ]]; then
        run mkdir -p "$DEST"
    fi
    if [[ $DRY_RUN -eq 0 && ! -w "$DEST" ]]; then
        fail "$DEST is not writable"
    fi
elif [[ -w /Applications ]]; then
    DEST="/Applications"
else
    DEST="$HOME/Applications"
    note "/Applications is not writable by you; using $DEST instead."
    if [[ ! -d "$DEST" ]]; then
        run mkdir -p "$DEST"
    fi
fi
TARGET="$DEST/${APP_NAME}.app"
note "destination: $TARGET"

INSTALLED=0
if [[ -e "$TARGET" ]]; then
    if pgrep -x "$EXECUTABLE_NAME" >/dev/null 2>&1; then
        note "$DISPLAY_NAME is running. Quit it from its menubar icon first, then run this script again."
        note "Leaving $TARGET untouched; the fresh build is at $ROOT/$APP_DIR."
    elif ask "Replace existing $TARGET? [y/N]"; then
        run rm -rf "$TARGET"
        run ditto "$APP_DIR" "$TARGET"
        INSTALLED=1
    else
        note "keeping the existing copy. The fresh build is at $ROOT/$APP_DIR."
    fi
else
    run ditto "$APP_DIR" "$TARGET"
    INSTALLED=1
fi
if [[ $INSTALLED -eq 1 && $DRY_RUN -eq 0 ]]; then
    codesign --verify --verbose=1 "$TARGET"
fi

# ---------------------------------------------------------------- 7. launch
step "7/8 Launching"
if [[ $NO_LAUNCH -eq 1 ]]; then
    note "skipped (--no-launch). Start it with: open \"$TARGET\""
elif [[ $INSTALLED -eq 0 && $DRY_RUN -eq 0 ]]; then
    note "nothing was installed, so nothing is launched."
else
    run open "$TARGET"
fi

# ---------------------------------------------------------------- 8. next
step "8/8 What to expect next"
MIC_STRING="$(plist_get NSMicrophoneUsageDescription)"
AUDIO_STRING="$(plist_get NSAudioCaptureUsageDescription)"
CAL_STRING="$(plist_get NSCalendarsFullAccessUsageDescription)"
[[ -n "$MIC_STRING" ]] || fail "App/Info.plist has no NSMicrophoneUsageDescription; macOS would refuse to ask for the microphone"
# The text macOS shows in each prompt is the usage string, quoted verbatim.
quote() { fold -s -w 70 <<<"\"$1\"" | sed -e 's/ *$//' -e 's/^/           /'; }
cat <<EOF
    $DISPLAY_NAME ($BUNDLE_ID) lives in the menu bar (no Dock icon). The setup
    window opens on first launch and asks where transcripts go (it suggests
    ~/Documents/Minnas Transcripts).

    Permission prompts. macOS shows the app's own explanation with each. The
    microphone comes during setup (step 2 of 4), the system audio one with your
    first recording:
      1. Microphone: your side of the call.
EOF
quote "$MIC_STRING"
if [[ -n "$AUDIO_STRING" ]]; then
    echo "      2. System Audio Recording: the other participants' side. This is the default"
    echo "         capture engine (a Core Audio process tap)."
    quote "$AUDIO_STRING"
    echo "         If you switch to the ScreenCaptureKit engine (Settings > Transcription),"
    echo "         macOS asks for Screen Recording instead, with no app text. Audio only."
else
    echo "      2. Screen Recording: the other participants' side. This build captures system"
    echo "         audio through ScreenCaptureKit, which macOS files under Screen Recording."
    echo "         It records audio only, never the screen."
fi
if [[ -n "$CAL_STRING" ]]; then
    echo "      3. Calendars (optional): only when you turn calendar prompts on."
    quote "$CAL_STRING"
fi
cat <<EOF
    If a prompt does not appear, open System Settings > Privacy & Security and switch
    $DISPLAY_NAME on under Microphone and the recording entry above, then relaunch it.
    Importing Voice Memos additionally needs Full Disk Access (macOS never prompts for it).

    Until a transcripts folder is chosen, transcripts stay with the recordings under
    ~/Library/Application Support/$EXECUTABLE_NAME/outbox (see the README, "Where files live").

    Uninstall:  bash scripts/uninstall.sh   (add --dry-run to preview)
EOF
if [[ $DRY_RUN -eq 1 ]]; then
    echo
    echo "DRY RUN complete: nothing was built, signed, copied or launched."
fi
