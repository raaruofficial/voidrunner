#!/usr/bin/env bash
# verify-diag-wallet.sh — v1.0.12 STORE-REJECTION diagnosis driver (2026-11-01).
#
# Reproduces the reviewer's wallet flow against the SEALED v1.0.12 APK
# (hash-gated by the diag-suite action) with three wallet compositions:
#   WALLET_KIND=mock       Mock MWA Wallet @ d444aff0 (control, lane-built)
#   WALLET_KIND=phantom    Phantom 26.23.1 production release (APKM bundle)
#   WALLET_KIND=seedvault  Seed Vault SDK simulator + fakewallet (SDK artefacts)
#
# Cells (run in the order given by $CELLS):
#   probe    (seedvault) MWA association-intent resolution census + package
#            intent-filter dumps — does any simulator-backed MWA endpoint exist?
#   onboard  (phantom)   first-run wallet creation, candidate-text driven;
#            every step's hierarchy is evidence, a dead-end is a finding.
#   connect  native WALLET screen connect (WalletManager.performConnect)
#            against the installed wallet, generic approval choreography.
#   gate     the reviewer's path: PLAY -> production game -> .skr sign-in
#            gate -> handle -> proof panel -> one-tap bridge button; watch
#            for the shipped failure copy + whether the wallet ever engages.
#
# Diagnosis only: nothing here patches, deploys, or submits anything.
# Env: WALLET_KIND, WALLET_PKG, CELLS, VR_APK, MOCK_APK, PHANTOM_DIR,
#      SV_SIM_APK, SV_FAKE_APK, OUT, DEVICE_PIN (default 1234),
#      GATE_HANDLE (default raaru.skr), ONBOARD_PW (throwaway, phantom cell)
set -u
export LC_ALL=C

VR_PKG="com.voidrunner.app"
ACT="$VR_PKG/.MainActivity"
WALLET_KIND="${WALLET_KIND:-mock}"
WALLET_PKG="${WALLET_PKG:-}"
# The emulator-runner executes the action's script block line-by-line via
# sh -c (run 41351187212 died on multi-line if-blocks), so no exports can
# be handed in from the action — derive wallet identity + SV paths here.
if [ -z "$WALLET_PKG" ]; then
  case "$WALLET_KIND" in
    phantom)   WALLET_PKG="app.phantom" ;;
    seedvault) WALLET_PKG="com.solanamobile.fakewallet" ;;
    *)         WALLET_PKG="com.solana.mwallet" ;;
  esac
fi
if [ "$WALLET_KIND" = "seedvault" ]; then
  SV_SIM_APK="${SV_SIM_APK:-$(find "${GITHUB_WORKSPACE:-$PWD}/sv-src/SeedVaultSimulator" -path '*outputs/apk*' -name '*.apk' 2>/dev/null | head -1)}"
  SV_FAKE_APK="${SV_FAKE_APK:-$(find "${GITHUB_WORKSPACE:-$PWD}/sv-src/fakewallet" -path '*outputs/apk*' -name '*.apk' 2>/dev/null | head -1)}"
  export SV_SIM_APK SV_FAKE_APK
fi
CELLS="${CELLS:-gate}"
VR_APK="${VR_APK:-}"
OUT="${OUT:-fun001-diag-evidence}"
DEVICE_PIN="${DEVICE_PIN:-1234}"
GATE_HANDLE="${GATE_HANDLE:-raaru.skr}"
ONBOARD_PW="${ONBOARD_PW:-DiagPass2026!}"
TMPD="$(mktemp -d)"
mkdir -p "$OUT"
NOTES="$OUT/diag-notes.txt"
LANE_LOG="$OUT/diag-lane.log"
: > "$NOTES"; : > "$LANE_LOG"

note() { echo "$*" | tee -a "$NOTES"; }
log() { echo "$*" | tee -a "$LANE_LOG"; }

# ---------------------------------------------------------------- helpers
dump_is_substantive() {
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
      mv "$dst.tmp" "$dst"; return 0
    fi
    sleep 3
  done
  log "dump_ui: FAILED after 8 attempts -> $dst"
  return 1
}

