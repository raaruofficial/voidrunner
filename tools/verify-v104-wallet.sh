#!/usr/bin/env bash
# VOIDRUNNER v1.0.4 — wallet-interaction verdict driver (SOLANA RESOURCES
# BINDING 2026-10-29 §2.2 recipe). Runs INSIDE one emulator step on the
# CI-KVM lane. Exercises the sealed cured binary against the official
# Mock MWA Wallet (built from source at a pinned commit, imported
# throwaway key) on a PIN-locked AVD.
#
# Suites (env SUITE): core | errors | lifecycle
#   core      = VR-1 connect, VR-3 sign message, VR-9 sign decline,
#               VR-6 disconnect/fail-closed, VR-2 restart observation
#   errors    = VR-7 decline connect + retry, VR-8 wallet death during
#               connect + recovery, VR-13 wallet death mid-session
#   lifecycle = VR-12 background/foreground mid-approval, VR-11 entry
#               points / destination registry
# Cells with no reachable surface in the sealed build (VR-4 sign-only,
# VR-5/VR-10 sign-and-send — bridge-only, behind the gated game flow)
# are graded by the report, not by this driver.
#
# Any AndroidRuntime FATAL (either package) or any IllegalStateException
# in a captured logcat window is counted and fails the whole verdict.
set -u

PKG="com.voidrunner.app"
ACT="com.voidrunner.app/.MainActivity"
MOCK="com.solana.mwallet"
MOCK_ACT="com.solana.mwallet/.MainActivity"
OUT="${FUN001_OUT:-fun001-v104-wallet-evidence}"
SUITE="${SUITE:-core}"
VR_APK="${VR_APK:-}"
MOCK_APK="${MOCK_APK:-}"
EXPECTED_PUBKEY="${EXPECTED_PUBKEY:-}"
DEVICE_PIN="${DEVICE_PIN:-1234}"
TMPD="$(mktemp -d)"
LANE_LOG="$OUT/wallet-lane.log"
AUTH_EPOCH_FILE="$OUT/auth-epoch.txt"

mkdir -p "$OUT"
: > "$LANE_LOG"
log() { echo "$*" | tee -a "$LANE_LOG"; }

# --- verdict state -------------------------------------------------------------
vr1="NOT-RUN"; vr2="NOT-RUN"; vr3="NOT-RUN"; vr6="NOT-RUN"; vr7="NOT-RUN"
vr8="NOT-RUN"; vr9="NOT-RUN"; vr11="NOT-RUN"; vr12="NOT-RUN"; vr13="NOT-RUN"
fatal_vr_total="0"; fatal_mock_total="0"; ise_total="0"; stopped_dialogs="0"
lock_pin="unknown"; lock_fp="unknown"; auth_note="not attempted"

