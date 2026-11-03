#!/usr/bin/env bash
# Picks the newest installed Xcode (27 when the runner has it, otherwise 26.x).
set -euo pipefail
XCODE=$(ls -d /Applications/Xcode_27*.app 2>/dev/null | sort -V | tail -1 || true)
if [ -z "${XCODE}" ]; then
  XCODE=$(ls -d /Applications/Xcode_26*.app 2>/dev/null | grep -v -i beta | sort -V | tail -1)
fi
echo "Using ${XCODE}"
sudo xcode-select -s "${XCODE}/Contents/Developer"
xcodebuild -version
