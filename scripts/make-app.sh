#!/usr/bin/env bash
#
# Build Minnas and assemble a minimal .app bundle.
#
# Why the wrapper: TCC (microphone, screen recording) attaches permissions
# to a CFBundleIdentifier. A raw `swift run` binary has none, so the system
# can't durably remember the user's grant — every launch would re-prompt.
# This script builds the binary and drops it into a hand-rolled .app shell
# with App/Info.plist, then signs it (hardened runtime, App/Minnas.entitlements)
# with the local "Minnas Dev" identity if present, else ad-hoc.
#
# Output: .build/Minnas.app — launch with `open .build/Minnas.app`.
#
# Run as: bash scripts/make-app.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-release}"
APP_NAME="Minnas"
APP_DIR=".build/${APP_NAME}.app"
EXECUTABLE_NAME="minnas"
INFO_PLIST="App/Info.plist"
ENTITLEMENTS="App/Minnas.entitlements"

if [[ ! -f "$INFO_PLIST" ]]; then
    echo "FAIL: $INFO_PLIST is missing." >&2
    exit 1
fi

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$EXECUTABLE_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "FAIL: expected built binary at $BIN_PATH" >&2
    exit 1
fi

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"

# Codesign. Prefer the stable self-signed "Minnas Dev" identity
# created by scripts/setup-signing-identity.sh — it gives the binary a
# consistent signature hash across rebuilds, which is what TCC keys
# Screen Recording / microphone grants off. Fall back to ad-hoc with a
# warning if the identity isn't installed; that mode works but TCC will
# revoke its grant on every rebuild.
# Refuse to ship FluidAudio's prebuilt NemoTextProcessing Rust library: the
# Diarizer-only trait must keep it out, and an unauditable native blob has
# no place in a process holding mic + screen + FDA grants. Checked BEFORE
# signing so a failed build never leaves a signed bundle behind.
if ! NM_OUT="$(nm "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME" 2>&1)"; then
    echo "ERROR: nm failed on the binary: $NM_OUT" >&2
    exit 1
fi
if grep -q _nemo_ <<<"$NM_OUT"; then
    echo "ERROR: NemoTextProcessing linked" >&2
    exit 1
fi

IDENTITY_NAME="Minnas Dev"
if security find-identity -p codesigning -v 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    echo "==> codesign with '$IDENTITY_NAME'"
    codesign --force --sign "$IDENTITY_NAME" --options runtime --entitlements "$ENTITLEMENTS" --timestamp=none "$APP_DIR"
else
    echo "==> ad-hoc codesign (no stable identity found)"
    echo "    Run scripts/setup-signing-identity.sh once to install a stable"
    echo "    identity. Without it, TCC grants reset on every rebuild." >&2
    codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" --timestamp=none "$APP_DIR"
fi

codesign --verify --verbose=1 "$APP_DIR"

echo ""
echo "Built: $APP_DIR"
echo "Launch with: open $APP_DIR"
