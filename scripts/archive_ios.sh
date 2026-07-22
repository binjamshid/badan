#!/usr/bin/env bash
# Archive BADAN for TestFlight/App Store and export a signed .ipa.
#
# Prereqs (one-time, done by YOU — see docs/TESTFLIGHT.md):
#   • Apple Developer Program membership
#   • Bundle ID net.binjamshid.badan registered in App Store Connect
#   • You are signed into Xcode with an account on that team (Xcode ▸ Settings ▸ Accounts),
#     so Automatic signing can fetch a Distribution provisioning profile.
#
# Usage:
#   scripts/archive_ios.sh <TEAM_ID>
#   e.g. scripts/archive_ios.sh ABCDE12345
#
# The .ipa lands in apps/ios/build/export/BADAN.ipa. Upload it with Transporter.app
# or `xcrun altool --upload-app` (see docs/TESTFLIGHT.md) — this script does NOT upload.
set -euo pipefail

TEAM_ID="${1:-}"
if [[ -z "$TEAM_ID" ]]; then
  echo "error: pass your 10-char Apple Developer Team ID, e.g. scripts/archive_ios.sh ABCDE12345" >&2
  exit 2
fi

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../apps/ios" && pwd)"
cd "$IOS_DIR"

ARCHIVE="build/BADAN.xcarchive"
EXPORT_DIR="build/export"
OPTS="build/ExportOptions.resolved.plist"

echo "▸ Generating project…"
xcodegen generate >/dev/null

echo "▸ Archiving (Release, generic iOS device)…"
xcodebuild -project BADAN.xcodeproj -scheme BADAN \
  -configuration Release -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic \
  clean archive

echo "▸ Writing export options for team $TEAM_ID…"
mkdir -p build
sed "s/__TEAM_ID__/$TEAM_ID/" ExportOptions.plist > "$OPTS"

echo "▸ Exporting signed .ipa…"
rm -rf "$EXPORT_DIR"
# -allowProvisioningUpdates here too (not just on the archive step above): the export step
# re-validates the archive's entitlements against profiles actually registered on the portal, and
# a newly-added capability/target (e.g. Phase 3D's BadanWidgets extension + App Groups) has no
# portal-side profile yet the first time this runs after such a change. Automatic signing can
# create/update the needed App ID capabilities and profiles here the same way it already does
# during archive; without this flag, export fails on exactly that class of change with no code
# path forward except doing the equivalent by hand in Xcode.
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OPTS" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID"

echo "✓ Done: $IOS_DIR/$EXPORT_DIR/BADAN.ipa"
echo "  Next: upload with Transporter.app, or:"
echo "    xcrun altool --upload-app -f \"$IOS_DIR/$EXPORT_DIR/BADAN.ipa\" -t ios \\"
echo "      --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>   # App Store Connect API key"
