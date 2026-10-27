#!/usr/bin/env bash
# VOIDRUNNER — M8-A remedial cold-run lane (JUDGE Amendment 2, 2026-10-27).
#
# One-off artefact lane for the v1.0.2 seal. It does NOT build anything:
# the workflow downloads the sealed CI artefact A-1 by id and verifies its
# sha256 before this script runs; APK_PATH points at that verified file.
# Diffs vs the tag's tools/verify-cold-run.sh are ONLY the three hardening
# classes Amendment 2 authorises:
#   (a) uiautomator dump retries with waits, until a non-empty hierarchy
#       file exists or the retry budget is exhausted and the lane fails;
#   (b) dismissal of the host "System UI isn't responding" dialog (Wait),
#       logged with before/after captures — host dialog only; an ANR or
#       crash in com.voidrunner.app itself fails the lane;
#   (c) fallback navigation (fixed-fraction taps) that does not depend on
#       dump-derived bounds, used only to REACH screens — the hierarchy
#       asserts are always executed against produced dumps, never replaced.
# Bundle plumbing note: every hierarchy XML actually produced is copied
# into verify-evidence/ (Amendment 2 section 4.6 bundle contents).
#
# Verdict vocabulary (Amendment 2 section 4.6): install=ok, launch_ms=<n>,
# crash_lines=0, home_nodes=PASS, stamps=PASS, frontpage=PASS,
# offline=PASS. The script exits non-zero unless every line is green.
set -u

PKG="com.voidrunner.app"
ACT="com.voidrunner.app/.MainActivity"
OUT="verify-evidence"
TMPD="$(mktemp -d)"
LANE_LOG="$OUT/m8a-lane.log"

APK_PATH="${APK_PATH:-}"
if [ -z "$APK_PATH" ]; then
  if [ -f "release-apk/app-release.apk" ]; then
    APK_PATH="release-apk/app-release.apk"
  else
    APK_PATH="$(find . -name 'app-release.apk' -not -path './verify-evidence/*' | head -n 1)"
  fi
fi

mkdir -p "$OUT"
: > "$LANE_LOG"
log() { echo "$*" | tee -a "$LANE_LOG"; }

install_v="FAIL"; launch_ms_v="FAIL"; crash_v="FAIL"
home_nodes_v="FAIL"; stamps_v="FAIL"; frontpage_v="FAIL"; offline_v="FAIL"
app_anr="0"

# (a) dump with retries: success = destination contains a complete hierarchy.
dump_ui() { # $1 = destination file
  local dst="$1" attempt
  for attempt in 1 2 3 4 5 6 7 8; do
    adb shell rm -f /sdcard/window_dump.xml >/dev/null 2>&1 || true
    timeout 40 adb shell uiautomator dump /sdcard/window_dump.xml >/dev/null 2>&1 || true
    adb exec-out cat /sdcard/window_dump.xml > "$dst.tmp" 2>/dev/null || true
    if grep -q "</hierarchy>" "$dst.tmp" 2>/dev/null; then
      mv "$dst.tmp" "$dst"
      log "dump_ui: ok on attempt $attempt -> $dst"
      return 0
    fi
    log "dump_ui: attempt $attempt produced no complete hierarchy; waiting"
    sleep 4
  done
  log "dump_ui: FAILED after 8 attempts -> $dst"
  return 1
}

tap_text() { # $1 = hierarchy file, $2 = text substring to tap
  local coords
  coords="$(python3 - "$1" "$2" <<'PY'
import re, sys
data = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
for m in re.finditer(r'text="([^"]*' + re.escape(sys.argv[2]) + r'[^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', data):
    x = (int(m.group(2)) + int(m.group(4))) // 2
    y = (int(m.group(3)) + int(m.group(5))) // 2
    print(f"{x} {y}")
    break
PY
)"
  if [ -n "$coords" ]; then
    # shellcheck disable=SC2086
    adb shell input tap $coords
    return 0
  fi
  return 1
}

