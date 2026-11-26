#!/usr/bin/env python3
"""Score one AI-66 evidence directory. Exit 0 only when change() and reset() both pass."""

import json
import pathlib
import re
import sys

REQUIRED_OFFSETS = (2, 5, 10, 15, 20, 30)
PKG = "com.example.app"
FINISH_TOKENS = ("wm_finish_activity", "am_finish_activity", "Force finishing")


def day_ms(line):
    match = re.search(r"(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d+)", line)
    if not match:
        return None
    month, day, hour, minute, second, frac = match.groups()
    millis = int((frac + "000")[:3])
    clock = ((int(hour) * 60 + int(minute)) * 60 + int(second)) * 1000 + millis
    return (int(month) * 31 + int(day)) * 86400000 + clock


def read_text(path):
    file = pathlib.Path(path)
    if not file.exists():
        return ""
    return file.read_text(errors="replace")


def load_jsonl(path):
    rows = []
    for line in read_text(path).splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            rows.append({"parse_error": line})
    return rows


def log_lines(out):
    names = (
        "logcat-main.txt",
        "logcat-events.txt",
        "logcat-main-dump.txt",
        "logcat-events-dump.txt",
        "getname-logcat.txt",
    )
    seen = set()
    lines = []
    for name in names:
        for line in read_text(out / name).splitlines():
            if line in seen:
                continue
            seen.add(line)
            lines.append(line)
    return lines


def classify_resumed(line):
    if not line or line.strip() in ("", "<none>"):
        return "missing", ""
    match = re.search(r"\bu\d+\s+(\S+)", line)
    component = match.group(1) if match else ""
    if not component:
        found = re.findall(r"([A-Za-z0-9_\.]+)/\.[A-Za-z0-9_\.\$]+", line)
        component = found[0] if found else ""
    if component.startswith(PKG):
        return "app", component
    if "com.example.app" in line and "launcher" not in line.lower():
        return "app", component or "com.example.app"
    package = component.split("/")[0] if component else line
    if "launcher" in package.lower() or "launcher" in component.lower():
        return "launcher", component or package
    return "other", component or line.strip()[:180]


def in_window(stamp, start, end):
    return stamp is not None and start is not None and end is not None and start <= stamp < end


def first_stamp(lines, needle, not_before=None):
    for line in lines:
        if needle not in line:
            continue
        stamp = day_ms(line)
        if stamp is None:
            continue
        if not_before is not None and stamp < not_before:
            continue
        return stamp, line
    return None, ""


