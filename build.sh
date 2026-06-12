#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/GreptileHUD.app"
BIN="$APP/Contents/MacOS/GreptileHUD"

echo "==> Cleaning"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

echo "==> Compiling (Swift)"
swiftc -O -swift-version 5 \
    -framework AppKit -framework SwiftUI \
    -o "$BIN" \
    "$ROOT/Sources/Models.swift" \
    "$ROOT/Sources/GitHub.swift" \
    "$ROOT/Sources/HUDView.swift" \
    "$ROOT/Sources/main.swift"

echo "==> Signing (ad-hoc, stable identity for Accessibility grant)"
codesign --force --deep --sign - "$APP"

echo "==> Built: $APP"
echo "    Run with: open \"$APP\"   (or double-click it)"
