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
# Driver r7 (v1.0.5 re-run): keyguard detection broadened — v105 r1
# starved both core jobs behind an all-SystemUI 'Unlock for all
# features and data' keyguard presentation the r5 triggers missed
# (structural detection in looks_locked + authenticate relaunch).
#
# Driver r8 (v1.0.5 re-run): VR-12 returns via the WALLET's recents
# card (labels are content-desc on API 36; r1 blind-tapped the dApp
# card and mis-graded a waiting app as 'hung'), and VR-11 starts
# from a clean process so a prior cell's pending session cannot
# poison its compact pass.
#
# Driver r10 (v1.0.7 verdict): VR-3 sign runs TWICE per core suite
# (vr3_attempt, tags vr3/vr3b); connect completion accepts BOTH paths
# — approval sheet or silent reauthorize via a live cached authToken
# (tap_connect_and_complete; the r9 sheet-only probes timed out on
# the silent path and starved VR-9 / misread VR-13's reconnect);
# VR-12 polls the post-return state for up to 30 s and records the
# resolution + latency (vr12-notes.txt), then proves the retry
# affordance recovers the flow.
# Driver r10.3 (REPORT_V107 diagnostic annex, main's relay of the
# HAUNT v0.1.15 finding on the identical cure shape): VR-12's
# observation window is VR12_OBSERVE_S (default 30 s = the SS2.2
# cell). A diagnostic dispatch may extend it (150 s) to put the
# 120 s backstop's behaviour on record: every 3 s sample lands in
# vr12-notes.txt, the grade stays keyed to resolution within 30 s,
# a late resolution is graded FAIL with its latency named, and the
# post-resolution recovery connect is recorded in the notes either
# way. tap_connect_and_complete also works the mock's Authenticate
# gate if a relaunched wallet sits at it.
# Driver r11 (v1.0.8 verdict, REPORT_V108): the reconciler now resolves
# UI state DIRECTLY from session truth (HAUNT v0.1.16 shape), so VR-12's
# PASS bar tightens to the design: resolution within grace+15 s of the
# return moment (latency <= 20 s; the 5 s grace is inside the app). The
# cell is graded as THREE first-class lines — vr12a (resolution
# promptness, connect branch), vr12b (in-process TRY AGAIN retry leg),
# vr12sign (sign branch: abandoned sign must resolve directly to
# Connected+pubkey, then a further sign must succeed) — recorded in
# vr12-notes.txt / vr12s-notes.txt and echoed into the verdict file.
# Driver r12 (v1.0.9 verdict prep): VR-12 logcat capture ordering FIX.
# REPORT_V108 §VR-12(b) documented that the retry leg's logcat window
# did not survive: cell_vr12 called capture_window "vr12" (dump +
# CLEAR) immediately after the resolution polling, BEFORE the retry
# leg ran, and the next cell's opening logcat -c wiped what the retry
# left in the buffer — so the retry's association behaviour was not
# determinable from VR's artefacts. The cell now captures exactly
# ONCE, after the retry leg: the clear at cell start opens the window
# and the single end-of-cell capture exports the FULL contiguous
# vr12 window — initial connect, abandonment, resolution, retry
# attempts (incl. the app's per-attempt Log.d markers, tag
# VoidrunnerWallet) and settlement — as logcat-vr12.txt with the
# cell's artefacts. No logcat clear happens between the resolution
# and the retry leg anymore.
# Driver r13 (v1.0.9 verdict, REPORT_V109): the retry approval helper
# (tap_connect_and_complete) now approves EVERY sheet a connect
# produces, not just the first — the v1.0.9 post-interruption refire
# loop can surface several sheets in one leg (a swallowed attempt's
# zombie sheet, then the refired attempt's own sheet on its fresh
# association; HAUNT r6 choreography). One tap on the recovery
# control, then an approval loop: bounded at 4 approvals, each waited
# on inside a 165 s overall budget that covers the full loop
# (3 attempts x 35 s + refire pauses + approval/auth time), with a
# <tag>-tcc.txt summary (approvals / elapsed / outcome) per call.
# The lifecycle suite order also changes: VR-11 runs FIRST, so the
# 120-min job cap cannot eat it after the long VR-12 legs
# (REPORT_V108 lost the API-35 VR-11 rep exactly that way).
#
# Driver r16 (v1.0.11 verdict, REPORT_V111): ONE change — the VR-12S
# follow-up sign leg. v1.0.11 protects the follow-up sign with a
# zombie-clear GATE (CURE_V111): after the sign-branch resolution, the
# follow-up sign does not transact until the zombie sheet of the
# interrupted request clears — and the zombie clears only when its
# result is delivered, i.e. when its sheet is APPROVED (or dismissed).
# The r15 leg waited for the follow-up's OWN sheet first, which on
# the cured build deadlocks the leg (that sheet cannot exist until
# the zombie is approved) and on the faulted predecessor graded the
# zombie approval as if it were the follow-up's (REPORT_V110: the
# driver approved the zombie, whose late result is generation-
# suppressed, and read the still-Working app as the failure). The
# leg now approves SEQUENTIALLY — zombie sheet first, then the
# follow-up's own sheet (approve_followup_sign, approve-all bounded
# at 4, PASS requires >= 2 approvals AND Connected+pubkey, so a lone
# zombie approval can never pass the leg) — and files a dedicated
# follow-up logcat window (logcat-vr12s-followup.txt) carrying the
# gate's Log.d markers (tag VoidrunnerWallet: zombie gate wait-start
# / cleared-by-late-result / wait-expired) for wire grading. Every
# other cell keeps the r15 choreography unchanged.
#
# Driver r15 (v1.0.10 cure, REPORT_V109): two lifecycle fixes.
# (r14 was the v1.0.9 verdict-lane retarget — workflow/action only,
# no driver change.) (1) The lifecycle order is REVERSED from r13:
# the VR-12 cells (connect + sign) now run BEFORE VR-11. r13 moved
# VR-11 first to protect it from the 120-min job cap (the V108
# failure mode); REPORT_V109 proved the opposite failure mode is
# the live one — the API-35 lifecycle job died INSIDE VR-11 in both
# dedicated runs and never reached VR-12 at all, so the KFC-008
# cells now run first, while the rig is fresh. (2) VR-11's
# game-destination probe is BOUNDED: the game hierarchy dump runs
# under a 120 s total budget (dump_ui_bounded); if the rig cannot
# produce the hierarchy inside the budget, VR-11 is recorded
# NOT-RUN (rig) and the suite CONTINUES to its verdict epilogue
# instead of burning the whole 120-min job in dump_ui's retries
# and the unbounded tail behind the failed dump (REPORT_V109
# addendum: dump_ui failed after 8 attempts, hier-vr11-game.xml
# never produced, both API-35 jobs uploaded no verdict at all).
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
vr12a="NOT-RUN"; vr12b="NOT-RUN"; vr12sign="NOT-RUN"
fatal_vr_total="0"; fatal_mock_total="0"; ise_total="0"; stopped_dialogs="0"
lock_pin="unknown"; lock_fp="unknown"; auth_note="not attempted"

