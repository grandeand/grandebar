#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/GrandeBar.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Assets/GrandeBar.icns" "$APP/Contents/Resources/GrandeBar.icns"

swiftc \
  "$ROOT/Sources/GrandeBar.swift" \
  "$ROOT/Sources/main.swift" \
  -framework AppKit \
  -framework ServiceManagement \
  -o "$APP/Contents/MacOS/GrandeBar"

echo "$APP"
