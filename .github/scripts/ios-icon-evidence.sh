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

xcrun simctl launch "$UDID" com.example.app --evidence-change-icon ionitron
# The public API shows a system alert. Give the plugin time, then try to accept it.
sleep 14
# simctl ui tap is point-based. The OK button is near the middle of an iPhone 17 screen.
{
  echo "=== simctl ui help ==="
  xcrun simctl ui help || true
  echo "=== taps ==="
  xcrun simctl ui "$UDID" tap 201 480 || true
  xcrun simctl ui "$UDID" tap 201 540 || true
  xcrun simctl ui "$UDID" tap 201 600 || true
} > "$OUT/simctl-tap.txt" 2>&1 || true
dismiss_icon_alert
sleep 3
xcrun simctl terminate "$UDID" com.example.app || true
sleep 2
xcrun simctl ui "$UDID" tap 201 540 > "$OUT/simctl-tap-after.txt" 2>&1 || true
dismiss_icon_alert
sleep 2
xcrun simctl io "$UDID" screenshot "$OUT/ios-home-after-ionitron.png"
ls -lh "$OUT/ios-home-after-ionitron.png"

CONTAINER="$(xcrun simctl get_app_container "$UDID" com.example.app data)"
EVIDENCE_FILE="$CONTAINER/tmp/evidence-icon.txt"
echo "Evidence file: $EVIDENCE_FILE"
if [ -f "$EVIDENCE_FILE" ]; then
  cp "$EVIDENCE_FILE" "$OUT/ios-evidence.log"
else
  echo "evidence file missing" | tee "$OUT/ios-evidence.log"
  find "$CONTAINER" -name evidence-icon.txt -print || true
fi
echo "=== evidence log ==="
cat "$OUT/ios-evidence.log"

if ! grep -q "EVIDENCE_ICON_EVAL called" "$OUT/ios-evidence.log"; then
  echo "Plugin change() was not invoked" >&2
  exit 1
fi
if ! grep -q "EVIDENCE_NATIVE_ICON ionitron" "$OUT/ios-evidence.log"; then
  echo "alternateIconName did not become ionitron" >&2
  exit 1
fi

echo "iOS icon evidence complete"