# --- helpers (carried from verify-fun001.sh, JUDGE Amendment 2 hardening) -----
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

tap_desc() { # $1 = hierarchy file, $2 = substring matched against content-desc
  local coords
  coords="$(python3 - "$1" "$2" <<'PY'
import re, sys
data = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
for m in re.finditer(r'content-desc="([^"]*' + re.escape(sys.argv[2]) + r'[^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', data):
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
  # The verdict-gating IllegalStateException count is SCOPED to the
  # KFC-001 signature: an ISE whose context names ActivityResultSender /
  # ActivityResultRegistry. A raw count over a full logcat buffer counts
  # unrelated system noise (r3: 20 hits, all GMS EmojiCompat + Settings
  # indexing, zero sender signatures) — recorded as informational only.
  local f="$1" a b c raw
  a="$(grep -A3 "FATAL EXCEPTION" "$f" 2>/dev/null | grep -c "Process: $PKG" || true)"
  b="$(grep -A3 "FATAL EXCEPTION" "$f" 2>/dev/null | grep -c "Process: $MOCK" || true)"
  c="$(python3 - "$f" <<'PY' || echo 0
import re, sys
lines = open(sys.argv[1], encoding="utf-8", errors="ignore").read().splitlines()
hits = 0
for i, ln in enumerate(lines):
    if "IllegalStateException" in ln:
        ctx = "\n".join(lines[max(0, i-3): i+12])
        if "ActivityResultSender" in ctx or "ActivityResultRegistry" in ctx:
            hits += 1
print(hits)
PY
)"
  raw="$(grep -c "IllegalStateException" "$f" 2>/dev/null || true)"
  fatal_vr_total=$((fatal_vr_total + ${a:-0}))
  fatal_mock_total=$((fatal_mock_total + ${b:-0}))
  ise_total=$((ise_total + ${c:-0}))
  log "scan: $f vr_fatal=${a:-0} mock_fatal=${b:-0} sender_signature_ise=${c:-0} (raw_system_ise=${raw:-0}, informational)"
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
# The PIN lock stays (binding), but the AVD must not lock ITSELF mid-suite:
# the API-35 trailing run (r4) starved every cell because the keyguard
# engaged during idle waits and every dump showed the lock screen.
# Mitigate by construction: screen/lock timeouts to max + stay-on-USB,
# plus an explicit PIN unlock helper used by the navigation paths.
adb shell settings put system screen_off_timeout 2147483647 >/dev/null 2>&1 || true
adb shell settings put secure lock_screen_lock_after_timeout 2147483647 >/dev/null 2>&1 || true
adb shell svc power stayon usb >/dev/null 2>&1 || true
log "security: lock mitigation applied (screen_off_timeout=max, lock_after_timeout=max, stayon usb)"

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
  ensure_unlocked
  adb shell am start -W -n "$ACT" >/dev/null 2>&1 || true
  for i in 1 2 3 4 5 6; do
    sleep 2
    if dump_ui "$f" && grep -q "PLAY" "$f" && grep -q "WALLET" "$f" && grep -q "SETTINGS" "$f"; then
      return 0
    fi
    dismiss_host_anr
    ensure_unlocked
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

state_of() { # echoes the wallet-screen state keyword read from a GIVEN dump file
  if grep -q "$EXPECTED_PUBKEY" "$1" && grep -q "CONNECTED" "$1"; then echo "connected"
  elif grep -q "CONNECT WALLET" "$1"; then echo "disconnected"
  elif grep -q "TRY AGAIN" "$1"; then echo "error"
  elif grep -q "Waiting for wallet" "$1"; then echo "working"
  else echo "unknown"; fi
}

vr_state() { # echoes the wallet-screen state keyword from a fresh dump: $1 = dump file
  if dump_ui "$1"; then state_of "$1"; else echo "nodump"; fi
}

