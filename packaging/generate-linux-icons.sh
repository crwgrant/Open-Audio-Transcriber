#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/app-icon.png"
DEST="$ROOT/linux-icons/hicolor"

if [[ ! -f "$SRC" ]]; then
    echo "error: missing $SRC" >&2
    exit 1
fi

if command -v magick >/dev/null 2>&1; then
    MAGICK=magick
elif command -v convert >/dev/null 2>&1; then
    MAGICK=convert
else
    echo "error: install ImageMagick (magick or convert) to generate Linux icons" >&2
    exit 1
fi

rm -rf "$ROOT/linux-icons"
for size in 16 32 48 64 128 256 512; do
    dir="$DEST/${size}x${size}/apps"
    mkdir -p "$dir"
    "$MAGICK" "$SRC" -resize "${size}x${size}" "$dir/audio-transcriber.png"
done

ASSETS="$ROOT/../src/assets"
mkdir -p "$ASSETS"
"$MAGICK" "$SRC" -resize 32x32 "$ASSETS/icon_32x32.png"
"$MAGICK" "$SRC" -resize 128x128 "$ASSETS/icon_128x128.png"
