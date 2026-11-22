#!/usr/bin/env bash
# Issue 66 evidence. After AppIcon.change, leave the app in the foreground for
# 30s with no HOME, am start, or other input, and sample pid, the resumed
# activity, and a screenshot at +2/+5/+10/+15/+20/+30s. Launcher queries and
# reset happen only after that window. getName is a later, separate call.
# Does not decide whether the bug reproduced; it only records what the device did.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${EVIDENCE_DIR:-$ROOT/ai66-evidence}"
APK="${DEBUG_APK:-$ROOT/example/android/app/build/outputs/apk/debug/app-debug.apk}"
PKG=com.example.app
mkdir -p "$OUT"

log() { echo "AI66_HOST $(date -u +%H:%M:%S) $*"; }

shot() {
  local dest="$1"
  adb exec-out screencap -p > "$dest" || true
  if ! cmp -s <(printf '\211PNG') <(head -c 4 "$dest" 2>/dev/null || true); then
    log "screenshot missing png magic: $dest"
  fi
  ls -lh "$dest" || true
}

pidof_pkg() {
  adb shell pidof "$PKG" 2>/dev/null | tr -d '\r' || true
}

save_pid() {
  local name="$1"
  local pid
  pid="$(pidof_pkg)"
  printf '%s\n' "$pid" > "$OUT/pid-$name.txt"
  adb shell ps -A > "$OUT/ps-$name.txt" || true
  log "pid $name=${pid:-<none>}"
}

launcher_queries() {
  local name="$1"
  adb shell pm query-activities -a android.intent.action.MAIN -c android.intent.category.LAUNCHER > "$OUT/pm-query-activities-$name.txt" || true
  adb shell cmd package query-activities -a android.intent.action.MAIN -c android.intent.category.LAUNCHER > "$OUT/cmd-query-activities-$name.txt" || true
  adb shell cmd package resolve-activity -a android.intent.action.MAIN -c android.intent.category.LAUNCHER "$PKG" > "$OUT/resolve-activity-$name.txt" || true
  adb shell dumpsys package "$PKG" > "$OUT/dumpsys-package-$name.txt" || true
  python3 - "$OUT" "$name" <<'PY' || true
import re, pathlib, sys
out, name = sys.argv[1], sys.argv[2]
dest = pathlib.Path(out) / f"launcher-entries-{name}.txt"
lines = []
for label in ("pm-query-activities", "cmd-query-activities", "resolve-activity"):
    path = pathlib.Path(out) / f"{label}-{name}.txt"
    text = path.read_text(errors="replace") if path.exists() else ""
    found = re.findall(r"name=(com\.example\.app\.(?:MainActivity|stencil|ionic|ionitron))\b", text)
    uniq = []
    for item in found:
        if item not in uniq:
            uniq.append(item)
    lines.append(f"== {label} raw={len(found)} unique={len(uniq)}")
    lines.extend(uniq or ["<none>"])
pkg = pathlib.Path(out) / f"dumpsys-package-{name}.txt"
text = pkg.read_text(errors="replace") if pkg.exists() else ""
for header in ("enabledComponents:", "disabledComponents:"):
    lines.append(f"== {header}")
    grabbing = False
    got = False
    for line in text.splitlines():
        if header in line:
            grabbing = True
            continue
        if grabbing:
            if re.match(r"\s+com\.example\.app\.", line):
                lines.append(line.strip())
                got = True
                continue
            if got:
                break
            if line.strip() == "":
                break
            if not line.startswith(" ") and not line.startswith("\t"):
                break
    if not got:
        lines.append("<none>")
# Enabled MAIN/LAUNCHER rows in the package resolver table.
lines.append("== resolver MAIN+LAUNCHER")
blocks = text.split("Activity Resolver Table:")
section = blocks[1] if len(blocks) > 1 else ""
# Stop at the next top-level table if present.
section = re.split(r"\n(?:Receiver|Service|Provider) Resolver Table:", section)[0]
current = None
chunk = []
rows = []
for line in section.splitlines() + [""]:
    if re.search(r"com\.example\.app/\.", line):
        current = line.strip()
        chunk = [current]
        continue
    if current:
        if line.strip() == "" or re.match(r"\S", line):
            blob = "\n".join(chunk)
            if "android.intent.category.LAUNCHER" in blob and "android.intent.action.MAIN" in blob:
                rows.append(current)
            current = None
            chunk = []
        else:
            chunk.append(line)
lines.append(f"count={len(rows)}")
lines.extend(rows or ["<none>"])
dest.write_text("\n".join(lines) + "\n")
print("\n".join(lines))
PY
}