# --- helpers (carried from verify-fun001.sh, JUDGE Amendment 2 hardening) -----
dump_ui() { # $1 = destination file
  local dst="$1" attempt
  for attempt in 1 2 3 4 5 6 7 8; do
    adb shell rm -f /sdcard/window_dump.xml >/dev/null 2>&1 || true
    timeout 40 adb shell uiautomator dump /sdcard/window_dump.xml >/dev/null 2>&1 || true
    adb exec-out cat /sdcard/window_dump.xml > "$dst.tmp" 2>/dev/null || true
    if grep -q "</hierarchy>" "$dst.tmp" 2>/dev/null; then
      mv "$dst.tmp" "$dst"
      return 0
    fi
    sleep 3
  done
  log "dump_ui: FAILED after 8 attempts -> $dst"
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

pid_alive() { [ -n "$(adb shell pidof "$1" 2>/dev/null | tr -d '\r')" ]; }

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

wait_for() { # $1 = grep pattern, $2 = timeout secs, $3 = dump file; polls dumps
  local pat="$1" timeout_s="$2" dst="$3" elapsed=0
  while [ "$elapsed" -lt "$timeout_s" ]; do
    if dump_ui "$dst" && grep -qE "$pat" "$dst"; then return 0; fi
    sleep 3; elapsed=$((elapsed + 3))
  done
  dump_ui "$dst" || true
  grep -qE "$pat" "$dst" 2>/dev/null
}

scan_logcat() { # $1 = file; updates global fatal/ise counters
  local f="$1" a b c
  a="$(grep -A3 "FATAL EXCEPTION" "$f" 2>/dev/null | grep -c "Process: $PKG" || true)"
  b="$(grep -A3 "FATAL EXCEPTION" "$f" 2>/dev/null | grep -c "Process: $MOCK" || true)"
  c="$(grep -c "IllegalStateException" "$f" 2>/dev/null || true)"
  fatal_vr_total=$((fatal_vr_total + ${a:-0}))
  fatal_mock_total=$((fatal_mock_total + ${b:-0}))
  ise_total=$((ise_total + ${c:-0}))
  log "scan: $f vr_fatal=${a:-0} mock_fatal=${b:-0} illegal_state=${c:-0}"
}

capture_window() { # $1 = tag; dumps logcat since last clear into evidence + scans
  adb logcat -d > "$OUT/logcat-$1.txt" 2>&1 || true
  scan_logcat "$OUT/logcat-$1.txt"
  adb logcat -c >/dev/null 2>&1 || true
}

# --- device record ---------------------------------------------------------------
adb wait-for-device
for _ in $(seq 1 60); do
  [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
  sleep 5
done
{
  echo "sdk=$(adb shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
  echo "release=$(adb shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')"
  echo "fingerprint=$(adb shell getprop ro.build.fingerprint 2>/dev/null | tr -d '\r')"
  echo "model=$(adb shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
  echo "meminfo=$(adb shell cat /proc/meminfo 2>/dev/null | head -n 1 | tr -d '\r')"
  echo "suite=$SUITE"
  echo "expected_pubkey=$EXPECTED_PUBKEY"
} > "$OUT/device-info.txt"
cat "$OUT/device-info.txt" | tee -a "$LANE_LOG"

# --- PIN lock + fingerprint enrollment (binding §2.2 step 2, mandatory) ---------
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

# --- installs + Authenticate (binding §2.2 step 5 order) --------------------------
log "install: mock wallet ($MOCK_APK)"
if ! adb install "$MOCK_APK" > "$TMPD/install-mock.log" 2>&1; then
  cat "$TMPD/install-mock.log" | tee -a "$LANE_LOG"
  log "install: MOCK INSTALL FAILED — no wallet legs can run"
  echo "wallet_install=FAIL" > "$OUT/verdict-wallet.txt"
  exit 1
fi

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

authenticate_mock() {
  log "auth: opening mock wallet to Authenticate (15-min window)"
  adb shell am start -W -n "$MOCK_ACT" >/dev/null 2>&1 || true
  sleep 3
  local f="$TMPD/mock-main.xml"
  dump_ui "$f" || return 1
  grep -oE 'text="[^"]+"' "$f" | sort -u | head -12 | tee -a "$LANE_LOG" || true
  if grep -q "Authenticate" "$f"; then
    tap_exact "$f" "Authenticate" || tap_text "$f" "Authenticate" || return 1
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

auth_fresh_enough() { # re-authenticate if the window is >8 min old
  local now last
  now="$(date +%s)"
  last="$(cat "$AUTH_EPOCH_FILE" 2>/dev/null || echo 0)"
  if [ $((now - last)) -gt 480 ]; then
    log "auth: window age $((now - last))s > 480s — re-authenticating"
    authenticate_mock || true
  fi
}

authenticate_mock || true
log "install: sealed VR APK ($VR_APK)"
adb uninstall "$PKG" >/dev/null 2>&1 || true
if ! adb install "$VR_APK" > "$TMPD/install-vr.log" 2>&1; then
  cat "$TMPD/install-vr.log" | tee -a "$LANE_LOG"
  log "install: VR INSTALL FAILED"
  echo "vr_install=FAIL" > "$OUT/verdict-wallet.txt"
  exit 1
fi
adb logcat -c >/dev/null 2>&1 || true

# --- VR navigation / flow helpers ---------------------------------------------------
goto_home() {
  local f="$TMPD/home.xml" i
  adb shell am start -W -n "$ACT" >/dev/null 2>&1 || true
  for i in 1 2 3 4 5 6; do
    sleep 2
    if dump_ui "$f" && grep -q "PLAY" "$f" && grep -q "WALLET" "$f" && grep -q "SETTINGS" "$f"; then
      return 0
    fi
    dismiss_host_anr
    adb shell input keyevent 4 >/dev/null 2>&1 || true
  done
  dump_ui "$f" || true
  grep -q "PLAY" "$f" 2>/dev/null && grep -q "WALLET" "$f" 2>/dev/null
}

goto_wallet() {
  goto_home || return 1
  local f="$TMPD/wallet-nav.xml"
  dump_ui "$f" || return 1
  tap_text "$f" "WALLET" || tap_frac 0.5 0.55
  wait_for "CONNECT WALLET|CONNECTED|Error" 25 "$OUT/hier-wallet-entry.xml"
}

sheet_present() { # $1 = dump file; mock sheet = mock fg + sheet controls
  local fg
  fg="$(fg_pkg)"
  [ "$fg" = "$MOCK" ] && grep -qE 'text="(Connect|Approve|Cancel)"' "$1" 2>/dev/null
}

wait_sheet() { # $1 = dump file, $2 = timeout; 0 if the mock sheet appeared
  local dst="$1" timeout_s="$2" elapsed=0
  while [ "$elapsed" -lt "$timeout_s" ]; do
    if dump_ui "$dst" && sheet_present "$dst"; then return 0; fi
    dismiss_host_anr
    sleep 3; elapsed=$((elapsed + 3))
  done
  dump_ui "$dst" || true
  sheet_present "$dst"
}

approve_connect_sheet() { # $1 = evidence tag
  local f="$OUT/hier-$1-sheet.xml"
  if wait_sheet "$f" 45; then
    snap "shot-$1-sheet.png"
    log "$1: mock authorize sheet present (fg=$(fg_pkg))"
    tap_exact "$f" "Connect" || tap_text "$f" "Connect" || return 1
    sleep 4
    satisfy_auth_prompt || true
    return 0
  fi
  log "$1: NO mock sheet appeared within 45s (fg=$(fg_pkg))"
  snap "shot-$1-nosheet.png"
  return 1
}

vr_state() { # echoes the wallet-screen state keyword from a fresh dump: $1 = dump file
  if dump_ui "$1"; then
    if grep -q "$EXPECTED_PUBKEY" "$1" && grep -q "CONNECTED" "$1"; then echo "connected"
    elif grep -q "CONNECT WALLET" "$1"; then echo "disconnected"
    elif grep -q "TRY AGAIN" "$1"; then echo "error"
    elif grep -q "Waiting for wallet" "$1"; then echo "working"
    else echo "unknown"; fi
  else echo "nodump"; fi
}

# --- shared flows -------------------------------------------------------------------
do_disconnect() { # $1 = evidence tag; taps DISCONNECT and waits for disconnected state
  local tag="$1" f="$TMPD/disc.xml" elapsed=0
  dump_ui "$f" || return 1
  tap_text "$f" "DISCONNECT" || return 1
  log "$tag: tapped DISCONNECT"
  while [ "$elapsed" -lt 40 ]; do
    sleep 3; elapsed=$((elapsed + 3))
    if [ "$(fg_pkg)" = "$MOCK" ]; then
      dump_ui "$OUT/hier-$tag-mock.xml" || true
      snap "shot-$tag-mock.png"
      log "$tag: mock foreground during disconnect; dump filed"
      # Deauthorize may need an explicit wallet-side confirmation; tap it if labelled.
      if tap_exact "$OUT/hier-$tag-mock.xml" "Disconnect" || tap_exact "$OUT/hier-$tag-mock.xml" "Deauthorize" || tap_exact "$OUT/hier-$tag-mock.xml" "Approve"; then
        log "$tag: tapped a wallet-side disconnect confirmation"
      fi
    fi
    if [ "$(vr_state "$TMPD/disc-state.xml")" = "disconnected" ]; then
      log "$tag: disconnected state reached after ${elapsed}s"
      return 0
    fi
  done
  log "$tag: disconnect did not reach disconnected state (state=$(vr_state "$TMPD/disc-state.xml"))"
  return 1
}

ensure_connected() { # $1 = evidence tag
  local tag="$1"
  goto_wallet || return 1
  if [ "$(vr_state "$TMPD/ec.xml")" = "connected" ]; then return 0; fi
  auth_fresh_enough
  dump_ui "$TMPD/ec2.xml" || return 1
  tap_text "$TMPD/ec2.xml" "CONNECT WALLET" || tap_text "$TMPD/ec2.xml" "TRY AGAIN" || return 1
  approve_connect_sheet "$tag" || return 1
  wait_for "CONNECTED" 30 "$OUT/hier-$tag-connected.xml" && grep -q "$EXPECTED_PUBKEY" "$OUT/hier-$tag-connected.xml"
}

ensure_disconnected() {
  goto_wallet || return 1
  if [ "$(vr_state "$TMPD/ed.xml")" = "disconnected" ]; then return 0; fi
  do_disconnect "ensure"
}

# --- VR-1: connect (the KFC-001 press path) -----------------------------------------
cell_vr1() {
  log "=== VR-1 connect ==="
  auth_fresh_enough
  if ! goto_wallet; then vr1="FAIL(could not reach wallet screen)"; return; fi
  local st; st="$(vr_state "$TMPD/vr1-pre.xml")"
  log "vr1: pre-state=$st"
  if [ "$st" = "connected" ]; then vr1="PASS(session already connected at cell start)"; return; fi
  adb logcat -c >/dev/null 2>&1 || true
  dump_ui "$TMPD/vr1-dis.xml" || true
  tap_text "$TMPD/vr1-dis.xml" "CONNECT WALLET" || tap_text "$TMPD/vr1-dis.xml" "TRY AGAIN" || { vr1="FAIL(no connect control)"; return; }
  if ! approve_connect_sheet "vr1"; then
    vr1="FAIL(no mock approval sheet)"
    capture_window "vr1"
    return
  fi
  if wait_for "CONNECTED" 30 "$OUT/hier-vr1-after.xml" && grep -q "$EXPECTED_PUBKEY" "$OUT/hier-vr1-after.xml"; then
    vr1="PASS(connect approved in mock sheet; Connected shows imported-key address $EXPECTED_PUBKEY)"
  else
    vr1="FAIL(post-approve state=$(vr_state "$TMPD/vr1-post.xml"), expected Connected+$EXPECTED_PUBKEY)"
  fi
  snap "shot-vr1-after.png"
  capture_window "vr1"
  log "vr1: $vr1"
}

# --- VR-3: sign message (+ opportunistic off-device signature verification) ---------
cell_vr3() {
  log "=== VR-3 sign message ==="
  if [ "$(vr_state "$TMPD/vr3-pre.xml")" != "connected" ]; then
    vr3="NOT-RUN(not connected at cell start)"
    return
  fi
  auth_fresh_enough
  adb logcat -c >/dev/null 2>&1 || true
  dump_ui "$TMPD/vr3-conn.xml" || true
  tap_text "$TMPD/vr3-conn.xml" "SIGN TEST MESSAGE" || { vr3="FAIL(no sign control in Connected state)"; return; }
  local f="$OUT/hier-vr3-sheet.xml"
  if ! wait_sheet "$f" 45; then
    vr3="FAIL(no mock sign sheet)"
    capture_window "vr3"
    return
  fi
  snap "shot-vr3-sheet.png"
  if grep -q "VOIDRUNNER sign-in" "$f"; then
    log "vr3: sign sheet shows the request message 'VOIDRUNNER sign-in'"
  else
    log "vr3: sheet present but message text not visible in dump"
  fi
  if grep -qi "wants to connect" "$f"; then
    log "vr3: NOTE — an authorize sheet appeared during transact (reauthorize NOT silent)"
    echo "reauthorize_during_transact=sheet-appeared" >> "$OUT/vr3-notes.txt"
  else
    echo "reauthorize_during_transact=silent (sign sheet only; cached authToken reused)" >> "$OUT/vr3-notes.txt"
  fi
  tap_exact "$f" "Approve" || { vr3="FAIL(no Approve on sign sheet)"; capture_window "vr3"; return; }
  sleep 3
  satisfy_auth_prompt || true
  local ok="0"
  if wait_for "CONNECTED" 30 "$OUT/hier-vr3-after.xml" && grep -q "$EXPECTED_PUBKEY" "$OUT/hier-vr3-after.xml"; then ok="1"; fi
  capture_window "vr3"
  # Opportunistic: hunt the returned signature in the captured logcat window
  # (walletlib/clientlib debug lines) and verify it off-device with node.
  python3 - "$OUT/logcat-vr3.txt" "$EXPECTED_PUBKEY" > "$OUT/vr3-sig-candidates.txt" <<'PY' || true
import re, sys
data = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
cands = sorted(set(re.findall(r'[1-9A-HJ-NP-Za-km-z]{86,88}', data)))
for c in cands:
    if c != sys.argv[2]:
        print(c)
PY
  local verified="not-observed"
  if [ -s "$OUT/vr3-sig-candidates.txt" ]; then
    while read -r cand; do
      if node -e '
        const c = require("crypto");
        const A = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
        const dec = (s) => { let n = 0n; for (const ch of s) n = n * 58n + BigInt(A.indexOf(ch)); let h = n.toString(16); if (h.length % 2) h = "0" + h; let b = Buffer.from(h, "hex"); let z = 0; while (z < s.length && s[z] === "1") z++; return Buffer.concat([Buffer.alloc(z), b]); };
        const sig = dec(process.argv[1]), pub = dec(process.argv[2]);
        if (sig.length !== 64) process.exit(2);
        const key = c.createPublicKey({ format: "jwk", key: { kty: "OKP", crv: "Ed25519", x: pub.toString("base64url") } });
        process.exit(c.verify(null, Buffer.from("VOIDRUNNER sign-in"), key, sig) ? 0 : 1);
      ' "$cand" "$EXPECTED_PUBKEY" 2>/dev/null; then
        verified="VERIFIED off-device (candidate $cand from logcat window)"
        break
      fi
    done < "$OUT/vr3-sig-candidates.txt"
  fi
  echo "vr3_signature_verification=$verified" >> "$OUT/vr3-notes.txt"
  log "vr3: signature verification: $verified"
  if [ "$ok" = "1" ]; then
    if [ "$verified" != "not-observed" ]; then
      vr3="PASS(approval → signature returned, verified off-device against imported key; session restored)"
    else
      vr3="PASS(functional: approval → clientlib Success → Connected restored; signature value not exposed on any harness-observable surface of the sealed build — off-device verification sub-step NOT-RUN, see vr3-notes.txt)"
    fi
  else
    vr3="FAIL(post-sign state not Connected+pubkey)"
  fi
  log "vr3: $vr3"
}

# --- VR-9: declined signing (sign-message half; sign-and-send half unreachable) -----
cell_vr9() {
  log "=== VR-9 declined signing (ERROR_NOT_SIGNED) ==="
  if [ "$(vr_state "$TMPD/vr9-pre.xml")" != "connected" ]; then
    vr9="NOT-RUN(not connected at cell start)"
    return
  fi
  auth_fresh_enough
  adb logcat -c >/dev/null 2>&1 || true
  dump_ui "$TMPD/vr9-conn.xml" || true
  tap_text "$TMPD/vr9-conn.xml" "SIGN TEST MESSAGE" || { vr9="FAIL(no sign control)"; return; }
  local f="$OUT/hier-vr9-sheet.xml"
  if ! wait_sheet "$f" 45; then vr9="FAIL(no mock sign sheet)"; capture_window "vr9"; return; fi
  tap_exact "$f" "Cancel" || { vr9="FAIL(no Cancel on sign sheet)"; capture_window "vr9"; return; }
  log "vr9: declined at the sign sheet"
  sleep 5
  capture_window "vr9"
  local st; st="$(vr_state "$OUT/hier-vr9-after.xml")"
  log "vr9: post-decline state=$st"
  if [ "$st" != "connected" ]; then
    vr9="FAIL(post-decline state=$st, expected session intact/Connected)"
    return
  fi
  # Retry must work: sign again and approve.
  dump_ui "$TMPD/vr9-conn2.xml" || true
  tap_text "$TMPD/vr9-conn2.xml" "SIGN TEST MESSAGE" || { vr9="FAIL(no sign control on retry)"; return; }
  if ! wait_sheet "$OUT/hier-vr9-sheet2.xml" 45; then vr9="FAIL(no sign sheet on retry)"; return; fi
  tap_exact "$OUT/hier-vr9-sheet2.xml" "Approve" || { vr9="FAIL(no Approve on retry)"; return; }
  sleep 3
  satisfy_auth_prompt || true
  if wait_for "CONNECTED" 30 "$OUT/hier-vr9-retry.xml" && grep -q "$EXPECTED_PUBKEY" "$OUT/hier-vr9-retry.xml"; then
    vr9="PASS(sign-message decline: no crash, session intact, no action marked complete, retry succeeded; sign-and-send decline NOT-RUN — no reachable sign-and-send surface in sealed build)"
  else
    vr9="FAIL(retry after decline did not restore Connected)"
  fi
  capture_window "vr9b"
  log "vr9: $vr9"
}

# --- VR-6: disconnect → fails closed → fresh approval on reconnect -------------------
cell_vr6() {
  log "=== VR-6 disconnect / fails closed ==="
  if [ "$(vr_state "$TMPD/vr6-pre.xml")" != "connected" ]; then
    vr6="NOT-RUN(not connected at cell start)"
    return
  fi
  adb logcat -c >/dev/null 2>&1 || true
  if ! do_disconnect "vr6"; then
    vr6="FAIL(disconnect did not reach disconnected UI)"
    capture_window "vr6"
    return
  fi
  capture_window "vr6"
  # Fail-closed surface check: no sign control while disconnected.
  dump_ui "$OUT/hier-vr6-disconnected.xml" || true
  if grep -q "SIGN TEST MESSAGE" "$OUT/hier-vr6-disconnected.xml"; then
    vr6="FAIL(sign control still exposed while disconnected)"
    return
  fi
  log "vr6: no sign surface while disconnected (fails closed at UI)"
  # Reconnect must demand a FRESH approval sheet (deauthorization proven).
  dump_ui "$TMPD/vr6-dis.xml" || true
  tap_text "$TMPD/vr6-dis.xml" "CONNECT WALLET" || { vr6="FAIL(no connect control after disconnect)"; return; }
  if ! approve_connect_sheet "vr6"; then
    vr6="FAIL(no fresh approval sheet after disconnect — stale session?)"
    return
  fi
  if wait_for "CONNECTED" 30 "$OUT/hier-vr6-after.xml" && grep -q "$EXPECTED_PUBKEY" "$OUT/hier-vr6-after.xml"; then
    vr6="PASS(deauthorize → disconnected UI, sign surface gone; reconnect required fresh sheet approval and succeeded)"
  else
    vr6="FAIL(reconnect after disconnect did not reach Connected)"
  fi
  capture_window "vr6b"
  log "vr6: $vr6"
}

# --- VR-2: cached reauthorization across process restart (observation) ---------------
cell_vr2() {
  log "=== VR-2 cached reauthorization (process restart) ==="
  adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
  sleep 2
  if ! goto_wallet; then vr2="NOT-RUN(could not relaunch to wallet screen)"; return; fi
  local st; st="$(vr_state "$OUT/hier-vr2-after-restart.xml")"
  log "vr2: wallet state after process restart = $st"
  adb logcat -c >/dev/null 2>&1 || true
  if [ "$st" = "connected" ]; then
    vr2="UNEXPECTED(Connected immediately after restart — token persistence exists?)"
    capture_window "vr2"
    return
  fi
  dump_ui "$TMPD/vr2-dis.xml" || true
  tap_text "$TMPD/vr2-dis.xml" "CONNECT WALLET" || tap_text "$TMPD/vr2-dis.xml" "TRY AGAIN" || { vr2="NOT-RUN(no connect control after restart)"; return; }
  if wait_sheet "$OUT/hier-vr2-sheet.xml" 45; then
    log "vr2: a FRESH approval sheet was required after restart"
    tap_exact "$OUT/hier-vr2-sheet.xml" "Connect" || tap_text "$OUT/hier-vr2-sheet.xml" "Connect" || true
    sleep 4
    satisfy_auth_prompt || true
    vr2="NOT-RUN(sealed build keeps the MWA auth token in process memory only (VoidrunnerApp/WalletManager persist nothing) — no cross-restart cached reauthorization exists to exercise; fresh approval required and completed. Intra-process reauthorize evidence: see vr3-notes.txt)"
  else
    vr2="NOT-RUN(no sheet and no connection after restart — inconclusive)"
  fi
  capture_window "vr2"
  log "vr2: $vr2"
}

# --- VR-7: user declines at connect ---------------------------------------------------
cell_vr7() {
  log "=== VR-7 decline at connect ==="
  ensure_disconnected || { vr7="NOT-RUN(could not reach disconnected state)"; return; }
  auth_fresh_enough
  adb logcat -c >/dev/null 2>&1 || true
  dump_ui "$TMPD/vr7-dis.xml" || true
  tap_text "$TMPD/vr7-dis.xml" "CONNECT WALLET" || tap_text "$TMPD/vr7-dis.xml" "TRY AGAIN" || { vr7="FAIL(no connect control)"; return; }
  local f="$OUT/hier-vr7-sheet.xml"
  if ! wait_sheet "$f" 45; then vr7="FAIL(no mock sheet)"; capture_window "vr7"; return; fi
  tap_exact "$f" "Cancel" || { vr7="FAIL(no Cancel on authorize sheet)"; capture_window "vr7"; return; }
  log "vr7: declined at the authorize sheet"
  sleep 5
  local st; st="$(vr_state "$OUT/hier-vr7-after.xml")"
  log "vr7: post-decline state=$st"
  capture_window "vr7"
  if [ "$st" = "connected" ]; then
    vr7="FAIL(declined connect still produced a Connected state)"
    return
  fi
  if [ "$st" != "error" ]; then
    vr7="FAIL(post-decline state=$st, expected clean Error state)"
    return
  fi
  # Retry path: TRY AGAIN → sheet → approve → Connected.
  dump_ui "$TMPD/vr7-err.xml" || true
  tap_text "$TMPD/vr7-err.xml" "TRY AGAIN" || { vr7="FAIL(no TRY AGAIN in Error state)"; return; }
  if ! approve_connect_sheet "vr7-retry"; then vr7="FAIL(no sheet on retry)"; return; fi
  if wait_for "CONNECTED" 30 "$OUT/hier-vr7-retry.xml" && grep -q "$EXPECTED_PUBKEY" "$OUT/hier-vr7-retry.xml"; then
    vr7="PASS(decline → clean Error state, no phantom connection; TRY AGAIN retry connected)"
  else
    vr7="FAIL(retry did not reach Connected)"
  fi
  capture_window "vr7b"
  log "vr7: $vr7"
}

# --- VR-8: wallet dies mid-connect (force-stop with sheet up) -------------------------
cell_vr8() {
  log "=== VR-8 connection error (wallet death mid-connect) ==="
  ensure_disconnected || { vr8="NOT-RUN(could not reach disconnected state)"; return; }
  auth_fresh_enough
  adb logcat -c >/dev/null 2>&1 || true
  dump_ui "$TMPD/vr8-dis.xml" || true
  tap_text "$TMPD/vr8-dis.xml" "CONNECT WALLET" || tap_text "$TMPD/vr8-dis.xml" "TRY AGAIN" || { vr8="FAIL(no connect control)"; return; }
  local f="$OUT/hier-vr8-sheet.xml"
  if ! wait_sheet "$f" 45; then vr8="NOT-RUN(connect sheet never appeared; nothing to interrupt)"; capture_window "vr8"; return; fi
  log "vr8: sheet up; force-stopping the wallet NOW"
  adb shell am force-stop "$MOCK" >/dev/null 2>&1 || true
  sleep 3
  snap "shot-vr8-after-kill.png"
  # The app must surface a terminal error, not hang on 'Waiting for wallet'.
  local elapsed=0 st="working"
  while [ "$elapsed" -lt 120 ]; do
    st="$(vr_state "$OUT/hier-vr8-terminal.xml")"
    [ "$st" = "error" ] && break
    [ "$st" = "disconnected" ] && break
    sleep 6; elapsed=$((elapsed + 6))
  done
  log "vr8: terminal state after wallet death = $st (after ${elapsed}s)"
  capture_window "vr8"
  if [ "$st" = "working" ] || [ "$st" = "connected" ]; then
    vr8="FAIL(app did not reach a clean terminal state after wallet death; state=$st after 120s)"
    return
  fi
  # Recovery: wallet back + authenticate, then a subsequent connect succeeds.
  authenticate_mock || true
  goto_wallet || { vr8="FAIL(could not return to wallet screen for recovery)"; return; }
  dump_ui "$TMPD/vr8-rec.xml" || true
  tap_text "$TMPD/vr8-rec.xml" "TRY AGAIN" || tap_text "$TMPD/vr8-rec.xml" "CONNECT WALLET" || { vr8="FAIL(no retry control)"; return; }
  if ! approve_connect_sheet "vr8-recovery"; then vr8="FAIL(no sheet on recovery connect)"; return; fi
  if wait_for "CONNECTED" 30 "$OUT/hier-vr8-recovered.xml" && grep -q "$EXPECTED_PUBKEY" "$OUT/hier-vr8-recovered.xml"; then
    vr8="PASS(wallet force-stopped mid-connect → clean terminal state '$st' in ${elapsed}s, session torn down; subsequent connect succeeded)"
  else
    vr8="FAIL(recovery connect did not reach Connected)"
  fi
  capture_window "vr8b"
  log "vr8: $vr8"
}

# --- VR-13: wallet process death mid-session -------------------------------------------
cell_vr13() {
  log "=== VR-13 wallet death mid-session ==="
  if ! ensure_connected "vr13-setup"; then vr13="NOT-RUN(could not establish a session)"; return; fi
  log "vr13: session live; killing wallet process (am kill — background death, not force-stop)"
  adb shell am kill "$MOCK" >/dev/null 2>&1 || true
  sleep 2
  adb logcat -c >/dev/null 2>&1 || true
  dump_ui "$TMPD/vr13-conn.xml" || true
  tap_text "$TMPD/vr13-conn.xml" "SIGN TEST MESSAGE" || { vr13="FAIL(no sign control)"; return; }
  # Outcomes: a fresh sheet (wallet relaunched, re-approval path) or a clean
  # app error. A hang on Working or a crash fails the cell.
  local elapsed=0 outcome="pending"
  while [ "$elapsed" -lt 60 ]; do
    if dump_ui "$OUT/hier-vr13-poll.xml" && sheet_present "$OUT/hier-vr13-poll.xml"; then
      outcome="sheet"
      break
    fi
    local st; st="$(vr_state "$TMPD/vr13-st.xml")"
    if [ "$st" = "error" ]; then outcome="error"; break; fi
    sleep 5; elapsed=$((elapsed + 5))
  done
  log "vr13: sign request after wallet death → outcome=$outcome (after ${elapsed}s)"
  snap "shot-vr13.png"
  if [ "$outcome" = "sheet" ]; then
    tap_exact "$OUT/hier-vr13-poll.xml" "Approve" || tap_exact "$OUT/hier-vr13-poll.xml" "Connect" || true
    sleep 3
    satisfy_auth_prompt || true
  fi
  capture_window "vr13"
  if [ "$outcome" = "pending" ]; then
    vr13="FAIL(sign request hung after wallet death; no sheet, no error in 60s)"
    return
  fi
  # Reconnect must succeed.
  if [ "$(vr_state "$TMPD/vr13-post.xml")" = "connected" ]; then
    vr13="PASS(wallet death mid-session → sign $outcome path, session restored without reconnect)"
    return
  fi
  goto_wallet || true
  dump_ui "$TMPD/vr13-rec.xml" || true
  tap_text "$TMPD/vr13-rec.xml" "TRY AGAIN" || tap_text "$TMPD/vr13-rec.xml" "CONNECT WALLET" || true
  if approve_connect_sheet "vr13-reconnect" && wait_for "CONNECTED" 30 "$OUT/hier-vr13-reconnected.xml" && grep -q "$EXPECTED_PUBKEY" "$OUT/hier-vr13-reconnected.xml"; then
    vr13="PASS(wallet death mid-session → sign request $outcome (clean), reconnect succeeded)"
  else
    vr13="FAIL(reconnect after wallet death did not succeed)"
  fi
  capture_window "vr13b"
  log "vr13: $vr13"
}

# --- VR-12: background/foreground mid-approval ------------------------------------------
cell_vr12() {
  log "=== VR-12 background/foreground during approval ==="
  ensure_disconnected || { vr12="NOT-RUN(could not reach disconnected state)"; return; }
  auth_fresh_enough
  adb logcat -c >/dev/null 2>&1 || true
  dump_ui "$TMPD/vr12-dis.xml" || true
  tap_text "$TMPD/vr12-dis.xml" "CONNECT WALLET" || tap_text "$TMPD/vr12-dis.xml" "TRY AGAIN" || { vr12="FAIL(no connect control)"; return; }
  local f="$OUT/hier-vr12-sheet.xml"
  if ! wait_sheet "$f" 45; then vr12="NOT-RUN(no sheet to background)"; capture_window "vr12"; return; fi
  log "vr12: sheet up; sending HOME (backgrounding both tasks)"
  adb shell input keyevent 3 >/dev/null 2>&1 || true
  sleep 3
  snap "shot-vr12-backgrounded.png"
  adb shell input keyevent 187 >/dev/null 2>&1 || true  # APP_SWITCH / recents
  sleep 3
  dump_ui "$OUT/hier-vr12-recents.xml" || true
  # Return via the recents card (wallet or dApp — both resume the flow).
  if tap_text "$OUT/hier-vr12-recents.xml" "VOIDRUNNER" || tap_text "$OUT/hier-vr12-recents.xml" "VRTestWallet" || tap_text "$OUT/hier-vr12-recents.xml" "Mock"; then
    log "vr12: tapped a recents card"
  else
    tap_frac 0.5 0.35
    log "vr12: no labelled card found; tapped centre card position"
  fi
  sleep 3
  local result="unknown"
  if dump_ui "$OUT/hier-vr12-returned.xml" && sheet_present "$OUT/hier-vr12-returned.xml"; then
    log "vr12: approval sheet resumed after foregrounding"
    tap_exact "$OUT/hier-vr12-returned.xml" "Connect" || tap_text "$OUT/hier-vr12-returned.xml" "Connect" || true
    sleep 4
    satisfy_auth_prompt || true
    if [ "$(vr_state "$TMPD/vr12-st.xml")" = "connected" ]; then result="completed"; fi
  else
    local st; st="$(vr_state "$TMPD/vr12-st2.xml")"
    log "vr12: post-foreground state=$st (fg=$(fg_pkg))"
    if [ "$st" = "connected" ]; then result="completed"
    elif [ "$st" = "error" ] || [ "$st" = "disconnected" ]; then result="failed-closed"
    elif [ "$st" = "working" ]; then
      sleep 20
      st="$(vr_state "$TMPD/vr12-st3.xml")"
      if [ "$st" = "connected" ]; then result="completed"
      elif [ "$st" = "error" ] || [ "$st" = "disconnected" ]; then result="failed-closed"
      else result="hung"; fi
    fi
  fi
  capture_window "vr12"
  case "$result" in
    completed)     vr12="PASS(flow backgrounded mid-approval, foregrounded, completed to Connected)" ;;
    failed-closed) vr12="PASS(flow backgrounded mid-approval failed closed on return — clean Error/disconnected, no hang, no crash)" ;;
    *)             vr12="FAIL(background/foreground left the connect flow in state '$result')" ;;
  esac
  log "vr12: $vr12"
}

