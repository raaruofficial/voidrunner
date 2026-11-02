#!/usr/bin/env bash
# VOIDRUNNER v1.0.13 cure — GATE CELL driver (CURE_PLAN §2, R-1 / R-2).
#
# The reviewer flow verbatim: fresh launch → PLAY → the .skr gate →
# fixture handle → SIGN IN → the gate's wallet action ("Link my
# wallet" in bind mode / "Prove it's you" in proof mode) → the Mock
# MWA Wallet FOREGROUNDS → approve its sheet → completion asserted by
# SERVER STATE (a runner-side /actions signIn read-back against
# ORIGIN: bind_required before the bind rep, proof_required after
# it — the transition exists only if completeBind persisted the
# binding). ORIGIN is the production origin in server-mode=production
# and the on-runner STAGING composition (production server bundle,
# registry seam stubbed for the fixture handle) in
# server-mode=staging — the owner's 2026-11-01 composition ruling;
# this driver is identical in both modes.
#
# Modes (GATE_MODE):
#   r1 — the cured candidate: candidate served bytes (via the
#        gate-suite serving rig at the production hostname) + the
#        v1.0.13 APK. Two reps in one run: rep 1 bind, rep 2 proof
#        (after pm clear). PASS: wallet_foreground_seen=yes in BOTH
#        reps, zero failure copies, read-back transition observed.
#   r2 — negative control: PRODUCTION (faulted) served bytes via the
#        same rig + the v1.0.12 APK (the rejected composition).
#        PASS = the diagnosis signature reproduces: a wallet failure
#        copy (Mb family) appears, the wallet NEVER foregrounds, and
#        the read-back still shows bind_required (nothing bound).
#
# Env (set by the gate-suite action):
#   VR_APK        path to the hash-verified APK under test
#   MOCK_APK      path to the Mock MWA Wallet APK
#   GATE_HANDLE   lane-designated fixture handle, full form (name.skr)
#   GATE_MODE     r1 | r2
#   ORIGIN        server origin for read-backs (direct, runner-side;
#                 production origin or the staging composition,
#                 per the gate-suite server-mode)
#   RIG_LOG       serving-rig log to mine for served-bytes evidence
#   SERVED_ASSET  JS asset filename the device must have fetched via the rig
#   OUT           evidence dir
#
# Fixture discipline (binding): only the lane-designated fixture
# handle is ever typed; midge.skr is HANDLE_RESERVED and never used.
#
# RE-HOST (2026-11-01, SEAL_V113 ADDENDUM #2): the device
# choreography now runs on the wallet-suite's proven driver lineage.
# Root cause of the 7-execution rig failure, from the gate runs' own
# logs (e.g. run 41396257103): the gate-suite action never granted
# KVM permissions, so the emulator launched with '-accel off'
# (ProbeKVM: "This user doesn't have permissions to use KVM") —
# 12–16-minute boots, uiautomator dumps timing out from the first
# call, installs failing. The wallet-suite action grants KVM first.
# Ported here: v104 r17's helper bodies verbatim (dump_is_substantive
# acceptance, fg_pkg window-focus parse, authenticate_mock with its
# keyguard-landing recovery, dismiss_host_anr host-only variant,
# enroll/satisfy/ensure helpers), its security prelude (PIN verify
# read-back, device-info), its install order (mock → Authenticate →
# APK under test), and ensure_unlocked at gate-navigation entry. The
# gate flow and every PASS criterion are unchanged.
set -u

PKG="com.voidrunner.app"
ACT="com.voidrunner.app/.MainActivity"
MOCK="com.solana.mwallet"
MOCK_ACT="com.solana.mwallet/.MainActivity"
OUT="${OUT:-gate-evidence}"
VR_APK="${VR_APK:-}"
MOCK_APK="${MOCK_APK:-}"
GATE_HANDLE="${GATE_HANDLE:-}"
GATE_MODE="${GATE_MODE:-r1}"
ORIGIN="${ORIGIN:-https://voidrunner-2hm7p.ondigitalocean.app}"
RIG_LOG="${RIG_LOG:-}"
SERVED_ASSET="${SERVED_ASSET:-}"
DEVICE_PIN="${DEVICE_PIN:-1234}"
TMPD="$(mktemp -d)"
LANE_LOG="$OUT/gate-lane.log"

