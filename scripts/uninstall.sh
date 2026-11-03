#!/usr/bin/env bash
#
# Remove the app and, only if you say yes to each, the data and system
# entries it created. Run from a clone:
#
#   bash scripts/uninstall.sh [--dry-run]
#
# Steps (each destructive one asks [y/N]; with no terminal on stdin every
# answer is N, so nothing is removed):
#   1. the app in /Applications and ~/Applications
#   2. ~/Library/Application Support/<app> (recordings and the outbox!)
#   3. Keychain items (service = bundle id): OPENAI_API_KEY
#   4. the local code-signing identity
#   5. permission grants (tccutil reset)
#
# It never touches your transcripts folder, wherever you chose to put it:
# those are your files. Delete that folder yourself if you want it gone.
#
# --dry-run prints what would be asked and run, and removes nothing.
# No sudo anywhere.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "error: unknown argument '$arg' (try --help)" >&2; exit 2 ;;
    esac
done

step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Run a command, or only print it under --dry-run. A failing command is
# reported but does not stop the remaining steps.
run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '    [dry-run]'; printf ' %q' "$@"; printf '\n'
        return 0
    fi
    printf '    $'; printf ' %q' "$@"; printf '\n'
    "$@" || printf '    (command failed with status %s, continuing)\n' "$?"
}

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

script_var() {
    sed -nE "s/^$2=\"([^\"]*)\".*/\\1/p" "$1" | head -n 1
}

[[ -f scripts/make-app.sh && -f App/Info.plist ]] || fail "run this from a clone of the repository (scripts/make-app.sh not found)"

APP_NAME="$(script_var scripts/make-app.sh APP_NAME)"
EXECUTABLE_NAME="$(script_var scripts/make-app.sh EXECUTABLE_NAME)"
IDENTITY_NAME="$(script_var scripts/make-app.sh IDENTITY_NAME)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' App/Info.plist 2>/dev/null || true)"
[[ -n "$APP_NAME" && -n "$EXECUTABLE_NAME" && -n "$IDENTITY_NAME" && -n "$BUNDLE_ID" ]] \
    || fail "could not read the app name, bundle id or identity name from scripts/make-app.sh and App/Info.plist"

# The app keeps its data in Application Support under the executable name.
SUPPORT_DIR="$HOME/Library/Application Support/$EXECUTABLE_NAME"

[[ $DRY_RUN -eq 1 ]] && echo "DRY RUN: nothing below is removed; commands are printed, not run."
echo "App: $APP_NAME.app   bundle id: $BUNDLE_ID   signing identity: $IDENTITY_NAME"

# ---------------------------------------------------------------- 1. app
step "1/5 The app"
if pgrep -x "$EXECUTABLE_NAME" >/dev/null 2>&1; then
    note "$APP_NAME is running. Quit it from its menubar icon (a recording in progress would be lost), then run this again."
    [[ $DRY_RUN -eq 1 ]] || exit 1
fi
FOUND=()
for dir in /Applications "$HOME/Applications"; do
    [[ -e "$dir/$APP_NAME.app" ]] && FOUND+=("$dir/$APP_NAME.app")
done
if [[ ${#FOUND[@]} -eq 0 ]]; then
    note "no $APP_NAME.app in /Applications or ~/Applications."
else
    for app in "${FOUND[@]}"; do
        if ask "Remove $app? [y/N]"; then
            run rm -rf "$app"
        else
            note "kept $app"
        fi
    done
fi
note "A copy built in this clone (.build/$APP_NAME.app) is removed by deleting the clone or running: swift package clean"

# ---------------------------------------------------------------- 2. data
step "2/5 App data: $SUPPORT_DIR"
if [[ -d "$SUPPORT_DIR" ]]; then
    SIZE="$(du -sh "$SUPPORT_DIR" 2>/dev/null | cut -f1 || true)"
    note "WARNING: this folder holds your recorded audio and the local copy of every transcript"
    note "(${SIZE:-unknown size}). Once removed they cannot be recovered or re-transcribed."
    note "Transcripts exported to your own transcripts folder are NOT in here and are not touched."
    if ask "Delete $SUPPORT_DIR and everything in it? [y/N]"; then
        run rm -rf "$SUPPORT_DIR"
    else
        note "kept"
    fi
else
    note "not present."
fi
note "Downloaded models are shared caches and are left alone. To reclaim the space delete:"
note "  ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml   (speech models)"
note "  ~/Library/Application Support/FluidAudio/Models              (speaker models)"

# ---------------------------------------------------------------- 3. keychain
step "3/5 Keychain items (service '$BUNDLE_ID')"
for account in OPENAI_API_KEY; do
    if security find-generic-password -s "$BUNDLE_ID" -a "$account" >/dev/null 2>&1; then
        if ask "Delete the Keychain item $account? [y/N]"; then
            run security delete-generic-password -s "$BUNDLE_ID" -a "$account"
        else
            note "kept $account"
        fi
    else
        note "$account: not in the keychain."
    fi
done

# ---------------------------------------------------------------- 4. identity
step "4/5 Signing identity '$IDENTITY_NAME'"
if security find-identity -p codesigning -v 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    note "This is the certificate and private key that scripts/setup-signing-identity.sh created."
    note "Removing it means the next build is signed ad-hoc (or you create it again)."
    note "Command: security delete-identity -c \"$IDENTITY_NAME\""
    if ask "Run it? [y/N]"; then
        run security delete-identity -c "$IDENTITY_NAME"
    else
        note "kept"
    fi
else
    note "not found in your keychains."
fi

# ---------------------------------------------------------------- 5. tcc
step "5/5 Permission grants for $BUNDLE_ID"
note "Commands:"
note "  tccutil reset Microphone $BUNDLE_ID"
note "  tccutil reset ScreenCapture $BUNDLE_ID"
note "  tccutil reset SystemPolicyAllFiles $BUNDLE_ID"
note "  tccutil reset Calendar $BUNDLE_ID"
if ask "Reset these permission grants? [y/N]"; then
    for service in Microphone ScreenCapture SystemPolicyAllFiles Calendar; do
        run tccutil reset "$service" "$BUNDLE_ID"
    done
    note "If System Audio Recording still lists the app, remove it in System Settings > Privacy & Security."
else
    note "kept"
fi

echo
if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY RUN complete: nothing was removed."
else
    echo "Done. Your transcripts folder was not touched."
fi
