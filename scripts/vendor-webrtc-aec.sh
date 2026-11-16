#!/bin/bash
# Regenerates Sources/CWebRTCAEC/upstream from the two pinned release
# tarballs: the files listed in upstream/MANIFEST (the AEC3 echo canceller
# and what it compiles against, nothing else) plus the licences.
#
#   bash scripts/vendor-webrtc-aec.sh <webrtc-audio-processing-2.1.tar.xz> <abseil-cpp-20240722.0.tar.gz>
#
# Sources: https://freedesktop.org/software/pulseaudio/webrtc-audio-processing/
# and https://github.com/abseil/abseil-cpp/releases (the abseil version
# webrtc-audio-processing 2.1 pins in subprojects/abseil-cpp.wrap).
# --check compares the vendored tree with the tarballs instead of writing.
set -euo pipefail

WEBRTC_SHA=ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe
ABSEIL_SHA=f50e5ac311a81382da7fa75b97310e4b9006474f9560ac46f54a9967f07d4ae3

check=0
if [[ ${1:-} == --check ]]; then check=1; shift; fi
if [[ $# -ne 2 ]]; then
  echo "usage: $0 [--check] <webrtc-audio-processing-2.1.tar.xz> <abseil-cpp-20240722.0.tar.gz>" >&2
  exit 2
fi

root=$(cd "$(dirname "$0")/.." && pwd)
dest=$root/Sources/CWebRTCAEC/upstream
manifest=$dest/MANIFEST

verify() {
  local got
  got=$(shasum -a 256 "$1" | awk '{print $1}')
  if [[ $got != "$2" ]]; then
    echo "error: $1 has sha256 $got, expected $2" >&2
    exit 1
  fi
}
verify "$1" "$WEBRTC_SHA"
verify "$2" "$ABSEIL_SHA"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/src"
tar -xJf "$1" -C "$work/src"
tar -xzf "$2" -C "$work/src"
mv "$work/src/webrtc-audio-processing-2.1" "$work/src/webrtc-audio-processing"
mv "$work/src/abseil-cpp-20240722.0" "$work/src/abseil-cpp"

out=$work/out
mkdir "$out"
while IFS= read -r path; do
  [[ -z $path ]] && continue
  mkdir -p "$out/$(dirname "$path")"
  cp "$work/src/$path" "$out/$path"
done < "$manifest"
cp "$work/src/webrtc-audio-processing/COPYING" "$out/webrtc-audio-processing/COPYING"
cp "$work/src/webrtc-audio-processing/webrtc/LICENSE" "$out/webrtc-audio-processing/webrtc/LICENSE"
cp "$work/src/webrtc-audio-processing/webrtc/PATENTS" "$out/webrtc-audio-processing/webrtc/PATENTS"
cp "$work/src/abseil-cpp/LICENSE" "$out/abseil-cpp/LICENSE"
cp "$manifest" "$out/MANIFEST"
cp "$dest/README.md" "$out/README.md"

if [[ $check == 1 ]]; then
  if diff -r "$out" "$dest" >/dev/null; then
    echo "vendored tree matches the tarballs"
  else
    diff -rq "$out" "$dest" >&2 || true
    echo "error: vendored tree differs from the tarballs" >&2
    exit 1
  fi
  exit 0
fi

rm -rf "$dest/webrtc-audio-processing" "$dest/abseil-cpp"
cp -R "$out/webrtc-audio-processing" "$out/abseil-cpp" "$dest/"
echo "vendored $(wc -l < "$manifest" | tr -d ' ') files into $dest"
