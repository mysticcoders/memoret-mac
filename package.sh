#!/usr/bin/env bash
#
# Builds a Developer ID-signed, notarized, stapled Memoret.app and packages
# it into a signed + notarized Memoret-<version>.dmg for direct download.
# This is the non-App-Store distribution path: the app is a companion to the
# iOS app, so it ships outside the Mac App Store.
#
# Prerequisites (one-time):
#   1. A "Developer ID Application" certificate in your login keychain.
#      Xcode > Settings > Accounts > (team) > Manage Certificates > "+" >
#      "Developer ID Application", or download from developer.apple.com.
#   2. A notarytool credential profile stored in the keychain:
#        xcrun notarytool store-credentials memoret-notary \
#          --apple-id "you@example.com" \
#          --team-id REMBT6JY4N \
#          --password "<app-specific-password from appleid.apple.com>"
#      (An App Store Connect API key works too — see notarytool --help.)
#
# Usage:  macos/package.sh
# Env overrides:
#   MEMORET_TEAM_ID        (default REMBT6JY4N)
#   MEMORET_NOTARY_PROFILE (default memoret-notary)
#   MEMORET_SKIP_NOTARIZE  (set to 1 to build+sign only, skip notarization)

set -euo pipefail

TEAM_ID="${MEMORET_TEAM_ID:-REMBT6JY4N}"
NOTARY_PROFILE="${MEMORET_NOTARY_PROFILE:-memoret-notary}"
SKIP_NOTARIZE="${MEMORET_SKIP_NOTARIZE:-0}"
SCHEME="Memoret"
CONFIG="Release"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ_DIR="$SCRIPT_DIR/Memoret"
BUILD="$PROJ_DIR/build"
ARCHIVE="$BUILD/Memoret.xcarchive"
EXPORT_DIR="$BUILD/export"
APP="$EXPORT_DIR/Memoret.app"
DMG_STAGE="$BUILD/dmg-stage"

log() { printf '\033[1;36m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }

# --- Preflight -------------------------------------------------------------
command -v xcodegen >/dev/null || die "xcodegen not found (brew install xcodegen)"

IDENTITY="$(security find-identity -v -p codesigning \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
[ -n "$IDENTITY" ] || die "No 'Developer ID Application' certificate in your keychain. See prerequisites at the top of this script."
log "Signing identity: $IDENTITY"

# --- Generate + archive ----------------------------------------------------
log "Regenerating Xcode project"
( cd "$PROJ_DIR" && xcodegen generate )

log "Cleaning build directory"
rm -rf "$BUILD"
mkdir -p "$BUILD"

log "Archiving ($CONFIG)"
xcodebuild archive \
  -project "$PROJ_DIR/MemoretMac.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  -allowProvisioningUpdates

log "Exporting Developer ID app"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$PROJ_DIR/ExportOptions.plist" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates

[ -d "$APP" ] || die "Export did not produce $APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$BUILD/Memoret-$VERSION.dmg"
log "Built Memoret.app version $VERSION"

log "Verifying app signature + hardened runtime"
codesign --verify --deep --strict --verbose=2 "$APP"
# Captured first rather than piped into grep -q: under pipefail, grep exiting
# on its first match kills codesign with SIGPIPE and fails the pipeline.
SIGN_INFO="$(codesign -dvv "$APP" 2>&1)"
case "$SIGN_INFO" in
  *flags=*runtime*) ;;
  *) die "Hardened runtime not enabled on the exported app" ;;
esac

# --- Notarize + staple the app --------------------------------------------
if [ "$SKIP_NOTARIZE" != "1" ]; then
  log "Notarizing the app (this can take a few minutes)"
  APP_ZIP="$BUILD/Memoret-app.zip"
  /usr/bin/ditto -c -k --keepParent "$APP" "$APP_ZIP"
  xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  log "Stapling the app"
  xcrun stapler staple "$APP"
else
  log "MEMORET_SKIP_NOTARIZE=1 — skipping app notarization"
fi

# --- Build the DMG ---------------------------------------------------------
log "Staging DMG contents"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

log "Creating DMG"
rm -f "$DMG"
hdiutil create \
  -volname "Memoret" \
  -srcfolder "$DMG_STAGE" \
  -ov -format UDZO \
  "$DMG"

log "Signing the DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

# --- Notarize + staple the DMG --------------------------------------------
if [ "$SKIP_NOTARIZE" != "1" ]; then
  log "Notarizing the DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  log "Stapling the DMG"
  xcrun stapler staple "$DMG"

  log "Gatekeeper assessment"
  spctl -a -t open --context context:primary-signature -vv "$DMG" || true
  spctl -a -vv "$APP" || true
fi

log "Done: $DMG"
