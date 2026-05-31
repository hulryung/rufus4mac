#!/usr/bin/env bash
#
# Build, Developer ID–sign, notarize, and staple a distributable rufus4mac DMG.
#
# This script is a STARTING POINT and has NOT been run end-to-end yet (signing +
# notarization require interactive/credential setup). Read the prerequisites and
# adjust as needed.
#
# Prerequisites
#   1. Developer ID Application cert in the keychain:
#        security find-identity -v -p codesigning
#      (expected: "Developer ID Application: HUCONN Co.,Ltd. (XGJ87M8ZZR)")
#   2. A notarytool keychain profile named "rufus4mac-notary":
#        xcrun notarytool store-credentials rufus4mac-notary \
#          --apple-id "<your-apple-id>" --team-id XGJ87M8ZZR --password "<app-specific-pw>"
#   3. xcodegen + Xcode 26 installed.
#
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="Developer ID Application: HUCONN Co.,Ltd. (XGJ87M8ZZR)"
NOTARY_PROFILE="rufus4mac-notary"
BUILD_DIR="build"
DERIVED="$BUILD_DIR/DerivedData"
APP="$BUILD_DIR/Release/RufusApp.app"
DMG="$BUILD_DIR/rufus4mac.dmg"

echo "==> Regenerating project"
xcodegen generate

echo "==> Building RufusApp (Release, Developer ID)"
rm -rf "$BUILD_DIR/Release"
mkdir -p "$BUILD_DIR/Release"
xcodebuild -project rufus4mac.xcodeproj -scheme RufusApp -configuration Release \
    -derivedDataPath "$DERIVED" -destination 'platform=macOS' \
    DEVELOPMENT_TEAM=XGJ87M8ZZR \
    CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    build
cp -R "$DERIVED/Build/Products/Release/RufusApp.app" "$APP"

# Sign inside-out: the embedded helper first, then the app bundle, both with
# hardened runtime + a secure timestamp. SMAppService requires a valid signature
# on both the daemon and the host app.
echo "==> Signing embedded helper"
codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" "$APP/Contents/MacOS/RufusHelper"

echo "==> Signing app bundle"
codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" "$APP"

echo "==> Verifying signatures"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Creating DMG"
rm -f "$DMG"
hdiutil create -volname rufus4mac -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "==> Notarizing (this can take a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$DMG"

echo "==> Gatekeeper assessment"
spctl -a -vvv -t install "$APP" || true

echo "Done. Notarized DMG: $DMG"
