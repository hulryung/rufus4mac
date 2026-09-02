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
# Version comes from project.yml so the DMG matches the name the README tells people to download.
VERSION="$(awk -F'"' '/MARKETING_VERSION/{print $2; exit}' project.yml)"
[ -n "$VERSION" ] || { echo "could not read MARKETING_VERSION from project.yml" >&2; exit 1; }
DMG="$BUILD_DIR/rufus4mac-$VERSION.dmg"

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

echo "==> Bundling wimlib-imagex"
bash scripts/bundle-wimlib.sh "$APP/Contents/Resources/wimlib"

# Sign inside-out: the bundled wimlib binary + dylib were mutated by install_name_tool
# (which invalidates their signatures), so they MUST be re-signed individually with the
# hardened runtime before the app bundle is sealed — otherwise AMFI refuses to exec the
# bundled wimlib-imagex in the distributed (hardened-runtime) app.
echo "==> Signing bundled wimlib (inside-out)"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    "$APP/Contents/Resources/wimlib/"*.dylib
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    "$APP/Contents/Resources/wimlib/wimlib-imagex"

# There is no embedded privileged helper — the privileged write goes through Apple's `authopen`.
echo "==> Signing app bundle"
codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" "$APP"

echo "==> Verifying signatures"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Creating DMG"
rm -f "$DMG"
hdiutil create -volname "rufus4mac $VERSION" -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "==> Notarizing (this can take a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$DMG"

echo "==> Gatekeeper assessment"
spctl -a -vvv -t install "$APP" || true

echo "Done. Notarized DMG: $DMG"
