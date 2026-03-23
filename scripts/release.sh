#!/bin/bash
# WE Release Script — Build, package DMG, ready for distribution.
# Usage: ./scripts/release.sh <version>
set -euo pipefail

VERSION="${1:?Usage: release.sh <version>}"
echo "=== WE Release v${VERSION} ==="

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/.build/arm64-apple-macosx/release"
APP_NAME="WE"
APP_BUNDLE="${PROJECT_DIR}/build/${APP_NAME}.app"
DMG_DIR="${PROJECT_DIR}/build"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
SIGN_ID="WE Dev Signing"

# Step 1: Build release
echo "→ Building release..."
cd "$PROJECT_DIR"
swift build -c release

# Step 2: Create app bundle
echo "→ Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/WE" "${APP_BUNDLE}/Contents/MacOS/WE"

if [ -f "${BUILD_DIR}/ggml-metal-embed.metal" ]; then
    cp "${BUILD_DIR}/ggml-metal-embed.metal" "${APP_BUNDLE}/Contents/Resources/"
elif [ -f "/Applications/WE.app/Contents/Resources/ggml-metal-embed.metal" ]; then
    cp "/Applications/WE.app/Contents/Resources/ggml-metal-embed.metal" "${APP_BUNDLE}/Contents/Resources/"
fi

if [ -d "${PROJECT_DIR}/.build/arm64-apple-macosx/debug/Sparkle.framework" ]; then
    mkdir -p "${APP_BUNDLE}/Contents/Frameworks"
    cp -R "${PROJECT_DIR}/.build/arm64-apple-macosx/debug/Sparkle.framework" "${APP_BUNDLE}/Contents/Frameworks/"
fi

cat > "${APP_BUNDLE}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>WE</string>
    <key>CFBundleDisplayName</key>
    <string>WE</string>
    <key>CFBundleIdentifier</key>
    <string>io.we.app</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>WE</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>WE needs microphone access for voice input.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>WE uses speech recognition to convert voice to text.</string>
</dict>
</plist>
PLIST

# Step 3: Code sign
echo "→ Code signing..."
codesign --force --deep --sign "${SIGN_ID}" "${APP_BUNDLE}" 2>/dev/null || \
    codesign --force --deep --sign - "${APP_BUNDLE}"

# Step 4: Create DMG
echo "→ Creating DMG..."
mkdir -p "$DMG_DIR"
rm -f "${DMG_DIR}/${DMG_NAME}"

STAGING="${DMG_DIR}/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "${DMG_DIR}/${DMG_NAME}"

rm -rf "$STAGING"

# Step 5: Summary
DMG_SIZE=$(du -h "${DMG_DIR}/${DMG_NAME}" | cut -f1)
echo ""
echo "=== Release v${VERSION} complete ==="
echo "  DMG: ${DMG_DIR}/${DMG_NAME} (${DMG_SIZE})"
echo "  App: ${APP_BUNDLE}"
