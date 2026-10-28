#!/usr/bin/env bash
# Turn a 1024×1024 PNG into an .icns using only sips and iconutil (both ship with macOS).
# Usage: scripts/make-icns.sh <input.png> <output.icns>
set -euo pipefail

SRC="$1"
OUT="$2"
WORK="$(mktemp -d)"
SET="$WORK/cubi.iconset"
mkdir -p "$SET"

for size in 16 32 128 256 512; do
  double=$((size * 2))
  sips -z "$size" "$size" "$SRC" --out "$SET/icon_${size}x${size}.png" >/dev/null
  sips -z "$double" "$double" "$SRC" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$SET" -o "$OUT"
echo "wrote $OUT"
