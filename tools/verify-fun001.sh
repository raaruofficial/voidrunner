#!/usr/bin/env bash
# VOIDRUNNER — FUN-001 runtime verification lane (estate directive, 2026-10-29).
#
# Runtime evidence only. Solana Mobile reviewers reported a HARD native
# crash class in the sibling app ORE HAUNT (system "<app> has stopped"
# dialog on first launch after install; ejection to the device home screen
# on ANY menu interaction) that static analysis did not find. This lane
# cold-runs the SEALED v1.0.3 artefact (sha256-verified by the workflow
# before install) through the reproduction matrix:
#
#   Phase A — fresh install, first launch: reaches home, no crash dialog,
#             no process death, no app FATAL EXCEPTION.
#   Phase B — menu sweep in on-screen order (PLAY -> game/WebView,
#             WALLET, SETTINGS): no ejection to launcher, no death,
#             expected screen content rendered on each destination.
#   Phase C — WebView provider disabled: relaunch + PLAY; record the
#             exact behaviour (graceful vs crash + verbatim stack).
#
# FUN001_PHASES selects phases (default ABC; the low-RAM and API-span
# lanes run AB). FUN001_OUT selects the evidence directory.
# The dump/ANR hardening (uiautomator retry budget, host "System UI isn't
# responding" dismissal with attribution, fraction-tap fallback navigation)
# is carried over from tools/verify-cold-run-m8a.sh (JUDGE Amendment 2).
# An ANR or crash dialog naming com.voidrunner.app itself is NEVER
# dismissed as a host artifact — it is recorded as a finding.
set -u

PKG="com.voidrunner.app"
ACT="com.voidrunner.app/.MainActivity"
OUT="${FUN001_OUT:-fun001-evidence}"
PHASES="${FUN001_PHASES:-ABC}"
TMPD="$(mktemp -d)"
LANE_LOG="$OUT/fun001-lane.log"

APK_PATH="${APK_PATH:-}"
if [ -z "$APK_PATH" ] && [ -f "artefact/app-release.apk" ]; then
  APK_PATH="artefact/app-release.apk"
fi

mkdir -p "$OUT"
: > "$LANE_LOG"
log() { echo "$*" | tee -a "$LANE_LOG"; }

# --- verdict state -----------------------------------------------------------
install_v="NOT-RUN"; first_launch_v="NOT-RUN"; dialog_first_v="unknown"
play_v="NOT-RUN"; wallet_v="NOT-RUN"; settings_v="NOT-RUN"
webview_v="NOT-RUN"; wallet_interaction_v="NOT-RUN"; game_bridge_v="NOT-RUN"
app_anr="0"; fatal_total="0"; death_total="0"

# --- helpers (carried from verify-cold-run-m8a.sh) ---------------------------
dump_is_substantive() { # rejects hollow mid-transition dumps (window present,
  # view tree not yet attached): a 1-node dump with no text, no content-desc
  # and no WebView node is a race artifact, not a screen. (Observed
  # 2026-10-29: Phase A first-launch dump = exactly 1 node, text="".)
  python3 - "$1" <<'PY'
import re, sys
data = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
nodes = re.findall(r"<node[^>]*>", data)
if len(nodes) >= 3:
    sys.exit(0)
for n in nodes:
    if re.search(r'text="[^"]+"', n) or re.search(r'content-desc="[^"]+"', n) or "WebView" in n:
        sys.exit(0)
sys.exit(1)
PY
}

