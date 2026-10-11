#!/bin/bash
# release.sh: builds a shareable ShotBox DMG.
#
#   scripts/release.sh [app_dir] [version]       defaults: apps/shotbox, 0.1.0
#
# Output: dist/ShotBox-<version>.dmg
#
# Signing, picked in this order:
#   1. $SIGN_ID, if set.
#   2. A "Developer ID Application" certificate, if one is in the keychain.
#   3. Ad-hoc ("-"). Other Macs will warn on first open: right-click the app, then Open.
#
# Notarization runs only with a Developer ID and a stored notarytool profile:
#   xcrun notarytool store-credentials nightsmith --apple-id <id> --team-id <team> --password <app-specific>
#   NOTARY_PROFILE=nightsmith scripts/release.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$(cd "${1:-$root/apps/shotbox}" && pwd)"
version="${2:-0.1.0}"
source "$app_dir/app.env"
dist="$root/dist"
work="$dist/.work"
rm -rf "$work"; mkdir -p "$work" "$dist"

echo "• release build ($app_dir)"
(cd "$app_dir" && swift build -c release --arch arm64 --arch x86_64 --product "$APP_NAME" >"$work/build.log" 2>&1) || { grep -E "error:" "$work/build.log" | head -20; exit 1; }
bin="$(cd "$app_dir" && swift build -c release --arch arm64 --arch x86_64 --product "$APP_NAME" --show-bin-path)/$APP_NAME"

echo "• app bundle"
app="$work/$APP_NAME.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/$APP_NAME"
for b in "$(dirname "$bin")"/*.bundle; do [ -d "$b" ] && cp -R "$b" "$app/Contents/Resources/"; done

icon_png="$app_dir/icon.png"
if [ ! -f "$icon_png" ]; then
  swiftc -O "$root/scripts/make_icon.swift" -o "$work/make_icon" && "$work/make_icon" "$work/icon.png" >/dev/null
  icon_png="$work/icon.png"
fi
iconset="$work/AppIcon.iconset"; mkdir -p "$iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$icon_png" --out "$iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$icon_png" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict></plist>
PLIST

sign_id="${SIGN_ID:-$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
if [ -n "$sign_id" ]; then
  echo "• sign: $sign_id (hardened runtime)"
  codesign --force --options runtime --timestamp --sign "$sign_id" "$app"
else
  echo "• sign: ad-hoc (no Developer ID found)"
  codesign --force --sign - "$app"
fi
codesign --verify --strict "$app"

echo "• dmg"
stage="$work/dmg"; mkdir -p "$stage"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
dmg="$dist/$APP_NAME-$version.dmg"
rm -f "$dmg"
hdiutil create -volname "$APP_NAME $version" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
[ -n "$sign_id" ] && codesign --force --timestamp --sign "$sign_id" "$dmg"

if [ -n "$sign_id" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "• notarize ($NOTARY_PROFILE)"
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
fi

rm -rf "$work"
echo "DMG: $dmg ($(du -h "$dmg" | cut -f1))"