_tap_coords() { # $1 = file, $2 = python regex over node attrs
  python3 - "$1" "$2" <<'PY'
import re, sys
data = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
pat = sys.argv[2]
for m in re.finditer(r"<node[^>]*>", data):
    tag = m.group(0)
    if re.search(pat, tag):
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
        if b:
            print(f"{(int(b.group(1))+int(b.group(3)))//2} {(int(b.group(2))+int(b.group(4)))//2}")
            break
PY
}

tap_text() { # $1 = file, $2 = substring of text=
  local c; c="$(_tap_coords "$1" "text=\"[^\"]*$(printf '%s' "$2" | sed 's/[][\.*^$/]/\\&/g')[^\"]*\"")"
  if [ -n "$c" ]; then adb shell input tap $c; return 0; fi; return 1
}

tap_exact() { # $1 = file, $2 = exact text=
  local c; c="$(_tap_coords "$1" "text=\"$(printf '%s' "$2" | sed 's/[][\.*^$/]/\\&/g')\"")"
  if [ -n "$c" ]; then adb shell input tap $c; return 0; fi; return 1
}

tap_class_nth() { # $1 = file, $2 = class, $3 = nth (0-based)
  local coords
  coords="$(python3 - "$1" "$2" "$3" <<'PY'
import re, sys
data = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
want_cls, nth = sys.argv[2], int(sys.argv[3])
seen = 0
for m in re.finditer(r"<node[^>]*>", data):
    tag = m.group(0)
    c = re.search(r'class="([^"]+)"', tag)
    if c and c.group(1) == want_cls:
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
        if b:
            if seen == nth:
                print(f"{(int(b.group(1))+int(b.group(3)))//2} {(int(b.group(2))+int(b.group(4)))//2}")
                break
            seen += 1
PY
)"
  if [ -n "$coords" ]; then adb shell input tap $coords; return 0; fi; return 1
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

wait_for() { # $1 = grep -E pattern, $2 = timeout secs, $3 = dump file
  local pat="$1" timeout_s="$2" dst="$3" elapsed=0
  while [ "$elapsed" -lt "$timeout_s" ]; do
    if dump_ui "$dst" && grep -qE "$pat" "$dst"; then return 0; fi
    dismiss_host_anr; sleep 3; elapsed=$((elapsed + 3))
  done
  dump_ui "$dst" || true
  grep -qE "$pat" "$dst" 2>/dev/null
}

snap() { adb exec-out screencap -p > "$OUT/$1" 2>/dev/null || true; }
fg_pkg() { adb shell dumpsys activity activities 2>/dev/null | sed -n 's/.*topResumedActivity=.* \([a-zA-Z0-9_.]*\)\/.*/\1/p' | head -n 1; }

dismiss_host_anr() {
  local f="$TMPD/anr.xml"
  if dump_ui "$f" 2>/dev/null && grep -qE "isn't responding" "$f" && ! grep -q "$VR_PKG" "$f"; then
    tap_text "$f" "Wait" || true
  fi
}

ensure_unlocked() {
  adb shell input keyevent 224 >/dev/null 2>&1 || true   # wake
  sleep 1
  local f="$TMPD/unlock.xml"
  if dump_ui "$f" && grep -qiE "swipe|PIN|pattern|password" "$f"; then
    adb shell input swipe 540 1800 540 800 300 >/dev/null 2>&1 || true
    sleep 1
    if dump_ui "$f" && grep -qiE "Enter PIN|PIN" "$f"; then
      adb shell input text "$DEVICE_PIN" >/dev/null 2>&1 || true
      adb shell input keyevent 66 >/dev/null 2>&1 || true
      sleep 2
    fi
  fi
}

scan_fatals() { # $1 = logcat file; echoes counts line
  local vr mock
  vr="$(grep -c "FATAL EXCEPTION" "$1" 2>/dev/null || true)"
  echo "fatal_lines=$(grep -c 'FATAL' "$1" 2>/dev/null || true) fatal_exceptions=$vr"
}