tap_connect_and_complete() { # $1 = evidence tag; from the wallet screen in a
  # disconnected/Error state: tap the connect control ONCE, then work the
  # completion like a real user (r13, HAUNT r6 pattern): approve EVERY
  # approval sheet the connect produces — the v1.0.9 post-interruption
  # refire loop can surface several sheets in one leg (a swallowed
  # attempt's zombie sheet, then the refired attempt's own sheet) —
  # bounded at 4 approvals, each waited on inside the overall budget.
  # Accepts EITHER completion path — approval sheet(s) (fresh authorize)
  # or a silent reauthorize (a live cached authToken completes the
  # transact with no sheet at all; the r9 sheet-only probes timed out on
  # the silent path — VR-9 setup, VR-13 reconnect). The 165 s budget
  # covers the full refire loop: 3 attempts x 35 s slots + refire pauses
  # + approval/auth time. An Error state in the app's own window at
  # >= 20 s is final (the loop never shows Error mid-flight — it ends
  # there), so the poll exits early instead of burning the budget.
  # Files hier-<tag>-sheet.xml (first sheet), hier-<tag>-sheet<N>.xml
  # (later sheets), hier-<tag>-after.xml (final state dump) and
  # <tag>-tcc.txt (approvals / elapsed / outcome summary).
  local tag="$1" elapsed=0 approvals=0 outcome="timeout"
  dump_ui "$TMPD/tcc-pre.xml" || return 1
  tap_text "$TMPD/tcc-pre.xml" "TRY AGAIN" || tap_text "$TMPD/tcc-pre.xml" "CONNECT WALLET" || return 1
  while [ "$elapsed" -lt 165 ]; do
    if dump_ui "$TMPD/tcc-poll.xml"; then
      if [ "$(fg_pkg)" = "$PKG" ]; then
        local st_poll; st_poll="$(state_of "$TMPD/tcc-poll.xml")"
        if [ "$st_poll" = "connected" ]; then
          if [ "$approvals" -eq 0 ]; then
            log "$tag: connect completed by silent reauthorize (no sheet)"
            outcome="connected-silent"
          else
            outcome="connected"
          fi
          break
        fi
        if [ "$st_poll" = "error" ] && [ "$elapsed" -ge 20 ]; then
          log "$tag: app settled in Error at ${elapsed}s (loop ended without Connected)"
          outcome="error"
          break
        fi
      fi
      if sheet_present "$TMPD/tcc-poll.xml"; then
        if [ "$approvals" -lt 4 ]; then
          approvals=$((approvals + 1))
          if [ "$approvals" -eq 1 ]; then
            cp "$TMPD/tcc-poll.xml" "$OUT/hier-$tag-sheet.xml"
          else
            cp "$TMPD/tcc-poll.xml" "$OUT/hier-$tag-sheet$approvals.xml"
          fi
          snap "shot-$tag-sheet$approvals.png"
          log "$tag: approval sheet #$approvals appeared at ${elapsed}s; approving"
          if tap_exact "$TMPD/tcc-poll.xml" "Connect" || tap_text "$TMPD/tcc-poll.xml" "Connect" || tap_exact "$TMPD/tcc-poll.xml" "Approve" || tap_text "$TMPD/tcc-poll.xml" "Approve"; then
            sleep 4
            satisfy_auth_prompt || true
          else
            log "$tag: sheet #$approvals present but no approve control matched; continuing to poll"
            approvals=$((approvals - 1))
          fi
        else
          log "$tag: sheet present but the approval cap (4) is reached; not approving"
          sleep 3
        fi
      elif [ "$(fg_pkg)" = "$MOCK" ] && grep -q "AUTHENTICATE" "$TMPD/tcc-poll.xml"; then
        log "$tag: wallet sits at its Authenticate gate - authenticating"
        tap_exact "$TMPD/tcc-poll.xml" "AUTHENTICATE" || true
        satisfy_auth_prompt || true
        date +%s > "$AUTH_EPOCH_FILE" || true
      fi
    fi
    sleep 3; elapsed=$((elapsed + 3))
  done
  if [ "$outcome" = "timeout" ] && [ "$(vr_state "$TMPD/tcc-final.xml")" = "connected" ]; then outcome="connected"; fi
  {
    echo "tcc_tag=$tag"
    echo "tcc_approvals=$approvals"
    echo "tcc_elapsed_s=$elapsed"
    echo "tcc_outcome=$outcome"
  } > "$OUT/$tag-tcc.txt"
  log "$tag: tap_connect_and_complete done: approvals=$approvals elapsed=${elapsed}s outcome=$outcome"
  wait_for "CONNECTED" 30 "$OUT/hier-$tag-after.xml" && grep -q "$EXPECTED_PUBKEY" "$OUT/hier-$tag-after.xml"
}

foreground_wallet_task() { # raise the wallet's TASK as-is (recents card),
  # so its top activity — a pending approval sheet — becomes reachable.
  # am start on the main activity is only the fallback: it can stack a
  # fresh main instance over the sheet instead of surfacing it.
  adb shell input keyevent 187 >/dev/null 2>&1 || true  # APP_SWITCH / recents
  sleep 2
  local f="$TMPD/recents.xml"
  if dump_ui "$f" && { tap_desc "$f" "Mock MWA Wallet" || tap_text "$f" "Mock"; }; then
    sleep 2
    return 0
  fi
  adb shell am start -W -n "$MOCK_ACT" >/dev/null 2>&1 || true
  sleep 2
}

approve_followup_sign() { # $1 = evidence tag; r16 sequential approvals.
  # Called by cell_vr12sign AFTER it taps the follow-up SIGN control.
  # Choreography (CURE_V111 lane note): on the cured build the
  # follow-up request sits behind the zombie-clear gate — its sheet
  # cannot exist until the zombie sheet is approved, because that
  # approval delivers the zombie's late result, which clears the gate
  # and lets the follow-up's single transact fire. So: bring the
  # wallet's task forward, approve the ZOMBIE sheet (#1), then approve
  # the follow-up's OWN sheet (#2) when the follow-up association
  # brings the wallet forward again. Approve-all, bounded at 4 sheets,
  # inside a 165 s budget (gate wait <= 35 s + zombie approval +
  # association + approval/auth time). PASS requires approvals >= 2
  # AND the app back at Connected+pubkey — a lone zombie approval can
  # never pass the leg: on the faulted predecessor the zombie's late
  # result is generation-suppressed, the follow-up's fresh association
  # is never served (wire-proven REPORT_V110 x5: ECONNREFUSED for the
  # scenario's whole life, most of it AFTER the zombie had cleared),
  # no second sheet ever appears, and the app rests in Working.
  # Files hier-<tag>-fup-sheet<N>.xml per approved sheet and
  # <tag>-fup.txt (approvals / elapsed / outcome).
  local tag="$1" elapsed=0 approvals=0 outcome="timeout" st_f=""
  while [ "$elapsed" -lt 165 ]; do
    if dump_ui "$TMPD/fup-poll.xml"; then
      if [ "$(fg_pkg)" = "$PKG" ]; then
        st_f="$(state_of "$TMPD/fup-poll.xml")"
        if [ "$st_f" = "connected" ] && [ "$approvals" -ge 2 ]; then
          outcome="connected"; break
        fi
        if [ "$approvals" -eq 0 ]; then
          # App in front and the zombie not yet approved: its sheet is
          # reachable only in the wallet's task — raise that task.
          foreground_wallet_task
        fi
      fi
      if sheet_present "$TMPD/fup-poll.xml"; then
        if [ "$approvals" -lt 4 ]; then
          approvals=$((approvals + 1))
          cp "$TMPD/fup-poll.xml" "$OUT/hier-$tag-fup-sheet$approvals.xml"
          snap "shot-$tag-fup-sheet$approvals.png"
          log "$tag: follow-up sequential sheet #$approvals at ${elapsed}s; approving (zombie first, then the follow-up's own)"
          if tap_exact "$TMPD/fup-poll.xml" "Approve" || tap_text "$TMPD/fup-poll.xml" "Approve" || tap_exact "$TMPD/fup-poll.xml" "Connect" || tap_text "$TMPD/fup-poll.xml" "Connect"; then
            sleep 4
            satisfy_auth_prompt || true
          else
            log "$tag: sheet #$approvals present but no approve control matched; continuing to poll"
            approvals=$((approvals - 1))
          fi
        else
          log "$tag: sheet present but the approval cap (4) is reached; not approving"
          sleep 3
        fi
      elif [ "$(fg_pkg)" = "$MOCK" ] && grep -q "AUTHENTICATE" "$TMPD/fup-poll.xml"; then
        log "$tag: wallet sits at its Authenticate gate - authenticating"
        tap_exact "$TMPD/fup-poll.xml" "AUTHENTICATE" || true
        satisfy_auth_prompt || true
        date +%s > "$AUTH_EPOCH_FILE" || true
      fi
    fi
    sleep 3; elapsed=$((elapsed + 3))
  done
  # Final acceptance re-check in the app's window (the last approval
  # may have returned focus to the app between polls).
  if [ "$outcome" != "connected" ] && [ "$approvals" -ge 2 ] && [ "$(vr_state "$TMPD/fup-final.xml")" = "connected" ]; then
    outcome="connected"
  fi
  {
    echo "fup_tag=$tag"
    echo "fup_approvals=$approvals"
    echo "fup_elapsed_s=$elapsed"
    echo "fup_outcome=$outcome"
  } > "$OUT/$tag-fup.txt"
  log "$tag: approve_followup_sign done: approvals=$approvals elapsed=${elapsed}s outcome=$outcome"
  [ "$outcome" = "connected" ]
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
  # r10: a connect with a live cached authToken completes WITHOUT a
  # sheet (silent reauthorize) — r9's sheet-only probe waited 45 s for
  # a sheet that never came and starved VR-9 on exactly that, although
  # the session was live. tap_connect_and_complete accepts either
  # completion path (sheet approval or silent reauthorize).
  tap_connect_and_complete "$tag"
}

