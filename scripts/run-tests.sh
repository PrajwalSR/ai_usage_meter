#!/bin/bash
# Builds and runs the regression tests in Tests/ using synthetic data only.
#
# XCTest needs full Xcode, so the tests are a small executable compiled together
# with every app source except the app's main.swift.
set -euo pipefail

cd "$(dirname "$0")/.."
SDK="${AI_USAGE_METER_SDK:-$(xcrun --show-sdk-path 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)}"

sources=()
for f in Sources/AIUsageMeter/*.swift; do
  [ "$(basename "$f")" = "main.swift" ] || sources+=("$f")
done

mkdir -p build
echo "==> Compiling tests"
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$SDK" \
  "${sources[@]}" Tests/main.swift -o build/tests

echo "==> Running"
./build/tests
