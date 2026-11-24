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
cp "$ROOT/scripts/install-update.sh" "$APP/Contents/Resources/install-update.sh"
chmod 0755 "$APP/Contents/Resources/install-update.sh"

# Match LSMinimumSystemVersion and build both architectures: without a target, swiftc builds
# for the macOS this Mac runs, and older Macs refuse the app ("update your software").
MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT/Info.plist")"
SOURCES=(
  "$ROOT/Sources/GrandeBar.swift"
  "$ROOT/Sources/ClaudeDesktopAccounts.swift"
  "$ROOT/Sources/ClaudeSessionSharing.swift"
  "$ROOT/Sources/ClaudeDesktopToken.swift"
  "$ROOT/Sources/ClaudeLimitResets.swift"
  "$ROOT/Sources/GrandeClaudex.swift"
  "$ROOT/Sources/ChiefMove.swift"
  "$ROOT/Sources/ClaudeLimitsTab.swift"
  "$ROOT/Sources/WeeklyPace.swift"
  "$ROOT/Sources/LocalCosts.swift"
  "$ROOT/Sources/GrandeBarUpdater.swift"
  "$ROOT/Sources/QuotaFile.swift"
  "$ROOT/Sources/main.swift"
)
for ARCH in arm64 x86_64; do
  swiftc -O -target "$ARCH-apple-macos$MIN_MACOS" \
    "${SOURCES[@]}" \
    -framework AppKit \
    -framework ServiceManagement \
    -o "$BUILD_DIR/GrandeBar-$ARCH"
done
lipo -create "$BUILD_DIR/GrandeBar-arm64" "$BUILD_DIR/GrandeBar-x86_64" -output "$APP/Contents/MacOS/GrandeBar"

xattr -cr "$APP"
codesign --force --sign - "$APP"

rm -rf "$OUTPUT"
mkdir -p "$ROOT/dist"
ditto --noextattr "$APP" "$OUTPUT"
xattr -cr "$OUTPUT"

echo "$OUTPUT"
