#!/bin/bash
set -euo pipefail

APP_NAME="Quilldown"
DMG_NAME="Quilldown"
BUILD_DIR="build/Release"
DMG_DIR="build/dmg"

echo "Building Release..."
xcodebuild -scheme Quilldown \
  -configuration Release \
  -derivedDataPath build \
  -destination 'platform=macOS' \
  build 2>&1 | tail -5

echo ""

# Find the built app
APP_PATH=$(find build -name "*.app" -path "*/Release/*" -maxdepth 5 | head -1)
if [ -z "$APP_PATH" ]; then
  echo "ERROR: Built app not found"
  exit 1
fi

echo "App found at: $APP_PATH"
echo "App size: $(du -sh "$APP_PATH" | cut -f1)"

# Create DMG staging directory
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"
cp -R "$APP_PATH" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

# Create DMG
rm -f "${DMG_NAME}.dmg"
hdiutil create -volname "$APP_NAME" \
  -srcfolder "$DMG_DIR" \
  -ov -format UDZO \
  "${DMG_NAME}.dmg"

echo ""
echo "DMG created: ${DMG_NAME}.dmg"
echo "DMG size: $(du -sh "${DMG_NAME}.dmg" | cut -f1)"

# Cleanup
rm -rf "$DMG_DIR"

echo ""
echo "Done! To distribute:"
echo "  1. codesign --sign 'Developer ID Application: ...' ${DMG_NAME}.dmg"
echo "  2. xcrun notarytool submit ${DMG_NAME}.dmg --keychain-profile 'profile' --wait"
echo "  3. xcrun stapler staple ${DMG_NAME}.dmg"