def phase_score(out, phase, lines, anchor_needle, home_needle):
    anchor_file = read_text(out / f"anchor-line-{phase}.txt").strip()
    anchor_stamp = day_ms(anchor_file)
    if anchor_stamp is None:
        anchor_stamp, anchor_file = first_stamp(lines, anchor_needle)
    home_line = read_text(out / f"home-line-{phase}.txt").strip()
    home_stamp = day_ms(home_line)
    if home_stamp is None or (anchor_stamp is not None and home_stamp < anchor_stamp):
        home_stamp, home_line = first_stamp(lines, home_needle, anchor_stamp)
    delivered = anchor_needle in anchor_file or any(
        anchor_needle in line and (anchor_stamp is None or day_ms(line) == anchor_stamp) for line in lines
    )
    # delivered means the plugin call resolved, not merely that it was attempted.
    delivered = any(anchor_needle in line and day_ms(line) == anchor_stamp for line in lines) or (
        anchor_needle in anchor_file
    )

    samples = load_jsonl(out / f"samples-{phase}.jsonl")
    polls = load_jsonl(out / f"home-poll-{phase}.jsonl")
    home_ms_text = read_text(out / f"home-ms-{phase}.txt").strip()
    home_ms = int(home_ms_text) if home_ms_text.isdigit() else None

    reasons = []
    finish_lines = []
    if anchor_stamp is None or home_stamp is None:
        reasons.append("missing anchor or HOME marker")
    else:
        for line in lines:
            if PKG not in line:
                continue
            if not any(token in line for token in FINISH_TOKENS):
                continue
            stamp = day_ms(line)
            if not in_window(stamp, anchor_stamp, home_stamp):
                continue
            delta = (stamp - anchor_stamp) / 1000.0
            finish_lines.append(f"+{delta:.3f}s {line.strip()[:400]}")
        if finish_lines:
            reasons.append("activity finished during foreground")

    pids = []
    resumed_problems = []
    launcher_hits = []
    present = set()
    counted = []
    for row in samples:
        offset = row.get("offset_s")
        if isinstance(offset, str) and offset.isdigit():
            offset = int(offset)
        if isinstance(offset, int):
            present.add(offset)
        pid = str(row.get("pid") or "").strip()
        pids.append((offset, pid))
        if home_ms is not None and isinstance(row.get("at_ms"), int) and row["at_ms"] > home_ms + 500:
            if isinstance(offset, int) and offset in REQUIRED_OFFSETS:
                reasons.append(f"sample +{offset}s was after HOME")
        kind, component = classify_resumed(str(row.get("resumed") or ""))
        if kind == "launcher":
            launcher_hits.append(f"+{offset}s {component}")
            resumed_problems.append(f"+{offset}s launcher {component}")
        elif kind != "app":
            resumed_problems.append(f"+{offset}s resumed={kind} {component}")
        if isinstance(row.get("launchers"), int):
            counted.append(row)
    missing = [offset for offset in REQUIRED_OFFSETS if offset not in present]
    if missing:
        reasons.append("missing samples " + ",".join(str(offset) for offset in missing))
    base_pid = ""
    for offset, pid in pids:
        if isinstance(offset, int) and pid:
            base_pid = pid
            break
    pid_changes = []
    for offset, pid in pids:
        if not isinstance(offset, int) and offset != "pre_home":
            continue
        if not pid or (base_pid and pid != base_pid):
            pid_changes.append(f"+{offset}s pid={pid or '<none>'} baseline={base_pid or '<none>'}")
    if pid_changes:
        reasons.append("pid changed")

    activity_pass = not reasons and not resumed_problems
    # resumed leaving the app is part of the activity-finish criterion.
    if resumed_problems:
        reasons.append("resumed activity left the app")
        activity_pass = False

    launcher_pass = not launcher_hits and not missing and anchor_stamp is not None

    get_end = home_stamp + 5000 if home_stamp is not None else None
    result_lines = []
    error_lines = []
    fatal_lines = []
    if anchor_stamp is not None and home_stamp is not None:
        indexed = [(day_ms(line), line) for line in lines]
        for stamp, line in indexed:
            if stamp is None or stamp < anchor_stamp or stamp >= get_end:
                continue
            if "AI66_GETNAME_RESULT" in line:
                result_lines.append(line.strip()[:400])
            if "AI66_GETNAME_ERR" in line:
                error_lines.append(line.strip()[:400])
        for index, (stamp, line) in enumerate(indexed):
            if not in_window(stamp, anchor_stamp, home_stamp):
                continue
            blob = "\n".join(item[1] for item in indexed[index : index + 20])
            if "FATAL EXCEPTION" in line and PKG in blob:
                fatal_lines.append(line.strip()[:400])
            if "NullPointerException" in line and "AppIcon" in blob:
                fatal_lines.append(line.strip()[:400])
    if error_lines or fatal_lines or not result_lines:
        get_pass = False
    else:
        get_pass = True
    if not result_lines:
        get_detail = "no getName result"
    elif error_lines or fatal_lines:
        get_detail = (error_lines or fatal_lines)[0]
    else:
        get_detail = result_lines[-1]

    final = None
    collapse_ms = None
    for row in polls:
        if not isinstance(row.get("launchers"), int):
            continue
        final = row
        if row["launchers"] == 1 and collapse_ms is None:
            collapse_ms = row.get("at_ms")
            break
    if final is None:
        count_pass = False
        count_value = None
        names = []
        waited = None
    else:
        count_value = final.get("launchers")
        names = final.get("names") or []
        if collapse_ms is not None and home_ms is not None:
            waited = round((collapse_ms - home_ms) / 1000.0, 3)
        elif home_ms is not None and final.get("at_ms") is not None:
            waited = round((final["at_ms"] - home_ms) / 1000.0, 3)
        else:
            waited = None
        count_pass = count_value == 1 and waited is not None and -1.0 <= waited <= 10.0

    above = [row for row in counted if row.get("launchers", 0) > 1 and isinstance(row.get("at_ms"), int)]
    max_count = max((row["launchers"] for row in counted), default=None)
    counts = {}
    for row in samples:
        if isinstance(row.get("launchers"), int):
            counts[str(row.get("offset_s"))] = row["launchers"]
    if above and collapse_ms is not None:
        seconds_above = round((collapse_ms - above[0]["at_ms"]) / 1000.0, 3)
    elif above and polls and isinstance(polls[-1].get("at_ms"), int):
        seconds_above = round((polls[-1]["at_ms"] - above[0]["at_ms"]) / 1000.0, 3)
    else:
        seconds_above = 0.0
    home_to_one = waited if count_pass else None

    post_home = []
    if home_stamp is not None:
        for line in lines:
            if PKG not in line or not any(token in line for token in FINISH_TOKENS):
                continue
            stamp = day_ms(line)
            if stamp is None or stamp < home_stamp or stamp > home_stamp + 15000:
                continue
            post_home.append(f"+{(stamp - home_stamp) / 1000.0:.3f}s {line.strip()[:300]}")

    phase_pass = bool(delivered and activity_pass and launcher_pass and get_pass and count_pass)
    return {
        "delivered": bool(delivered and anchor_needle in (anchor_file + "".join(lines))),
        "activity_finish": {
            "pass": bool(activity_pass and delivered),
            "signals": finish_lines + pid_changes + resumed_problems + ([f"missing {missing}"] if missing else []),
        },
        "launcher_on_top": {
            "pass": bool(launcher_pass and delivered),
            "observed": launcher_hits,
        },
        "get_name": {"pass": bool(get_pass and delivered), "detail": get_detail},
        "count_after_home": {
            "pass": bool(count_pass and delivered),
            "count": count_value,
            "names": names,
            "home_to_exactly_one_seconds": home_to_one if count_pass else waited,
        },
        "pass": phase_pass,
        "samples": samples,
        "two_icon": {
            "counts": counts,
            "max_count": max_count,
            "seconds_above_one": seconds_above,
            "home_to_exactly_one_seconds": home_to_one,
        },
        "finish_after_home": post_home[:8],
        "window": {
            "anchor": anchor_file[:300],
            "home": home_line[:300],
        },
    }


