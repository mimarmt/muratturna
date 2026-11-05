#!/usr/bin/env bash
# Builds the app for the simulator, opens the purchase screen and saves paywall.png
# (used as the App Review screenshot of the in-app purchases).
set -euo pipefail
SIM=$(xcrun simctl list devices available -j | python3 -c "
import sys, json, re
devs = json.load(sys.stdin)['devices']
ios = sorted((k for k in devs if 'iOS' in k), key=lambda k: [int(x) for x in re.findall(r'\d+', k)])
for runtime in reversed(ios):
    phones = [d for d in devs[runtime] if d['name'].startswith('iPhone') and 'Pro' in d['name'] and 'Max' not in d['name']] \
             or [d for d in devs[runtime] if d['name'].startswith('iPhone')]
    if phones:
        print(phones[-1]['udid']); break
")
echo "Simulator: $SIM"
xcodebuild build -project Loopnote.xcodeproj -scheme Loopnote \
  -destination "id=$SIM" -derivedDataPath DerivedData \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO | xcbeautify --renderer github-actions
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b
xcrun simctl ui "$SIM" appearance dark || true
xcrun simctl status_bar "$SIM" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 || true
xcrun simctl install "$SIM" DerivedData/Build/Products/Debug-iphonesimulator/Loopnote.app
xcrun simctl launch "$SIM" com.muratturna.loopnote -uitest -paywall -AppleLanguages "(en)" -AppleLocale en_US
sleep 15
# Newer simulators can expose more than one display; take the primary phone screen.
if ! xcrun simctl io "$SIM" screenshot paywall.png 2> shot.err; then
  cat shot.err
  DISPLAY_ID=$(grep -E -- '--display=[0-9]+ +LCD \(primary\)' shot.err | sed -E 's/.*--display=([0-9]+).*/\1/' | head -1)
  DISPLAY_ID=${DISPLAY_ID:-$(grep -oE -- '--display=[0-9]+' shot.err | head -1 | cut -d= -f2)}
  xcrun simctl io "$SIM" screenshot --display="$DISPLAY_ID" paywall.png
fi
ls -l paywall.png