capture_logcat() { # $1 = tag
  adb logcat -d > "$OUT/logcat-$1.txt" 2>/dev/null || true
  log "logcat-$1: $(scan_fatals "$OUT/logcat-$1.txt")"
}

# ---------------------------------------------------------------- setup
setup_device() {
  log "setup: wallet_kind=$WALLET_KIND cells=$CELLS"
  adb wait-for-device
  adb shell locksettings set-pin "$DEVICE_PIN" >> "$LANE_LOG" 2>&1 || true
  ensure_unlocked
  # sealed app under test
  if [ -n "$VR_APK" ]; then
    log "install VR: $(sha256sum "$VR_APK" | awk '{print $1}')"
    adb install -r "$VR_APK" >> "$LANE_LOG" 2>&1 || log "VR install FAILED"
  fi
  case "$WALLET_KIND" in
    mock)
      [ -n "${MOCK_APK:-}" ] && { adb install -r "$MOCK_APK" >> "$LANE_LOG" 2>&1 || log "mock install FAILED"; }
      ;;
    phantom)
      local dir="${PHANTOM_DIR:-}" base
      base="$dir/base.apk"
      if [ -f "$base" ]; then
        local parts=("$base")
        for s in split_config.x86_64.apk split_config.en.apk split_config.xxxhdpi.apk split_config.xhdpi.apk; do
          [ -f "$dir/$s" ] && parts+=("$dir/$s")
        done
        log "phantom install-multiple: ${parts[*]}"
        if ! adb install-multiple -r "${parts[@]}" >> "$LANE_LOG" 2>&1; then
          log "phantom minimal split set FAILED; trying full split set"
          adb install-multiple -r "$base" "$dir"/split_config.*.apk >> "$LANE_LOG" 2>&1 || log "phantom install FAILED (full set)"
        fi
      else
        log "phantom base.apk MISSING at $base"
      fi
      ;;
    seedvault)
      [ -n "${SV_SIM_APK:-}" ] && { adb install -r "$SV_SIM_APK" >> "$LANE_LOG" 2>&1 || log "simulator install FAILED"; }
      [ -n "${SV_FAKE_APK:-}" ] && { adb install -r "$SV_FAKE_APK" >> "$LANE_LOG" 2>&1 || log "fakewallet install FAILED"; }
      ;;
  esac
  adb shell pm list packages > "$OUT/pm-packages.txt" 2>/dev/null || true
  note "setup_done wallet_kind=$WALLET_KIND wallet_pkg=${WALLET_PKG:-?} fg=$(fg_pkg)"
}

goto_home() {
  ensure_unlocked
  adb shell am start -W -n "$ACT" >/dev/null 2>&1 || true
  wait_for "PLAY" 30 "$OUT/hier-home.xml" || true
}

# ---------------------------------------------------------------- cells
cell_probe() {
  note "probe: MWA association-intent resolution census"
  {
    echo "== query-intent-activities VIEW solana-wallet://localhost =="
    adb shell cmd package query-intent-activities -a android.intent.action.VIEW -d "solana-wallet://localhost" 2>&1 | head -60
    echo "== pm query-intent-activities (legacy form) =="
    adb shell pm query-intent-activities -a android.intent.action.VIEW -d "solana-wallet://localhost" 2>&1 | head -40
    echo "== solana-related packages =="
    adb shell pm list packages 2>/dev/null | grep -iE "solana|seed|fakewallet|phantom" || true
    for p in com.solanamobile.fakewallet com.solanamobile.seedvault; do
      echo "== dumpsys package $p (filters) =="
      adb shell dumpsys package "$p" 2>/dev/null | grep -iE "intent|solana-wallet|Activity|Service" | head -30 || true
    done
  } > "$OUT/probe-intent.txt" 2>&1
  if grep -qiE "fakewallet" "$OUT/probe-intent.txt" && grep -qiE "solana-wallet" "$OUT/probe-intent.txt"; then
    note "probe_result=fakewallet MAY resolve MWA intent (inspect probe-intent.txt)"
  else
    note "probe_result=NO simulator-backed package resolves the MWA association intent"
  fi
}

