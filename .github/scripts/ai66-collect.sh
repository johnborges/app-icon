#!/usr/bin/env bash
# Issue 66 acceptance. After change() and again after reset(), hold the app in
# the foreground for 30s. The run fails if the activity finishes, the launcher
# comes to the top, getName crashes, or HOME does not leave exactly one launcher.
# Two icons while foregrounded are measured, not judged.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${EVIDENCE_DIR:-$ROOT/ai66-evidence}"
APK="${DEBUG_APK:-$ROOT/example/android/app/build/outputs/apk/debug/app-debug.apk}"
PKG=com.example.app
MAIN_PID=""
EVENTS_PID=""
mkdir -p "$OUT"

log() { echo "AI66_HOST $(date -u +%H:%M:%S) $*"; }

finalize() {
  local code=$?
  trap - EXIT
  if [ -n "$MAIN_PID" ]; then
    kill "$MAIN_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$EVENTS_PID" ]; then
    kill "$EVENTS_PID" >/dev/null 2>&1 || true
  fi
  if [ ! -f "$OUT/summary.json" ]; then
    python3 "$ROOT/.github/scripts/ai66-score.py" "$OUT" > "$OUT/score-stdout.txt" || true
  fi
  if [ -f "$OUT/summary.json" ]; then
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("AI66_SUMMARY pass=%s variant=%s" % (d.get("pass"), d.get("variant")))' "$OUT/summary.json" || true
  fi
  exit "$code"
}
trap finalize EXIT

shot() {
  local dest="$1"
  adb exec-out screencap -p > "$dest" || true
}

pidof_pkg() {
  adb shell pidof -s "$PKG" 2>/dev/null | tr -d '\r' || true
}

save_pid() {
  local name="$1"
  local pid
  pid="$(pidof_pkg)"
  printf '%s\n' "$pid" > "$OUT/pid-$name.txt"
  log "pid $name=${pid:-<none>}"
}

device_now_ms() {
  adb shell date '+%s %N' 2>/dev/null | tr -d '\r' | python3 -c '
import sys
parts = sys.stdin.read().split()
if not parts or not parts[0].isdigit():
    print(0)
    raise SystemExit
millis = 0
if len(parts) > 1 and parts[1].isdigit():
    millis = int((parts[1] + "000")[:3])
print(int(parts[0]) * 1000 + millis)
'
}

log_time_ms() {
  python3 - "$1" <<'PY'
import datetime, subprocess, sys
line = sys.argv[1]
parts = line.split()
stamp = parts[0] + " " + parts[1]
mon, day = stamp[:5].split("-")
hh, mm, rest = stamp[6:].split(":")
sec, frac = rest.split(".")
year = subprocess.check_output(["adb", "shell", "date", "+%Y"], text=True).strip()
z = subprocess.check_output(["adb", "shell", "date", "+%z"], text=True).strip()
sign = 1 if z.startswith("+") else -1
off = datetime.timedelta(hours=sign * int(z[1:3]), minutes=sign * int(z[3:5]))
frac = (frac + "000")[:3]
dt = datetime.datetime(int(year), int(mon), int(day), int(hh), int(mm), int(sec), int(frac) * 1000)
epoch = (dt - off - datetime.datetime(1970, 1, 1)).total_seconds()
print(int(round(epoch * 1000)))
PY
}

wait_until_ms() {
  local target="$1"
  local now spins=0
  while true; do
    now="$(device_now_ms)"
    if [ "$now" -ge "$target" ]; then
      return 0
    fi
    if [ $((target - now)) -gt 60000 ]; then
      log "clock skew ${target} vs ${now}; sampling now"
      return 0
    fi
    spins=$((spins + 1))
    if [ "$spins" -gt 200 ]; then
      log "timed wait exceeded 40s; sampling now"
      return 0
    fi
    sleep 0.2
  done
}

count_launchers() {
  local name="$1"
  adb shell pm query-activities -a android.intent.action.MAIN -c android.intent.category.LAUNCHER > "$OUT/pm-query-activities-$name.txt" || true
  python3 - "$OUT/pm-query-activities-$name.txt" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text(errors="replace")
shorts = []
patterns = (
    r"name=(com\.example\.app\.(?:MainActivity|stencil|ionic|ionitron))\b",
    r"(com\.example\.app/\.(?:MainActivity|stencil|ionic|ionitron))\b",
    r"\b(com\.example\.app\.(?:MainActivity|stencil|ionic|ionitron))\b",
)
for pattern in patterns:
    for item in re.findall(pattern, text):
        short = item.split("/")[-1].split(".")[-1]
        if short not in shorts:
            shorts.append(short)
names = ["com.example.app/." + short for short in shorts]
print("launchers=%d names=%s" % (len(names), ",".join(names) if names else "-"))
PY
}

