#!/bin/bash
# Builds AIUsageMeter.app with Command Line Tools only -- no Xcode, no
# developer account. SwiftPM's manifest linking is broken under CLT, and
# SwiftUI's macro plugins ship only with Xcode, so this compiles directly.
set -euo pipefail

cd "$(dirname "$0")"
SDK="$(xcrun --show-sdk-path 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)"
APP="build/AI Usage Meter.app"

echo "==> Compiling"
mkdir -p build
swiftc -O -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  -sdk "$SDK" \
  Sources/AIUsageMeter/*.swift \
  -o build/AIUsageMeter

echo "==> Bundling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp assets/claude.svg assets/openai.svg "$APP/Contents/Resources/"
cp build/AIUsageMeter "$APP/Contents/MacOS/AIUsageMeter"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AI Usage Meter</string>
  <key>CFBundleDisplayName</key><string>AI Usage Meter</string>
  <key>CFBundleIdentifier</key><string>local.aiusagemeter</string>
  <key>CFBundleExecutable</key><string>AIUsageMeter</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Menu bar accessory: no Dock icon, no window. -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run locally on this Mac. Distributing to anyone
# else would need a paid Developer ID and notarization.
codesign --force --sign - "$APP" 2>/dev/null || echo "(ad-hoc signing skipped)"

echo "==> Done: $APP"