capture_resumed() {
  local name="$1"
  adb shell dumpsys activity activities > "$OUT/dumpsys-activities-$name.txt" || true
  grep -E "topResumedActivity=|ResumedActivity:" \
    "$OUT/dumpsys-activities-$name.txt" > "$OUT/resumed-$name.txt" || true
}

capture_phase() {
  local name="$1"
  save_pid "$name"
  shot "$OUT/screen-$name.png"
  capture_resumed "$name"
  launcher_queries "$name"
}

# Foreground sample. Reads only: screencap, pidof, dumpsys. No keys, no broadcasts.
capture_foreground() {
  local offset="$1"
  local name="plus-$offset"
  local now pid resumed
  now="$(adb shell date '+%m-%d %H:%M:%S' | tr -d '\r')"
  save_pid "$name"
  pid="$(cat "$OUT/pid-$name.txt")"
  shot "$OUT/screen-$name.png"
  capture_resumed "$name"
  resumed="$(paste -sd ' | ' "$OUT/resumed-$name.txt" 2>/dev/null || true)"
  printf 'capture +%ss device=%s pid=%s resumed=%s\n' "$offset" "$now" "${pid:-<none>}" "${resumed:-<none>}" | tee -a "$OUT/timeline.txt"
}

device_now_ms() {
  adb shell date '+%s %N' | tr -d '\r' | python3 -c 'import sys; p=sys.stdin.read().split(); n=(p[1]+"000")[:3] if len(p)>1 and p[1].isdigit() else "0"; print(int(p[0])*1000+int(n))'
}

# Print epoch milliseconds for a logcat timestamp "MM-DD HH:MM:SS.mmm".
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
      log "clock skew: target is $((target - now))ms ahead of device; capturing now"
      echo "WAIT_SKEW now=$now target=$target" | tee -a "$OUT/timeline.txt"
      return 0
    fi
    spins=$((spins + 1))
    if [ "$spins" -gt 200 ]; then
      log "timed wait exceeded 40s; capturing now"
      return 0
    fi
    sleep 0.2
  done
}

screen_size() {
  adb shell wm size | tr -d '\r' | awk -F '[ x:]+' '/Physical size/{print $3, $4}'
}

dump_ui() {
  local dest="$1"
  local i
  for i in 1 2 3 4 5; do
    if adb shell uiautomator dump /sdcard/ui-ai66.xml >/dev/null 2>&1; then
      adb pull /sdcard/ui-ai66.xml "$dest" >/dev/null
      return 0
    fi
    sleep 1
  done
  return 1
}

home_shot() {
  local label="$1"
  local png="$2"
  local xml="$3"
  adb shell input keyevent KEYCODE_HOME || true
  sleep 2
  dump_ui "$xml" || true
  if grep -q "text=\"${label}\"" "$xml" 2>/dev/null || grep -q "content-desc=\"${label}\"" "$xml" 2>/dev/null; then
    shot "$png"
    log "home shows $label"
    return 0
  fi
  # Best-effort: drag the labeled icon from the drawer onto the workspace.
  # Do not force-stop the launcher; that drops the shortcut.
  local W H
  read -r W H < <(screen_size || true)
  if [ -n "${W:-}" ]; then
    adb shell input swipe $((W / 2)) $((H * 85 / 100)) $((W / 2)) $((H * 25 / 100)) 250 || true
    sleep 2
    dump_ui "$xml" || true
  fi
  shot "$png"
  if grep -q "text=\"${label}\"" "$xml" 2>/dev/null; then
    log "drawer/home shows $label"
  else
    log "home screenshot saved without label $label"
  fi
}

wait_log() {
  local pat="$1"
  local secs="$2"
  local i
  for i in $(seq 1 "$secs"); do
    if adb logcat -d -b main -b system -b crash | grep -q "$pat"; then
      log "saw $pat after ${i}s"
      return 0
    fi
    sleep 1
  done
  log "timeout waiting for $pat"
  return 1
}

