#!/bin/bash
# Renders the README screenshots in docs/images/ from made-up data.
# Uses no real usage data, so the images are always safe to publish.
set -euo pipefail

cd "$(dirname "$0")/.."
SDK="$(xcrun --show-sdk-path 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)"

sources=()
for f in Sources/AIUsageMeter/*.swift; do
  [ "$(basename "$f")" = "main.swift" ] || sources+=("$f")
done

mkdir -p build
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$SDK" \
  "${sources[@]}" tools/screenshots/main.swift -o build/render-screenshots

./build/render-screenshots docs/images