ensure_disconnected() {
  goto_wallet || return 1
  local st; st="$(vr_state "$TMPD/ed.xml")"
  # The Error state IS a disconnected state (no session; TRY AGAIN is
  # the retry control) — VR-8 in r4 starved on this bookkeeping after
  # VR-7 left the app in Error.
  if [ "$st" = "disconnected" ] || [ "$st" = "error" ]; then return 0; fi
  do_disconnect "ensure"
}

identity_wall() { # 0 if the wallet screen shows the clientlib identity rejection
  local f="$TMPD/wall.xml"
  dump_ui "$f" || return 1
  grep -q "iconRelativeUri" "$f"
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
    # Distinguish 'wallet never engaged' causes from the app's own error
    # surface: if the wallet screen sits in its Error state, quote the
    # message verbatim — r3 surfaced the clientlib identity rejection
    # ('If non-null, iconRelativeUri must be a relative Uri') this way.
    local st2 msg
    st2="$(vr_state "$OUT/hier-vr1-errorstate.xml")"
    msg=""
    if [ "$st2" = "error" ]; then
      msg="$(python3 - "$OUT/hier-vr1-errorstate.xml" <<'PY' || true
import re, sys
texts = re.findall(r'text="([^"]+)"', open(sys.argv[1], encoding="utf-8", errors="ignore").read())
skip = {"Error", "TRY AGAIN", "WALLET", "Not connected"}
cands = [t for t in texts if t not in skip]
print(cands[0] if cands else "")
PY
)"
    fi
    if [ -n "$msg" ]; then
      vr1="FAIL(connect cannot complete on the sealed build — app Error state, verbatim: '$msg'; no crash, process alive, no sheet ever presented)"
    else
      vr1="FAIL(no mock approval sheet; post-tap state=$st2)"
    fi
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
# r10: the sign runs TWICE per core suite (v1.0.7 verdict tasking —
# repeat x2 per API). vr3_attempt <tag> executes one full sign and sets
# VR3_ATTEMPT_GRADE / VR3_ATTEMPT_VERIFIED; the first attempt keeps the
# r9 evidence names (hier-vr3-after.xml, logcat-vr3.txt, vr3-notes.txt),
# the second files under vr3b.
VR3_ATTEMPT_GRADE="NOT-RUN"; VR3_ATTEMPT_VERIFIED="not-observed"
vr3_attempt() {
  local tag="$1"
  VR3_ATTEMPT_GRADE="NOT-RUN"; VR3_ATTEMPT_VERIFIED="not-observed"
  log "=== VR-3 sign attempt ($tag) ==="
  if [ "$(vr_state "$TMPD/$tag-pre.xml")" != "connected" ]; then
    VR3_ATTEMPT_GRADE="NOT-RUN(not connected at attempt start)"
    log "$tag: $VR3_ATTEMPT_GRADE"
    return 1
  fi
  auth_fresh_enough
  adb logcat -c >/dev/null 2>&1 || true
  dump_ui "$TMPD/$tag-conn.xml" || true
  tap_text "$TMPD/$tag-conn.xml" "SIGN TEST MESSAGE" || { VR3_ATTEMPT_GRADE="FAIL(no sign control in Connected state)"; return 1; }
  local f="$OUT/hier-$tag-sheet.xml"
  if ! wait_sheet "$f" 45; then
    VR3_ATTEMPT_GRADE="FAIL(no mock sign sheet)"
    capture_window "$tag"
    return 1
  fi
  snap "shot-$tag-sheet.png"
  if grep -q "VOIDRUNNER sign-in" "$f"; then
    log "$tag: sign sheet shows the request message 'VOIDRUNNER sign-in'"
  else
    log "$tag: sheet present but message text not visible in dump"
  fi
  if grep -qi "wants to connect" "$f"; then
    log "$tag: NOTE — an authorize sheet appeared during transact (reauthorize NOT silent)"
    echo "reauthorize_during_transact=sheet-appeared" >> "$OUT/$tag-notes.txt"
  else
    echo "reauthorize_during_transact=silent (sign sheet only; cached authToken reused)" >> "$OUT/$tag-notes.txt"
  fi
  tap_exact "$f" "Approve" || { VR3_ATTEMPT_GRADE="FAIL(no Approve on sign sheet)"; capture_window "$tag"; return 1; }
  sleep 3
  satisfy_auth_prompt || true
  local ok="0"
  if wait_for "CONNECTED" 30 "$OUT/hier-$tag-after.xml" && grep -q "$EXPECTED_PUBKEY" "$OUT/hier-$tag-after.xml"; then ok="1"; fi
  capture_window "$tag"
  # Opportunistic: hunt the returned signature in the captured logcat window
  # (walletlib/clientlib debug lines) and verify it off-device with node.
  python3 - "$OUT/logcat-$tag.txt" "$EXPECTED_PUBKEY" > "$OUT/$tag-sig-candidates.txt" <<'PY' || true
import re, sys
data = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
cands = sorted(set(re.findall(r'[1-9A-HJ-NP-Za-km-z]{86,88}', data)))
for c in cands:
    if c != sys.argv[2]:
        print(c)
PY
  local verified="not-observed"
  if [ -s "$OUT/$tag-sig-candidates.txt" ]; then
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
    done < "$OUT/$tag-sig-candidates.txt"
  fi
  VR3_ATTEMPT_VERIFIED="$verified"
  echo "vr3_signature_verification=$verified" >> "$OUT/$tag-notes.txt"
  log "$tag: signature verification: $verified"
  if [ "$ok" = "1" ]; then
    if [ "$verified" != "not-observed" ]; then
      VR3_ATTEMPT_GRADE="PASS(approval → signature returned, verified off-device against imported key; session restored)"
    else
      VR3_ATTEMPT_GRADE="PASS(functional: approval → clientlib Success → Connected restored; signature value not exposed on any harness-observable surface of the sealed build — off-device verification sub-step NOT-RUN, see $tag-notes.txt)"
    fi
    log "$tag: $VR3_ATTEMPT_GRADE"
    return 0
  fi
  VR3_ATTEMPT_GRADE="FAIL(post-sign state not Connected+pubkey)"
  log "$tag: $VR3_ATTEMPT_GRADE"
  return 1
}

