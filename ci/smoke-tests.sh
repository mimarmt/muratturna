#!/usr/bin/env bash
# Runs the UI smoke tests on the newest available iPhone simulator.
set -euo pipefail
SIM=$(xcrun simctl list devices available -j | python3 -c "
import sys, json, re
devs = json.load(sys.stdin)['devices']
ios = sorted((k for k in devs if 'iOS' in k), key=lambda k: [int(x) for x in re.findall(r'\d+', k)])
for runtime in reversed(ios):
    phones = [d for d in devs[runtime] if d['name'].startswith('iPhone')]
    if phones:
        print(phones[-1]['udid']); break
")
echo "Simulator: $SIM"
xcodebuild test \
  -project Loopnote.xcodeproj -scheme Loopnote \
  -destination "id=$SIM" \
  -derivedDataPath DerivedData \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO | xcbeautify --renderer github-actions
