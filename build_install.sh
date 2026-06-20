#!/bin/bash
# Build → SIGN → install → launch the menu bar app.
#
# The signing step is NOT optional: building with CODE_SIGNING_ALLOWED=NO yields
# an ad-hoc signature with a new cdhash each build, which makes macOS TCC treat
# every rebuild as a new app and REVOKE the Reminders permission (the app then
# silently shows no reminders). Re-signing with the stable Apple Development
# identity keeps the Designated Requirement constant, so the grant persists.
set -euo pipefail

cd "$(dirname "$0")"

# Signing identity: auto-detected from the keychain (first "Apple Development"
# certificate), or override with RMB_SIGN_IDENTITY="Apple Development: NAME (TEAMID)".
# Re-signing with a STABLE identity each build is what keeps macOS's Reminders
# (TCC) permission from being revoked on every rebuild.
IDENTITY="${RMB_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')}"
if [ -z "$IDENTITY" ]; then
  echo "✗ No 'Apple Development' codesigning identity found."
  echo "  Set one up in Xcode (Settings ▸ Accounts), or set RMB_SIGN_IDENTITY."
  exit 1
fi
BUNDLE_ID="com.andrewmott.reminders-menubar"
APP_NAME="Reminders Spotlight.app"
PROJECT="RemindersSpotlight.xcodeproj"
SCHEME="RemindersSpotlight"
DERIVED=".build-new"
# Release: -O optimized. SwiftUI in Debug (-Onone, + Main Thread Checker when run
# from Xcode) can use many times the CPU of Release, especially during animation.
# This is the daily-use build, so it must be Release.
CONFIG="Release"

echo "▸ Building ($CONFIG)…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
  -configuration "$CONFIG" -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build \
  | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" || true

BUILT=$(find "$DERIVED/Build/Products/$CONFIG" -maxdepth 1 -name "$APP_NAME" | head -1)
[ -n "$BUILT" ] || { echo "✗ No built $APP_NAME found"; exit 1; }

echo "▸ Signing with stable identity (keeps the TCC Reminders grant)…"
codesign --force --deep --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$BUILT"
codesign --verify "$BUILT" && echo "  signature OK"

echo "▸ Installing to /Applications…"
pkill -f "Reminders Spotlight" 2>/dev/null || true
sleep 1
rm -rf "/Applications/$APP_NAME"
cp -R "$BUILT" "/Applications/$APP_NAME"

echo "▸ Launching…"
open "/Applications/$APP_NAME"
echo "✓ Done."
