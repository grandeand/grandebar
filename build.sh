#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="$ROOT/dist/GrandeBar.app"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/grandebar.XXXXXX")"
APP="$BUILD_DIR/GrandeBar.app"
trap 'rm -rf "$BUILD_DIR"' EXIT

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Assets/GrandeBar.icns" "$APP/Contents/Resources/GrandeBar.icns"
cp "$ROOT/Resources/ccusage.json" "$APP/Contents/Resources/ccusage.json"

swiftc \
  "$ROOT/Sources/GrandeBar.swift" \
  "$ROOT/Sources/main.swift" \
  -framework AppKit \
  -framework ServiceManagement \
  -o "$APP/Contents/MacOS/GrandeBar"

xattr -cr "$APP"
codesign --force --sign - "$APP"

rm -rf "$OUTPUT"
mkdir -p "$ROOT/dist"
ditto "$APP" "$OUTPUT"

echo "$OUTPUT"
