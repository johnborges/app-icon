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
dismiss_icon_alert() {
  # The system icon alert's default button is OK. Return activates it when Simulator is focused.
  osascript <<'EOF' || true
tell application "Simulator" to activate
delay 0.4
tell application "System Events" to key code 36
EOF
  # Some Xcode versions also accept a simctl tap. Ignore it when the subcommand is absent.
  xcrun simctl ui booted tap 200 480 >/dev/null 2>&1 || true
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

# Boot a concrete phone and install.
UDID="$(printf '%s\n' "$DEVICE_LINE" | sed -E 's/.*\(([A-Fa-f0-9-]+)\).*/\1/')"
echo "Booting $DEVICE_NAME ($UDID)"
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
open -a Simulator --args -CurrentDeviceUDID "$UDID" || true
sleep 3

xcrun simctl install "$UDID" "$APP_PATH"
# Launch once so SpringBoard places the icon, then leave the app.
xcrun simctl launch "$UDID" com.example.app
sleep 5
xcrun simctl terminate "$UDID" com.example.app || true
sleep 3
xcrun simctl io "$UDID" screenshot "$OUT/ios-home-before-default.png"
ls -lh "$OUT/ios-home-before-default.png"

# Follow the system log for the evidence hook while the plugin runs.
xcrun simctl spawn "$UDID" log stream --style compact --timeout 50 --predicate 'composedMessage CONTAINS "EVIDENCE_" OR eventMessage CONTAINS "EVIDENCE_"' \
  > "$OUT/ios-evidence.log" 2>&1 &
LOG_PID=$!

xcrun simctl launch "$UDID" com.example.app --evidence-change-icon ionitron
# The public setAlternateIconName API shows a system alert and applies the icon when OK is tapped.
sleep 10
dismiss_icon_alert
sleep 3
dismiss_icon_alert
sleep 8
xcrun simctl terminate "$UDID" com.example.app || true
sleep 3
xcrun simctl io "$UDID" screenshot "$OUT/ios-home-after-ionitron.png"
ls -lh "$OUT/ios-home-after-ionitron.png"

wait "$LOG_PID" || true
echo "=== evidence log ==="
cat "$OUT/ios-evidence.log" || true

if ! grep -q "EVIDENCE_NATIVE_ICON ionitron" "$OUT/ios-evidence.log"; then
  echo "Plugin did not report the ionitron alternate icon" >&2
  exit 1
fi

echo "iOS icon evidence complete"
