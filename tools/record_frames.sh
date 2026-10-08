#!/bin/bash
# record_frames.sh <seconds> <n> <app> [outdir] [--title T]
# Records the app's window (by window id, so other windows on top do not matter) for
# <seconds>, then extracts <n> evenly spaced PNG frames. Prints one frame path per line.
# Start the interaction right after calling this (or run it in the background).
set -euo pipefail

TOOLS="$(cd "$(dirname "$0")" && pwd)"
AXCLI="$TOOLS/axcli/.build/release/axcli"

secs="${1:?usage: record_frames.sh <seconds> <n> <app> [outdir] [--title T]}"
n="${2:?missing <n>}"
app="${3:?missing <app>}"
outdir="${4:-${SCREENSHOT_DIR:-/tmp}/frames_$(date +%Y%m%d_%H%M%S)}"
shift $(( $# >= 4 ? 4 : 3 ))

read -r wid _rect < <("$AXCLI" window-id --app "$app" "$@")
mkdir -p "$outdir"
mov="$outdir/recording.mov"
rm -f "$mov"

if ! screencapture -x -o -l "$wid" -V "$secs" "$mov" 2>/dev/null || [ ! -s "$mov" ]; then
  echo '{"error":"recording failed; check Screen Recording permission"}' >&2; exit 1
fi

# n frames over secs seconds -> fps = n/secs
ffmpeg -loglevel error -y -i "$mov" -vf "fps=$n/$secs" -frames:v "$n" "$outdir/frame_%02d.png"
ls "$outdir"/frame_*.png
