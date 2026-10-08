#!/bin/bash
# run.sh: kills any running instance, launches the built .app, waits for its window.
# Prints "RUNNING pid=<pid> window=<id>" or "RUNNING pid=<pid> window=none" for menubar-only state.
# Usage: ./run.sh [--wait-seconds N]   App stdout/stderr go to .build/run.log
set -uo pipefail
cd "$(dirname "$0")"
source ./app.env
AXCLI="${AXCLI:-$(cd "$(dirname "$0")" && cd ../../.. && pwd)/tools/axcli/.build/release/axcli}"
wait_s=10
[ "${1:-}" = "--wait-seconds" ] && wait_s="${2:-10}"

app="build/$APP_NAME.app"
[ -d "$app" ] || { echo "NOT BUILT: run ./build.sh first"; exit 1; }

# test.env (optional, written by the harness) sets app-specific test variables; $WS is this folder.
if [ -f test.env ]; then export WS="$PWD"; set -a; source ./test.env; set +a; fi

pkill -x "$APP_NAME" 2>/dev/null && sleep 0.5
mkdir -p .build
nohup "$app/Contents/MacOS/$APP_NAME" >.build/run.log 2>&1 &
pid=$!

for _ in $(seq 1 $((wait_s * 4))); do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "CRASHED on launch. Last log lines:"; tail -20 .build/run.log; exit 1
  fi
  if out="$("$AXCLI" window-id --app "$pid" 2>/dev/null)"; then
    echo "RUNNING pid=$pid window=${out%% *}"; exit 0
  fi
  sleep 0.25
done
echo "RUNNING pid=$pid window=none (no on-screen window after ${wait_s}s; menubar-only?)"