# (c) fallback tap by screen fraction (home layout fractions measured from
# the tag runs' home captures: PLAY row centre y=0.475, SETTINGS y=0.625).
tap_frac() { # $1 = x fraction, $2 = y fraction
  local wh w h x y
  wh="$(adb shell wm size 2>/dev/null | sed -n 's/.*: \([0-9]*\)x\([0-9]*\).*/\1 \2/p' | head -n 1)"
  w="$(printf '%s' "$wh" | awk '{print $1}')"; h="$(printf '%s' "$wh" | awk '{print $2}')"
  [ -n "$w" ] && [ -n "$h" ] || { w=1080; h=2400; }
  x="$(awk -v w="$w" -v f="$1" 'BEGIN{printf "%d", w*f}')"
  y="$(awk -v h="$h" -v f="$2" 'BEGIN{printf "%d", h*f}')"
  log "tap_frac: tapping ($x,$y) of ${w}x${h}"
  adb shell input tap "$x" "$y"
}

# (b) host ANR dismissal. Returns 0 always; sets app_anr=1 if the ANR is
# the app's own (lane must fail). Before/after captures are filed.
maybe_dismiss_anr() { # $1 = tag for capture names
  local tag="$1" f="$TMPD/anr-$1.xml"
  adb exec-out screencap -p > "$OUT/anr-$tag-before.png" 2>/dev/null || true
  if dump_ui "$f"; then
    if grep -q "isn.t responding" "$f"; then
      # The dialog is system-rendered either way; attribution is by the
      # process NAMED in its title text. Only "System UI isn't
      # responding" is the host's dialog (Amendment 2 class b). Any
      # other named process — in particular the app itself — fails.
      anr_title="$(python3 - "$f" <<'PY'
import re, sys
data = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
m = re.search(r'text="([^"]*isn.t responding[^"]*)"', data)
print(m.group(1) if m else "")
PY
)"
      log "anr: dialog title at checkpoint $tag: '$anr_title'"
      if [ "$anr_title" = "System UI isn’t responding" ] || [ "$anr_title" = "System UI isn't responding" ]; then
        log "anr: host System UI dialog; dismissing via Wait"
        tap_text "$f" "Wait" || tap_frac 0.66 0.54
        sleep 3
      else
        app_anr="1"
        log "anr: dialog NOT attributable to host System UI — lane must fail"
      fi
    else
      log "anr: no dialog present at checkpoint $tag"
    fi
  else
    log "anr: checkpoint $tag dump unavailable; proceeding"
  fi
  adb exec-out screencap -p > "$OUT/anr-$tag-after.png" 2>/dev/null || true
}

