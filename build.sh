#!/bin/zsh
# Builds rūpa.app into ./build and installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

ICON_SRC=/Users/amrit/fractaldesign/assets/rupa.png
APP="build/rūpa.app"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/AppIcon.iconset

swiftc -O -parse-as-library -target arm64-apple-macos14 Sources/rupa.swift -o "$APP/Contents/MacOS/rupa"

for s in 16 32 128 256 512; do
  sips -z $s $s "$ICON_SRC" --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICON_SRC" --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/AppIcon.iconset

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

rm -rf "/Applications/rūpa.app"
ditto "$APP" "/Applications/rūpa.app"
echo "Installed /Applications/rūpa.app"