capture_resumed() {
  local name="$1"
  adb shell "dumpsys activity activities | grep -E 'topResumedActivity=|ResumedActivity:'" > "$OUT/resumed-$name.txt" || true
}

append_sample() {
  local phase="$1"
  local offset="$2"
  local pid="$3"
  local resumed="$4"
  local count_line="$5"
  local at_ms="$6"
  python3 - "$OUT/samples-${phase}.jsonl" "$offset" "$pid" "$resumed" "$count_line" "$at_ms" <<'PY'
import json, re, sys
path, offset, pid, resumed, count_line, at_ms = sys.argv[1:]
match = re.search(r"launchers=(\d+)", count_line)
names = []
named = re.search(r"names=(\S+)", count_line)
if named and named.group(1) != "-":
    names = named.group(1).split(",")
try:
    offset_value = int(offset)
except ValueError:
    offset_value = offset
row = {
    "offset_s": offset_value,
    "pid": pid.strip(),
    "resumed": resumed.strip(),
    "launchers": int(match.group(1)) if match else None,
    "names": names,
    "at_ms": int(at_ms) if at_ms.isdigit() else None,
}
with open(path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(row) + "\n")
PY
}

capture_sample() {
  local phase="$1"
  local offset="$2"
  local name="${phase}-${offset}"
  local at pid resumed launchers
  at="$(device_now_ms)"
  save_pid "$name"
  pid="$(tr -d '\r' < "$OUT/pid-$name.txt")"
  capture_resumed "$name"
  resumed="$(paste -sd ' | ' "$OUT/resumed-$name.txt" 2>/dev/null || true)"
  launchers="$(count_launchers "$name" | tail -n 1)"
  append_sample "$phase" "$offset" "$pid" "$resumed" "$launchers" "$at"
  printf '%s sample +%s %s pid=%s resumed=%s\n' "$phase" "$offset" "$launchers" "${pid:-<none>}" "${resumed:-<none>}" | tee -a "$OUT/timeline.txt"
  if [ "$offset" = "0" ] || [ "$offset" = "30" ] || [ "$offset" = "pre_home" ]; then
    shot "$OUT/screen-$name.png"
    adb shell dumpsys activity activities > "$OUT/dumpsys-activities-$name.txt" || true
  fi
}

hold_foreground() {
  local phase="$1"
  local anchor anchor_ms offset
  adb shell input keyevent KEYCODE_WAKEUP || true
  anchor="$(tr -d '\r' < "$OUT/anchor-line-${phase}.txt")"
  if [ -z "$anchor" ]; then
    echo "NO_ANCHOR $phase" | tee -a "$OUT/timeline.txt"
    return 1
  fi
  capture_sample "$phase" 0
  anchor_ms="$(log_time_ms "$anchor" || true)"
  echo "$phase anchor_ms=$anchor_ms" | tee -a "$OUT/timeline.txt"
  if printf '%s' "$anchor_ms" | grep -Eq '^[0-9]+$'; then
    for offset in 2 5 10 15 20 30; do
      wait_until_ms $((anchor_ms + offset * 1000))
      capture_sample "$phase" "$offset"
    done
  else
    log "anchor clock failed; sampling on a sleep schedule"
    local previous=0 gap
    for offset in 2 5 10 15 20 30; do
      gap=$((offset - previous))
      sleep "$gap"
      capture_sample "$phase" "$offset"
      previous=$offset
    done
  fi
  capture_sample "$phase" pre_home
}