echo "== APK under test: $APK_PATH" | tee -a "$LANE_LOG"
adb wait-for-device
for _ in $(seq 1 60); do
  [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
  sleep 5
done

# --- Install the hash-verified sealed artefact on the fresh AVD ---
if [ -n "$APK_PATH" ] && [ -f "$APK_PATH" ] && adb install -r "$APK_PATH" > "$TMPD/install.log" 2>&1; then
  install_v="ok"
else
  cat "$TMPD/install.log" 2>/dev/null || true
fi

# --- Cold launch, timed ---
adb logcat -c >/dev/null 2>&1 || true
start_ms="$(date +%s%3N)"
am_out="$(adb shell am start -W -n "$ACT" 2>&1)"
end_ms="$(date +%s%3N)"
total_time="$(printf '%s' "$am_out" | sed -n 's/.*TotalTime: \([0-9]*\).*/\1/p' | head -n 1)"
if [ -n "$total_time" ]; then
  launch_ms_v="$total_time"
else
  launch_ms_v="$((end_ms - start_ms))"
fi
echo "== am start -W: $am_out" | tee -a "$LANE_LOG"

sleep 6
maybe_dismiss_anr "post-launch"

# --- Logcat: any FATAL EXCEPTION for this launch fails the run ---
adb logcat -d > "$OUT/logcat.txt" 2>&1 || true
if [ "$install_v" = "ok" ] && ! grep -q "FATAL EXCEPTION" "$OUT/logcat.txt"; then
  crash_v="0"
fi

# --- Home hierarchy: PLAY / WALLET / SETTINGS + rendered stamp ---
if dump_ui "$OUT/hierarchy-home.xml"; then
  if grep -q "PLAY" "$OUT/hierarchy-home.xml" \
     && grep -q "WALLET" "$OUT/hierarchy-home.xml" \
     && grep -q "SETTINGS" "$OUT/hierarchy-home.xml"; then
    home_nodes_v="PASS"
  fi
  if grep -q "v1.0.2" "$OUT/hierarchy-home.xml"; then
    stamps_v="PASS"
  fi
fi
adb exec-out screencap -p > "$OUT/home.png" 2>/dev/null || true

# --- Settings: stamp must render as "v1.0.2 (2)" in a produced dump ---
settings_ok="0"
if [ -f "$OUT/hierarchy-home.xml" ] && tap_text "$OUT/hierarchy-home.xml" "SETTINGS"; then
  log "nav: SETTINGS via dump bounds"
else
  log "nav: SETTINGS via fallback tap"
  tap_frac 0.5 0.625
fi
sleep 3
maybe_dismiss_anr "settings"
for s in 1 2 3; do
  if dump_ui "$OUT/hierarchy-settings-$s.xml" && grep -q "v1.0.2 (2)" "$OUT/hierarchy-settings-$s.xml"; then
    settings_ok="1"
    break
  fi
  log "settings: stamp not in dump $s; scrolling"
  adb shell input swipe 540 1800 540 900 300 >/dev/null 2>&1 || true
  sleep 2
done
if [ "$settings_ok" != "1" ]; then
  stamps_v="FAIL"
fi
adb exec-out screencap -p > "$OUT/settings.png" 2>/dev/null || true
adb shell input keyevent 4
sleep 2

# --- Front page: PLAY, wait for the WebView ---
if dump_ui "$OUT/hierarchy-home2.xml" && tap_text "$OUT/hierarchy-home2.xml" "PLAY"; then
  log "nav: PLAY via dump bounds"
else
  log "nav: PLAY via fallback tap"
  tap_frac 0.5 0.475
fi
sleep 5
maybe_dismiss_anr "frontpage"
if dump_ui "$OUT/hierarchy-frontpage.xml" && grep -q "android.webkit.WebView" "$OUT/hierarchy-frontpage.xml"; then
  frontpage_v="PASS"
fi
adb exec-out screencap -p > "$OUT/frontpage.png" 2>/dev/null || true
adb shell input keyevent 4
sleep 2

# --- Offline variant: radios off, relaunch, front page again ---
adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
adb shell svc wifi disable >/dev/null 2>&1 || true
adb shell svc data disable >/dev/null 2>&1 || true
sleep 2
adb shell am start -W -n "$ACT" >/dev/null 2>&1
sleep 6
maybe_dismiss_anr "offline"
off_ok="0"
if dump_ui "$OUT/hierarchy-offline-home.xml" && grep -q "PLAY" "$OUT/hierarchy-offline-home.xml"; then
  if tap_text "$OUT/hierarchy-offline-home.xml" "PLAY"; then
    log "nav: offline PLAY via dump bounds"
  else
    tap_frac 0.5 0.475
  fi
  sleep 5
  if dump_ui "$OUT/hierarchy-offline.xml" && grep -q "android.webkit.WebView" "$OUT/hierarchy-offline.xml"; then
    off_ok="1"
  fi
fi
if [ "$off_ok" = "1" ]; then
  offline_v="PASS"
fi
adb exec-out screencap -p > "$OUT/frontpage-offline.png" 2>/dev/null || true

# App-attributable ANR at any checkpoint fails the lane (Amendment 2 4.1b).
if [ "$app_anr" = "1" ]; then
  crash_v="FAIL"
  log "lane: failed on app-attributable ANR"
fi

# --- Verdict ---
{
  echo "install=$install_v"
  echo "launch_ms=$launch_ms_v"
  echo "crash_lines=$crash_v"
  echo "home_nodes=$home_nodes_v"
  echo "stamps=$stamps_v"
  echo "frontpage=$frontpage_v"
  echo "offline=$offline_v"
} > "$OUT/verdict.txt"
cat "$OUT/verdict.txt"

if [ "$install_v" != "ok" ] || [ "$crash_v" != "0" ] || [ "$launch_ms_v" = "FAIL" ] \
   || [ "$home_nodes_v" != "PASS" ] || [ "$stamps_v" != "PASS" ] \
   || [ "$frontpage_v" != "PASS" ] || [ "$offline_v" != "PASS" ]; then
  echo "verify-cold-run-m8a: FAIL"
  exit 1
fi
echo "verify-cold-run-m8a: PASS"
exit 0
