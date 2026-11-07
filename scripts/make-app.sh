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
# CODESIGN_IDENTITY=<name> signs with that identity instead, and
# CODESIGN_KEYCHAIN=<path> restricts the lookup and the signing to that
# keychain. The release workflow (.github/workflows/release.yml) sets both to
# the "Developer ID Application" certificate in a throwaway keychain; a
# Developer ID signature gets a secure timestamp, which notarization requires.
# Local identities are signed without one (no network, and a self-signed
# certificate cannot be timestamped anyway). SKIP_BUILD=1 skips `swift build`
# and only assembles and signs the binary already in .build (the release
# workflow builds before the signing key is anywhere near the runner).
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

IDENTITY_NAME="Minnas Dev"
# Validate the signing request before the old bundle is torn down, so a bad
# CODESIGN_IDENTITY or CODESIGN_KEYCHAIN cannot leave an unsigned bundle in
# place of a working one.
if [[ -n "${CODESIGN_KEYCHAIN:-}" && -z "${CODESIGN_IDENTITY:-}" ]]; then
    echo "FAIL: CODESIGN_KEYCHAIN is set but CODESIGN_IDENTITY is not; the default identity is looked up in the login keychain." >&2
    exit 1
fi
if [[ -n "${CODESIGN_KEYCHAIN:-}" && ! -f "$CODESIGN_KEYCHAIN" ]]; then
    echo "FAIL: CODESIGN_KEYCHAIN '$CODESIGN_KEYCHAIN' does not exist." >&2
    exit 1
fi
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    if ! security find-identity -p codesigning -v ${CODESIGN_KEYCHAIN:+"$CODESIGN_KEYCHAIN"} 2>/dev/null | grep -qF "\"$CODESIGN_IDENTITY\""; then
        echo "FAIL: CODESIGN_IDENTITY '$CODESIGN_IDENTITY' is not a valid code-signing identity${CODESIGN_KEYCHAIN:+ in $CODESIGN_KEYCHAIN}." >&2
        exit 1
    fi
fi

if [[ "${SKIP_BUILD:-0}" == "1" ]]; then
    # No swift invocation at all on this path, not even --show-bin-path:
    # SwiftPM evaluates the manifest, and the release workflow runs this
    # step with the signing key in reach. .build/<config> is SwiftPM's
    # stable symlink to the per-architecture build directory.
    echo "==> SKIP_BUILD=1: using the existing $CONFIG build"
    BIN_PATH=".build/$CONFIG/$EXECUTABLE_NAME"
else
    echo "==> swift build -c $CONFIG"
    swift build -c "$CONFIG"
    BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$EXECUTABLE_NAME"
fi
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

# Codesign. Prefer the stable self-signed "Minnas Dev" identity
# created by scripts/setup-signing-identity.sh — it gives the binary a
# consistent signature hash across rebuilds, which is what TCC keys the
# microphone, system audio and calendar grants off. Fall back to ad-hoc with
# a warning if the identity isn't installed; that mode works but TCC will
# revoke the grants on every rebuild.
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    TIMESTAMP="--timestamp=none"
    case "$CODESIGN_IDENTITY" in
        "Developer ID Application:"*) TIMESTAMP="--timestamp" ;;
    esac
    echo "==> codesign with '$CODESIGN_IDENTITY' ($TIMESTAMP${CODESIGN_KEYCHAIN:+, keychain $CODESIGN_KEYCHAIN})"
    # Two invocations rather than an optional-argument array: an empty array
    # expanded under `set -u` is an error in the macOS /bin/bash (3.2).
    if [[ -n "${CODESIGN_KEYCHAIN:-}" ]]; then
        codesign --force --sign "$CODESIGN_IDENTITY" --keychain "$CODESIGN_KEYCHAIN" --options runtime --entitlements "$ENTITLEMENTS" "$TIMESTAMP" "$APP_DIR"
    else
        codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --entitlements "$ENTITLEMENTS" "$TIMESTAMP" "$APP_DIR"
    fi
elif security find-identity -p codesigning -v 2>/dev/null | grep -qF "\"$IDENTITY_NAME\""; then
    echo "==> codesign with '$IDENTITY_NAME'"
    codesign --force --sign "$IDENTITY_NAME" --options runtime --entitlements "$ENTITLEMENTS" --timestamp=none "$APP_DIR"
else
    echo "==> ad-hoc codesign (no stable identity found)"
    echo "    Run scripts/setup-signing-identity.sh once to install a stable"
    echo "    identity. Without it, TCC grants reset on every rebuild." >&2
    codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" --timestamp=none "$APP_DIR"
fi

codesign --verify --deep --strict --verbose=1 "$APP_DIR"

echo ""
echo "Built: $APP_DIR"
echo "Launch with: open $APP_DIR"