cell_vr3() {
  log "=== VR-3 sign message (x2 repetitions) ==="
  local g1="NOT-RUN" v1="not-observed" g2="NOT-RUN(second repetition not attempted)" v2="not-observed"
  if vr3_attempt "vr3"; then g1="$VR3_ATTEMPT_GRADE"; v1="$VR3_ATTEMPT_VERIFIED"
  else g1="$VR3_ATTEMPT_GRADE"; v1="$VR3_ATTEMPT_VERIFIED"; fi
  if [ "${g1#PASS}" != "$g1" ]; then
    if vr3_attempt "vr3b"; then g2="$VR3_ATTEMPT_GRADE"; v2="$VR3_ATTEMPT_VERIFIED"
    else g2="$VR3_ATTEMPT_GRADE"; v2="$VR3_ATTEMPT_VERIFIED"; fi
  fi
  {
    echo "vr3_rep1=$g1"
    echo "vr3_rep1_signature_verification=$v1"
    echo "vr3_rep2=$g2"
    echo "vr3_rep2_signature_verification=$v2"
  } > "$OUT/vr3-summary.txt"
  if [ "${g1#PASS}" != "$g1" ] && [ "${g2#PASS}" != "$g2" ]; then
    vr3="PASS(x2 repetitions: post-sign state Connected+pubkey after each approval; rep1 verification: $v1; rep2 verification: $v2 — see vr3-summary.txt)"
  elif [ "${g1#FAIL}" != "$g1" ] || [ "${g2#FAIL}" != "$g2" ]; then
    vr3="FAIL(rep1: $g1 | rep2: $g2)"
  else
    vr3="NOT-RUN(rep1: $g1 | rep2: $g2)"
  fi
  log "vr3: $vr3"
}

