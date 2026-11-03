package com.voidrunner.gatetest;

import android.app.Instrumentation;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.util.Log;

import androidx.test.InstrumentationRegistry;
import androidx.test.runner.AndroidJUnit4;
import androidx.test.uiautomator.By;
import androidx.test.uiautomator.UiDevice;
import androidx.test.uiautomator.UiObject2;
import androidx.test.uiautomator.Until;

import org.json.JSONObject;
import org.junit.Test;
import org.junit.runner.RunWith;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileWriter;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.Assert.assertTrue;

/**
 * VOIDRUNNER R-1 gate cell, ported INTO an instrumentation test for
 * Firebase Test Lab (the CI rig drives the same flow from outside via
 * adb/uiautomator; on FTL the driver must live in a test APK — and
 * that removes the rig's outside dump channel, the component that
 * kept failing, by construction).
 *
 * The flow is the reviewer's, verbatim (CURE_PLAN §2, R-1): fresh
 * profile → launch → PLAY → the .skr gate → type the fixture handle →
 * SIGN IN → "Link my wallet" → the Mock MWA Wallet FOREGROUNDS →
 * approve its sheet → completion asserted by SERVER STATE (read-back
 * transition bind_required → proof_required). Rep 2 (after an app-data
 * reset): the same gate in proof mode — "Prove it's you" → wallet →
 * signed-in state (the client's lobby marker "CONNECTED .SKR").
 *
 * PASS criteria, unchanged from the cell of record: wallet foreground
 * seen in BOTH reps, zero failure copies (Mb "Wallet signing didn't
 * complete." / Nb "The wallet didn't return a signature." / Ab
 * "Signing was cancelled." — DIAGNOSIS.md), the bind read-back
 * transition observed, both reps completing in-app.
 *
 * Structured verdicts are emitted three ways: Log.i lines tagged
 * GATE_VERDICT (FTL returns logcat), a JSON file in the app-under-
 * test's external files dir (pullable in CI; on FTL via
 * --directories-to-pull), and JUnit assertions mirroring the PASS
 * criteria (FTL reports them natively).
 *
 * Instrumentation arguments (am instrument -e / FTL --test-targets
 * extras are NOT used; gcloud passes these via the test APK defaults
 * or the CI job's -e flags):
 *   vrHandleLocal  fixture handle local part   (default gatefixture113)
 *   vrOrigin       staging origin, no slash    (default https://voidrunner-staging.137-184-143-128.sslip.io)
 *   vrPin          device PIN for auth prompts (default 1234)
 */
@RunWith(AndroidJUnit4.class)
public class GateFlowTest {

    private static final String TAG = "GATE_VERDICT";

    private static final String APP_PKG = "com.voidrunner.app";
    private static final String APP_ACT = "com.voidrunner.app/.MainActivity";
    private static final String MOCK_PKG = "com.solana.mwallet";
    private static final String MOCK_ACT = "com.solana.mwallet/.MainActivity";

    private static final String[] FAILURE_COPIES = {
            "Wallet signing didn't complete.",
            "The wallet didn't return a signature.",
            "Signing was cancelled."
    };

    private static final long REP_BUDGET_MS = 240_000;
    private static final long POLL_MS = 2_000;

    private UiDevice device;
    private Instrumentation instr;
    private String handleLocal;
    private String handleFull;
    private String origin;
    private String pin;

    private final Map<String, String> verdict = new LinkedHashMap<>();

    // ------------------------------------------------------------------
    // small helpers
    // ------------------------------------------------------------------

    private void kv(String key, String value) {
        verdict.put(key, value);
        Log.i(TAG, key + "=" + value);
    }

