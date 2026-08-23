#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/GreptileHUD.app"
BIN="$APP/Contents/MacOS/GreptileHUD"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/greptile-hud-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "==> Cleaning"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

SOURCES=(
    "$ROOT/Sources/Theme.swift"
    "$ROOT/Sources/Models.swift"
    "$ROOT/Sources/GitHub.swift"
    "$ROOT/Sources/Updater.swift"
    "$ROOT/Sources/Vibecoders.swift"
    "$ROOT/Sources/HUDView.swift"
    "$ROOT/Sources/main.swift"
)

echo "==> Compiling universal app (macOS 13+)"
for ARCH in arm64 x86_64; do
    swiftc -O -swift-version 5 \
        -target "$ARCH-apple-macos13.0" -sdk "$SDK" \
        -framework AppKit -framework SwiftUI \
        -o "$BUILD_DIR/GreptileHUD-$ARCH" \
        "${SOURCES[@]}"
done
lipo -create \
    "$BUILD_DIR/GreptileHUD-arm64" \
    "$BUILD_DIR/GreptileHUD-x86_64" \
    -output "$BIN"

echo "==> Signing (ad-hoc, stable identity for Accessibility grant)"
codesign --force --deep --sign - "$APP"

echo "==> Built: $APP"
echo "    Run with: open \"$APP\"   (or double-click it)"