mkdir -p "$OUT"
: > "$LANE_LOG"
log() { echo "$*" | tee -a "$LANE_LOG"; }

AUTH_EPOCH_FILE="$OUT/auth-epoch.txt"
auth_note="not attempted"
lock_pin="unknown"; lock_fp="unknown"

FAILCOPY_RE="Wallet signing didn't complete|wallet didn't return a signature|cancelled before the wallet returned"
HANDLE_LOCAL="${GATE_HANDLE%.skr}"

# --- read-back (runner-side, direct to the production origin) -------------------
readback() { # echoes the signIn status for the fixture handle, or the error code
  local body status
  body="$(curl -s -m 30 -X POST "$ORIGIN/actions" -H 'Content-Type: application/json' \
    -d "{\"action\":\"signIn\",\"args\":{\"name\":\"$GATE_HANDLE\"},\"actionCallId\":\"gate-readback-$(date +%s%N)\"}" 2>/dev/null)"
  echo "$body" > "$OUT/readback-$1.json"
  status="$(printf '%s' "$body" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print((d.get("data") or {}).get("status") or ("error:" + str((d.get("error") or {}).get("code") or (d.get("error") or {}).get("message") or "unknown")))
except Exception as e:
    print("parse-fail")' 2>/dev/null)"
  echo "$status"
}

# --- UI helpers (carried from the lane drivers, verify-v104 r17 / diag) ---------
dump_is_substantive() { # rejects hollow mid-transition dumps (1 node, no
  # text/content-desc, no WebView) — a race artifact, not a screen.
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

dump_ui() { # $1 = destination file
  local dst="$1" attempt
  for attempt in 1 2 3 4 5 6 7 8; do
    adb shell rm -f /sdcard/window_dump.xml >/dev/null 2>&1 || true
    timeout 40 adb shell uiautomator dump /sdcard/window_dump.xml >/dev/null 2>&1 || true
    adb exec-out cat /sdcard/window_dump.xml > "$dst.tmp" 2>/dev/null || true
    if grep -q "</hierarchy>" "$dst.tmp" 2>/dev/null && dump_is_substantive "$dst.tmp"; then
      mv "$dst.tmp" "$dst"
      return 0
    fi
    sleep 3
  done
  log "dump_ui: FAILED after 8 attempts -> $dst"
  return 1
}

dump_ui_bounded() { # $1 = destination file, $2 = total budget secs
  # r15: dump_ui with a hard wall-clock budget. dump_ui's 8 attempts
  # at up to 40 s each can burn ~6 min per call on a rig whose
  # uiautomator is wedged; a caller that must not stall the suite
  # (VR-11's game-destination probe, REPORT_V109 addendum) uses this
  # instead and treats budget exhaustion as a rig NOT-RUN.
  local dst="$1" budget="$2" start attempt=0
  start=$SECONDS
  while [ $((SECONDS - start)) -lt "$budget" ]; do
    attempt=$((attempt + 1))
    adb shell rm -f /sdcard/window_dump.xml >/dev/null 2>&1 || true
    timeout 25 adb shell uiautomator dump /sdcard/window_dump.xml >/dev/null 2>&1 || true
    adb exec-out cat /sdcard/window_dump.xml > "$dst.tmp" 2>/dev/null || true
    if grep -q "</hierarchy>" "$dst.tmp" 2>/dev/null && dump_is_substantive "$dst.tmp"; then
      mv "$dst.tmp" "$dst"
      return 0
    fi
    sleep 2
  done
  log "dump_ui_bounded: budget ${budget}s exhausted after $attempt attempts -> $dst"
  return 1
}

tap_text() { # $1 = hierarchy file, $2 = substring
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
  if [ -n "$coords" ]; then adb shell input tap $coords; return 0; fi
  return 1
}

tap_exact() { # $1 = hierarchy file, $2 = exact text
  local coords
  coords="$(python3 - "$1" "$2" <<'PY'
import re, sys
data = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
for m in re.finditer(r'<node[^>]*>', data):
    tag = m.group(0)
    t = re.search(r'text="([^"]*)"', tag)
    b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
    if t and b and t.group(1) == sys.argv[2]:
        x = (int(b.group(1)) + int(b.group(3))) // 2
        y = (int(b.group(2)) + int(b.group(4))) // 2
        print(f"{x} {y}")
        break
PY
)"
  if [ -n "$coords" ]; then adb shell input tap $coords; return 0; fi
  return 1
}