# --- VR-9: declined signing (sign-message half; sign-and-send half unreachable) -----
cell_vr9() {
  log "=== VR-9 declined signing (ERROR_NOT_SIGNED) ==="
  # r9: explicit precondition, as in cell_vr6 (VR-3's fallout starved it).
  if ! ensure_connected "vr9-setup"; then
    vr9="NOT-RUN(could not establish a session)"
    return
  fi
  auth_fresh_enough
  adb logcat -c >/dev/null 2>&1 || true
  dump_ui "$TMPD/vr9-conn.xml" || true
  tap_text "$TMPD/vr9-conn.xml" "SIGN TEST MESSAGE" || { vr9="FAIL(no sign control)"; return; }
  local f="$OUT/hier-vr9-sheet.xml"
  if ! wait_sheet "$f" 45; then vr9="FAIL(no mock sign sheet)"; capture_window "vr9"; return; fi
  if tap_exact "$f" "Cancel"; then
    log "vr9: declined via the sign sheet's Cancel control"
  else
    # r10: if the sign sheet exposes no literal Cancel control, BACK
    # dismisses the sheet, which is the wallet-side user rejection.
    log "vr9: no Cancel control on the sign sheet — declining via BACK (sheet dismissal)"
    adb shell input keyevent 4 >/dev/null 2>&1 || true
  fi
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
  # r9: establish the precondition explicitly (mirrors cell_vr13) — in
  # the r8 order VR-3 ran first and the sealed build's post-transact
  # state defect left the app Disconnected, starving this cell.
  if ! ensure_connected "vr6-setup"; then
    vr6="NOT-RUN(could not establish a session)"
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
  if ! wait_sheet "$f" 45; then
    if identity_wall; then vr7="NOT-RUN(authorize sheet unreachable — connect fails client-side on the sealed build (iconRelativeUri identity rejection, see VR-1); decline-at-sheet cannot be exercised)"; else vr7="FAIL(no mock sheet)"; fi
    capture_window "vr7"; return
  fi
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
  if ! wait_sheet "$f" 45; then
    if identity_wall; then vr8="NOT-RUN(connect sheet unreachable — connect fails client-side on the sealed build (iconRelativeUri identity rejection, see VR-1); nothing to interrupt)"; else vr8="NOT-RUN(connect sheet never appeared; nothing to interrupt)"; fi
    capture_window "vr8"; return
  fi
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
  if ! ensure_connected "vr13-setup"; then
    if identity_wall; then vr13="NOT-RUN(no session can be established on the sealed build — connect fails client-side (iconRelativeUri identity rejection, see VR-1))"; else vr13="NOT-RUN(could not establish a session)"; fi
    return
  fi
  # r9: `am kill` did NOT verifiably kill the session-bound mock in the
  # v1.0.6 r8 run (no process-death line in the cell's logcat window; a
  # sign sheet appeared 5s later) — the death premise was never
  # established. Force-stop (the VR-8 instrument) + pidof verification.
  local pid_before; pid_before="$(adb shell pidof "$MOCK" 2>/dev/null | tr -d '\r')"
  log "vr13: session live; force-stopping wallet process (pid $pid_before)"
  adb shell am force-stop "$MOCK" >/dev/null 2>&1 || true
  sleep 2
  if pid_alive "$MOCK"; then
    vr13="NOT-RUN(wallet process survived force-stop — death premise not established)"
    return
  fi
  log "vr13: wallet death VERIFIED (pidof empty after force-stop)"
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
    # r9: a force-stopped wallet relaunched by the association intent can
    # sit at its Authenticate gate (mock main screen) with the request
    # queued — work the gate so the sheet can follow.
    if [ "$(fg_pkg)" = "$MOCK" ] && grep -q "AUTHENTICATE" "$OUT/hier-vr13-poll.xml"; then
      log "vr13: relaunched wallet sits at its Authenticate gate — authenticating"
      tap_exact "$OUT/hier-vr13-poll.xml" "AUTHENTICATE" || true
      satisfy_auth_prompt || true
      date +%s > "$AUTH_EPOCH_FILE" || true
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
  # r10: the reconnect can complete by silent reauthorize (the cached
  # authToken lives in the APP's clientlib and survives the wallet's
  # death) — r9's sheet-only probe timed out on exactly that and the
  # driver string read FAIL on a reconnect the artefacts showed had
  # completed. tap_connect_and_complete accepts either path.
  if tap_connect_and_complete "vr13-reconnect"; then
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
  if ! wait_sheet "$f" 45; then
    if identity_wall; then vr12="NOT-RUN(no sheet to background — connect fails client-side on the sealed build (iconRelativeUri identity rejection, see VR-1))"; else vr12="NOT-RUN(no sheet to background)"; fi
    capture_window "vr12"; return
  fi
  log "vr12: sheet up; sending HOME (backgrounding both tasks)"
  adb shell input keyevent 3 >/dev/null 2>&1 || true
  sleep 3
  snap "shot-vr12-backgrounded.png"
  adb shell input keyevent 187 >/dev/null 2>&1 || true  # APP_SWITCH / recents
  sleep 3
  dump_ui "$OUT/hier-vr12-recents.xml" || true
  # Return via the recents card. API 36's recents labels live in
  # content-desc, NOT text — r1 reported 'no labelled card' while a
  # 'Mock MWA Wallet' card sat in its own dump, then blind-tapped the
  # dApp card and graded the app 'hung' for waiting on an approval
  # that sat untouched in the wallet's task (driver r8 fix). Match
  # both attributes, WALLET card first: the approval flow lives in
  # the wallet's task; foregrounding the dApp alone leaves it at
  # 'Waiting for wallet' by design.
  if tap_desc "$OUT/hier-vr12-recents.xml" "Mock MWA Wallet" || tap_text "$OUT/hier-vr12-recents.xml" "Mock" || tap_desc "$OUT/hier-vr12-recents.xml" "VOIDRUNNER" || tap_text "$OUT/hier-vr12-recents.xml" "VOIDRUNNER"; then
    log "vr12: tapped a recents card (wallet first)"
  else
    adb shell am start -W -n "$MOCK_ACT" >/dev/null 2>&1 || true
    log "vr12: no labelled card matched; brought the wallet task forward via am start"
  fi
  sleep 3
  local result="unknown" res_state="" res_latency=""
  if dump_ui "$OUT/hier-vr12-returned.xml" && sheet_present "$OUT/hier-vr12-returned.xml"; then
    log "vr12: approval sheet resumed after foregrounding (wallet did NOT abandon)"
    tap_exact "$OUT/hier-vr12-returned.xml" "Connect" || tap_text "$OUT/hier-vr12-returned.xml" "Connect" || true
    sleep 4
    satisfy_auth_prompt || true
    if [ "$(vr_state "$TMPD/vr12-st.xml")" = "connected" ]; then result="completed"; res_state="connected"; fi
  else
    # The wallet abandoned the request (mock back at its main screen).
    # Bring the DAPP forward — that is the return moment the v1.0.7
    # cure keys on: MainActivity.onResume -> onReturnedToForeground()
    # cancels a still-pending request after a 5 s grace window and
    # resolves connect to the interrupted Error state (TRY AGAIN).
    # r10: poll the state for up to 30 s from the return moment and
    # record the resolution + its latency (r9 read twice, 20 s apart,
    # and graded a binary hung/not-hung).
    adb shell am start -W -n "$ACT" >/dev/null 2>&1 || true
    local observe_s="${VR12_OBSERVE_S:-30}" elapsed=0 st="working" samples=""
    while [ "$elapsed" -lt "$observe_s" ]; do
      sleep 3; elapsed=$((elapsed + 3))
      st="$(vr_state "$TMPD/vr12-poll.xml")"
      samples="${samples}vr12_sample_${elapsed}s=$st
"
      if [ "$st" != "working" ] && [ "$st" != "nodump" ]; then break; fi
    done
    cp "$TMPD/vr12-poll.xml" "$OUT/hier-vr12-resolved.xml" 2>/dev/null || true
    res_state="$st"; res_latency="$elapsed"
    log "vr12: post-return resolution state=$st after ${elapsed}s (fg=$(fg_pkg))"
    {
      echo "vr12_resolution_state=$st"
      echo "vr12_resolution_latency_s=$elapsed"
      echo "vr12_observe_window_s=$observe_s"
      printf '%s' "$samples"
      if [ "$st" != "working" ] && [ "$elapsed" -le 20 ]; then echo "vr12_in_window_resolution=yes"; else echo "vr12_in_window_resolution=no"; fi
      echo "vr12_bar_s=20 (grace 5 s + 15 s; REPORT_V108 cell definition)"
      echo "vr12_expectation=v1.0.9 KFC-008: after the 5 s grace the reconciler — scoped to the generation pending at backgrounding — claims it and writes UI state DIRECTLY from session truth -> interrupted Error (TRY AGAIN); the retry (TRY AGAIN) runs the post-interruption refire loop (up to 3 attempts x 35 s on a reset adapter; slow >25 s outcomes refire) with per-attempt Log.d markers (tag VoidrunnerWallet) preserved in logcat-vr12.txt"
    } > "$OUT/vr12-notes.txt"
    if [ "$st" = "connected" ]; then result="completed"
    elif [ "$st" = "error" ] || [ "$st" = "disconnected" ]; then result="failed-closed"
    elif [ "$st" = "working" ]; then result="hung"; fi
  fi
  # r12: NO capture_window here. The pre-r12 driver dumped + cleared
  # the vr12 window at exactly this point — before the retry leg ran —
  # and the next cell's opening clear destroyed the retry's evidence
  # (REPORT_V108 §VR-12(b)). The cell's single capture now happens
  # after the case block, so logcat-vr12.txt spans the whole cell.
  case "$result" in
    completed)
      vr12a="PASS(approval completed through the result path after foregrounding — the wallet had not abandoned, so no direct resolution was needed)"
      vr12b="NOT-RUN(no interrupted Error to retry from — the flow completed)"
      vr12="PASS(flow backgrounded mid-approval, foregrounded, completed to Connected)" ;;
    failed-closed)
      # r11: (a) resolution promptness and (b) the in-process retry leg
      # are graded as separate first-class lines. (a) passes only on the
      # designed outcome: the interrupted Error within grace+15 s
      # (latency <= 20 s from the return moment). (b) passes only if
      # TRY AGAIN from that Error completes the connect IN-PROCESS.
      if [ "$res_state" = "error" ] && [ "$res_latency" -le 20 ]; then
        vr12a="PASS(resolved out of Working to the interrupted Error in ${res_latency}s — within the grace+15 s bar)"
      elif [ "$res_latency" -le 20 ]; then
        vr12a="FAIL(resolved out of Working to '$res_state' in ${res_latency}s — not the designed interrupted Error)"
      else
        vr12a="FAIL(resolved out of Working only at ${res_latency}s — outside the grace+15 s bar (20 s) — to '$res_state'; v1.0.7-class late resolution)"
      fi
      if tap_connect_and_complete "vr12-retry"; then
        echo "vr12_post_resolution_connect=PASS (recovery connect after resolution to '$res_state' at ${res_latency}s)" >> "$OUT/vr12-notes.txt"
        vr12b="PASS(TRY AGAIN from the interrupted Error completed the connect in-process to Connected+pubkey)"
      else
        echo "vr12_post_resolution_connect=FAIL (no recovery connect after resolution to '$res_state' at ${res_latency}s)" >> "$OUT/vr12-notes.txt"
        vr12b="FAIL(TRY AGAIN from the interrupted Error did not complete a connect in-process)"
      fi
      # r13: fold the helper's per-leg summary (approvals / elapsed /
      # outcome — elapsed is the retry leg's time-to-Connected when the
      # outcome is connected) into the cell's notes for the report.
      if [ -f "$OUT/vr12-retry-tcc.txt" ]; then cat "$OUT/vr12-retry-tcc.txt" >> "$OUT/vr12-notes.txt"; fi
      if [ "${vr12a#PASS}" != "$vr12a" ] && [ "${vr12b#PASS}" != "$vr12b" ]; then
        vr12="PASS(abandoned mid-approval resolved to the interrupted Error in ${res_latency}s; in-process TRY AGAIN recovery connect succeeded)"
      else
        vr12="FAIL(vr12a: $vr12a | vr12b: $vr12b)"
      fi
      ;;
    *)
      vr12a="FAIL(no resolution — post-return flow ended in state '$result')"
      vr12b="NOT-RUN(no resolution to retry from)"
      vr12="FAIL(background/foreground left the connect flow in state '$result')" ;;
  esac
  # r12: the cell's ONE logcat capture — after the retry leg, so
  # logcat-vr12.txt holds the full contiguous vr12 window (initial
  # connect, abandonment, resolution, retry attempts, settlement).
  capture_window "vr12"
  if [ -f "$OUT/vr12-notes.txt" ]; then
    { echo "vr12a=$vr12a"; echo "vr12b=$vr12b"; } >> "$OUT/vr12-notes.txt"
  fi
  log "vr12: $vr12"
  log "vr12a: $vr12a"
  log "vr12b: $vr12b"
}

