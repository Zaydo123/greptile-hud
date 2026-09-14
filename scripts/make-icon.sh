#!/bin/bash
# Regenerate Resources/GreptileHUD.icns from Resources/icon.svg (macOS).
# Maintainers run this when the SVG changes and commit the resulting .icns;
# build.sh copies the committed .icns into the bundle so CI and users never
# need a rendering toolchain.
#
# Requires a vector rasterizer (rsvg-convert from brew `librsvg`, or sips) and
# Apple's `iconutil` (built into macOS).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Resources/icon.svg"
ICNS="$ROOT/Resources/GreptileHUD.icns"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/greptile-hud-icon.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

command -v iconutil >/dev/null || { echo "make-icon.sh needs macOS \`iconutil\`" >&2; exit 1; }

render_png() { # render_png WIDTH OUT
    local w="$1" out="$2"
    if command -v rsvg-convert >/dev/null; then
        rsvg-convert -w "$w" -h "$w" "$SRC" -o "$out"
    elif command -v sips >/dev/null; then
        sips -s format png "$SRC" --out "$TMP/big.png" >/dev/null
        sips -z "$w" "$w" "$TMP/big.png" --out "$out" >/dev/null
    else
        echo "install rsvg-convert (brew install librsvg) to render $SRC" >&2
        exit 1
    fi
    test -s "$out" || { echo "failed to render $w" >&2; exit 1; }
}

echo "==> Rendering icon set from $SRC"
mkdir -p "$TMP/iconset"
for size in 16 32 64 128 256 512 1024; do
    render_png "$size" "$TMP/iconset/icon_${size}x${size}.png"
done

echo "==> Packing $ICNS"
iconutil -c icns -o "$ICNS" "$TMP/iconset"
echo "    wrote $ICNS"
echo "    tip: frame it with \`open $ICNS\` (sips cannot rasterize SVG on all macOS releases)"