tap_frac() {
  local wh w h x y
  wh="$(adb shell wm size 2>/dev/null | sed -n 's/.*: \([0-9]*\)x\([0-9]*\).*/\1 \2/p' | head -n 1)"
  w="$(printf '%s' "$wh" | awk '{print $1}')"; h="$(printf '%s' "$wh" | awk '{print $2}')"
  [ -n "$w" ] && [ -n "$h" ] || { w=1080; h=2400; }
  x="$(awk -v w="$w" -v f="$1" 'BEGIN{printf "%d", w*f}')"
  y="$(awk -v h="$h" -v f="$2" 'BEGIN{printf "%d", h*f}')"
  adb shell input tap "$x" "$y"
}

fg_pkg() {
  local f
  f="$(adb shell dumpsys window windows 2>/dev/null | sed -n 's/.*mCurrentFocus=Window{[^ ]* [^ ]* \([^/]*\)\/.*/\1/p' | head -n 1 | tr -d '\r')"
  if [ -z "$f" ]; then
    f="$(adb shell dumpsys activity activities 2>/dev/null | sed -n 's/.*topResumedActivity=ActivityRecord{[^ ]* [^ ]* \([^/]*\)\/.*/\1/p' | head -n 1 | tr -d '\r')"
  fi
  printf '%s' "$f"
}

snap() { adb exec-out screencap -p > "$OUT/$1" 2>/dev/null || true; }

dismiss_host_anr() { # if a host (launcher/System UI) ANR dialog is up, tap Wait
  local f="$TMPD/anr-check.xml"
  if dump_ui "$f" && grep -q "isn.t responding" "$f"; then
    if grep -q "Pixel Launcher isn.t responding\|System UI isn.t responding" "$f"; then
      log "anr: host dialog present; tapping Wait"
      tap_text "$f" "Wait" || tap_frac 0.66 0.54
      sleep 2
    fi
  fi
}

wait_for() { # $1 = grep pattern, $2 = timeout secs, $3 = dump file
  local pat="$1" timeout_s="$2" dst="$3" elapsed=0
  while [ "$elapsed" -lt "$timeout_s" ]; do
    if dump_ui "$dst" && grep -qE "$pat" "$dst"; then return 0; fi
    dismiss_host_anr
    sleep 3; elapsed=$((elapsed + 3))
  done
  dump_ui "$dst" || true
  grep -qE "$pat" "$dst" 2>/dev/null
}

looks_locked() { # $1 = dump file; keyguard/AOD heuristics (driver r7)
  # v105 r1 starved BOTH core jobs behind a keyguard presentation the
  # r5 triggers missed: an all-SystemUI hierarchy whose only texts are
  # the clock, carrier and 'Unlock for all features and data' — no
  # 'Swipe up to open' string, and fg_pkg's focus parse never yielded
  # 'com.android.systemui'. Detect the state structurally instead.
  python3 - "$1" <<'PY'
import re, sys
try:
    data = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
except OSError:
    sys.exit(1)
pkgs = set(re.findall(r'package="([^"]+)"', data))
texts = " ".join(re.findall(r'text="([^"]*)"', data))
if "Unlock for all features and data" in texts: sys.exit(0)
if "Swipe up to open" in texts or "Swipe up to unlock" in texts: sys.exit(0)
if pkgs and pkgs <= {"com.android.systemui"}: sys.exit(0)
sys.exit(1)
PY
}

ensure_unlocked() {
  local f="$TMPD/lock.xml" try
  dump_ui "$f" || return 0
  if ! looks_locked "$f" && [ "$(fg_pkg)" != "com.android.systemui" ]; then return 0; fi
  for try in 1 2 3; do
    log "lock: keyguard appears engaged (try $try; fg=$(fg_pkg)); wake + swipe + PIN unlock"
    adb shell input keyevent 224 >/dev/null 2>&1 || true  # WAKEUP
    sleep 1
    adb shell input keyevent 82 >/dev/null 2>&1 || true   # MENU — dismisses AOD on some images
    sleep 1
    adb shell input swipe 540 2200 540 700 300 >/dev/null 2>&1 || true
    sleep 1
    # Send the PIN only if the post-swipe surface still looks like a
    # credential gate (never type blindly into an unlocked UI).
    if dump_ui "$f" && looks_locked "$f"; then
      adb shell input text "$DEVICE_PIN" >/dev/null 2>&1 || true
      adb shell input keyevent 66 >/dev/null 2>&1 || true
      sleep 2
    fi
    dump_ui "$f" || return 0
    if ! looks_locked "$f"; then log "lock: unlocked on try $try"; return 0; fi
  done
  log "lock: STILL LOCKED after 3 unlock attempts"
}

