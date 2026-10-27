#!/usr/bin/env bash
# VOIDRUNNER corrected-shell cold-run proof (M8, build-lineage keeper pass 2026-10-27).
#
# Runs inside reactivecircus/android-emulator-runner on a fresh AVD
# (first-run, no-wallet state by construction). Installs the signed release
# APK, cold-launches it, and machine-checks: no crash lines in logcat, the
# home hierarchy carries PLAY / WALLET / SETTINGS + the rendered version
# stamp, Settings renders the name+code stamp, the bundled front page loads
# in the WebView after PLAY, and the front page still renders offline.
#
# Evidence lands in ./verify-evidence/ (uploaded by the workflow).
# verdict.txt lines: install / launch_ms / crash_lines / home_nodes /
# stamps / frontpage / offline — each =FAIL where failed.
# The script exits non-zero if any line is FAIL: a red job blocks the seal.
set -u

PKG="com.voidrunner.app"
ACT="com.voidrunner.app/.MainActivity"
OUT="verify-evidence"
TMPD="$(mktemp -d)"

APK_PATH="${APK_PATH:-}"
if [ -z "$APK_PATH" ]; then
  if [ -f "release-apk/app-release.apk" ]; then
    APK_PATH="release-apk/app-release.apk"
  else
    APK_PATH="$(find . -name 'app-release.apk' -not -path './verify-evidence/*' | head -n 1)"
  fi
fi

mkdir -p "$OUT"

install_v="FAIL"; launch_ms_v="FAIL"; crash_v="FAIL"
home_nodes_v="FAIL"; stamps_v="FAIL"; frontpage_v="FAIL"; offline_v="FAIL"

dump_ui() { # $1 = destination file
  adb shell uiautomator dump /sdcard/window_dump.xml >/dev/null 2>&1
  adb pull /sdcard/window_dump.xml "$1" >/dev/null 2>&1
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

echo "== APK under test: $APK_PATH"
adb wait-for-device
# Wait for the emulator to finish booting.
for _ in $(seq 1 60); do
  [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
  sleep 5
done

# --- Install on the fresh AVD (first-run state by construction) ---
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
echo "== am start -W: $am_out"

# Splash is 1.2s; give the home screen time to settle.
sleep 6

# --- Logcat: any FATAL EXCEPTION for this launch fails the run ---
adb logcat -d > "$OUT/logcat.txt" 2>&1 || true
if [ "$install_v" = "ok" ] && ! grep -q "FATAL EXCEPTION" "$OUT/logcat.txt"; then
  crash_v="0"
fi

# --- Home hierarchy: PLAY / WALLET / SETTINGS + rendered stamp ---
dump_ui "$OUT/hierarchy-home.xml"
if grep -q "PLAY" "$OUT/hierarchy-home.xml" \
   && grep -q "WALLET" "$OUT/hierarchy-home.xml" \
   && grep -q "SETTINGS" "$OUT/hierarchy-home.xml"; then
  home_nodes_v="ok"
fi
if grep -q "v1.0.2" "$OUT/hierarchy-home.xml"; then
  stamps_v="ok"
fi
adb exec-out screencap -p > "$OUT/home.png" 2>/dev/null || true

# --- Settings: stamp must render as "v1.0.2 (2)" ---
if tap_text "$OUT/hierarchy-home.xml" "SETTINGS"; then
  sleep 3
  dump_ui "$TMPD/hierarchy-settings.xml"
  if grep -q "v1.0.2 (2)" "$TMPD/hierarchy-settings.xml"; then
    : # stamps_v already requires the home stamp; settings form checked here
  else
    stamps_v="FAIL"
  fi
  adb exec-out screencap -p > "$OUT/settings.png" 2>/dev/null || true
  adb shell input keyevent 4
  sleep 2
else
  stamps_v="FAIL"
fi

# --- Front page: tap PLAY, wait for the WebView ---
dump_ui "$TMPD/hierarchy-home2.xml"
if tap_text "$TMPD/hierarchy-home2.xml" "PLAY"; then
  sleep 5
  dump_ui "$TMPD/hierarchy-frontpage.xml"
  if grep -q "android.webkit.WebView" "$TMPD/hierarchy-frontpage.xml"; then
    frontpage_v="ok"
  fi
  adb exec-out screencap -p > "$OUT/frontpage.png" 2>/dev/null || true
  adb shell input keyevent 4
  sleep 2
fi

# --- Offline variant: radios off, relaunch, front page again ---
adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
adb shell svc wifi disable >/dev/null 2>&1 || true
adb shell svc data disable >/dev/null 2>&1 || true
sleep 2
adb shell am start -W -n "$ACT" >/dev/null 2>&1
sleep 6
dump_ui "$TMPD/hierarchy-offline-home.xml"
if grep -q "PLAY" "$TMPD/hierarchy-offline-home.xml" \
   && tap_text "$TMPD/hierarchy-offline-home.xml" "PLAY"; then
  sleep 5
  dump_ui "$OUT/hierarchy-offline.xml"
  if grep -q "android.webkit.WebView" "$OUT/hierarchy-offline.xml"; then
    offline_v="ok"
  fi
  adb exec-out screencap -p > "$OUT/frontpage-offline.png" 2>/dev/null || true
else
  # Still emit the offline artefacts so the evidence shows the failure state.
  dump_ui "$OUT/hierarchy-offline.xml"
  adb exec-out screencap -p > "$OUT/frontpage-offline.png" 2>/dev/null || true
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

if grep -q "=FAIL" "$OUT/verdict.txt" || [ "$crash_v" != "0" ] || [ "$launch_ms_v" = "FAIL" ]; then
  echo "verify-cold-run: FAIL"
  exit 1
fi
echo "verify-cold-run: PASS"
exit 0