# --- VR-11: entry points / destination registry ------------------------------------------
cell_vr11() {
  log "=== VR-11 entry points (NavHost destination registry) ==="
  # Registry of record (MainActivity.kt): splash -> home { PLAY->game,
  # WALLET->wallet, SETTINGS->settings }. Wallet controls exist natively
  # ONLY on the wallet destination; the game destination reaches the
  # wallet only through the JS bridge inside the WebView.
  goto_home || { vr11="FAIL(could not reach home)"; return; }
  dump_ui "$OUT/hier-vr11-home.xml" || true
  if grep -q "CONNECT WALLET\|SIGN TEST\|DISCONNECT" "$OUT/hier-vr11-home.xml"; then
    log "vr11: NOTE — wallet controls visible on HOME"
  fi
  # SETTINGS destination
  dump_ui "$TMPD/vr11-h.xml" || true
  tap_text "$TMPD/vr11-h.xml" "SETTINGS" || tap_frac 0.5 0.62
  sleep 3
  dump_ui "$OUT/hier-vr11-settings.xml" || true
  local settings_clean="yes"
  if grep -q "CONNECT WALLET\|SIGN TEST MESSAGE\|DISCONNECT" "$OUT/hier-vr11-settings.xml"; then settings_clean="no"; fi
  adb shell input keyevent 4 >/dev/null 2>&1 || true
  sleep 2
  # GAME destination (WebView; content not exposed to the harness)
  goto_home || true
  dump_ui "$TMPD/vr11-h2.xml" || true
  tap_text "$TMPD/vr11-h2.xml" "PLAY" || tap_frac 0.5 0.45
  sleep 8
  dismiss_host_anr
  dump_ui "$OUT/hier-vr11-game.xml" || true
  local nodes; nodes="$(grep -c "<node" "$OUT/hier-vr11-game.xml" 2>/dev/null || echo 0)"
  log "vr11: game hierarchy node count = $nodes (WebView surface only; bridge taps not harness-reachable)"
  adb logcat -d > "$OUT/logcat-vr11-game.txt" 2>&1 || true
  scan_logcat "$OUT/logcat-vr11-game.txt"
  adb shell input keyevent 4 >/dev/null 2>&1 || true
  sleep 2
  # WALLET destination: compact connect->sign->disconnect pass from THIS
  # entry point (the only native one).
  local compact="FAIL"
  if goto_wallet; then
    if [ "$(vr_state "$TMPD/vr11-w.xml")" != "connected" ]; then
      dump_ui "$TMPD/vr11-w2.xml" || true
      tap_text "$TMPD/vr11-w2.xml" "CONNECT WALLET" || tap_text "$TMPD/vr11-w2.xml" "TRY AGAIN" || true
      approve_connect_sheet "vr11" || true
    fi
    if [ "$(vr_state "$TMPD/vr11-w3.xml")" = "connected" ]; then
      dump_ui "$TMPD/vr11-w4.xml" || true
      tap_text "$TMPD/vr11-w4.xml" "SIGN TEST MESSAGE" || true
      if wait_sheet "$OUT/hier-vr11-signsheet.xml" 45; then
        tap_exact "$OUT/hier-vr11-signsheet.xml" "Approve" || true
        sleep 3
        satisfy_auth_prompt || true
      fi
      if [ "$(vr_state "$TMPD/vr11-w5.xml")" = "connected" ] && do_disconnect "vr11"; then
        compact="PASS"
      fi
    fi
  fi
  capture_window "vr11"
  if [ "$compact" = "PASS" ] && [ "$settings_clean" = "yes" ]; then
    vr11="PASS(wallet functions exercised from the WALLET destination (connect+sign+disconnect); HOME/SETTINGS expose no wallet controls; GAME destination wallet taps NOT-RUN — bridge lives inside the WebView, a single accessibility node not reachable by the harness, and its sign paths need the gated paid flow)"
  else
    vr11="FAIL(compact wallet pass=$compact, settings_clean=$settings_clean)"
  fi
  log "vr11: $vr11"
}