satisfy_auth_prompt() { # works the biometric/PIN prompt until it clears
  local f="$TMPD/auth.xml" i
  for i in 1 2 3 4 5 6; do
    sleep 2
    dump_ui "$f" || return 1
    if grep -q "Log in to" "$f"; then
      adb emu finger touch 1 >/dev/null 2>&1 || true
      sleep 2
      dump_ui "$f" || return 1
      if grep -q "Log in to" "$f"; then
        # fall back to device credential
        tap_text "$f" "Use PIN" || tap_text "$f" "PIN" || true
        sleep 1
        adb shell input text "$DEVICE_PIN" >/dev/null 2>&1 || true
        adb shell input keyevent 66 >/dev/null 2>&1 || true
        sleep 2
      fi
    else
      return 0
    fi
  done
  dump_ui "$f" || true
  ! grep -q "Log in to" "$f"
}

# --- device security (binding recipe: PIN-locked AVD + enrolled fingerprint) ----
# (Prelude + helpers re-hosted on the wallet-suite driver, verify-v104
# r17 — REPORT_V112's proven lineage — 2026-11-01; see the re-host note
# in this file's header and SEAL_V113 ADDENDUM #2.)
{
  echo "sdk=$(adb shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
  echo "release=$(adb shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')"
  echo "fingerprint=$(adb shell getprop ro.build.fingerprint 2>/dev/null | tr -d '\r')"
  echo "model=$(adb shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
  echo "meminfo=$(adb shell cat /proc/meminfo 2>/dev/null | head -n 1 | tr -d '\r')"
} > "$OUT/device-info.txt"
cat "$OUT/device-info.txt" | tee -a "$LANE_LOG"

log "security: setting device PIN via locksettings"
adb shell locksettings set-pin "$DEVICE_PIN" >> "$LANE_LOG" 2>&1 || true
if adb shell locksettings verify --old "$DEVICE_PIN" >/dev/null 2>&1; then
  lock_pin="set+verified (PIN $DEVICE_PIN)"
else
  # verify subcommand support varies; fall back to lock-state probe
  ls_state="$(adb shell dumpsys lock_settings 2>/dev/null | grep -i "credential" | head -n 2 | tr -d '\r')"
  log "security: locksettings verify unsupported; dumpsys lock_settings: $ls_state"
  lock_pin="set (locksettings set-pin issued, PIN $DEVICE_PIN)"
fi
log "security: lock_pin=$lock_pin"
# The PIN lock stays (binding), but the AVD must not lock ITSELF
# mid-cell: screen/lock timeouts to max + stay-on-USB (the wallet
# suite's r4 cure for keyguard starvation during idle waits).
adb shell settings put system screen_off_timeout 2147483647 >/dev/null 2>&1 || true
adb shell settings put secure lock_screen_lock_after_timeout 2147483647 >/dev/null 2>&1 || true
adb shell svc power stayon usb >/dev/null 2>&1 || true
log "security: lock mitigation applied (screen_off_timeout=max, lock_after_timeout=max, stayon usb)"

