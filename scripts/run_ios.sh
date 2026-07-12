#!/usr/bin/env bash
# Build BADAN, boot a simulator, install and launch it.
# Usage: scripts/run_ios.sh ["iPhone 17"]
set -euo pipefail
IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../apps/ios" && pwd)"
SIM="${1:-iPhone 17}"
BUNDLE_ID="net.binjamshid.badan"

cd "$IOS_DIR"
echo "▸ Generating project…"
xcodegen generate >/dev/null

echo "▸ Building for $SIM…"
xcodebuild -project BADAN.xcodeproj -scheme BADAN \
  -sdk iphonesimulator -destination "platform=iOS Simulator,name=$SIM" \
  -derivedDataPath build -quiet build

APP="build/Build/Products/Debug-iphonesimulator/BADAN.app"
echo "▸ Booting $SIM…"
xcrun simctl boot "$SIM" 2>/dev/null || true
open -a Simulator

echo "▸ Installing + launching…"
xcrun simctl install "$SIM" "$APP"
xcrun simctl launch "$SIM" "$BUNDLE_ID"
echo "✓ BADAN launched on $SIM"