cell_onboard() {
  # Phantom first-run creation. Candidate-driven; every step dumps evidence.
  local pkg="${WALLET_PKG:-app.phantom}"
  adb shell monkey -p "$pkg" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || \
    adb shell am start -W -a android.intent.action.MAIN -c android.intent.category.LAUNCHER "$pkg" >/dev/null 2>&1 || true
  sleep 6
  local step f ok=""
  try_tap_any() { # $1 = dump file; rest = candidate texts
    local file="$1"; shift
    local cand
    for cand in "$@"; do
      if tap_exact "$file" "$cand" || tap_text "$file" "$cand"; then echo "$cand"; return 0; fi
    done
    return 1
  }
  # s1: entry
  f="$OUT/hier-onboard-s1.xml"
  if wait_for "wallet|Wallet" 45 "$f"; then
    step="$(try_tap_any "$f" "Create new wallet" "Create a new wallet" "Get started" "Get Started" "I'm new to crypto" 2>/dev/null || true)"
    note "onboard_s1 tapped='${step:-none}' fg=$(fg_pkg)"; sleep 4
  else
    note "onboard_result=DEADEND_S1 (no wallet UI in 45s) fg=$(fg_pkg)"; snap shot-onboard-deadend.png; return 1
  fi
  # s2: creation method (seed phrase path)
  f="$OUT/hier-onboard-s2.xml"; dump_ui "$f" || true
  step="$(try_tap_any "$f" "Seed phrase" "Seed Phrase" "secret recovery phrase" "Create with seed phrase" "Continue with seed phrase" 2>/dev/null || true)"
  [ -n "$step" ] && { note "onboard_s2 tapped='$step'"; sleep 4; }
  # s3: password / PIN creation if a form is present
  f="$OUT/hier-onboard-s3.xml"; dump_ui "$f" || true
  if grep -qiE "password|passcode|create a pin|create pin" "$f"; then
    tap_class_nth "$f" "android.widget.EditText" 0 || tap_frac 0.5 0.35
    sleep 1; adb shell input text "$ONBOARD_PW" || true; sleep 1
    dump_ui "$f" || true
    tap_class_nth "$f" "android.widget.EditText" 1 && { sleep 1; adb shell input text "$ONBOARD_PW" || true; sleep 1; }
    dump_ui "$f" || true
    step="$(try_tap_any "$f" "Continue" "Create password" "Create" "Next" "Done" 2>/dev/null || true)"
    note "onboard_s3 password form filled tapped='${step:-none}'"; sleep 5
  else
    note "onboard_s3 no password form seen"
  fi
  # s4..s7: generic progression (backup nags, biometrics, notifications, username)
  local i
  for i in 4 5 6 7; do
    f="$OUT/hier-onboard-s$i.xml"
    if dump_ui "$f" && grep -qE "Deposit|Receive|Swap|Send|Buy|Activity|\\$0" "$f" && [ "$(fg_pkg)" = "$pkg" ]; then
      ok=1; note "onboard_home_reached at s$i"; break
    fi
    # checkbox-style acknowledgements first
    tap_text "$f" "I understand" >/dev/null 2>&1 || true
    tap_text "$f" "I saved" >/dev/null 2>&1 || true
    step="$(try_tap_any "$f" "Remind me later" "Skip" "Not now" "Maybe later" "No thanks" "I've saved it" "I saved my recovery phrase" "Continue" "Done" "Got it" 2>/dev/null || true)"
    note "onboard_s$i tapped='${step:-none}' fg=$(fg_pkg)"
    [ -z "$step" ] && { snap "shot-onboard-s$i.png"; }
    sleep 4
  done
  f="$OUT/hier-onboard-final.xml"; dump_ui "$f" || true; snap shot-onboard-final.png
  if [ -n "$ok" ] || { [ "$(fg_pkg)" = "$pkg" ] && grep -qE "Deposit|Receive|Swap|Send|Buy|Activity" "$f"; }; then
    note "onboard_result=HOME"
  else
    note "onboard_result=DEADEND (see hier-onboard-*.xml) fg=$(fg_pkg)"
  fi
}

