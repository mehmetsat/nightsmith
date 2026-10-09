#!/bin/bash
# realistic_fixtures.sh <outdir>
# Test images that look like real screenshots: public web pages rendered by headless Chrome with a
# fresh, empty profile (no cookies, no logins). Flat colour fixtures make every design look the same.
set -uo pipefail
out="${1:?usage: realistic_fixtures.sh <outdir>}"
mkdir -p "$out"
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$chrome" ] || { echo "no Chrome: skipping realistic fixtures"; exit 0; }
profile=$(mktemp -d /tmp/nightsmith-chrome.XXXX)

shot() { # name url WxH
  local f="$out/real_$1.png"
  [ -s "$f" ] && return 0
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --user-data-dir="$profile" \
    --window-size="$3" --timeout=8000 --screenshot="$f" "$2" >/dev/null 2>&1 &
  local pid=$!
  for _ in $(seq 1 25); do [ -s "$f" ] && break; sleep 1; done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ -s "$f" ] && echo "real_$1.png" || echo "failed: $1"
}

shot wikipedia "https://en.wikipedia.org/wiki/Screenshot" 1440,900
shot github "https://github.com/apple/swift" 1280,800
shot docs "https://developer.apple.com/documentation/vision" 1200,900
shot news "https://news.ycombinator.com" 1100,1300
shot mdn "https://developer.mozilla.org/en-US/docs/Web/HTML" 1920,1080
shot data "https://ourworldindata.org/co2-emissions" 1366,768
rm -rf "$profile"