def sha_and_sdk(out):
    text = read_text(out / "device-and-git.txt")
    sha = ""
    sdk = ""
    for line in text.splitlines():
        if line.startswith("sha "):
            sha = line.split(" ", 1)[1].strip()
        if "ro.build.version.sdk" in line or line.strip().isdigit():
            sdk = line.strip()
    variant = read_text(out / "variant.txt").strip() or "unset"
    return sha, sdk, variant


def main():
    out = pathlib.Path(sys.argv[1])
    lines = log_lines(out)
    sha, sdk, variant = sha_and_sdk(out)
    change = phase_score(out, "change", lines, "AI66_CHANGE_OK", "AI66_HOME change")
    reset = phase_score(out, "reset", lines, "AI66_RESET_OK", "AI66_HOME reset")
    native = []
    for line in lines:
        if any(
            token in line
            for token in (
                "AppIconBase",
                "AI66_CHANGE",
                "AI66_RESET",
                "AI66_GETNAME",
                "wm_finish_activity",
                "Force finishing",
                "reset default=",
            )
        ):
            native.append(line.strip()[:400])
    summary = {
        "variant": variant,
        "sha": sha,
        "sdk": sdk,
        "pass": bool(change["pass"] and reset["pass"]),
        "change": change,
        "reset": reset,
        "native_excerpt": native[:80],
    }
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    return 0 if summary["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