# --- VR-12S: sign-branch abandonment (KFC-008, sign path) --------------------------------
cell_vr12sign() {
  log "=== VR-12S sign-branch abandonment mid-approval ==="
  if ! ensure_connected "vr12s-setup"; then
    vr12sign="NOT-RUN(could not establish a session)"; log "vr12sign: $vr12sign"; return
  fi
  auth_fresh_enough
  adb logcat -c >/dev/null 2>&1 || true
  dump_ui "$TMPD/vr12s-conn.xml" || true
  tap_text "$TMPD/vr12s-conn.xml" "SIGN TEST MESSAGE" || { vr12sign="FAIL(no sign control)"; log "vr12sign: $vr12sign"; return; }
  local f="$OUT/hier-vr12s-sheet.xml"
  if ! wait_sheet "$f" 45; then vr12sign="FAIL(no mock sign sheet)"; capture_window "vr12s"; log "vr12sign: $vr12sign"; return; fi
  log "vr12s: sign sheet up; sending HOME (backgrounding both tasks)"
  adb shell input keyevent 3 >/dev/null 2>&1 || true
  sleep 3
  snap "shot-vr12s-backgrounded.png"
  adb shell input keyevent 187 >/dev/null 2>&1 || true  # APP_SWITCH / recents
  sleep 3
  dump_ui "$OUT/hier-vr12s-recents.xml" || true
  if tap_desc "$OUT/hier-vr12s-recents.xml" "Mock MWA Wallet" || tap_text "$OUT/hier-vr12s-recents.xml" "Mock" || tap_desc "$OUT/hier-vr12s-recents.xml" "VOIDRUNNER" || tap_text "$OUT/hier-vr12s-recents.xml" "VOIDRUNNER"; then
    log "vr12s: tapped a recents card (wallet first)"
  else
    adb shell am start -W -n "$MOCK_ACT" >/dev/null 2>&1 || true
    log "vr12s: no labelled card matched; brought the wallet task forward via am start"
  fi
  sleep 3
  if dump_ui "$OUT/hier-vr12s-returned.xml" && sheet_present "$OUT/hier-vr12s-returned.xml"; then
    # Premise not established: the wallet kept the sign request alive.
    vr12sign="NOT-RUN(wallet did not abandon the sign request — its sheet resumed on foregrounding)"
    adb shell input keyevent 4 >/dev/null 2>&1 || true  # dismiss the sheet so later cells start clean
    sleep 2
    capture_window "vr12s"
    log "vr12sign: $vr12sign"
    return
  fi
  # Wallet abandoned the sign request. Bring the DAPP forward — the
  # return moment the reconciler keys on. Designed v1.0.8 outcome: the
  # state resolves DIRECTLY to Connected (restored from the stored
  # session field) within grace+15 s — no error, no disconnect.
  adb shell am start -W -n "$ACT" >/dev/null 2>&1 || true
  local elapsed=0 st="working" samples=""
  while [ "$elapsed" -lt 30 ]; do
    sleep 3; elapsed=$((elapsed + 3))
    st="$(vr_state "$TMPD/vr12s-poll.xml")"
    samples="${samples}vr12s_sample_${elapsed}s=$st
"
    if [ "$st" != "working" ] && [ "$st" != "nodump" ]; then break; fi
  done
  cp "$TMPD/vr12s-poll.xml" "$OUT/hier-vr12s-resolved.xml" 2>/dev/null || true
  {
    echo "vr12s_resolution_state=$st"
    echo "vr12s_resolution_latency_s=$elapsed"
    printf '%s' "$samples"
    echo "vr12s_bar_s=20 (grace 5 s + 15 s; REPORT_V108 cell definition)"
    echo "vr12s_expectation=v1.0.11 KFC-008 sign branch: reconciler — scoped to the generation pending at backgrounding — restores Connected from sessionPublicKeyBase58 directly; no error, no disconnect; the follow-up sign then waits behind the zombie-clear gate (Log.d tag VoidrunnerWallet: zombie gate wait-start / cleared-by-late-result / wait-expired) and succeeds after SEQUENTIAL approvals — zombie sheet first, then its own (driver r16)"
  } > "$OUT/vr12s-notes.txt"
  log "vr12s: post-return resolution state=$st after ${elapsed}s (fg=$(fg_pkg))"
  capture_window "vr12s"
  if [ "$st" = "connected" ] && [ "$elapsed" -le 20 ]; then
    # A further sign must now succeed. r16: it is worked by
    # approve_followup_sign — SEQUENTIAL approvals, zombie first
    # (CURE_V111 lane note): approving the zombie delivers its late
    # result, which clears the gate and lets the follow-up's single
    # transact fire; only then can the follow-up's own sheet appear.
    auth_fresh_enough
    dump_ui "$TMPD/vr12s-conn2.xml" || true
    if tap_text "$TMPD/vr12s-conn2.xml" "SIGN TEST MESSAGE"; then
      if approve_followup_sign "vr12s"; then
        vr12sign="PASS(abandoned sign resolved directly to Connected+pubkey in ${elapsed}s — within the grace+15 s bar, no error/disconnect; the follow-up sign then succeeded via sequential zombie-first approvals behind the zombie-clear gate — gate markers in logcat-vr12s-followup.txt, approvals in vr12s-fup.txt)"
      else
        vr12sign="FAIL(resolved to Connected in ${elapsed}s but the follow-up sign did not complete — see vr12s-fup.txt + logcat-vr12s-followup.txt)"
      fi
    else
      vr12sign="FAIL(resolved to Connected in ${elapsed}s but no sign control for the follow-up sign)"
    fi
    # r16: the follow-up leg's own wire window (gate markers, the
    # follow-up association, the settlement), dumped WITHOUT clearing
    # so logcat-vr11.txt keeps spanning it as in prior verdicts.
    adb logcat -d > "$OUT/logcat-vr12s-followup.txt" 2>&1 || true
    scan_logcat "$OUT/logcat-vr12s-followup.txt"
    grep "VoidrunnerWallet" "$OUT/logcat-vr12s-followup.txt" 2>/dev/null | grep -i "zombie" | head -20 >> "$OUT/vr12s-notes.txt" || true
  elif [ "$st" = "connected" ]; then
    vr12sign="FAIL(resolved to Connected only at ${elapsed}s — outside the grace+15 s bar (20 s))"
  else
    vr12sign="FAIL(post-return state '$st' after ${elapsed}s — expected direct resolution to Connected+pubkey)"
  fi
  echo "vr12sign=$vr12sign" >> "$OUT/vr12s-notes.txt"
  log "vr12sign: $vr12sign"
}

