#!/usr/bin/env bash
# Build BADAN Android, boot an emulator, install and launch it.
# Usage: scripts/run_android.sh [AVD_NAME]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
AVD="${1:-Medium_Phone}"
# Read the bundle id from the single source of truth (build.gradle.kts) instead of
# hardcoding a second copy that could drift.
BUNDLE_ID="$(grep -m1 'applicationId' "$ROOT/apps/android/app/build.gradle.kts" | sed -E 's/.*applicationId[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/')"

cd "$ROOT/apps/android"
echo "▸ Building debug APK…"
./gradlew :app:assembleDebug -q

# Find an already-connected emulator (as opposed to a physical test device that
# might also be plugged in) that has actually finished booting.
find_booted_emulator() {
  local serial
  serial="$(adb devices | awk '$1 ~ /^emulator-/ && $2 == "device" {print $1; exit}')"
  if [ -n "$serial" ] && [ "$(adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
    echo "$serial"
  fi
}

SERIAL="$(find_booted_emulator || true)"
if [ -n "$SERIAL" ]; then
  echo "▸ Reusing already-booted emulator $SERIAL…"
else
  if ! "$ANDROID_HOME/emulator/emulator" -list-avds | grep -qx "$AVD"; then
    echo "✗ No AVD named '$AVD' found. Available AVDs:" >&2
    "$ANDROID_HOME/emulator/emulator" -list-avds >&2
    exit 1
  fi
  echo "▸ Booting emulator $AVD…"
  "$ANDROID_HOME/emulator/emulator" -avd "$AVD" -no-snapshot-save -netdelay none -netspeed full >/dev/null 2>&1 &
  until [ -n "$SERIAL" ]; do
    SERIAL="$(adb devices | awk '$1 ~ /^emulator-/ && $2 == "device" {print $1; exit}')"
    [ -n "$SERIAL" ] || sleep 1
  done
  adb -s "$SERIAL" wait-for-device
  until [ "$(adb -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 2; done
fi

# Scope adb/gradle to the target emulator explicitly so a physical device connected
# alongside it can't make either tool ambiguous.
export ANDROID_SERIAL="$SERIAL"
echo "▸ Installing + launching on $SERIAL…"
./gradlew :app:installDebug -q
adb -s "$SERIAL" shell am start -n "$BUNDLE_ID/.MainActivity"
echo "✓ BADAN launched on $AVD ($SERIAL)"
