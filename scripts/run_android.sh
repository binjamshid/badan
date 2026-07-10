#!/usr/bin/env bash
# Build BADAN Android, boot an emulator, install and launch it.
# Usage: scripts/run_android.sh [AVD_NAME]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
AVD="${1:-Medium_Phone}"
BUNDLE_ID="net.albayyan.badan"

cd "$ROOT/apps/android"
echo "▸ Building debug APK…"
./gradlew :app:assembleDebug -q

if ! adb devices | grep -q "emulator.*device"; then
  echo "▸ Booting emulator $AVD…"
  "$ANDROID_HOME/emulator/emulator" -avd "$AVD" -no-snapshot-save -netdelay none -netspeed full >/dev/null 2>&1 &
  adb wait-for-device
  until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 2; done
fi

echo "▸ Installing + launching…"
./gradlew :app:installDebug -q
adb shell am start -n "$BUNDLE_ID/.MainActivity"
echo "✓ BADAN launched on $AVD"
