#!/bin/bash
# build.sh: builds the Swift package and wraps it into $APP_NAME.app.
# Prints only errors, warnings and one status line. Exit code is the build's.
set -uo pipefail
cd "$(dirname "$0")"
source ./app.env

log=.build/build.log
mkdir -p .build
swift build -c debug --product "$APP_NAME" >"$log" 2>&1
status=$?

# Unique error/warning lines only; raw swift output is too noisy for agent context.
grep -E "(error|warning):" "$log" | grep -v "^warning: 'swift-" | awk '!seen[$0]++' | head -60
if [ $status -ne 0 ]; then
  grep -qE "error:" "$log" || tail -20 "$log"
  echo "BUILD FAILED (exit $status). Full log: $log"
  exit $status
fi

bin="$(swift build -c debug --product "$APP_NAME" --show-bin-path)/$APP_NAME"
app="build/$APP_NAME.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/$APP_NAME"
for b in "$(dirname "$bin")"/*.bundle; do [ -d "$b" ] && cp -R "$b" "$app/Contents/Resources/"; done

if [ -f Info.plist ]; then
  cp Info.plist "$app/Contents/Info.plist"
else
  cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
fi

# A stable signing identity keeps macOS permission grants across rebuilds.
sign_id="${SIGN_ID:-$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${sign_id:--}" "$app" >/dev/null 2>&1 || codesign --force --sign - "$app" >/dev/null 2>&1

echo "BUILD OK: $app"
