#!/usr/bin/env bash
# Builds the Bedlington Terrier app icon at 1024 px, generates a complete iconset, and
# packs it into a .icns file that make-app.sh embeds in the bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ICON_DIR="$ROOT/build/AppIcon.iconset"
ICON_PATH="$ROOT/build/AppIcon.icns"
SOURCE_ICON="$ROOT/Sources/token-run-menubar/Resources/bedl-icon.png"
SOURCE_PNG="$ROOT/build/tokenterrier-1024.png"

mkdir -p "$ROOT/build"
rm -rf "$ICON_DIR" "$ICON_PATH"
mkdir -p "$ICON_DIR"

echo "▶ prepare 1024×1024 source"
swift "$ROOT/scripts/render-bedl-icon.swift" "$SOURCE_ICON" "$SOURCE_PNG"

# macOS iconset requires these specific filenames + dpi suffixes.
declare -a sizes=(
    "16:icon_16x16.png"
    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"
    "64:icon_32x32@2x.png"
    "128:icon_128x128.png"
    "256:icon_128x128@2x.png"
    "256:icon_256x256.png"
    "512:icon_256x256@2x.png"
    "512:icon_512x512.png"
    "1024:icon_512x512@2x.png"
)
for entry in "${sizes[@]}"; do
    size="${entry%%:*}"
    file="${entry##*:}"
    sips -z "$size" "$size" "$SOURCE_PNG" --out "$ICON_DIR/$file" >/dev/null
done

echo "▶ pack iconset → .icns"
iconutil -c icns "$ICON_DIR" -o "$ICON_PATH"
ls -la "$ICON_PATH"