# --- VR-11: entry points / destination registry ------------------------------------------
cell_vr11() {
  log "=== VR-11 entry points (NavHost destination registry) ==="
  # r8: start from a clean process — a prior cell's pending session
  # (VR-12's backgrounded, never-approved sheet in r1) otherwise
  # poisons the compact pass: the wallet screen sits in 'Waiting for
  # wallet' with no connect control to tap, and the mock still holds
  # the old sheet open in its own task.
  adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
  sleep 1
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
  # r15: the game-destination probe is bounded (REPORT_V109
  # addendum). On the API-35 rig uiautomator could not produce this
  # hierarchy at all; dump_ui's retries plus the unbounded tail
  # behind the failed dump burned the entire 120-min job before
  # VR-12 ever ran. If the hierarchy cannot be captured inside the
  # probe budget, VR-11 is NOT-RUN (rig) and the suite continues.
  if ! dump_ui_bounded "$OUT/hier-vr11-game.xml" 120; then
    vr11="NOT-RUN(rig: game-destination probe exceeded its 120 s budget — uiautomator hierarchy unavailable on this AVD; REPORT_V109 API-35 stall shape)"
    log "vr11: $vr11"
    return
  fi
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
  elif identity_wall; then
    vr11="FAIL(registry assertions held — HOME/SETTINGS expose no wallet controls, GAME is a single WebView node — but the WALLET destination's connect fails client-side on the sealed build (iconRelativeUri identity rejection, see VR-1); compact pass impossible)"
  else
    vr11="FAIL(compact wallet pass=$compact, settings_clean=$settings_clean)"
  fi
  log "vr11: $vr11"
}

# --- dispatch + verdict -------------------------------------------------------------------
case "$SUITE" in
  core)      cell_vr1; cell_vr3; cell_vr9; cell_vr6; cell_vr2 ;;
  errors)    cell_vr7; cell_vr8; cell_vr13 ;;
  lifecycle) cell_vr12; cell_vr12sign; cell_vr11 ;;
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
  echo "vr12a=$vr12a"
  echo "vr12b=$vr12b"
  echo "vr12sign=$vr12sign"
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
for v in "$vr1" "$vr2" "$vr3" "$vr6" "$vr7" "$vr8" "$vr9" "$vr11" "$vr12" "$vr12sign" "$vr13"; do
  case "$v" in FAIL*) fail="1" ;; esac
done
if [ "$fatal_vr_total" -gt 0 ] || [ "$fatal_mock_total" -gt 0 ] || [ "$ise_total" -gt 0 ]; then fail="1"; fi
[ "$fail" = "0" ]