cell_connect() {
  goto_home
  local f="$OUT/hier-connect-entry.xml"
  dump_ui "$f" || return 1
  tap_text "$f" "WALLET" || tap_frac 0.5 0.55
  if ! wait_for "CONNECT WALLET|CONNECTED|Error" 25 "$OUT/hier-connect-wallet.xml"; then
    note "connect_result=NO_WALLET_SCREEN"; return 1
  fi
  f="$OUT/hier-connect-wallet.xml"
  if grep -q "CONNECTED" "$f" && ! grep -q "Not connected" "$f"; then
    note "connect_result=ALREADY_CONNECTED"; return 0
  fi
  adb logcat -c >/dev/null 2>&1 || true
  tap_text "$f" "CONNECT WALLET" || { note "connect_result=NO_CONNECT_BUTTON"; return 1; }
  note "connect: tapped CONNECT WALLET, working approval loop (budget 180s)"
  local elapsed=0 n=0 tapped=""
  while [ "$elapsed" -lt 180 ]; do
    sleep 5; elapsed=$((elapsed + 5))
    f="$OUT/hier-connect-loop-$elapsed.xml"
    if ! dump_ui "$f"; then continue; fi
    if grep -q "CONNECTED" "$f" && ! grep -q "Not connected" "$f" && grep -q "$VR_PKG" "$f"; then
      local pk; pk="$(grep -oE 'text="[1-9A-HJ-NP-Za-km-z]{32,44}"' "$f" | head -1 | sed 's/text="//;s/"//')"
      note "connect_result=CONNECTED pubkey=${pk:-unknown} after ${elapsed}s approvals=$n"
      capture_logcat connect; return 0
    fi
    if grep -q "TRY AGAIN" "$f"; then
      local err; err="$(grep -oE 'text="[^"]{4,160}"' "$f" | sed 's/text="//;s/"$//' | grep -viE "^(TRY AGAIN|WALLET|Error|CONNECTED)$" | head -3 | tr '\n' '|')"
      note "connect_result=ERROR after ${elapsed}s approvals=$n error_texts=$err"
      capture_logcat connect; return 1
    fi
    if [ "$(fg_pkg)" = "$WALLET_PKG" ]; then
      cp "$f" "$OUT/hier-connect-sheet-$elapsed.xml"; snap "shot-connect-sheet-$elapsed.png"
      tapped=""
      for cand in "Connect" "Approve" "Confirm" "Continue" "Allow" "Unlock" "Sign"; do
        if tap_exact "$f" "$cand" || tap_text "$f" "$cand"; then tapped="$cand"; n=$((n + 1)); break; fi
      done
      if [ -z "$tapped" ] && grep -q "android.widget.EditText" "$f"; then
        # wallet unlock form (password) — fill with the onboarding password
        tap_class_nth "$f" "android.widget.EditText" 0 && { adb shell input text "$ONBOARD_PW" || true; tapped="filled-unlock"; }
      fi
      log "connect loop ${elapsed}s: wallet fg, tapped='${tapped:-none}'"
    fi
    if grep -qiE "Authenticate|fingerprint" "$f"; then
      adb emu finger touch 1 >/dev/null 2>&1 || true
    fi
  done
  note "connect_result=TIMEOUT after 180s approvals=$n fg=$(fg_pkg)"
  snap shot-connect-timeout.png
  capture_logcat connect
  return 1
}

cell_gate() {
  goto_home
  local f="$OUT/hier-gate-home.xml"
  dump_ui "$f" || return 1
  tap_text "$f" "PLAY" || tap_frac 0.5 0.35
  note "gate: PLAY tapped; waiting for game sign-in surface (network load)"
  if ! wait_for "PILOT SIGNAL|SIGN IN WITH|IDENTITY" 120 "$OUT/hier-gate-game.xml"; then
    note "gate_result=GAME_DID_NOT_LOAD fg=$(fg_pkg)"
    snap shot-gate-noload.png; capture_logcat gate; return 1
  fi
  f="$OUT/hier-gate-game.xml"; snap shot-gate-game.png
  # focus the handle field and type the handle
  if ! tap_class_nth "$f" "android.widget.EditText" 0; then tap_frac 0.5 0.45; fi
  sleep 1
  adb shell input text "$GATE_HANDLE" || true
  sleep 1
  dump_ui "$OUT/hier-gate-typed.xml" || true; snap shot-gate-typed.png
  tap_exact "$OUT/hier-gate-typed.xml" "SIGN IN" || tap_text "$OUT/hier-gate-typed.xml" "SIGN IN" || { note "gate_result=NO_SIGNIN_BUTTON"; capture_logcat gate; return 1; }
  note "gate: handle '$GATE_HANDLE' submitted; waiting for proof panel"
  if ! wait_for "PROVE IT|LINK MY WALLET|Paste the base58|reserved|not registered|couldn" 90 "$OUT/hier-gate-panel.xml"; then
    note "gate_result=NO_PANEL fg=$(fg_pkg)"
    snap shot-gate-nopanel.png; capture_logcat gate; return 1
  fi
  f="$OUT/hier-gate-panel.xml"; snap shot-gate-panel.png
  if grep -qE "reserved|not registered" "$f"; then
    note "gate_result=SERVER_REFUSED_HANDLE (panel never offered)"; capture_logcat gate; return 1
  fi
  adb logcat -c >/dev/null 2>&1 || true
  local t0=$SECONDS
  tap_text "$f" "PROVE IT" || tap_text "$f" "LINK MY WALLET" || { note "gate_result=NO_BRIDGE_BUTTON"; capture_logcat gate; return 1; }
  note "gate: bridge button tapped at t0; observing 60s (wallet_pkg=${WALLET_PKG:-none})"
  local i fg_seen="" outcome="TIMEOUT_NO_CHANGE"
  for i in $(seq 1 20); do
    sleep 3
    local cur; cur="$(fg_pkg)"
    [ "$cur" = "$WALLET_PKG" ] && fg_seen="yes"
    f="$OUT/hier-gate-obs-$i.xml"
    if dump_ui "$f"; then
      if grep -q "Wallet signing didn't complete" "$f"; then outcome="FAILURE_COPY_MB (Wallet signing didn't complete)"; break; fi
      if grep -q "The wallet didn't return a signature" "$f"; then outcome="FAILURE_COPY_NB (wallet didn't return a signature)"; break; fi
      if grep -q "Signing was cancelled" "$f"; then outcome="FAILURE_COPY_AB (cancelled)"; break; fi
      if ! grep -qE "PROVE IT|LINK MY WALLET|WAITING FOR WALLET" "$f" && grep -qE "PILOT SIGNAL|PLAY|Sector|sector|Wave|wave" "$f"; then
        outcome="PANEL_CLEARED (possible success — inspect dumps)"; break
      fi
    fi
  done
  note "gate_result=$outcome elapsed=$((SECONDS - t0))s wallet_foreground_seen=${fg_seen:-no}"
  snap shot-gate-final.png
  dump_ui "$OUT/hier-gate-final.xml" || true
  capture_logcat gate
  grep -iE "VoidrunnerWallet|chromium|solana-wallet|ActivityTaskManager.*START" "$OUT/logcat-gate.txt" | head -40 > "$OUT/gate-logcat-extract.txt" || true
}

# ---------------------------------------------------------------- main
setup_device
for cell in $CELLS; do
  note "=== cell $cell (wallet=$WALLET_KIND) ==="
  case "$cell" in
    probe) cell_probe ;;
    onboard) cell_onboard ;;
    connect) cell_connect || true ;;
    gate) cell_gate || true ;;
    *) note "unknown cell $cell" ;;
  esac
done
adb logcat -d > "$OUT/logcat-final.txt" 2>/dev/null || true
adb shell getprop ro.build.version.sdk > "$OUT/device-info.txt" 2>/dev/null || true
adb shell getprop ro.build.version.release >> "$OUT/device-info.txt" 2>/dev/null || true
note "diag_done wallet_kind=$WALLET_KIND"
log "driver finished"
