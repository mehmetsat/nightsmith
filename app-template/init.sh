#!/bin/bash
# init.sh: one-time setup for this workspace. Checks permissions (granted by hand),
# seeds test images. The orchestrator runs it once before round 1.
set -uo pipefail
cd "$(dirname "$0")"
AXCLI="${AXCLI:-$(cd ../../.. && pwd)/tools/axcli/.build/release/axcli}"

perm="$("$AXCLI" check)"
echo "permissions for this terminal: $perm"
if ! echo "$perm" | grep -q '"accessibility":true' || ! echo "$perm" | grep -q '"screen_recording":true'; then
  echo "Grant Accessibility and Screen Recording to the terminal running the harness"
  echo "(System Settings > Privacy & Security), then re-run. Agents must not work around this."
  exit 1
fi

mkdir -p fixtures
i=0
for label in "Invoice 4821" "Error: disk full" "Meeting notes Q3" "Boarding pass LH 1234" "Hello World"; do
  i=$((i + 1))
  "$AXCLI" fixture "fixtures/fixture_$i.png" "$label" >/dev/null
done
"$AXCLI" fixture fixtures/fixture_large.png "Large capture" --size 6000x4000 >/dev/null
# Realistic screenshots of public web pages (real_*.png), so designs are judged on real content.
"$(dirname "$AXCLI")/../../../realistic_fixtures.sh" fixtures >/dev/null 2>&1 || true
echo "seeded $(ls fixtures | wc -l | tr -d ' ') test images in fixtures/"
