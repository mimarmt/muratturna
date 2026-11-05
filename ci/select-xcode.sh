#!/usr/bin/env bash
# Picks the newest stable Xcode on the runner (27.x on the xcode-27 image), skipping betas
# and release candidates so builds are accepted by App Store Connect.
set -euo pipefail
pick() { ls -d /Applications/Xcode_$1*.app 2>/dev/null | grep -viE 'beta|release_candidate|_rc' | sort -V | tail -1 || true; }
XCODE=$(pick 27)
[ -z "$XCODE" ] && XCODE=$(pick 26)
echo "Using ${XCODE}"
sudo xcode-select -s "${XCODE}/Contents/Developer"
xcodebuild -version
