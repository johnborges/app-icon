#!/usr/bin/env bash
# Scratch-branch evidence: simulator home-screen screenshots before and after AppIcon.change.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${EVIDENCE_DIR:-$ROOT/evidence-ios}"
mkdir -p "$OUT"
cd "$ROOT/example/ios/App"

echo "=== xcodebuild -version ==="
xcodebuild -version | tee "$OUT/xcode-version.txt"
xcode-select -p

if ! command -v pod >/dev/null 2>&1; then
  brew install cocoapods
fi
pod install | tee "$OUT/pod-install.log"

# An exact "iPhone 17" line, not "iPhone 17 Pro". Fall back to the first iPhone.
DEVICE_LINE="$(xcrun simctl list devices available | grep -E '^[[:space:]]+iPhone [0-9]+ \(' | grep -v unavailable | head -1 || true)"
if [ -z "$DEVICE_LINE" ]; then
  DEVICE_LINE="$(xcrun simctl list devices available | grep -E '^[[:space:]]+iPhone ' | grep -v unavailable | head -1 || true)"
fi
DEVICE_NAME="$(printf '%s\n' "$DEVICE_LINE" | sed -E 's/^[[:space:]]+//;s/ \([A-Fa-f0-9-]+\).*//')"
if [ -z "$DEVICE_NAME" ]; then
  echo "No available iPhone simulator" >&2
  xcrun simctl list devices available | tee "$OUT/simctl-devices.txt"
  exit 1
fi
# Xcode 27 does not put Simulator.app at the historical Developer/Applications path.
SIM_APP="$(/usr/bin/find /Applications /Library/Developer -name Simulator.app -type d 2>/dev/null | head -1 || true)"
echo "Simulator.app: ${SIM_APP:-not found}"
# Hardware keyboard lets Return reach the system icon alert.
defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool true || true

dismiss_icon_alert() {
  # A click on the Simulator window becomes a touch on the device. The OK button
  # sits just below the middle of an iPhone screen.
  osascript <<'EOF' || true
tell application "System Events"
  if exists process "Simulator" then
    tell process "Simulator"
      set frontmost to true
      keystroke return
      if (count of windows) > 0 then
        set w to window 1
        set {px, py} to position of w
        set {ww, wh} to size of w
        click at {px + (ww / 2), py + (wh * 0.62)}
      end if
    end tell
  else
    log "Simulator process is not running"
  end if
end tell
EOF
}

echo "Using simulator: $DEVICE_NAME"
xcrun simctl list devices available | tee "$OUT/simctl-devices.txt"

xcodebuild \
  -workspace App.xcworkspace \
  -scheme App \
  -configuration Debug \
  -destination "generic/platform=iOS Simulator" \
  -sdk iphonesimulator \
  -derivedDataPath "$OUT/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM="" \
  build | tee "$OUT/xcodebuild.log"

APP_PATH="$(find "$OUT/DerivedData" -type d -name 'App.app' | head -1)"
if [ -z "$APP_PATH" ]; then
  echo "App.app was not produced" >&2
  exit 1
fi
echo "Built $APP_PATH"

echo "=== build alert-dismiss UI test ==="
xcodebuild \
  -project "$ROOT/.github/ios-alert-dismiss/IconAlertDismiss.xcodeproj" \
  -scheme IconAlertDismiss \
  -configuration Debug \
  -destination "generic/platform=iOS Simulator" \
  -sdk iphonesimulator \
  -derivedDataPath "$OUT/AlertDerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM="" \
  build-for-testing | tee "$OUT/uitest-build.log"

# Boot a concrete phone and install.
UDID="$(printf '%s\n' "$DEVICE_LINE" | sed -E 's/.*\(([A-Fa-f0-9-]+)\).*/\1/')"
echo "Booting $DEVICE_NAME ($UDID)"
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
if [ -n "$SIM_APP" ] && [ -d "$SIM_APP" ]; then
  open "$SIM_APP" --args -CurrentDeviceUDID "$UDID" || true
else
  echo "Simulator.app was not found on this runner" | tee "$OUT/simulator-app.txt"
fi
sleep 8

xcrun simctl install "$UDID" "$APP_PATH"
# Launch once so SpringBoard places the icon, then leave the app.
xcrun simctl launch "$UDID" com.example.app
sleep 5
xcrun simctl terminate "$UDID" com.example.app || true
sleep 3
xcrun simctl io "$UDID" screenshot "$OUT/ios-home-before-default.png"
ls -lh "$OUT/ios-home-before-default.png"

evidence_file() {
  local container
  container="$(xcrun simctl get_app_container "$UDID" com.example.app data)"
  echo "$container/tmp/evidence-icon.txt"
}

refresh_evidence_log() {
  local file
  file="$(evidence_file)"
  if [ -f "$file" ]; then
    cp "$file" "$OUT/ios-evidence.log"
  fi
}

wait_evidence() {
  local needle="$1" tries="$2" i
  for i in $(seq 1 "$tries"); do
    refresh_evidence_log
    if [ -f "$OUT/ios-evidence.log" ] && grep -q "$needle" "$OUT/ios-evidence.log"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

xcrun simctl launch "$UDID" com.example.app --evidence-change-icon ionitron
if ! wait_evidence "EVIDENCE_ICON_EVAL called" 30; then
  echo "Plugin change() was not invoked" >&2
  cat "$OUT/ios-evidence.log" || true
  exit 1
fi
# The alert, when the plugin still shows it, sits on top of SpringBoard.
xcrun simctl io "$UDID" screenshot "$OUT/ios-home-with-alert-ionitron.png" || true
echo "=== dismiss icon alert with XCUITest ==="
set +e
xcodebuild test-without-building \
  -project "$ROOT/.github/ios-alert-dismiss/IconAlertDismiss.xcodeproj" \
  -scheme IconAlertDismiss \
  -configuration Debug \
  -destination "id=$UDID" \
  -derivedDataPath "$OUT/AlertDerivedData" \
  -only-testing:IconAlertDismissUITests/IconAlertUITests/testDismissAlternateIconAlert \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM="" \
  | tee "$OUT/uitest.log"
UITEST_STATUS=${PIPESTATUS[0]}
set -e
echo "uitest exit $UITEST_STATUS"
if [ "$UITEST_STATUS" -ne 0 ]; then
  echo "Alert dismiss UI test failed" >&2
  exit 1
fi
if ! grep -Eq "ALERT_DISMISSED|ALERT_ABSENT" "$OUT/uitest.log"; then
  echo "UI test did not report the alert outcome" >&2
  exit 1
fi
if ! wait_evidence "EVIDENCE_NATIVE_ICON ionitron" 25; then
  echo "alternateIconName did not become ionitron" >&2
  cat "$OUT/ios-evidence.log" || true
  exit 1
fi
if ! grep -q "EVIDENCE_GETNAME ionitron" "$OUT/ios-evidence.log"; then
  if ! wait_evidence "EVIDENCE_GETNAME ionitron" 15; then
    echo "plugin getName did not return ionitron" >&2
    cat "$OUT/ios-evidence.log" || true
    exit 1
  fi
fi
xcrun simctl terminate "$UDID" com.example.app || true
xcrun simctl terminate "$UDID" com.example.alert-dismiss-host || true
sleep 3
xcrun simctl io "$UDID" screenshot "$OUT/ios-home-after-ionitron.png"
ls -lh "$OUT/ios-home-after-ionitron.png"
echo "=== evidence log ==="
cat "$OUT/ios-evidence.log"

echo "iOS icon evidence complete"