broadcast() {
  local action="$1"
  local icon="${2:-}"
  if [ -n "$icon" ]; then
    adb shell am broadcast -n "$PKG/.HarnessReceiver" -a "$PKG.AI66" --es evidenceAction "$action" --es evidenceIcon "$icon"
  else
    adb shell am broadcast -n "$PKG/.HarnessReceiver" -a "$PKG.AI66" --es evidenceAction "$action"
  fi
}

log "apk=$APK"
ls -lh "$APK"
{
  echo "sha $(git -C "$ROOT" rev-parse HEAD)"
  echo "branch $(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
  adb shell getprop ro.build.fingerprint || true
  adb shell getprop ro.build.version.sdk || true
  adb shell getprop ro.build.version.release || true
} | tee "$OUT/device-and-git.txt"

cp "$ROOT/example/android/app/src/main/AndroidManifest.xml" "$OUT/AndroidManifest.xml"
grep -n "LAUNCHER" "$OUT/AndroidManifest.xml" > "$OUT/manifest-launcher-lines.txt" || true
if ! grep -q '<!-- <category android:name="android.intent.category.LAUNCHER" /> -->' "$OUT/AndroidManifest.xml"; then
  log "manifest is not the documented setup"
  echo "MANIFEST_UNEXPECTED" > "$OUT/manifest-check.txt"
  exit 1
fi
echo "MANIFEST_OK" > "$OUT/manifest-check.txt"
sed -n '59,110p' "$ROOT/android/src/main/java/com/mycompany/plugins/example/AppIconBase.java" > "$OUT/AppIconBase-excerpt.java"

adb wait-for-device
adb shell input keyevent KEYCODE_WAKEUP || true
adb shell wm dismiss-keyguard || true
adb shell settings put system screen_off_timeout 1800000 || true

adb uninstall "$PKG" || true
adb install -r "$APK"
adb logcat -b all -c || true
adb shell am start -W -n "$PKG/.stencil" > "$OUT/am-start-initial.txt" || true

if ! wait_log "AI66" 40; then
  log "activity did not log AI66; continuing to poll the UI"
fi
for i in $(seq 1 30); do
  if dump_ui "$OUT/ui-before.xml" && grep -q "Swap App Icon" "$OUT/ui-before.xml"; then
    log "ui ready after ${i} polls"
    break
  fi
  sleep 2
done

capture_phase "before"
PID_BEFORE="$(pidof_pkg)"

stdbuf -oL adb logcat -v threadtime > "$OUT/logcat-main.txt" &
MAIN_PID=$!
stdbuf -oL adb logcat -b events -v threadtime > "$OUT/logcat-events.txt" &
EVENTS_PID=$!
adb shell screenrecord --time-limit 180 /sdcard/ai66.mp4 > "$OUT/screenrecord-start.txt" 2>&1 &
sleep 1

: > "$OUT/timeline.txt"
log "broadcast change"
broadcast change ionic | tee "$OUT/broadcast-change.txt" || true
if ! wait_log "REQUEST change:ionic" 12; then
  log "broadcast did not deliver; falling back to am start on the running alias"
  echo "fallback_am_start_before_window" | tee -a "$OUT/timeline.txt"
  adb shell am start -n "$PKG/.stencil" --es evidenceAction change --es evidenceIcon ionic > "$OUT/am-start-change-fallback.txt" || true
  wait_log "REQUEST change:ionic" 12 || true
fi
wait_log "AI66_CHANGE_OK" 25 || wait_log "AI66_CHANGE_CALL" 5 || wait_log "EVAL change" 5 || true

ANCHOR_LINE="$(adb logcat -d -b main -b system -b crash -v threadtime | grep -F "AI66_CHANGE_OK" | head -1 || true)"
ANCHOR_KIND="CHANGE_OK"
if [ -z "$ANCHOR_LINE" ]; then
  ANCHOR_LINE="$(adb logcat -d -b main -b system -b crash -v threadtime | grep -F "AI66_CHANGE_CALL" | head -1 || true)"
  ANCHOR_KIND="CHANGE_CALL"