    private void sleep(long ms) {
        try { Thread.sleep(ms); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
    }

    private boolean hasText(String exact) {
        return device.hasObject(By.text(exact));
    }

    private boolean hasTextContaining(String part) {
        return device.hasObject(By.textContains(part));
    }

    private UiObject2 findText(String exact) {
        List<UiObject2> objs = device.findObjects(By.text(exact));
        return objs.isEmpty() ? null : objs.get(0);
    }

    private boolean tapText(String exact) {
        UiObject2 o = findText(exact);
        if (o == null) return false;
        try { o.click(); return true; } catch (Exception e) { return false; }
    }

    private boolean tapTextContaining(String part) {
        List<UiObject2> objs = device.findObjects(By.textContains(part));
        if (objs.isEmpty()) return false;
        try { objs.get(0).click(); return true; } catch (Exception e) { return false; }
    }

    private boolean tapDesc(String exact) {
        List<UiObject2> objs = device.findObjects(By.desc(exact));
        if (objs.isEmpty()) return false;
        try { objs.get(0).click(); return true; } catch (Exception e) { return false; }
    }

    private boolean tapDescContaining(String part) {
        List<UiObject2> objs = device.findObjects(By.descContains(part));
        if (objs.isEmpty()) return false;
        try { objs.get(0).click(); return true; } catch (Exception e) { return false; }
    }

    /** Case-insensitive manual scan over every node: matches when the
     *  node's text OR content-description contains the needle
     *  (lowercased). The WebView's accessibility exposure of a button
     *  varies (text vs aria-label/desc, casing via text-transform),
     *  so selector-only matching is not reliable — proven 2026-11-02
     *  (build a87cab78: the LINK MY WALLET button rendered on screen
     *  for the full 4-minute rep budget while By.text never matched). */
    private boolean tapNodeScan(String needleLower) {
        for (String cls : new String[]{"android.widget.Button", "android.view.View",
                "android.widget.TextView"}) {
            for (UiObject2 o : device.findObjects(By.clazz(cls))) {
                try {
                    String t = o.getText();
                    String d = o.getContentDescription();
                    if ((t != null && t.toLowerCase().contains(needleLower))
                            || (d != null && d.toLowerCase().contains(needleLower))) {
                        android.graphics.Rect r = o.getVisibleBounds();
                        device.click(r.centerX(), r.centerY());
                        return true;
                    }
                } catch (Exception ignored) { }
            }
        }
        return false;
    }

    /** One-shot accessibility census: class | text | desc per node,
     *  so a selector failure carries the tree's true shape in the log. */
    private String nodeCensus() {
        List<String> out = new ArrayList<>();
        for (String cls : new String[]{"android.widget.Button", "android.widget.EditText",
                "android.view.View", "android.widget.TextView"}) {
            for (UiObject2 o : device.findObjects(By.clazz(cls))) {
                try {
                    String t = o.getText();
                    String d = o.getContentDescription();
                    if ((t != null && !t.trim().isEmpty()) || (d != null && !d.trim().isEmpty())) {
                        String e = cls.substring(cls.lastIndexOf('.') + 1)
                                + ":t=" + (t == null ? "" : t.trim())
                                + ":d=" + (d == null ? "" : d.trim());
                        if (!out.contains(e) && out.size() < 40) out.add(e);
                    }
                } catch (Exception ignored) { }
            }
        }
        return String.join(" | ", out);
    }

    /** The action-button tap ladder: exact text, contains text, the
     *  client's aria-label via desc (both exact and contains), then a
     *  case-insensitive scan over every node's text+desc for the FULL
     *  label. There is deliberately NO bare-keyword scan: build
     *  b4c78b59 (2026-11-03) phantom-tapped the sign-in form's prose
     *  ("...yours with its wallet") half a second after SIGN IN,
     *  before the panel even rendered, and the run bled out. */
    private String tapActionLadder(String actionText, String ariaLabel) {
        if (tapText(actionText)) return "text_exact";
        if (tapTextContaining(actionText)) return "text_contains";
        if (ariaLabel != null && tapDesc(ariaLabel)) return "desc_exact";
        if (ariaLabel != null && tapDescContaining(ariaLabel)) return "desc_contains";
        if (tapNodeScan(actionText.toLowerCase())) return "node_scan";
        if (ariaLabel != null && tapNodeScan(ariaLabel.toLowerCase())) return "node_scan_aria";
        return null;
    }

    /** Panel-presence gate for the tap ladder: the wallet-action
     *  button only exists once the post-sign-in panel renders (the
     *  challenge copy, the button itself, or the busy state). The
     *  ladder must never fire before this is true. */
    private boolean panelPresent(String actionText, String ariaLabel) {
        if (hasText(actionText) || hasTextContaining(actionText)) return true;
        if (ariaLabel != null && (device.hasObject(By.desc(ariaLabel))
                || device.hasObject(By.descContains(ariaLabel)))) return true;
        if (hasTextContaining("Prove this handle") || hasTextContaining("WAITING FOR WALLET")) return true;
        String census = nodeCensus().toLowerCase();
        return census.contains(actionText.toLowerCase())
                || (ariaLabel != null && census.contains(ariaLabel.toLowerCase()));
    }

    /** All visible texts (deduped, capped) — the sheet-evidence line. */
    private String visibleTexts() {
        List<String> out = new ArrayList<>();
        for (String cls : new String[]{"android.widget.TextView", "android.widget.Button", "android.view.View"}) {
            for (UiObject2 o : device.findObjects(By.clazz(cls))) {
                try {
                    String t = o.getText();
                    if (t != null && !t.trim().isEmpty() && !out.contains(t.trim()) && out.size() < 24) {
                        out.add(t.trim());
                    }
                } catch (Exception ignored) { }
            }
        }
        return String.join(" | ", out);
    }

    private String failCopySeen() {
        for (String copy : FAILURE_COPIES) {
            if (hasTextContaining(copy)) return copy;
        }
        return "";
    }

    private void screenshot(String name) {
        try {
            File dir = instr.getTargetContext().getExternalFilesDir(null);
            if (dir != null) {
                //noinspection ResultOfMethodCallIgnored
                dir.mkdirs();
                device.takeScreenshot(new File(dir, "gate-" + name + ".png"));
            }
        } catch (Exception ignored) { }
    }

    private String shell(String cmd) {
        try {
            String out = device.executeShellCommand(cmd);
            return out == null ? "" : out.trim();
        } catch (Exception e) {
            return "shell-error:" + e.getMessage();
        }
    }

    /** Runner-independent read-back: POST {origin}/actions signIn. Returns data.status or error:<code>. */
    private String readback(String tag) {
        String status;
        try {
            HttpURLConnection conn = (HttpURLConnection) new URL(origin + "/actions").openConnection();
            conn.setConnectTimeout(20_000);
            conn.setReadTimeout(30_000);
            conn.setRequestMethod("POST");
            conn.setRequestProperty("Content-Type", "application/json");
            conn.setDoOutput(true);
            String body = "{\"action\":\"signIn\",\"args\":{\"name\":\"" + handleFull
                    + "\"},\"actionCallId\":\"ftl-gate-" + System.currentTimeMillis() + "\"}";
            try (OutputStream os = conn.getOutputStream()) {
                os.write(body.getBytes(StandardCharsets.UTF_8));
            }
            StringBuilder sb = new StringBuilder();
            try (BufferedReader br = new BufferedReader(new InputStreamReader(conn.getInputStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = br.readLine()) != null) sb.append(line);
            }
            JSONObject d = new JSONObject(sb.toString());
            JSONObject data = d.optJSONObject("data");
            if (data != null && data.has("status")) {
                status = data.optString("status");
            } else {
                JSONObject err = d.optJSONObject("error");
                status = "error:" + (err != null ? err.optString("code", "unknown") : "unknown");
            }
        } catch (Exception e) {
            status = "unreachable:" + e.getClass().getSimpleName();
        }
        kv("readback_" + tag, status);
        return status;
    }

    // ------------------------------------------------------------------
    // auth prompt (biometric / device credential) — the Mock's sheet
    // and its Authenticate both ride the system prompt. PIN path is
    // driven in-band (the CI watcher covers the emulator-fingerprint
    // path host-side; on FTL's lockscreen-less devices the first run
    // records what the Mock actually presents).
    // ------------------------------------------------------------------

    private boolean promptVisible() {
        return hasTextContaining("Log in to")
                || (MOCK_PKG.equals(device.getCurrentPackageName()) && hasTextContaining("Authenticate") && hasTextContaining("PIN"));
    }

    /** If the device's secure keyguard is showing (its PIN pad
     *  carries an "Emergency call" key), unlock it with the rig
     *  PIN. A no-op everywhere else. Build 5b23da5e lost both reps
     *  to a keyguard that engaged during setup. */
    private void dismissKeyguardIfPresent(String where) {
        try {
            if (!hasText("Emergency call")) return;
            kv("keyguard_unlock", where);
            try { device.wakeUp(); } catch (Exception ignored) { }
            for (String d : new String[]{"1", "2", "3", "4"}) {
                tapText(d);
                sleep(250);
            }
            tapText("OK");
            sleep(1500);
        } catch (Exception e) {
            kv("keyguard_unlock_failed", where + " " + e.getClass().getSimpleName());
        }
    }

    private boolean satisfyAuthPrompt(long budgetMs) {
        long deadline = System.currentTimeMillis() + budgetMs;
        boolean acted = false;
        while (System.currentTimeMillis() < deadline) {
            if (!promptVisible() && !hasTextContaining("Log in to")) {
                return acted || !hasTextContaining("Log in to");
            }
            // Prefer the device-credential route.
            if (tapText("Use PIN") || tapTextContaining("Use PIN")) {
                acted = true;
                sleep(1200);
            }
            // A PIN/password field up? Type the PIN.
            List<UiObject2> fields = device.findObjects(By.clazz("android.widget.EditText"));
            if (!fields.isEmpty()) {
                try {
                    fields.get(0).setText(pin);
                    acted = true;
                    sleep(600);
                    device.pressEnter();
                } catch (Exception ignored) { }
                sleep(1500);
            }
            sleep(1000);
        }
        return acted && !hasTextContaining("Log in to");
    }

    // ------------------------------------------------------------------
    // mock authentication (opens the 15-minute window before the reps)
    // ------------------------------------------------------------------

    private void authenticateMock() {
        try {
            dismissKeyguardIfPresent("mock_auth");
            device.pressHome();
            sleep(800);
            Intent intent = new Intent().setComponent(ComponentName.unflattenFromString(MOCK_ACT))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            instr.getContext().startActivity(intent);
            boolean up = device.wait(Until.hasObject(By.text("AUTHENTICATE")), 15_000)
                    || device.wait(Until.hasObject(By.text("Authenticate")), 5_000);
            if (!up) {
                kv("mock_auth", "button_absent fg=" + device.getCurrentPackageName() + " texts=" + visibleTexts());
                return;
            }
            if (!tapText("AUTHENTICATE")) tapText("Authenticate");
            sleep(1500);
            boolean ok = satisfyAuthPrompt(30_000);
            kv("mock_auth", ok ? "satisfied" : "prompt_not_satisfied texts=" + visibleTexts());
            screenshot("mock-after-auth");
        } catch (Exception e) {
            kv("mock_auth", "exception:" + e.getClass().getSimpleName());
        }
        device.pressHome();
        sleep(800);
    }

    // ------------------------------------------------------------------
    // app launch + gate navigation
    // ------------------------------------------------------------------

    private void launchApp() {
        Intent intent = new Intent().setComponent(ComponentName.unflattenFromString(APP_ACT))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
        instr.getContext().startActivity(intent);
    }

    /** PLAY (shell home) → the game's sign-in form. Generic interstitial
     *  progression: while the form is absent, a lone modal button from
     *  the known progression set is tapped and logged. */
    private boolean navigateToGateForm(String tag) {
        dismissKeyguardIfPresent(tag + "_nav");
        // Contains-matching for PLAY: the shell label carries a glyph
        // prefix ("▶ PLAY"), so exact-text can never match it — proven
        // 2026-11-02 (BrowserStack build ee3c83f9: play_absent logged
        // with "▶ PLAY" present in the dumped visible texts).
        if (!device.wait(Until.hasObject(By.textContains("PLAY")), 60_000)) {
            kv(tag + "_nav", "play_absent texts=" + visibleTexts());
            return false;
        }
        if (!tapTextContaining("PLAY")) tapText("PLAY");
        long deadline = System.currentTimeMillis() + 120_000;
        long navStart = System.currentTimeMillis();
        boolean woke = false;
        while (System.currentTimeMillis() < deadline) {
            boolean formUp = !device.findObjects(By.clazz("android.widget.EditText")).isEmpty()
                    && hasText("SIGN IN");
            if (formUp) {
                kv(tag + "_nav", "gate_form_reached");
                return true;
            }
            // WebView accessibility trees can lag the render by
            // minutes on some units (BrowserStack build bbf7dff5,
            // 2026-11-03: the form was on screen in video while the
            // tree stayed empty for the full nav budget, then
            // populated late). Two countermeasures: a wake tap on an
            // inert area to prod the tree, and at +45 s a blind
            // proceed — the sign-in step's coordinate route plus the
            // server read-backs arbitrate the outcome honestly.
            if (!woke && System.currentTimeMillis() - navStart > 15_000) {
                woke = true;
                device.click(device.getDisplayWidth() / 2, device.getDisplayHeight() / 4);
                sleep(2000);
            }
            if (System.currentTimeMillis() - navStart > 45_000) {
                kv(tag + "_nav", "blind_proceed_tree_absent texts=" + visibleTexts());
                return true;
            }
            for (String modal : new String[]{"OK", "CONTINUE", "START", "BEGIN", "GOT IT"}) {
                if (hasText(modal) && tapText(modal)) {
                    kv(tag + "_interstitial", modal);
                    sleep(1500);
                    break;
                }
            }
            sleep(2000);
        }
        kv(tag + "_nav", "gate_form_absent texts=" + visibleTexts());
        screenshot(tag + "-no-gate-form");
        return false;
    }

    private boolean enterHandleAndSignIn(String tag) {
        List<UiObject2> fields = device.findObjects(By.clazz("android.widget.EditText"));
        if (fields.isEmpty()) {
            // Coordinate route (tree absent — see the nav note): the
            // form's field and button sit at stable relative positions
            // in the fixed gate layout (verified against the
            // 2026-11-03 run's video frames on the 1080x2340 unit:
            // field centre ~ (0.50w, 0.425h), SIGN IN ~ (0.50w,
            // 0.545h)). Type via the shell input channel, dismiss the
            // keyboard, tap the button. The server read-backs and the
            // bind panel's appearance arbitrate whether it landed.
            // Guard: never spray coordinate taps at another app or
            // the launcher (rep2 of build 9cfcfe79 backed out to the
            // home screen when the app was not foreground).
            if (!APP_PKG.equals(device.getCurrentPackageName())) {
                kv(tag + "_signin", "coordinate_aborted fg=" + device.getCurrentPackageName());
                return false;
            }
            int w = device.getDisplayWidth();
            int h = device.getDisplayHeight();
            device.click(w / 2, (int) (h * 0.425));
            sleep(800);
            shell("input text " + handleLocal);
            sleep(800);
            // Dismiss the keyboard with ESC, never pressBack: when
            // no keyboard is up, BACK navigates out of the app
            // (build 9cfcfe79's rep2 ended on the launcher).
            shell("input keyevent 111");
            sleep(800);
            device.click(w / 2, (int) (h * 0.545));
            kv(tag + "_signin", "handle_entered_coordinate");
            return true;
        }
        try {
            UiObject2 field = fields.get(0);
            field.click();
            sleep(600);
            field.setText(handleLocal);
        } catch (Exception e) {
            shell("input tap 540 800");
            shell("input text " + handleLocal);
        }
        sleep(800);
        device.pressBack(); // dismiss the soft keyboard
        sleep(800);
        if (!tapText("SIGN IN")) {
            kv(tag + "_signin", "signin_button_absent texts=" + visibleTexts());
            return false;
        }
        kv(tag + "_signin", "handle_entered");
        return true;
    }

    // ------------------------------------------------------------------
    // one wallet-action rep: tap the gate's pending action, work the
    // wallet sheet, watch for foreground / failure copy / completion.
    // ------------------------------------------------------------------

    private static class Rep {
        boolean fgSeen = false;
        boolean tapped = false;
        boolean sheetTapped = false;
        boolean completed = false;
        String failCopy = "";
        String sheetAction = "";
    }

    private Rep runWalletAction(String tag, String actionText, String ariaLabel) {
        Rep rep = new Rep();
        long repStart = System.currentTimeMillis();
        long deadline = repStart + REP_BUDGET_MS;
        long tappedAt = 0;
        boolean retried = false;
        boolean censusLogged = false;
        int tapAttempts = 0;
        long tapUnverifiedAt = 0;
        int coordAttempts = 0;
        long lastCoordAt = 0;
        String lastSheetTexts = "";
        java.util.Map<String, Long> sheetTapAt = new java.util.HashMap<>();
        while (System.currentTimeMillis() < deadline) {
            String fg = device.getCurrentPackageName();
            String fc = failCopySeen();
            if (!fc.isEmpty()) {
                rep.failCopy = fc;
                kv(tag + "_failcopy", fc);
                screenshot(tag + "-failcopy");
                return rep;
            }
            if (MOCK_PKG.equals(fg)) {
                rep.fgSeen = true;
                // Sheet handling is CONTENT-DRIVEN, not latched:
                // authorize and sign sheets can both appear inside
                // ONE continuous wallet foregrounding (build
                // 5cd394eb's rep1: Connect tapped, then the sign
                // sheet waited out the 90 s timeout because the
                // stint never ended; its rep2 proved the cure
                // works when the sheet is reached — Approve tapped,
                // bind completed, server state advanced). Log the
                // sheet whenever its texts change, and tap any
                // visible sheet action, throttled per action so a
                // transitioning sheet is never double-tapped.
                String texts = visibleTexts();
                if (!texts.equals(lastSheetTexts)) {
                    lastSheetTexts = texts;
                    kv(tag + "_sheet_texts", texts);
                    screenshot(tag + "-sheet");
                }
                if (promptVisible() || hasTextContaining("Log in to")) {
                    satisfyAuthPrompt(20_000);
                    sleep(1000);
                    continue;
                }
                long nowMs = System.currentTimeMillis();
                for (String action : new String[]{"Approve", "APPROVE", "Sign", "SIGN", "Connect", "CONNECT"}) {
                    Long last = sheetTapAt.get(action);
                    if (last != null && nowMs - last < 6_000) continue;
                    if (tapText(action) || tapTextContaining(action)) {
                        sheetTapAt.put(action, nowMs);
                        rep.sheetTapped = true;
                        rep.sheetAction = action;
                        kv(tag + "_sheet_tapped", action);
                        sleep(2500);
                        satisfyAuthPrompt(15_000);
                        break;
                    }
                }
                sleep(1500);
                continue;
            }
            // Tap verification (runs regardless of branch): a tap
            // that produces no wallet foreground and no busy state
            // within 12 s did not land — clear it so the ladder can
            // run again. (The wallet-foreground branch above
            // `continue`s before this point whenever fg is the Mock.)
            if (rep.tapped && tapUnverifiedAt > 0
                    && System.currentTimeMillis() - tapUnverifiedAt > 12_000
                    && !rep.fgSeen
                    && !hasTextContaining("WAITING FOR WALLET")) {
                rep.tapped = false;
                tapUnverifiedAt = 0;
                kv(tag + "_tap_unverified", "attempt " + tapAttempts);
            }
            if (!rep.tapped) {
                if (panelPresent(actionText, ariaLabel)) {
                    String how = tapActionLadder(actionText, ariaLabel);
                    if (how != null) {
                        rep.tapped = true;
                        tapAttempts++;
                        tapUnverifiedAt = System.currentTimeMillis();
                        tappedAt = System.currentTimeMillis();
                        kv(tag + "_action_tapped", actionText + " via " + how
                                + " attempt " + tapAttempts);
                        sleep(1500);
                        continue;
                    }
                }
                // Coordinate route — some BrowserStack units never
                // expose the WebView button to the accessibility tree
                // at all (build 3c06c692: the census held only the
                // panel headings for the full budget). The panel's
                // action button sits at a measured, stable position:
                // centre-x, ~0.70 of height (pixel-measured on build
                // 9cfcfe79's recorded panel frame). Tap by
                // coordinates once the panel has had time to render,
                // throttled, and let the same tap verification +
                // server read-backs arbitrate.
                if (System.currentTimeMillis() - repStart > 25_000
                        && System.currentTimeMillis() - lastCoordAt > 15_000
                        && APP_PKG.equals(device.getCurrentPackageName())) {
                    lastCoordAt = System.currentTimeMillis();
                    coordAttempts++;
                    int w = device.getDisplayWidth();
                    int h = device.getDisplayHeight();
                    device.click(w / 2, (int) (h * 0.70));
                    rep.tapped = true;
                    tapAttempts++;
                    tapUnverifiedAt = System.currentTimeMillis();
                    tappedAt = System.currentTimeMillis();
                    kv(tag + "_action_tapped", actionText + " via coordinate"
                            + " attempt " + coordAttempts);
                    sleep(1500);
                    continue;
                }
                if (!censusLogged
                        && System.currentTimeMillis() - repStart > 20_000) {
                    censusLogged = true;
                    kv(tag + "_census", nodeCensus());
                }
            } else {
                // Completion: back in the app, the pending action is
                // gone, and the signed-in lobby marker is up — the
                // client only advances on the server's success
                // response (completeBind / completeSignIn state).
                boolean lobbyMarker = hasText("CONNECTED .SKR")
                        || hasTextContaining("CONNECTED")
                        || device.hasObject(By.descContains("CONNECTED"))
                        || hasText("SIGN OUT");
                if (APP_PKG.equals(fg) && !hasText(actionText)
                        && !hasText("WAITING FOR WALLET…")
                        && lobbyMarker) {
                    rep.completed = true;
                    kv(tag + "_completed", "lobby_marker");
                    screenshot(tag + "-completed");
                    return rep;
                }
                // One re-tap if the first tap plainly never landed
                // (action still offered, no busy state, wallet never
                // foregrounded, 30 s gone).
                if (!retried && !rep.fgSeen && hasText(actionText)
                        && System.currentTimeMillis() - tappedAt > 30_000) {
                    if (tapActionLadder(actionText, ariaLabel) != null) {
                        retried = true;
                        kv(tag + "_action_retapped", actionText);
                        tappedAt = System.currentTimeMillis();
                    }
                }
            }
            sleep(POLL_MS);
        }
        kv(tag + "_budget_exhausted", "fg=" + rep.fgSeen + " sheet=" + rep.sheetTapped
                + " texts=" + visibleTexts());
        screenshot(tag + "-final");
        return rep;
    }

    /** Reset the app to a fresh profile for the proof rep: navigate
     *  to the gate panel and use the in-app SIGN OUT (clears the
     *  local session; the server-side binding persists, which is all
     *  the proof rep needs). Shell-level resets (force-stop, pm
     *  clear) are FORBIDDEN in this suite: they kill the app process
     *  mid-test, which ends BrowserStack Espresso sessions outright
     *  (proven twice, 2026-11-02). */
    private String resetAppData() {
        dismissKeyguardIfPresent("reset");
        // The SIGN OUT control lives in the WebView gate panel, not
        // on the shell home — navigate via PLAY first, then poll for
        // it (the 2026-11-02 run ee3c83f9 waited 45 s on the home
        // screen for a control that was never there). If the sign-in
        // form is up instead, the app is already in the reset state
        // the proof rep needs. NO force-stop/pm-clear fallback: both
        // kill the app process, which ends BrowserStack sessions
        // outright (proven twice, 2026-11-02), while a "none" reset
        // still lets the rep run and log honestly.
        launchApp();
        if (!device.wait(Until.hasObject(By.textContains("PLAY")), 30_000)) {
            return "none(no_play texts=" + visibleTexts() + ")";
        }
        if (!tapTextContaining("PLAY")) tapText("PLAY");
        long deadline = System.currentTimeMillis() + 60_000;
        while (System.currentTimeMillis() < deadline) {
            if (hasText("SIGN OUT") || hasTextContaining("SIGN OUT")) {
                if (tapText("SIGN OUT") || tapTextContaining("SIGN OUT")) {
                    sleep(1500);
                    return "sign_out";
                }
            }
            boolean formUp = !device.findObjects(By.clazz("android.widget.EditText")).isEmpty()
                    && hasText("SIGN IN");
            if (formUp) return "already_signed_out";
            sleep(1500);
        }
        return "none(texts=" + visibleTexts() + ")";
    }

    // ------------------------------------------------------------------
    // the cell
    // ------------------------------------------------------------------

    @Test(timeout = 1_500_000)
    public void gateBindThenProof() {
        instr = InstrumentationRegistry.getInstrumentation();
        device = UiDevice.getInstance(instr);
        Bundle args = InstrumentationRegistry.getArguments();
        handleLocal = args.getString("vrHandleLocal", "gatefixture113");
        handleFull = handleLocal + ".skr";
        origin = args.getString("vrOrigin", "https://voidrunner-staging.137-184-143-128.sslip.io");
        pin = args.getString("vrPin", "1234");
        kv("config", "handle=" + handleFull + " origin=" + origin);

        try { device.wakeUp(); } catch (Exception ignored) { }

        // Security prelude — the rig contract the FTL wrapper used to
        // provide host-side (locksettings set-pin before the cell).
        // On BrowserStack nobody sets it, and without a secure lock
        // screen the Mock wallet CRASHES at its first dapp authorize:
        // its keystore encryption creates user-authentication-bound
        // keys, which Android refuses without a lock screen
        // ("Secure lock screen must be enabled to create keys
        // requiring user authentication" — device log, BrowserStack
        // build 9cfcfe79, 2026-11-03; the client correctly reported
        // "Wallet signing didn't complete" for the dead wallet).
        // Set the PIN first, before any wallet interaction.
        String pinOut = shell("locksettings set-pin " + pin);
        sleep(600);
        String pinVerify = shell("locksettings verify --old " + pin);
        kv("pin_prelude", "set=[" + pinOut.trim() + "] verify=[" + pinVerify.trim() + "]");
        // Keep the device awake and unlocked for the whole cell:
        // build 5b23da5e's unit idled into its secure keyguard
        // during setup and both reps nav-failed against the PIN
        // pad. Pooled units may also arrive with a credential
        // already set (set-pin then refuses; verify above is the
        // arbiter — 1234 verified on that unit too).
        shell("settings put system screen_off_timeout 1800000");
        shell("svc power stayon true");
        dismissKeyguardIfPresent("prelude");

        String pre = readback("pre"); // runner asserts bind_required too
        authenticateMock();

        // Rep 1 — bind. NO force-stop/pm-clear here: rigs provision a
        // fresh install for the cell (app data starts empty), and
        // BrowserStack's Espresso harness kills the session on a
        // mid-test force-stop of the app package — proven 2026-11-02
        // (build 8a229504: config + readback_pre + mock_auth all
        // logged, then the run died on this exact line, verdict
        // "Process Crashed", device left at the home screen).
        launchApp();
        Rep rep1 = new Rep();
        if (navigateToGateForm("rep1") && enterHandleAndSignIn("rep1")) {
            rep1 = runWalletAction("rep1", "LINK MY WALLET", "Link my wallet");
        } else {
            kv("rep1", "navigation_failed");
        }
        kv("rep1_fg", String.valueOf(rep1.fgSeen));
        kv("rep1_completed", String.valueOf(rep1.completed));
        // The mid read-back is a server query — always take it. Gating
        // it on the UI completion marker would let a selector miss
        // erase the authoritative evidence (2026-11-02 lesson).
        String mid = readback("mid");

        // Rep 2 — proof.
        String reset = resetAppData();
        kv("rep2_reset", reset);
        launchApp();
        Rep rep2 = new Rep();
        if (navigateToGateForm("rep2") && enterHandleAndSignIn("rep2")) {
            rep2 = runWalletAction("rep2", "PROVE IT'S YOU", "Prove it's you with your wallet");
        } else {
            kv("rep2", "navigation_failed");
        }
        kv("rep2_fg", String.valueOf(rep2.fgSeen));
        kv("rep2_completed", String.valueOf(rep2.completed));
        readback("post");

        boolean pass = rep1.fgSeen && rep2.fgSeen
                && rep1.failCopy.isEmpty() && rep2.failCopy.isEmpty()
                && rep1.completed && rep2.completed
                && "proof_required".equals(mid);
        kv("gate_verdict", pass ? "PASS" : "FAIL");

        emitVerdictFile();
        assertTrue("rep1 wallet foreground", rep1.fgSeen);
        assertTrue("rep2 wallet foreground", rep2.fgSeen);
        assertTrue("rep1 no failure copy", rep1.failCopy.isEmpty());
        assertTrue("rep2 no failure copy", rep2.failCopy.isEmpty());
        assertTrue("rep1 completed in-app", rep1.completed);
        assertTrue("rep2 completed in-app", rep2.completed);
        assertTrue("bind persisted (mid read-back proof_required)", "proof_required".equals(mid));
    }

    private void emitVerdictFile() {
        try {
            JSONObject json = new JSONObject();
            for (Map.Entry<String, String> e : verdict.entrySet()) {
                json.put(e.getKey(), e.getValue());
            }
            File dir = instr.getTargetContext().getExternalFilesDir(null);
            if (dir != null) {
                //noinspection ResultOfMethodCallIgnored
                dir.mkdirs();
                File out = new File(dir, "gate-verdict.json");
                try (FileWriter w = new FileWriter(out)) {
                    w.write(json.toString(2));
                }
                // BrowserStack only surfaces session assets from its
                // own directory — mirror the verdict there so the
                // file comes back with the build's artefacts.
                shell("mkdir -p /sdcard/Download/assets/session_data"
                        + " && cp " + out.getAbsolutePath()
                        + " /sdcard/Download/assets/session_data/ 2>/dev/null");
            }
        } catch (Exception e) {
            Log.i(TAG, "verdict_file_failed=" + e.getClass().getSimpleName());
        }
    }
}
