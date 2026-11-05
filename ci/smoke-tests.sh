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
RESULT=DerivedData/smoke.xcresult
rm -rf "$RESULT"
set +e
xcodebuild test \
  -project Loopnote.xcodeproj -scheme Loopnote \
  -destination "id=$SIM" \
  -derivedDataPath DerivedData \
  -resultBundlePath "$RESULT" \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO | xcbeautify --renderer github-actions
STATUS=${PIPESTATUS[0]}
set -e
if [ "$STATUS" -ne 0 ] && [ -d "$RESULT" ]; then
  echo "::group::Test activities (what the test did, step by step)"
  TEST_ID=$(xcrun xcresulttool get test-results tests --path "$RESULT" | python3 -c "
import sys, json
def walk(n):
    if n.get('nodeType') == 'Test Case': print(n.get('nodeIdentifier', '')); return
    for c in n.get('children', []): walk(c)
for n in json.load(sys.stdin).get('testNodes', []): walk(n)
" | head -1 || true)
  xcrun xcresulttool get test-results activities --test-id "$TEST_ID" --path "$RESULT" | python3 -c "
import sys, json
def walk(a, d=0):
    print('  ' * d + a.get('title', ''))
    for c in a.get('childActivities', []): walk(c, d + 1)
for run in json.load(sys.stdin).get('testRuns', []):
    for a in run.get('activities', []): walk(a)
" || true
  echo "::endgroup::"
fi
exit "$STATUS"
