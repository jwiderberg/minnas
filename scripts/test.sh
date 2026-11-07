#!/bin/bash
# Runs the package tests. swift-testing needs the Xcode toolchain: with only
# the Command Line Tools selected, `swift test` cannot find the Testing
# module, so point DEVELOPER_DIR at Xcode.app for this one command when
# xcode-select still names the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" ]] && [[ "$(xcode-select -p)" == */CommandLineTools ]] && [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
exec swift test "$@"
