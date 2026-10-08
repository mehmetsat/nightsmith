#!/bin/bash
# screenshot.sh <app> [out.png] [--title T]
# PNG of the app's main window only (no shadow, no sound). Prints the file path.
set -euo pipefail

TOOLS="$(cd "$(dirname "$0")" && pwd)"
AXCLI="$TOOLS/axcli/.build/release/axcli"

app="${1:?usage: screenshot.sh <app> [out.png] [--title T]}"
out="${2:-${SCREENSHOT_DIR:-/tmp}/shot_$(date +%Y%m%d_%H%M%S).png}"
shift $(( $# >= 2 ? 2 : 1 ))

read -r wid _rect < <("$AXCLI" window-id --app "$app" "$@")
mkdir -p "$(dirname "$out")"
if ! screencapture -x -o -l "$wid" "$out" 2>/dev/null || [ ! -s "$out" ]; then
  echo '{"error":"screencapture failed; check Screen Recording permission"}' >&2; exit 1
fi
echo "$out"