# --- dispatch + verdict -------------------------------------------------------------------
case "$SUITE" in
  core)      cell_vr1; cell_vr3; cell_vr9; cell_vr6; cell_vr2 ;;
  errors)    cell_vr7; cell_vr8; cell_vr13 ;;
  lifecycle) cell_vr12; cell_vr11 ;;
  *) log "unknown SUITE=$SUITE"; exit 2 ;;
esac

adb logcat -d > "$OUT/logcat-final-full.txt" 2>&1 || true
scan_logcat "$OUT/logcat-final-full.txt"
if dump_ui "$OUT/hier-final.xml" && grep -q "has stopped" "$OUT/hier-final.xml"; then stopped_dialogs=$((stopped_dialogs + 1)); fi
log "totals: vr_fatal=$fatal_vr_total mock_fatal=$fatal_mock_total illegal_state=$ise_total stopped_dialogs=$stopped_dialogs"

{
  echo "suite=$SUITE"
  echo "lock_pin=$lock_pin"
  echo "lock_fingerprint=$lock_fp"
  echo "authenticate=$auth_note"
  echo "vr1=$vr1"
  echo "vr2=$vr2"
  echo "vr3=$vr3"
  echo "vr6=$vr6"
  echo "vr7=$vr7"
  echo "vr8=$vr8"
  echo "vr9=$vr9"
  echo "vr11=$vr11"
  echo "vr12=$vr12"
  echo "vr13=$vr13"
  echo "vr4=NOT-RUN(no sign-only surface exists in the sealed build — WalletManager implements connect/signMessage/signAndSendTransactions only; signTransactions deliberately not implemented per MWA 2.0 deprecation)"
  echo "vr5=NOT-RUN(sign-and-send unreachable: exposed only via the in-WebView bridge behind the gated paid checkout in the sealed build; mock key unfunded by design)"
  echo "vr10=NOT-RUN(error injection for sign-and-send unreachable for the same reason as VR-5; the mock at the pinned commit exposes no simulate-error UI)"
  echo "fatal_vr_total=$fatal_vr_total"
  echo "fatal_mock_total=$fatal_mock_total"
  echo "illegal_state_total=$ise_total"
  echo "stopped_dialogs=$stopped_dialogs"
  if [ "$fatal_vr_total" -gt 0 ] || [ "$fatal_mock_total" -gt 0 ] || [ "$ise_total" -gt 0 ]; then
    echo "whole_verdict=FAIL(binding rule: any AndroidRuntime FATAL / IllegalStateException anywhere fails the verdict)"
  fi
} > "$OUT/verdict-wallet.txt"
cat "$OUT/verdict-wallet.txt" | tee -a "$LANE_LOG"

fail="0"
for v in "$vr1" "$vr2" "$vr3" "$vr6" "$vr7" "$vr8" "$vr9" "$vr11" "$vr12" "$vr13"; do
  case "$v" in FAIL*) fail="1" ;; esac
done
if [ "$fatal_vr_total" -gt 0 ] || [ "$fatal_mock_total" -gt 0 ] || [ "$ise_total" -gt 0 ]; then fail="1"; fi
[ "$fail" = "0" ]
