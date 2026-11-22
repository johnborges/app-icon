#!/usr/bin/env bash
# Issue 66 evidence. Calls AppIcon.change then AppIcon.reset on the example app
# and saves logcat, dumpsys, launcher queries, and screenshots. Does not decide
# whether the bug reproduced; it only records what the device did.
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

capture_phase() {
  local name="$1"
  save_pid "$name"
  shot "$OUT/screen-$name.png"
  adb shell dumpsys activity activities > "$OUT/dumpsys-activities-$name.txt" || true
  grep -E "ResumedActivity|topResumedActivity|mResumedActivity|lastPausedActivity|realActivity=|com.example.app" \
    "$OUT/dumpsys-activities-$name.txt" > "$OUT/dumpsys-activities-$name.excerpt.txt" || true
  launcher_queries "$name"
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
adb shell screenrecord --time-limit 150 /sdcard/ai66.mp4 > "$OUT/screenrecord-start.txt" 2>&1 &
sleep 1

log "broadcast change"
broadcast change ionic | tee "$OUT/broadcast-change.txt" || true
if ! wait_log "REQUEST change:ionic" 12; then
  log "broadcast did not deliver; falling back to am start on the running alias"
  adb shell am start -n "$PKG/.stencil" --es evidenceAction change --es evidenceIcon ionic > "$OUT/am-start-change-fallback.txt" || true
  wait_log "REQUEST change:ionic" 12 || true
fi
wait_log "EVAL change" 20 || true
sleep 4
capture_phase "after-change"
PID_AFTER_CHANGE="$(pidof_pkg)"

home_shot "Ionic" "$OUT/screen-home-after-change.png" "$OUT/ui-home-after-change.xml" || true
launcher_queries "home-after-change"

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
  wait_log "EVAL reset" 20 || true
  sleep 4
  capture_phase "after-reset"
  home_shot "Stencil" "$OUT/screen-home-after-reset.png" "$OUT/ui-home-after-reset.xml" || true
  launcher_queries "home-after-reset"
else
  log "process gone after change; not relaunching for reset"
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
