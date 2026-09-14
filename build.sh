#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/GreptileHUD.app"
BIN="$APP/Contents/MacOS/GreptileHUD"
DMG="$ROOT/GreptileHUD.dmg"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/greptile-hud-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "==> Cleaning"
rm -rf "$APP" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

# App icon, so the bundle — and its Dock/DMG representation — looks like a
# real Mac app instead of a generic binary. The .icns is a committed asset
# (regen: scripts/make-icon.sh from Resources/icon.svg), so the build never
# depends on a rendering toolchain.
if [[ -f "$ROOT/Resources/GreptileHUD.icns" ]]; then
    cp "$ROOT/Resources/GreptileHUD.icns" "$APP/Contents/Resources/GreptileHUD.icns"
fi

# Classic bundle marker: tells Finder/`file` this is a proper installed .app
# layout (`usr/local/` install root), not a loose directory.
printf 'usr/local/\n' > "$APP/Contents/PkgInfo"

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

echo "==> Building installer disk image (drag-to-Applications DMG)"
DMG_STAGE="$BUILD_DIR/dmg"
mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "Greptile HUD" -srcfolder "$DMG_STAGE" -ov "$DMG" >/dev/null
# Sign the disk image's embedded app too, so it stays valid after a drag install.
# The app inside is already signed; a DMG-level signature is best-effort so a
# signing quirk can't fail the whole build.
codesign --force --deep --sign - "$DMG" 2>/dev/null \
    || echo "note: DMG-level ad-hoc signature skipped (embedded app is already signed)"

echo "==> Built: $APP"
echo "    Installer: $DMG"
echo "    Run with: open \"$APP\"   (or double-click the installer)"