fi
if [ -z "$ANCHOR_LINE" ]; then
  ANCHOR_LINE="$(adb logcat -d -b main -b system -b crash -v threadtime | grep -F "EVAL change" | head -1 || true)"
  ANCHOR_KIND="EVAL_CHANGE"
fi
printf 'anchor kind=%s line=%s\n' "$ANCHOR_KIND" "$ANCHOR_LINE" | tee -a "$OUT/timeline.txt"
printf '%s\n' "$ANCHOR_LINE" > "$OUT/anchor-line.txt"

if [ -n "$ANCHOR_LINE" ]; then
  ANCHOR_MS="$(log_time_ms "$ANCHOR_LINE")"
  echo "anchor_ms=$ANCHOR_MS" | tee -a "$OUT/timeline.txt"
  for offset in 2 5 10 15 20 30; do
    wait_until_ms $((ANCHOR_MS + offset * 1000))
    capture_foreground "$offset"
  done
else
  log "no change anchor; capturing once without a timed window"
  echo "NO_ANCHOR" | tee -a "$OUT/timeline.txt"
  capture_foreground "0"
fi

python3 - "$OUT" <<'PY' || true
import pathlib, re, sys
out = pathlib.Path(sys.argv[1])
anchor = (out / "anchor-line.txt").read_text(errors="replace").strip()
m = re.match(r"(\d\d-\d\d \d\d:\d\d:\d\d\.\d+)", anchor)
anchor_s = m.group(1) if m else ""
def to_ms(stamp):
    # Compare within the same minute-scale by parsing to seconds-of-day plus millis.
    mmdd, hms = stamp.split(" ")
    hh, mi, rest = hms.split(":")
    sec, frac = rest.split(".")
    return ((int(hh) * 60 + int(mi)) * 60 + int(sec)) * 1000 + int((frac + "000")[:3])
lines = ["== finish/kill for com.example.app in the 30s foreground window =="]
if not anchor_s:
    lines.append("no anchor")
else:
    start = to_ms(anchor_s)
    end = start + 30000
    seen = set()
    interesting = ("wm_finish_activity", "am_kill", "am_proc_died", "am_finish_activity", "Force finishing")
    blobs = []
    for name in ("logcat-events.txt", "logcat-main.txt"):
        p = out / name
        if p.exists():
            blobs.append(p.read_text(errors="replace"))
    # Streamed logs can lag; also read the live buffer.
    import subprocess
    live = subprocess.check_output(["adb", "logcat", "-d", "-v", "threadtime", "-b", "main", "-b", "system", "-b", "crash", "-b", "events"], text=True, errors="replace")
    blobs.append(live)
    for blob in blobs:
        for line in blob.splitlines():
            if "com.example.app" not in line and "Force finishing" not in line:
                continue
            if not any(tok in line for tok in interesting):
                continue
            tm = re.match(r"(\d\d-\d\d \d\d:\d\d:\d\d\.\d+)", line)
            if not tm:
                continue
            delta = to_ms(tm.group(1)) - start
            if delta < -500 or delta > 31000:
                continue
            key = (tm.group(1), line.split(":", 2)[-1] if False else line[20:])
            if line in seen:
                continue
            seen.add(line)
            lines.append(f"+{delta/1000:.3f}s {line}")
    if len(lines) == 1:
        lines.append("none")
text = "\n".join(lines) + "\n"
(out / "foreground-events.txt").write_text(text)
print(text)
PY
cat "$OUT/foreground-events.txt" >> "$OUT/timeline.txt" || true

# Launcher queries and home only after the 30s foreground window.
launcher_queries "after-change"
home_shot "Ionic" "$OUT/screen-home-after-change.png" "$OUT/ui-home-after-change.xml" || true
launcher_queries "home-after-change"
PID_AFTER_CHANGE="$(pidof_pkg)"

