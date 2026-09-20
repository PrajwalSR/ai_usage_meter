#!/bin/bash
# Rebuilds the app icon from its source artwork, assets/app-icon.svg.
#
#   ./scripts/make-app-icon.sh             # updates assets/AppIcon.iconset and assets/AppIcon.icns
#   ./scripts/make-app-icon.sh build/icon  # writes somewhere else instead, to preview
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-assets}"
SDK="$(xcrun --show-sdk-path 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)"

mkdir -p build "$OUT/AppIcon.iconset"
swiftc -O -target arm64-apple-macosx14.0 -sdk "$SDK" tools/svg2png/main.swift -o build/svg2png

for size in 16 32 128 256 512; do
  ./build/svg2png assets/app-icon.svg "$OUT/AppIcon.iconset/icon_${size}x${size}.png" "$size"
  ./build/svg2png assets/app-icon.svg "$OUT/AppIcon.iconset/icon_${size}x${size}@2x.png" "$((size * 2))"
done

iconutil -c icns "$OUT/AppIcon.iconset" -o "$OUT/AppIcon.icns"
echo "==> Wrote $OUT/AppIcon.icns"