dump_ui() { # $1 = destination file; success = complete hierarchy produced
  local dst="$1" attempt
  for attempt in 1 2 3 4 5 6 7 8; do
    adb shell rm -f /sdcard/window_dump.xml >/dev/null 2>&1 || true
    timeout 40 adb shell uiautomator dump /sdcard/window_dump.xml >/dev/null 2>&1 || true
    adb exec-out cat /sdcard/window_dump.xml > "$dst.tmp" 2>/dev/null || true
    if grep -q "</hierarchy>" "$dst.tmp" 2>/dev/null && dump_is_substantive "$dst.tmp"; then
      mv "$dst.tmp" "$dst"
      log "dump_ui: ok on attempt $attempt -> $dst"
      return 0
    fi
    log "dump_ui: attempt $attempt produced no complete/substantive hierarchy; waiting"
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

tap_frac() { # $1 = x fraction, $2 = y fraction (home fractions from prior lanes)
  local wh w h x y
  wh="$(adb shell wm size 2>/dev/null | sed -n 's/.*: \([0-9]*\)x\([0-9]*\).*/\1 \2/p' | head -n 1)"
  w="$(printf '%s' "$wh" | awk '{print $1}')"; h="$(printf '%s' "$wh" | awk '{print $2}')"
  [ -n "$w" ] && [ -n "$h" ] || { w=1080; h=2400; }
  x="$(awk -v w="$w" -v f="$1" 'BEGIN{printf "%d", w*f}')"
  y="$(awk -v h="$h" -v f="$2" 'BEGIN{printf "%d", h*f}')"
  log "tap_frac: tapping ($x,$y) of ${w}x${h}"
  adb shell input tap "$x" "$y"
}

maybe_dismiss_anr() { # $1 = checkpoint tag; dismisses ONLY the host System UI dialog
  local tag="$1" f="$TMPD/anr-$1.xml"
  adb exec-out screencap -p > "$OUT/anr-$tag-before.png" 2>/dev/null || true
  if dump_ui "$f"; then
    if grep -q "isn.t responding" "$f"; then
      anr_title="$(python3 - "$f" <<'PY'
import re, sys
data = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
m = re.search(r'text="([^"]*isn.t responding[^"]*)"', data)
print(m.group(1) if m else "")
PY
)"
      log "anr: dialog title at checkpoint $tag: '$anr_title'"
      if [ "$anr_title" = "System UI isn’t responding" ] || [ "$anr_title" = "System UI isn't responding" ] \
        || [ "$anr_title" = "Pixel Launcher isn’t responding" ] || [ "$anr_title" = "Pixel Launcher isn't responding" ]; then
        log "anr: host dialog ('$anr_title' — emulator image component, not $PKG); dismissing via Wait"
        tap_text "$f" "Wait" || tap_frac 0.66 0.54
        sleep 3
      else
        app_anr="1"
        log "anr: dialog NOT attributable to host System UI — recorded as finding"
      fi
    else
      log "anr: no dialog present at checkpoint $tag"
    fi
  else
    log "anr: checkpoint $tag dump unavailable; proceeding"
  fi
  adb exec-out screencap -p > "$OUT/anr-$tag-after.png" 2>/dev/null || true
}

# --- FUN-001-specific helpers --------------------------------------------------
pid_alive() { [ -n "$(adb shell pidof "$PKG" 2>/dev/null | tr -d '\r')" ]; }

fg_pkg() { # foreground package, best-effort
  local f
  f="$(adb shell dumpsys window windows 2>/dev/null | sed -n 's/.*mCurrentFocus=Window{[^ ]* [^ ]* \([^/]*\)\/.*/\1/p' | head -n 1 | tr -d '\r')"
  if [ -z "$f" ]; then
    f="$(adb shell dumpsys activity activities 2>/dev/null | sed -n 's/.*topResumedActivity=ActivityRecord{[^ ]* [^ ]* \([^/]*\)\/.*/\1/p' | head -n 1 | tr -d '\r')"
  fi
  printf '%s' "$f"
}

has_stopped_dialog() { # $1 = hierarchy file
  grep -q "has stopped" "$1" 2>/dev/null || grep -q "keeps stopping" "$1" 2>/dev/null
}