press_home() {
  local phase="$1"
  local home_ms start now line marker
  adb shell "log -p I -t AI66 'AI66_HOME ${phase}'" || adb shell "log -t AI66 'AI66_HOME ${phase}'" || true
  sleep 0.3
  marker="$(adb logcat -d -b main -v threadtime | grep -F "AI66_HOME ${phase}" | tail -1 || true)"
  printf '%s\n' "$marker" > "$OUT/home-line-${phase}.txt"
  home_ms="$(device_now_ms)"
  printf '%s\n' "$home_ms" > "$OUT/home-ms-${phase}.txt"
  adb shell input keyevent KEYCODE_HOME || true
  echo "$phase HOME ms=$home_ms marker=$marker" | tee -a "$OUT/timeline.txt"
  : > "$OUT/home-poll-${phase}.jsonl"
  start="$(device_now_ms)"
  local spins=0 retried=0
  while true; do
    spins=$((spins + 1))
    now="$(device_now_ms)"
    line="$(count_launchers "${phase}-poll" | tail -n 1)"
    python3 - "$OUT/home-poll-${phase}.jsonl" "$now" "$line" <<'PY'
import json, re, sys
path, now, line = sys.argv[1:]
match = re.search(r"launchers=(\d+)", line)
names = []
named = re.search(r"names=(\S+)", line)
if named and named.group(1) != "-":
    names = named.group(1).split(",")
row = {
    "at_ms": int(now) if str(now).isdigit() else None,
    "launchers": int(match.group(1)) if match else None,
    "names": names,
}
with open(path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(row) + "\n")
print(json.dumps(row))
PY
    if printf '%s' "$line" | grep -Eq 'launchers=1([^0-9]|$)'; then
      break
    fi
    if [ "$retried" -eq 0 ] && [ $((now - home_ms)) -ge 2000 ]; then
      retried=1
      if adb shell "dumpsys activity activities | grep -m1 topResumedActivity=" | grep -q "$PKG"; then
        log "app still resumed after HOME; sending HOME again"
        adb shell input keyevent KEYCODE_HOME || true
        adb shell am start -a android.intent.action.MAIN -c android.intent.category.HOME > "$OUT/am-home-${phase}.txt" 2>&1 || true
      fi
    fi
    if [ $((now - start)) -ge 10000 ] || [ "$spins" -gt 25 ]; then
      break
    fi
    sleep 0.5
  done
  shot "$OUT/screen-home-after-${phase}.png"
  adb shell dumpsys package "$PKG" > "$OUT/dumpsys-package-home-after-${phase}.txt" || true
  cp "$OUT/pm-query-activities-${phase}-poll.txt" "$OUT/pm-query-activities-home-after-${phase}.txt" || true
}

broadcast() {
  local action="$1"
  local icon="${2:-}"
  local nonce="${3:-}"
  if [ -n "$icon" ] && [ -n "$nonce" ]; then
    adb shell am broadcast -n "$PKG/.HarnessReceiver" -a "$PKG.AI66" --es evidenceAction "$action" --es evidenceIcon "$icon" --es evidenceNonce "$nonce"
  elif [ -n "$nonce" ]; then
    adb shell am broadcast -n "$PKG/.HarnessReceiver" -a "$PKG.AI66" --es evidenceAction "$action" --es evidenceNonce "$nonce"
  elif [ -n "$icon" ]; then
    adb shell am broadcast -n "$PKG/.HarnessReceiver" -a "$PKG.AI66" --es evidenceAction "$action" --es evidenceIcon "$icon"
  else
    adb shell am broadcast -n "$PKG/.HarnessReceiver" -a "$PKG.AI66" --es evidenceAction "$action"
  fi
}

wait_log() {
  local pattern="$1"
  local secs="$2"
  local i
  for i in $(seq 1 "$secs"); do
    if adb logcat -d -b main -b system -b crash | grep -q "$pattern"; then
      log "saw $pattern after ${i}s"
      return 0
    fi
    sleep 1
  done
  log "timeout waiting for $pattern"
  return 1
}

save_anchor() {
  local phase="$1"
  local token="$2"
  local line
  line="$(adb logcat -d -b main -b system -b crash -v threadtime | grep -F "$token" | head -1 || true)"
  printf '%s\n' "$line" > "$OUT/anchor-line-${phase}.txt"
  printf '%s anchor %s\n' "$phase" "$line" | tee -a "$OUT/timeline.txt"
  [ -n "$line" ]
}

if [ ! -f "$APK" ]; then
  log "missing apk $APK"
  exit 1
fi

