#!/usr/bin/env bash
# Scratch-branch evidence: launcher screenshots before and after AppIcon.change.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${EVIDENCE_DIR:-$ROOT/evidence-android}"
DEBUG_APK="${DEBUG_APK:-$ROOT/example/android/app/build/outputs/apk/debug/app-debug.apk}"
RELEASE_APK="${RELEASE_APK:-$ROOT/example/android/app/build/outputs/apk/release/app-release-signed.apk}"
mkdir -p "$OUT"
echo "Debug APK: $DEBUG_APK"
echo "Release APK: $RELEASE_APK"
adb wait-for-device
adb shell input keyevent KEYCODE_WAKEUP || true
adb shell wm dismiss-keyguard || true
adb shell settings put system screen_off_timeout 1800000 || true

screen_size() {
  adb shell wm size | awk -F '[ x:]+' '/Physical size/{print $3, $4}'
}

shot() {
  local dest="$1"
  adb exec-out screencap -p > "$dest"
  ls -lh "$dest"
}

dump_ui() {
  local dest="$1"
  local i
  for i in 1 2 3 4 5; do
    if adb shell uiautomator dump /sdcard/ui-evidence.xml >/dev/null 2>&1; then
      adb pull /sdcard/ui-evidence.xml "$dest" >/dev/null
      return 0
    fi
    sleep 1
  done
  echo "uiautomator dump failed" >&2
  return 1
}

open_drawer() {
  adb shell input keyevent KEYCODE_HOME
  sleep 2
  read -r W H < <(screen_size)
  adb shell input swipe $((W / 2)) $((H * 85 / 100)) $((W / 2)) $((H * 25 / 100)) 250
  sleep 2
}

# Scroll the drawer until the launcher label is on screen, then screenshot.
capture_label() {
  local label="$1"
  local png="$2"
  local xml="$3"
  local i
  open_drawer
  for i in 1 2 3 4 5 6; do
    dump_ui "$xml" || true
    if grep -q "text=\"${label}\"" "$xml" 2>/dev/null; then
      shot "$png"
      echo "Found launcher label ${label}"
      return 0
    fi
    read -r W H < <(screen_size)
    adb shell input swipe $((W / 2)) $((H * 75 / 100)) $((W / 2)) $((H * 35 / 100)) 250
    sleep 1
  done
  shot "$png"
  echo "Launcher label ${label} was not in the drawer hierarchy" >&2
  return 1
}

refresh_launcher() {
  adb shell am force-stop com.google.android.apps.nexuslauncher || true
  sleep 1
  adb shell input keyevent KEYCODE_HOME
  sleep 2
}

resolve_launcher() {
  adb shell cmd package resolve-activity -a android.intent.action.MAIN -c android.intent.category.LAUNCHER com.example.app || true
}

install_and_show_default() {
  local png="$1"
  local xml="$2"
  adb uninstall com.example.app || true
  adb install -r "$APK"
  # Launch without the evidence extra so the launcher indexes the default alias.
  adb shell am start -n com.example.app/.stencil
  sleep 4
  refresh_launcher
  capture_label "Stencil" "$png" "$xml"
  resolve_launcher | tee "${png%.png}.resolve.txt"
}

change_icon() {
  local icon="$1"
  local component="$2"
  adb logcat -c || true
  # The default launcher alias is .stencil, which targets MainActivity.
  adb shell am start -n "com.example.app/.${component}" --es evidenceIcon "$icon"
  local i
  for i in $(seq 1 20); do
    sleep 2
    if resolve_launcher | grep -q "name=com.example.app.${icon}"; then
      echo "Launcher component is now .${icon} after ${i} polls"
      resolve_launcher | tee "$OUT/resolve-after-${icon}.txt"
      adb logcat -d > "$OUT/logcat-${icon}.txt" || true
      return 0
    fi
  done
  echo "Launcher component did not become .${icon}" >&2
  resolve_launcher | tee "$OUT/resolve-after-${icon}.txt" || true
  adb shell dumpsys package com.example.app > "$OUT/dumpsys-${icon}.txt" || true
  adb logcat -d > "$OUT/logcat-${icon}.txt" || true
  return 1
}

APK="$DEBUG_APK"
echo "=== debug default icon ==="
install_and_show_default "$OUT/android-launcher-before-default-stencil.png" "$OUT/android-launcher-before-default-stencil.xml"
echo "=== debug change to ionic ==="
change_icon ionic stencil
refresh_launcher
capture_label "Ionic" "$OUT/android-launcher-after-debug-ionic.png" "$OUT/android-launcher-after-debug-ionic.xml"

APK="$RELEASE_APK"
echo "=== release default then change to ionitron ==="
install_and_show_default "$OUT/android-launcher-before-release-stencil.png" "$OUT/android-launcher-before-release-stencil.xml"
change_icon ionitron stencil
refresh_launcher
capture_label "Ionitron" "$OUT/android-launcher-after-release-ionitron.png" "$OUT/android-launcher-after-release-ionitron.xml"

echo "Android icon evidence complete"
ls -lh "$OUT"