count_app_crashes() { # $1 = logcat file; updates fatal_total / death_total
  local f="$1" n d
  n="$(grep -A3 "FATAL EXCEPTION" "$f" 2>/dev/null | grep -c "Process: $PKG" || true)"
  d="$(grep -c "Process $PKG (pid" "$f" 2>/dev/null || true)"
  fatal_total=$((fatal_total + ${n:-0}))
  death_total=$((death_total + ${d:-0}))
  log "crashes: file=$f app_fatal_blocks=${n:-0} process_death_lines=${d:-0}"
}

extract_stacks() { # $1 = logcat file, $2 = output file
  awk '/FATAL EXCEPTION/{c=60} c&&c--' "$1" > "$2" 2>/dev/null || true
}

back_home() { # press Back until the home hierarchy (PLAY+SETTINGS) is produced
  local i
  for i in 1 2 3 4; do
    if dump_ui "$TMPD/probe-home.xml" && grep -q "PLAY" "$TMPD/probe-home.xml" && grep -q "SETTINGS" "$TMPD/probe-home.xml"; then
      log "back_home: home reached after $((i-1)) back presses"
      return 0
    fi
    adb shell input keyevent 4 >/dev/null 2>&1 || true
    sleep 2
  done
  if dump_ui "$TMPD/probe-home.xml" && grep -q "PLAY" "$TMPD/probe-home.xml"; then
    return 0
  fi
  log "back_home: FAILED to return to a recognisable home screen"
  return 1
}

# --- device record -------------------------------------------------------------
adb wait-for-device
for _ in $(seq 1 60); do
  [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
  sleep 5
done
{
  echo "sdk=$(adb shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
  echo "release=$(adb shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')"
  echo "model=$(adb shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
  echo "device=$(adb shell getprop ro.product.device 2>/dev/null | tr -d '\r')"
  echo "meminfo=$(adb shell cat /proc/meminfo 2>/dev/null | head -n 1 | tr -d '\r')"
  echo "phases=$PHASES"
  echo "apk_path=$APK_PATH"
} > "$OUT/device-info.txt"
cat "$OUT/device-info.txt" | tee -a "$LANE_LOG"
echo "== APK under test: $APK_PATH" | tee -a "$LANE_LOG"

# === Phase A — fresh install + first launch ====================================
if [ "${PHASES#*A}" != "$PHASES" ]; then
  adb uninstall "$PKG" >/dev/null 2>&1 || true
  if [ -n "$APK_PATH" ] && [ -f "$APK_PATH" ] && adb install "$APK_PATH" > "$TMPD/install.log" 2>&1; then
    install_v="ok"
  else
    install_v="FAIL"
    cat "$TMPD/install.log" 2>/dev/null | tee -a "$LANE_LOG" || true
  fi
  log "phaseA: install=$install_v"

  if [ "$install_v" = "ok" ]; then
    adb logcat -c >/dev/null 2>&1 || true
    am_out="$(adb shell am start -W -n "$ACT" 2>&1)"
    echo "== am start -W: $am_out" | tee -a "$LANE_LOG"
    sleep 9
    maybe_dismiss_anr "first-launch"
    adb logcat -d > "$OUT/logcat-phaseA.txt" 2>&1 || true
    count_app_crashes "$OUT/logcat-phaseA.txt"
    extract_stacks "$OUT/logcat-phaseA.txt" "$OUT/stacks-phaseA.txt"

    a_ok="1"
    pid_alive || { a_ok="0"; log "phaseA: process NOT alive after first launch"; }
    if dump_ui "$OUT/hierarchy-first-launch.xml"; then
      if has_stopped_dialog "$OUT/hierarchy-first-launch.xml"; then
        dialog_first_v="yes"; a_ok="0"
        log "phaseA: 'has stopped' crash dialog PRESENT on first launch"
      else
        dialog_first_v="no"
      fi
      grep -q "PLAY" "$OUT/hierarchy-first-launch.xml" \
        && grep -q "WALLET" "$OUT/hierarchy-first-launch.xml" \
        && grep -q "SETTINGS" "$OUT/hierarchy-first-launch.xml" \
        || { a_ok="0"; log "phaseA: home menu nodes incomplete in hierarchy"; }
    else
      a_ok="0"; log "phaseA: no hierarchy produced"
    fi
    [ "$app_anr" = "1" ] && a_ok="0"
    grep -A3 "FATAL EXCEPTION" "$OUT/logcat-phaseA.txt" 2>/dev/null | grep -q "Process: $PKG" && a_ok="0"
    adb exec-out screencap -p > "$OUT/first-launch.png" 2>/dev/null || true
    if [ "$a_ok" = "1" ]; then first_launch_v="PASS"; else first_launch_v="FAIL"; fi
    log "phaseA: first_launch=$first_launch_v dialog=$dialog_first_v"
  fi
fi

# === Phase B — menu sweep in on-screen order: PLAY, WALLET, SETTINGS ==========
sweep_one() { # $1 key, $2 menu text, $3 expect regex, $4 fallback y-frac, $5 settle secs
  local key="$1" text="$2" expect="$3" yfrac="$4" settle="$5"
  local res="FAIL" why=""
  if ! pid_alive; then log "sweep $key: process dead before tap"; echo "FAIL" > "$TMPD/verdict-$key.txt"; return; fi
  if dump_ui "$OUT/hier-before-$key.xml" && tap_text "$OUT/hier-before-$key.xml" "$text"; then
    log "sweep $key: tapped '$text' via dump bounds"
  else
    log "sweep $key: tapped '$text' via fallback fraction"
    tap_frac 0.5 "$yfrac"
  fi
  sleep "$settle"
  maybe_dismiss_anr "sweep-$key"
  adb logcat -d > "$OUT/logcat-sweep-$key.txt" 2>&1 || true
  if ! pid_alive; then why="process dead after tap"; fi
  if dump_ui "$OUT/hier-$key.xml"; then
    if has_stopped_dialog "$OUT/hier-$key.xml"; then why="$why crash-dialog present;"; fi
    if ! grep -q "$expect" "$OUT/hier-$key.xml"; then why="$why expected content /$expect/ not in hierarchy;"; fi
  else
    why="$why no hierarchy produced;"
  fi
  fg="$(fg_pkg)"
  log "sweep $key: foreground after tap = '$fg'"
  if [ -n "$fg" ] && [ "$fg" != "$PKG" ]; then why="$why ejected: foreground=$fg;"; fi
  [ "$app_anr" = "1" ] && why="$why app ANR recorded;"
  adb exec-out screencap -p > "$OUT/sweep-$key.png" 2>/dev/null || true
  if [ -z "$why" ]; then res="PASS"; fi
  log "sweep $key: verdict=$res ($why)"
  back_home || log "sweep $key: could not return home after sweep step"
  sleep 2
  echo "$res" > "$TMPD/verdict-$key.txt"
}

if [ "${PHASES#*B}" != "$PHASES" ] && [ "$install_v" = "ok" ]; then
  back_home || true
  sweep_one play "PLAY" "android.webkit.WebView" 0.475 10
  play_v="$(cat "$TMPD/verdict-play.txt" 2>/dev/null || echo FAIL)"
  sweep_one wallet "WALLET" "CONNECT WALLET" 0.55 5
  wallet_v="$(cat "$TMPD/verdict-wallet.txt" 2>/dev/null || echo FAIL)"
  sweep_one settings "SETTINGS" "${FUN001_VERSION_STAMP:-v1.0.3 (3)}" 0.625 5
  settings_v="$(cat "$TMPD/verdict-settings.txt" 2>/dev/null || echo FAIL)"
  adb logcat -d > "$OUT/logcat-phaseB-final.txt" 2>&1 || true
  count_app_crashes "$OUT/logcat-phaseB-final.txt"
fi

# === Phase C — WebView provider disabled =======================================
if [ "${PHASES#*C}" != "$PHASES" ] && [ "$install_v" = "ok" ]; then
  # Target the ACTUAL WebView provider package (from dumpsys), never a
  # webview-named overlay: the v1.0.4 battery's first Phase C attempt
  # disabled com.google.android.overlay.googlewebview and the real
  # provider (com.google.android.webview) stayed active throughout.
  wv_pkg="$(adb shell dumpsys webviewupdate 2>/dev/null | sed -n 's/.*Current WebView package (name, version): (\([^,]*\),.*/\1/p' | head -n 1 | tr -d '\r')"
  if [ -z "$wv_pkg" ]; then
    wv_pkg="$(adb shell pm list packages 2>/dev/null | tr -d '\r' | sed -n 's/^package://p' | grep -x "com.google.android.webview" | head -n 1)"
  fi
  {
    echo "webview_packages:"
    adb shell pm list packages 2>/dev/null | tr -d '\r' | grep -i webview || true
    echo "current_provider:"
    adb shell cmd webviewupdate getCurrentWebViewPackage 2>&1 | tr -d '\r' || true
    adb shell dumpsys webviewupdate 2>/dev/null | head -n 20 || true
  } > "$OUT/webview-provider-before.txt"
  log "phaseC: provider package candidate = '$wv_pkg'"

  disabled_ok="0"
  if [ -n "$wv_pkg" ]; then
    # Escalation ladder (r2 evidence, 2026-10-29): `pm disable` from the
    # shell throws SecurityException on this package; `pm disable-user`
    # reports 'disabled-user' but WebViewUpdateService keeps the sole
    # provider current anyway. Escalate: hide, then uninstall-for-user-0.
    # Success is judged ONLY by the dumpsys current-provider check below.
    adb shell pm disable "$wv_pkg" > "$TMPD/wv-disable.log" 2>&1 || true
    adb shell pm disable-user --user 0 "$wv_pkg" >> "$TMPD/wv-disable.log" 2>&1 || true
    sleep 3
    cur_try="$(adb shell dumpsys webviewupdate 2>/dev/null | sed -n 's/.*Current WebView package (name, version): (\([^,]*\),.*/\1/p' | head -n 1 | tr -d '\r')"
    if [ "$cur_try" = "$wv_pkg" ]; then
      echo "escalating: pm hide" >> "$TMPD/wv-disable.log"
      adb shell pm hide "$wv_pkg" >> "$TMPD/wv-disable.log" 2>&1 || true
      sleep 3
      cur_try="$(adb shell dumpsys webviewupdate 2>/dev/null | sed -n 's/.*Current WebView package (name, version): (\([^,]*\),.*/\1/p' | head -n 1 | tr -d '\r')"
    fi
    if [ "$cur_try" = "$wv_pkg" ]; then
      echo "escalating: pm uninstall --user 0" >> "$TMPD/wv-disable.log"
      adb shell pm uninstall --user 0 "$wv_pkg" >> "$TMPD/wv-disable.log" 2>&1 || true
      sleep 3
    fi
    cat "$TMPD/wv-disable.log" | tee -a "$LANE_LOG" || true
    {
      echo "after disable attempts:"
      adb shell cmd webviewupdate getCurrentWebViewPackage 2>&1 | tr -d '\r' || true
      adb shell dumpsys webviewupdate 2>/dev/null | head -n 20 || true
      adb shell pm list packages -d 2>/dev/null | tr -d '\r' | grep -i webview || true
    } > "$OUT/webview-provider-after-disable.txt"
    wv_dump_after="$(adb shell dumpsys webviewupdate 2>/dev/null)"
    cur_after="$(printf '%s' "$wv_dump_after" | sed -n 's/.*Current WebView package (name, version): (\([^,]*\),.*/\1/p' | head -n 1 | tr -d '\r')"
    log "phaseC: current provider after disable attempts = '$cur_after' (target was '$wv_pkg')"
    # Removal is verified by EITHER signal (r3 evidence, 2026-10-29):
    # after `pm uninstall --user 0` succeeded, the service's header kept
    # NAMING the package as 'current' (stale last-known state) while its
    # own validity line flipped to 'is NOT installed/enabled for all
    # users' — the validity line is the operative fact. Accept either.
    if [ -n "$wv_pkg" ] && [ "$cur_after" != "$wv_pkg" ]; then
      disabled_ok="1"
    fi
    if printf '%s' "$wv_dump_after" | grep "Valid package $wv_pkg" | grep -q "NOT installed/enabled"; then
      log "phaseC: dumpsys validity line confirms $wv_pkg is NOT installed/enabled for all users"
      disabled_ok="1"
    fi
  fi
  log "phaseC: provider disabled = $disabled_ok"

  if [ "$disabled_ok" = "1" ]; then
    adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
    adb logcat -c >/dev/null 2>&1 || true
    adb shell am start -W -n "$ACT" >/dev/null 2>&1 || true
    sleep 8
    maybe_dismiss_anr "webview-disabled-launch"
    c_home="0"
    if back_home; then c_home="1"; fi
    log "phaseC: home reachable with provider disabled = $c_home"
    # Settle loop: the host Pixel Launcher ANR dialog recurs on this
    # image and covered EVERY dump in r5 — PLAY was fraction-tapped
    # blind and the leg's observation was contaminated. Require a dump
    # that actually shows the app's home menu before tapping, and tap
    # PLAY by bounds only; otherwise the leg is NOT-RUN, never guessed.
    play_tapped="0"
    for try in 1 2 3 4 5 6; do
      if dump_ui "$OUT/hier-wv-home.xml" && grep -q "PLAY" "$OUT/hier-wv-home.xml" && grep -q "WALLET" "$OUT/hier-wv-home.xml"; then
        if tap_text "$OUT/hier-wv-home.xml" "PLAY"; then
          play_tapped="1"
          log "phaseC: tapped PLAY via dump bounds (settle try $try)"
          break
        fi
      fi
      maybe_dismiss_anr "webview-disabled-settle-$try"
      sleep 3
    done
    if [ "$play_tapped" != "1" ]; then
      webview_v="NOT-RUN(home menu never cleanly observable — host launcher ANR dialog covered every dump; provider removal itself was verified)"
      log "phaseC: $webview_v"
      adb shell pm enable "$wv_pkg" >/dev/null 2>&1 || true
      adb shell cmd package install-existing "$wv_pkg" >/dev/null 2>&1 || true
    fi
    if [ "$play_tapped" = "1" ]; then
    sleep 7
    maybe_dismiss_anr "webview-disabled-postplay"
    adb logcat -d > "$OUT/logcat-webview-disabled.txt" 2>&1 || true
    count_app_crashes "$OUT/logcat-webview-disabled.txt"
    extract_stacks "$OUT/logcat-webview-disabled.txt" "$OUT/stacks-webview-disabled.txt"
    adb exec-out screencap -p > "$OUT/webview-disabled.png" 2>/dev/null || true
    dump_ui "$OUT/hier-webview-disabled.xml" || true

    if [ -f "$OUT/hier-webview-disabled.xml" ] && grep -q "isn.t responding" "$OUT/hier-webview-disabled.xml"; then
      webview_v="NOT-RUN(post-PLAY hierarchy still covered by the host ANR dialog — observation contaminated, see evidence)"
    elif grep -A3 "FATAL EXCEPTION" "$OUT/logcat-webview-disabled.txt" 2>/dev/null | grep -q "Process: $PKG"; then
      webview_v="CRASH(app FATAL EXCEPTION with provider disabled — see stacks-webview-disabled.txt)"
    elif ! pid_alive; then
      webview_v="CRASH(process dead after PLAY with provider disabled)"
    elif [ -f "$OUT/hier-webview-disabled.xml" ] && has_stopped_dialog "$OUT/hier-webview-disabled.xml"; then
      webview_v="CRASH('has stopped' dialog with provider disabled)"
    elif [ -f "$OUT/hier-webview-disabled.xml" ] && grep -q "android.webkit.WebView" "$OUT/hier-webview-disabled.xml"; then
      webview_v="NOT-RUN(provider still active — WebView rendered despite disable)"
    elif pid_alive; then
      webview_v="GRACEFUL(no crash, no WebView node, process alive)"
    else
      webview_v="INDETERMINATE(see phase C evidence)"
    fi
    adb shell pm enable "$wv_pkg" >/dev/null 2>&1 || true
    adb shell cmd package install-existing "$wv_pkg" >/dev/null 2>&1 || true
    log "phaseC: provider re-enabled; verdict=$webview_v"
    fi
  else
    webview_v="NOT-RUN(could not disable WebView provider '$wv_pkg' — see webview-provider-*.txt)"
    log "phaseC: $webview_v"
  fi
fi

# === Phase W — wallet interaction: CONNECT WALLET tap ==========================
# The estate's device-proved crash class (Paper Moon v0.2.4): constructing
# the MWA clientlib ActivityResultSender while the activity lifecycle is
# RESUMED throws IllegalStateException from ActivityResultRegistry.register
# ("LifecycleOwners must call register before they are STARTED"). VOIDRUNNER
# constructs ActivityResultSender(activity) at event time — inside the
# CONNECT WALLET / TRY AGAIN click handlers (WalletScreen) and inside the
# WebView bridge calls — never in onCreate. Navigation alone (Phase B)
# cannot reach those sites; this phase taps CONNECT WALLET on a wallet-less
# emulator: if construction throws, the process dies BEFORE any wallet is
# needed; if construction succeeds, MWA connect fails soft into the app's
# own Error/Working state with the process alive.
if [ "${PHASES#*W}" != "$PHASES" ] && [ "$install_v" = "ok" ]; then
  if ! pid_alive; then
    log "phaseW: process not alive at phase start; relaunching"
    adb shell am start -W -n "$ACT" >/dev/null 2>&1 || true
    sleep 8
  fi
  back_home || true
  if dump_ui "$OUT/hier-w-before.xml" && tap_text "$OUT/hier-w-before.xml" "WALLET"; then
    log "phaseW: tapped WALLET via dump bounds"
  else
    log "phaseW: tapped WALLET via fallback fraction"
    tap_frac 0.5 0.55
  fi
  sleep 5
  adb logcat -c >/dev/null 2>&1 || true
  if dump_ui "$OUT/hier-w-wallet.xml" && tap_text "$OUT/hier-w-wallet.xml" "CONNECT WALLET"; then
    log "phaseW: tapped CONNECT WALLET via dump bounds"
  else
    log "phaseW: CONNECT WALLET not tappable from a produced dump"
  fi
  sleep 7
  maybe_dismiss_anr "phaseW"
  adb logcat -d > "$OUT/logcat-phaseW.txt" 2>&1 || true
  count_app_crashes "$OUT/logcat-phaseW.txt"
  extract_stacks "$OUT/logcat-phaseW.txt" "$OUT/stacks-phaseW.txt"
  adb exec-out screencap -p > "$OUT/phaseW-after-connect.png" 2>/dev/null || true
  dump_ui "$OUT/hier-w-after.xml" || true
  if grep -A3 "FATAL EXCEPTION" "$OUT/logcat-phaseW.txt" 2>/dev/null | grep -q "Process: $PKG"; then
    wallet_interaction_v="CRASH(app FATAL EXCEPTION after CONNECT WALLET tap — see stacks-phaseW.txt)"
  elif ! pid_alive; then
    wallet_interaction_v="CRASH(process dead after CONNECT WALLET tap)"
  elif [ -f "$OUT/hier-w-after.xml" ] && has_stopped_dialog "$OUT/hier-w-after.xml"; then
    wallet_interaction_v="CRASH('has stopped' dialog after CONNECT WALLET tap)"
  elif [ -f "$OUT/hier-w-after.xml" ] && grep -qE "TRY AGAIN|Waiting for wallet" "$OUT/hier-w-after.xml"; then
    wallet_interaction_v="NO_CRASH(reached post-tap wallet state)"
  elif pid_alive; then
    wallet_interaction_v="NO_CRASH(process alive after CONNECT WALLET tap; see hier-w-after.xml)"
  else
    wallet_interaction_v="INDETERMINATE(see phase W evidence)"
  fi
  log "phaseW: wallet_interaction=$wallet_interaction_v"
fi

# === Phase G — bridge path: in-game wallet action from the WebView =============
# VoidrunnerWalletBridge constructs ActivityResultSender(activity) inline
# inside its @JavascriptInterface methods (connect :69, signMessage :88,
# signAndSendTransactions :113), evaluated when the hosted game invokes
# them — activity RESUMED, same registration-throw class as Phase W.
# Instrument: enter PLAY, let the live game load, find an actionable
# wallet/bind/connect node in the WebView accessibility hierarchy and tap
# it. If no such node is exposed, the phase is NOT-RUN with the dumps
# filed — no blind taps are reported as bridge evidence. The node text
# actually tapped is logged verbatim for honesty.
if [ "${PHASES#*G}" != "$PHASES" ] && [ "$install_v" = "ok" ]; then
  if ! pid_alive; then
    log "phaseG: process not alive at phase start; relaunching"
    adb shell am start -W -n "$ACT" >/dev/null 2>&1 || true
    sleep 8
  fi
  back_home || true
  adb logcat -c >/dev/null 2>&1 || true
  if dump_ui "$OUT/hier-g-home.xml" && tap_text "$OUT/hier-g-home.xml" "PLAY"; then
    log "phaseG: tapped PLAY via dump bounds"
  else
    log "phaseG: tapped PLAY via fallback fraction"
    tap_frac 0.5 0.475
  fi
  sleep 12
  find_wallet_node() { # $1 = hierarchy file; prints "x y text" for first match
    python3 - "$1" <<'PY'
import re, sys
data = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
prio = ["CONNECT", "BIND", "SIGN", "WALLET", "LINK"]
nodes = []
for m in re.finditer(r'<node[^>]*>', data):
    tag = m.group(0)
    t = re.search(r'text="([^"]*)"', tag)
    d = re.search(r'content-desc="([^"]*)"', tag)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
    if not b:
        continue
    label = ((t.group(1) if t else "") + " " + (d.group(1) if d else "")).strip()
    if not label:
        continue
    up = label.upper()
    for i, kw in enumerate(prio):
        if kw in up:
            x = (int(b.group(1)) + int(b.group(3))) // 2
            y = (int(b.group(2)) + int(b.group(4))) // 2
            nodes.append((i, x, y, label))
            break
nodes.sort()
if nodes:
    _, x, y, label = nodes[0]
    print(f"{x} {y} {label}")
PY
  }
  tapped_node=""
  for attempt in 1 2; do
    if dump_ui "$OUT/hier-g-game-$attempt.xml"; then
      found="$(find_wallet_node "$OUT/hier-g-game-$attempt.xml")"
      if [ -n "$found" ]; then
        coords="$(printf '%s' "$found" | awk '{print $1, $2}')"
        tapped_node="$(printf '%s' "$found" | cut -d' ' -f3-)"
        log "phaseG: tapping in-game node '$tapped_node' at $coords (attempt $attempt)"
        # shellcheck disable=SC2086
        adb shell input tap $coords
        break
      fi
    fi
    log "phaseG: no wallet-action node in dump $attempt; nudging game with centre tap"
    adb exec-out screencap -p > "$OUT/g-game-$attempt.png" 2>/dev/null || true
    tap_frac 0.5 0.5
    sleep 8
  done
  if [ -n "$tapped_node" ]; then
    sleep 8
    maybe_dismiss_anr "phaseG"
    adb logcat -d > "$OUT/logcat-phaseG.txt" 2>&1 || true
    count_app_crashes "$OUT/logcat-phaseG.txt"
    extract_stacks "$OUT/logcat-phaseG.txt" "$OUT/stacks-phaseG.txt"
    adb exec-out screencap -p > "$OUT/g-after-tap.png" 2>/dev/null || true
    dump_ui "$OUT/hier-g-after.xml" || true
    if grep -A3 "FATAL EXCEPTION" "$OUT/logcat-phaseG.txt" 2>/dev/null | grep -q "Process: $PKG"; then
      game_bridge_v="CRASH(app FATAL EXCEPTION after in-game node '$tapped_node' tap — see stacks-phaseG.txt)"
    elif ! pid_alive; then
      game_bridge_v="CRASH(process dead after in-game node '$tapped_node' tap)"
    elif [ -f "$OUT/hier-g-after.xml" ] && has_stopped_dialog "$OUT/hier-g-after.xml"; then
      game_bridge_v="CRASH('has stopped' dialog after in-game node '$tapped_node' tap)"
    elif pid_alive; then
      game_bridge_v="NO_CRASH(process alive after in-game node '$tapped_node' tap; see hier-g-after.xml)"
    else
      game_bridge_v="INDETERMINATE(see phase G evidence)"
    fi
  else
    adb logcat -d > "$OUT/logcat-phaseG.txt" 2>&1 || true
    adb exec-out screencap -p > "$OUT/g-final.png" 2>/dev/null || true
    game_bridge_v="NOT-RUN(no wallet-action node exposed in WebView hierarchy; see hier-g-game-*.xml)"
  fi
  log "phaseG: game_bridge=$game_bridge_v"
fi

# === Verdict ====================================================================
adb logcat -d > "$OUT/logcat-final.txt" 2>&1 || true
{
  echo "install=$install_v"
  echo "first_launch=$first_launch_v"
  echo "crash_dialog_first_launch=$dialog_first_v"
  echo "menu_play=$play_v"
  echo "menu_wallet=$wallet_v"
  echo "menu_settings=$settings_v"
  echo "webview_disabled=$webview_v"
  echo "wallet_interaction=$wallet_interaction_v"
  echo "game_bridge=$game_bridge_v"
  echo "app_fatal_blocks_total=$fatal_total"
  echo "process_death_lines_total=$death_total"
} > "$OUT/verdict.txt"
cat "$OUT/verdict.txt"

fail="0"
[ "$install_v" != "ok" ] && [ "$install_v" != "NOT-RUN" ] && fail="1"
[ "$first_launch_v" = "FAIL" ] && fail="1"
[ "$play_v" = "FAIL" ] && fail="1"
[ "$wallet_v" = "FAIL" ] && fail="1"
[ "$settings_v" = "FAIL" ] && fail="1"
case "$webview_v" in CRASH*) fail="1";; esac
case "$wallet_interaction_v" in CRASH*) fail="1";; esac
case "$game_bridge_v" in CRASH*) fail="1";; esac
if [ "$fail" = "1" ]; then
  echo "verify-fun001: FAIL (see verdict.txt)"
  exit 1
fi
echo "verify-fun001: PASS"
exit 0