enroll_fingerprint() {
  # Best-effort Settings-driven enrollment; every step logged. The
  # emulator's virtual sensor is driven with `adb emu finger touch`.
  log "security: attempting fingerprint enrollment via Settings"
  adb shell am start -a android.settings.SECURITY_SETTINGS >/dev/null 2>&1 || true
  sleep 3
  local f="$TMPD/fp.xml" i
  for i in 1 2 3 4 5 6; do
    dump_ui "$f" || return 1
    if grep -q "Fingerprint" "$f"; then
      tap_text "$f" "Fingerprint" || return 1
      sleep 2
      break
    fi
    adb shell input swipe 540 1800 540 900 300 >/dev/null 2>&1 || true
    sleep 1
  done
  dump_ui "$f" || return 1
  # PIN gate before enrollment
  if grep -q "PIN\|password" "$f" && ! grep -q "Fingerprint" "$f"; then
    adb shell input text "$DEVICE_PIN" >/dev/null 2>&1 || true
    adb shell input keyevent 66 >/dev/null 2>&1 || true
    sleep 2
    dump_ui "$f" || return 1
  fi
  # "Add a fingerprint" / enroll entry
  if grep -q "Add a fingerprint\|Fingerprint Unlock\|fingerprint" "$f"; then
    tap_text "$f" "Add a fingerprint" || tap_text "$f" "Fingerprint" || true
    sleep 2
  fi
  # Sensor-touch phase: the enroll screen asks for repeated touches
  local t
  for t in 1 2 3 4 5 6 7 8 9 10 11 12; do
    adb emu finger touch 1 >/dev/null 2>&1 || true
    sleep 1
    if dump_ui "$f" && grep -q "Fingerprint added\|Done\|fingerprint.*added" "$f"; then
      tap_text "$f" "Done" || true
      return 0
    fi
  done
  dump_ui "$f" || true
  grep -q "Fingerprint added" "$f" 2>/dev/null
}
if enroll_fingerprint; then
  lock_fp="enrolled (emulator virtual sensor, id 1)"
else
  lock_fp="ENROLLMENT FAILED (see lane log + fp dumps; PIN-secured path still exercised)"
fi
log "security: lock_fp=$lock_fp"
adb shell input keyevent 3 >/dev/null 2>&1 || true  # HOME
sleep 1

# --- installs + Authenticate -----------------------------------------------------
# Wallet-suite order (verify-v104 §2.2 step 5): mock install, then
# Authenticate, then the APK under test — the 15-minute auth window
# opens as late as the proven lane opens it.
if [ -z "$VR_APK" ] || [ -z "$MOCK_APK" ] || [ -z "$GATE_HANDLE" ]; then
  log "config: VR_APK/MOCK_APK/GATE_HANDLE are all required"
  echo "gate_verdict=CONFIG-FAIL" > "$OUT/verdict-gate.txt"
  exit 1
fi
log "install: mock wallet ($MOCK_APK)"
adb install "$MOCK_APK" > "$TMPD/install-mock.log" 2>&1 || { log "install: MOCK INSTALL FAILED"; echo "gate_verdict=FAIL" > "$OUT/verdict-gate.txt"; exit 1; }

authenticate_mock() {
  log "auth: opening mock wallet to Authenticate (15-min window)"
  ensure_unlocked
  adb shell am start -W -n "$MOCK_ACT" >/dev/null 2>&1 || true
  sleep 3
  local f="$TMPD/mock-main.xml"
  dump_ui "$f" || return 1
  if ! grep -q "AUTHENTICATE\|Authenticate" "$f" && looks_locked "$f"; then
    # r7: the launch can land behind an engaged keyguard (v105 r1) —
    # the first dump then shows the lock screen, not the mock. Unlock
    # and relaunch once before concluding the button is absent.
    log "auth: mock launch landed behind the keyguard — unlocking + relaunching"
    ensure_unlocked
    adb shell am start -W -n "$MOCK_ACT" >/dev/null 2>&1 || true
    sleep 3
    dump_ui "$f" || return 1
  fi
  grep -oE 'text="[^"]+"' "$f" | sort -u | head -12 | tee -a "$LANE_LOG" || true
  # The button's dump text is 'AUTHENTICATE' (Material all-caps) — r3
  # searched for 'Authenticate' and missed a healthy mock main screen
  # that showed Name/Address/AUTHENTICATE exactly as configured.
  if grep -q "AUTHENTICATE\|Authenticate" "$f"; then
    tap_exact "$f" "AUTHENTICATE" || tap_exact "$f" "Authenticate" || tap_text "$f" "UTHENTICATE" || return 1
    if satisfy_auth_prompt; then
      date +%s > "$AUTH_EPOCH_FILE"
      auth_note="authenticated (window opened $(date -u +%H:%M:%S)Z)"
      log "auth: $auth_note"
      sleep 1
      dump_ui "$OUT/mock-after-auth.xml" || true
      snap "mock-after-auth.png"
      return 0
    fi
    auth_note="AUTHENTICATE PROMPT NOT SATISFIED"
    log "auth: $auth_note"
    return 1
  fi
  auth_note="Authenticate button not found on mock main screen"
  log "auth: $auth_note"
  return 1
}
if authenticate_mock; then log "auth: mock authenticated (15-min window)"; else log "auth: mock AUTHENTICATE FAILED"; fi
adb shell input keyevent 3 >/dev/null 2>&1 || true  # HOME