PID_BEFORE_RESET="$(pidof_pkg)"
if [ -n "$PID_BEFORE_RESET" ]; then
  log "process still alive ($PID_BEFORE_RESET); bringing it forward and resetting"
  adb shell am start -n "$PKG/.MainActivity" > "$OUT/am-start-before-reset.txt" || true
  sleep 2
  broadcast reset | tee "$OUT/broadcast-reset.txt" || true
  if ! wait_log "REQUEST reset:" 12; then
    log "reset broadcast missed; trying am start"
    adb shell am start -n "$PKG/.MainActivity" --es evidenceAction reset > "$OUT/am-start-reset-fallback.txt" || \
      adb shell am start -n "$PKG/.ionic" --es evidenceAction reset > "$OUT/am-start-reset-fallback.txt" || true
    wait_log "REQUEST reset:" 12 || true
  fi
  wait_log "AI66_RESET_OK" 25 || wait_log "EVAL reset" 10 || true
  sleep 4
  capture_phase "after-reset"
  home_shot "Stencil" "$OUT/screen-home-after-reset.png" "$OUT/ui-home-after-reset.xml" || true
  launcher_queries "home-after-reset"
  # getName is after the reset captures. A null launch intent NPEs in
  # AppIconBase.getName and can kill the process; that stack is separate.
  log "getName after reset captures"
  broadcast getname | tee "$OUT/broadcast-getname.txt" || true
  wait_log "AI66_GETNAME_CALL" 20 || true
  sleep 3
  adb logcat -d -v threadtime -b main -b system -b crash > "$OUT/getname-logcat.txt" || true
  python3 - "$OUT/getname-logcat.txt" "$OUT/getname-stack.txt" <<'PY' || true
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines()
start = 0
for i, line in enumerate(text):
    if "AI66_GETNAME_CALL" in line or "Fatal signal" in line or "FATAL EXCEPTION" in line:
        start = i
keys = ("AI66_GETNAME", "AndroidRuntime", "FATAL EXCEPTION", "NullPointerException", "AppIconBase.java", "Force finishing", "am_crash", "am_proc_died")
kept = [line for line in text[max(0, start - 5):] if any(k in line for k in keys)]
pathlib.Path(sys.argv[2]).write_text("\n".join(kept) + ("\n" if kept else "no getName lines\n"))
PY
else
  log "process gone after the foreground window; not relaunching for reset"
  echo "SKIPPED process dead after change" > "$OUT/reset-skipped.txt"
  shot "$OUT/screen-after-reset-skipped.png"
fi

adb shell kill -2 "$(adb shell pidof screenrecord | tr -d '\r')" >/dev/null 2>&1 || true
sleep 2
adb pull /sdcard/ai66.mp4 "$OUT/ai66.mp4" || log "no screenrecord"
kill "$MAIN_PID" "$EVENTS_PID" >/dev/null 2>&1 || true
wait "$MAIN_PID" "$EVENTS_PID" 2>/dev/null || true
# Snapshots in case the streamed log was buffered.
adb logcat -d -v threadtime -b main -b system -b crash > "$OUT/logcat-main-dump.txt" || true
adb logcat -d -v threadtime -b events > "$OUT/logcat-events-dump.txt" || true

python3 - "$OUT" <<'PY' || true
import pathlib, re, sys
out = pathlib.Path(sys.argv[1])
patterns = re.compile(
    r"am_finish_activity|am_kill|wm_finish_activity|am_proc_died|am_proc_start|"
    r"am_on_resume_called|wm_resume_activity|wm_destroy_activity|wm_create_activity|"
    r"am_crash|Force finishing|has died|AI66|AppIconBase|ActivityManager|ActivityTaskManager"
)
for name in ("logcat-main.txt", "logcat-events.txt", "logcat-main-dump.txt", "logcat-events-dump.txt"):
    src = out / name
    if not src.exists():
        continue
    kept = [line for line in src.read_text(errors="replace").splitlines() if patterns.search(line)]
    (out / (name.replace(".txt", "") + ".filtered.txt")).write_text("\n".join(kept) + ("\n" if kept else ""))
PY

{
  echo "pid_before=$PID_BEFORE"
  echo "pid_after_change=$PID_AFTER_CHANGE"
  echo "pid_before_reset=$PID_BEFORE_RESET"
  echo "pid_after_reset=$(pidof_pkg)"
} | tee "$OUT/pids.txt"

if grep -q "REQUEST change:ionic" "$OUT/logcat-main.txt" "$OUT/logcat-main-dump.txt" 2>/dev/null; then
  log "change request was delivered"
  exit 0
fi
log "change request was never delivered"
exit 1
