#!/bin/bash
# Build AppIcon.icns from a 1024x1024 source PNG using only stock macOS tools.
set -euo pipefail

SRC="${1:-assets/icon-1024.png}"
OUT="${2:-build/AppIcon.icns}"

if [ ! -f "$SRC" ]; then
  echo "make-icns: source icon not found: $SRC" >&2
  exit 1
fi

OUT_DIR="$(dirname "$OUT")"
ICONSET="$OUT_DIR/AppIcon.iconset"

mkdir -p "$OUT_DIR"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" "$SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil --convert icns "$ICONSET" --output "$OUT"
rm -rf "$ICONSET"

echo "make-icns: wrote $OUT"