log "install: VR APK under test ($VR_APK)"
adb uninstall "$PKG" >/dev/null 2>&1 || true
adb install "$VR_APK" > "$TMPD/install-vr.log" 2>&1 || { log "install: VR INSTALL FAILED"; echo "gate_verdict=FAIL" > "$OUT/verdict-gate.txt"; exit 1; }
adb logcat -c >/dev/null 2>&1 || true

# --- gate navigation ---------------------------------------------------------------
launch_to_gate() { # $1 = rep tag
  local tag="$1"
  ensure_unlocked
  adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
  sleep 1
  adb shell am start -W -n "$ACT" >/dev/null 2>&1 || true
  if ! wait_for "PLAY" 60 "$OUT/hier-$tag-home.xml"; then log "$tag: home (PLAY) never appeared"; return 1; fi
  dump_ui "$TMPD/g.xml" || return 1
  tap_text "$TMPD/g.xml" "PLAY" || return 1
  if ! wait_for "while you were away|SIGN IN|CONTINUE|WALLET" 45 "$OUT/hier-$tag-afterplay.xml"; then
    log "$tag: post-PLAY surface never settled"; return 1
  fi
  if grep -q "while you were away" "$OUT/hier-$tag-afterplay.xml"; then
    tap_text "$OUT/hier-$tag-afterplay.xml" "OK" || true
    sleep 2
  fi
  if ! wait_for "SIGN IN" 45 "$OUT/hier-$tag-gate.xml"; then log "$tag: sign-in gate never appeared"; return 1; fi
  log "$tag: sign-in gate reached (fg=$(fg_pkg))"
  return 0
}