log "apk=$APK"
{
  echo "sha $(git -C "$ROOT" rev-parse HEAD)"
  echo "branch $(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
  echo "variant ${AI66_VARIANT:-unset}"
  adb shell getprop ro.build.fingerprint || true
  adb shell getprop ro.build.version.sdk || true
  adb shell getprop ro.build.version.release || true
} | tee "$OUT/device-and-git.txt"
printf '%s\n' "${AI66_VARIANT:-unset}" > "$OUT/variant.txt"
cp "$ROOT/example/android/app/src/main/AndroidManifest.xml" "$OUT/AndroidManifest.xml"
cp "$ROOT/android/src/main/java/com/mycompany/plugins/example/AppIconBase.java" "$OUT/AppIconBase.java"
if ! grep -q '<!-- <category android:name="android.intent.category.LAUNCHER" /> -->' "$OUT/AndroidManifest.xml"; then
  log "manifest is not the documented setup"
  echo "MANIFEST_UNEXPECTED" > "$OUT/manifest-check.txt"
  exit 1
fi
echo "MANIFEST_OK" > "$OUT/manifest-check.txt"

adb wait-for-device
adb shell input keyevent KEYCODE_WAKEUP || true
adb shell wm dismiss-keyguard || true
adb shell settings put system screen_off_timeout 1800000 || true
adb shell settings put global stay_on_while_plugged_in 7 || true
adb shell svc power stayon true || true
adb logcat -G 16M || true

adb uninstall "$PKG" || true
adb install -r "$APK"
adb logcat -b all -c || true
adb shell am start -W -n "$PKG/.stencil" > "$OUT/am-start-initial.txt" || true
wait_log "AI66" 40 || true
for i in $(seq 1 30); do
  if adb shell uiautomator dump /sdcard/ui-ai66.xml >/dev/null 2>&1; then
    adb pull /sdcard/ui-ai66.xml "$OUT/ui-before.xml" >/dev/null || true
    if grep -q "Swap App Icon" "$OUT/ui-before.xml" 2>/dev/null; then
      log "ui ready after ${i} polls"
      break
    fi
  fi
  sleep 2
done

: > "$OUT/timeline.txt"
stdbuf -oL adb logcat -v threadtime > "$OUT/logcat-main.txt" &
MAIN_PID=$!
stdbuf -oL adb logcat -b events -v threadtime > "$OUT/logcat-events.txt" &
EVENTS_PID=$!
sleep 1

log "broadcast change"
broadcast change ionic change | tee "$OUT/broadcast-change.txt" || true
wait_log "AI66_CHANGE_OK" 30 || true
save_anchor change "AI66_CHANGE_OK" || true
if [ -s "$OUT/anchor-line-change.txt" ]; then
  broadcast getname "" change | tee "$OUT/broadcast-getname-change.txt" || true
  echo "=== change foreground ===" | tee -a "$OUT/timeline.txt"
  hold_foreground change || true
  press_home change
else
  echo "change was not delivered" | tee -a "$OUT/timeline.txt"
fi

echo "=== reset bring-forward ===" | tee -a "$OUT/timeline.txt"
for component in "$PKG/.ionic" "$PKG/.stencil" "$PKG/.MainActivity"; do
  short="${component##*.}"
  if adb shell am start -W -n "$component" > "$OUT/am-start-before-reset-$short.txt" 2>&1; then
    if ! grep -Eqi "error|unable to resolve|does not exist" "$OUT/am-start-before-reset-$short.txt"; then
      log "started $component before reset"
      break
    fi
  fi
  log "could not start $component before reset"
done
sleep 4

log "broadcast reset"
broadcast reset "" reset | tee "$OUT/broadcast-reset.txt" || true
wait_log "AI66_RESET_OK" 30 || true
save_anchor reset "AI66_RESET_OK" || true
if [ -s "$OUT/anchor-line-reset.txt" ]; then
  broadcast getname "" reset2 | tee "$OUT/broadcast-getname-reset.txt" || true
  echo "=== reset foreground ===" | tee -a "$OUT/timeline.txt"
  hold_foreground reset || true
  press_home reset
else
  echo "reset was not delivered" | tee -a "$OUT/timeline.txt"
fi

sleep 2
adb logcat -d -v threadtime -b main -b system -b crash > "$OUT/logcat-main-dump.txt" || true
adb logcat -d -v threadtime -b events > "$OUT/logcat-events-dump.txt" || true
log "scoring"
python3 "$ROOT/.github/scripts/ai66-score.py" "$OUT" > "$OUT/score-stdout.txt"
score=$?
cat "$OUT/score-stdout.txt"
exit "$score"
