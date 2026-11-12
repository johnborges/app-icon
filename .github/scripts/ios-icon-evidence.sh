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
# Xcode 27 keeps Simulator.app inside the toolchain, not in /Applications.
DEVROOT="$(xcode-select -p)"
SIM_APP="$DEVROOT/Applications/Simulator.app"
echo "Simulator.app: $SIM_APP"
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
if [ -d "$SIM_APP" ]; then
  open "$SIM_APP" --args -CurrentDeviceUDID "$UDID" || true
else
  echo "Simulator.app was not at $SIM_APP" >&2
  ls "$DEVROOT/Applications" || true
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
# The public API shows a system alert. The icon is applied when that alert is accepted.
sleep 12
dismiss_icon_alert
sleep 2
dismiss_icon_alert
sleep 6
xcrun simctl spawn "$UDID" log show --last 3m --style compact --predicate 'composedMessage CONTAINS "EVIDENCE_"' \
  > "$OUT/ios-evidence.log" 2>&1 || true
echo "=== evidence log ==="
cat "$OUT/ios-evidence.log" || true
xcrun simctl terminate "$UDID" com.example.app || true
sleep 2
dismiss_icon_alert
sleep 2
xcrun simctl io "$UDID" screenshot "$OUT/ios-home-after-ionitron.png"
ls -lh "$OUT/ios-home-after-ionitron.png"

if ! grep -q "EVIDENCE_ICON_EVAL called" "$OUT/ios-evidence.log"; then
  echo "Plugin change() was not invoked" >&2
  exit 1
fi
if ! grep -q "EVIDENCE_NATIVE_ICON ionitron" "$OUT/ios-evidence.log"; then
  echo "alternateIconName did not become ionitron" >&2
  exit 1
fi

echo "iOS icon evidence complete"