enter_handle_and_signin() { # $1 = rep tag; leaves the gate's pending action on screen
  local tag="$1" f="$TMPD/signin.xml"
  # The gate screen is a live-rendering WebView; a single-shot dump
  # can catch it mid-transition and fail every retry inside one
  # dump_ui call (execution 41403201148 died exactly here, on an
  # otherwise healthy rig). The wallet suite's answer for game
  # screens is the bounded variant (VR-11, r15) — same budget
  # pattern, choreography only; the assertions are unchanged.
  dump_ui_bounded "$f" 150 || return 1
  # Tap the handle input: the EditText nearest above the SIGN IN button.
  local coords
  coords="$(python3 - "$f" <<'PY'
import re, sys
data = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
ets = [m for m in re.finditer(r'class="android.widget.EditText"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', data)]
if not ets:
    ets = [m for m in re.finditer(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"[^>]*class="android.widget.EditText"', data)]
if ets:
    m = ets[0]
    print(f"{(int(m.group(1)) + int(m.group(3))) // 2} {(int(m.group(2)) + int(m.group(4))) // 2}")
PY
)"
  if [ -n "$coords" ]; then
    adb shell input tap $coords
  elif ! tap_text "$f" ".skr"; then
    log "$tag: handle EditText not found and no .skr suffix to focus"
    return 1
  fi
  sleep 1
  adb shell input text "$HANDLE_LOCAL" >/dev/null 2>&1 || true
  sleep 1
  adb shell input keyevent 4 >/dev/null 2>&1 || true  # dismiss soft keyboard
  sleep 1
  dump_ui_bounded "$f" 150 || return 1
  tap_text "$f" "SIGN IN" || return 1
  log "$tag: handle entered + SIGN IN tapped"
  return 0
}

# One wallet-action rep: poll the gate until the pending action appears,
# tap it, then work the wallet sheet; track foreground + failure copies.
# Sets globals: REP_FG (yes/no), REP_FAILCOPY (text or ""), REP_SHEET (yes/no),
# REP_DONE (yes = gate left the pending state with no failure copy).
run_wallet_action() { # $1 = rep tag, $2 = budget secs
  local tag="$1" budget="$2" elapsed=0 tapped=0
  REP_FG="no"; REP_FAILCOPY=""; REP_SHEET="no"; REP_DONE="no"
  local f="$TMPD/wa.xml"
  while [ "$elapsed" -lt "$budget" ]; do
    sleep 3; elapsed=$((elapsed + 3))
    if [ "$(fg_pkg)" = "$MOCK" ]; then REP_FG="yes"; fi
    if ! dump_ui "$f"; then continue; fi
    if grep -qE "$FAILCOPY_RE" "$f"; then
      REP_FAILCOPY="$(grep -oE "$FAILCOPY_RE[^ ]*( [^ ]*){0,3}" "$f" | head -n1)"
      cp "$f" "$OUT/hier-$tag-failcopy.xml"; snap "shot-$tag-failcopy.png"
      log "$tag: FAILURE COPY observed: $REP_FAILCOPY"
      return 0
    fi
    # Mock re-auth prompt up instead of a sheet (15-min window lapsed)?
    if [ "$(fg_pkg)" = "$MOCK" ] && grep -q "Log in to" "$f"; then
      log "$tag: mock re-auth prompt — satisfying"
      satisfy_auth_prompt || true
      continue
    fi
    # Wallet sheet up? (mock foreground + sheet controls)
    if [ "$(fg_pkg)" = "$MOCK" ] && grep -qE 'text="(Approve|Sign|Connect|Cancel)"' "$f"; then
      REP_SHEET="yes"
      cp "$f" "$OUT/hier-$tag-sheet.xml"; snap "shot-$tag-sheet.png"
      log "$tag: wallet sheet present — approving"
      tap_text "$f" "Approve" || tap_text "$f" "Sign" || tap_text "$f" "Connect" || true
      sleep 3
      satisfy_auth_prompt || true
      sleep 3
      continue
    fi
    # The gate's pending wallet action: tap it once.
    if [ "$tapped" -eq 0 ]; then
      if grep -q "Link my wallet" "$f"; then
        tap_text "$f" "Link my wallet" && tapped=1 && log "$tag: tapped 'Link my wallet'"
        continue
      fi
      if grep -q "Prove it's you" "$f"; then
        tap_text "$f" "Prove it's you" && tapped=1 && log "$tag: tapped 'Prove it's you'"
        continue
      fi
    fi
    # Completion: tapped, wallet foregrounded, sheet approved, and the
    # gate's pending action is gone with no failure copy — the client
    # only advances on the server's success response.
    if [ "$tapped" -eq 1 ] && [ "$REP_SHEET" = "yes" ] && [ "$(fg_pkg)" = "$PKG" ] \
       && ! grep -q "Link my wallet\|Prove it's you" "$f"; then
      REP_DONE="yes"
      cp "$f" "$OUT/hier-$tag-completed.xml"; snap "shot-$tag-completed.png"
      log "$tag: gate completed in-app (pending action cleared)"
      return 0
    fi
  done
  cp "$f" "$OUT/hier-$tag-final.xml" 2>/dev/null || true
  log "$tag: budget exhausted (tapped=$tapped fg=$REP_FG sheet=$REP_SHEET)"
  return 0
}

# --- the cell ---------------------------------------------------------------------
log "gate cell: mode=$GATE_MODE handle=$GATE_HANDLE"
RB_PRE="$(readback pre)"
log "read-back PRE: signIn($GATE_HANDLE) -> $RB_PRE"

if [ "$GATE_MODE" = "r2" ]; then
  # Negative control: the faulted composition must fail with the signature.
  launch_to_gate r2 || { echo "gate_verdict=NAV-FAIL" > "$OUT/verdict-gate.txt"; exit 1; }
  enter_handle_and_signin r2 || { echo "gate_verdict=NAV-FAIL" > "$OUT/verdict-gate.txt"; exit 1; }
  run_wallet_action r2 120
  sleep 5
  RB_POST="$(readback post)"
  log "read-back POST: signIn($GATE_HANDLE) -> $RB_POST"
  verdict="FAIL"
  if [ -n "$REP_FAILCOPY" ] && [ "$REP_FG" = "no" ] && [ "$RB_POST" = "bind_required" ]; then
    verdict="PASS"
  fi
  {
    echo "gate_mode=r2 (negative control: production faulted bytes + v1.0.12 shell)"
    echo "handle=$GATE_HANDLE"
    echo "failure_copy_observed=${REP_FAILCOPY:-none}"
    echo "wallet_foreground_seen=$REP_FG"
    echo "readback_pre=$RB_PRE"
    echo "readback_post=$RB_POST"
    echo "gate_verdict=$verdict"
  } > "$OUT/verdict-gate.txt"
  cat "$OUT/verdict-gate.txt"
  [ "$verdict" = "PASS" ]
  exit $?
fi

# R-1: rep 1 (bind) + rep 2 (proof).
launch_to_gate rep1 || { echo "gate_verdict=NAV-FAIL" > "$OUT/verdict-gate.txt"; exit 1; }
enter_handle_and_signin rep1 || { echo "gate_verdict=NAV-FAIL" > "$OUT/verdict-gate.txt"; exit 1; }
run_wallet_action rep1 240
R1_FG="$REP_FG"; R1_FAIL="$REP_FAILCOPY"; R1_SHEET="$REP_SHEET"; R1_DONE="$REP_DONE"
RB_MID="$(readback mid)"
log "read-back MID (after rep 1): signIn($GATE_HANDLE) -> $RB_MID"

# Rep 2: fresh app state — the profile now exists server-side, so the
# gate must offer the proof action.
adb shell pm clear "$PKG" >/dev/null 2>&1 || true
sleep 1
launch_to_gate rep2 || { echo "gate_verdict=NAV-FAIL" > "$OUT/verdict-gate.txt"; exit 1; }
enter_handle_and_signin rep2 || { echo "gate_verdict=NAV-FAIL" > "$OUT/verdict-gate.txt"; exit 1; }
run_wallet_action rep2 240
R2_FG="$REP_FG"; R2_FAIL="$REP_FAILCOPY"; R2_SHEET="$REP_SHEET"; R2_DONE="$REP_DONE"
RB_POST="$(readback post)"
log "read-back POST (after rep 2): signIn($GATE_HANDLE) -> $RB_POST"

# Served-bytes evidence: the device must have fetched the candidate
# asset through the rig (proof the rig, not production, served it).
RIG_HIT="unknown"
if [ -n "$RIG_LOG" ] && [ -n "$SERVED_ASSET" ] && [ -f "$RIG_LOG" ]; then
  if grep -q "RIG static /assets/$SERVED_ASSET" "$RIG_LOG"; then RIG_HIT="yes"; else RIG_HIT="no"; fi
fi

verdict="PASS"
for cond in \
  "pre:$RB_PRE:bind_required" \
  "mid:$RB_MID:proof_required" \
  "post:$RB_POST:proof_required"; do
  got="$(printf '%s' "$cond" | cut -d: -f2)"
  want="$(printf '%s' "$cond" | cut -d: -f3)"
  [ "$got" = "$want" ] || verdict="FAIL"
done
[ "$R1_FG" = "yes" ] && [ "$R2_FG" = "yes" ] || verdict="FAIL"
[ -z "$R1_FAIL" ] && [ -z "$R2_FAIL" ] || verdict="FAIL"
[ "$R1_DONE" = "yes" ] && [ "$R2_DONE" = "yes" ] || verdict="FAIL"
[ "$RIG_HIT" != "no" ] || verdict="FAIL"

{
  echo "gate_mode=r1 (cured candidate: candidate served bytes + v1.0.13 shell)"
  echo "handle=$GATE_HANDLE"
  echo "rep1_bind: wallet_foreground_seen=$R1_FG sheet_approved=$R1_SHEET failure_copy=${R1_FAIL:-none} in_app_completed=$R1_DONE"
  echo "rep2_proof: wallet_foreground_seen=$R2_FG sheet_approved=$R2_SHEET failure_copy=${R2_FAIL:-none} in_app_completed=$R2_DONE"
  echo "readback_pre=$RB_PRE (expect bind_required)"
  echo "readback_mid=$RB_MID (expect proof_required — bind persisted)"
  echo "readback_post=$RB_POST (expect proof_required)"
  echo "rig_served_candidate_asset=$RIG_HIT (asset=$SERVED_ASSET)"
  echo "gate_verdict=$verdict"
} > "$OUT/verdict-gate.txt"
cat "$OUT/verdict-gate.txt"
[ "$verdict" = "PASS" ]
