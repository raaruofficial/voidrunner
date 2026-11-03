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
        while (System.currentTimeMillis() < deadline) {
            boolean formUp = !device.findObjects(By.clazz("android.widget.EditText")).isEmpty()
                    && hasText("SIGN IN");
            if (formUp) {
                kv(tag + "_nav", "gate_form_reached");
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
            kv(tag + "_signin", "no_edittext");
            return false;
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

    private Rep runWalletAction(String tag, String actionText) {
        Rep rep = new Rep();
        long deadline = System.currentTimeMillis() + REP_BUDGET_MS;
        long tappedAt = 0;
        boolean retried = false;
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
                if (promptVisible() || hasTextContaining("Log in to")) {
                    satisfyAuthPrompt(20_000);
                    sleep(1000);
                    continue;
                }
                // Wallet sheet: record what it shows, then approve.
                if (!rep.sheetTapped) {
                    kv(tag + "_sheet_texts", visibleTexts());
                    screenshot(tag + "-sheet");
                    for (String action : new String[]{"Approve", "APPROVE", "Sign", "SIGN", "Connect", "CONNECT"}) {
                        if (tapText(action) || tapTextContaining(action)) {
                            rep.sheetTapped = true;
                            rep.sheetAction = action;
                            kv(tag + "_sheet_tapped", action);
                            break;
                        }
                    }
                    if (rep.sheetTapped) {
                        sleep(2500);
                        satisfyAuthPrompt(15_000);
                    }
                }
                sleep(1500);
                continue;
            }
            if (!rep.tapped) {
                if (hasText(actionText) && tapText(actionText)) {
                    rep.tapped = true;
                    tappedAt = System.currentTimeMillis();
                    kv(tag + "_action_tapped", actionText);
                    sleep(1500);
                    continue;
                }
            } else {
                // Completion: back in the app, the pending action is
                // gone, and the signed-in lobby marker is up — the
                // client only advances on the server's success
                // response (completeBind / completeSignIn state).
                if (APP_PKG.equals(fg) && !hasText(actionText)
                        && !hasText("WAITING FOR WALLET…")
                        && hasText("CONNECTED .SKR")) {
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
                    if (tapText(actionText)) {
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
            rep1 = runWalletAction("rep1", "LINK MY WALLET");
        } else {
            kv("rep1", "navigation_failed");
        }
        kv("rep1_fg", String.valueOf(rep1.fgSeen));
        kv("rep1_completed", String.valueOf(rep1.completed));
        String mid = rep1.completed ? readback("mid") : "skipped";

        // Rep 2 — proof.
        String reset = resetAppData();
        kv("rep2_reset", reset);
        launchApp();
        Rep rep2 = new Rep();
        if (navigateToGateForm("rep2") && enterHandleAndSignIn("rep2")) {
            rep2 = runWalletAction("rep2", "PROVE IT'S YOU");
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
                try (FileWriter w = new FileWriter(new File(dir, "gate-verdict.json"))) {
                    w.write(json.toString(2));
                }
            }
        } catch (Exception e) {
            Log.i(TAG, "verdict_file_failed=" + e.getClass().getSimpleName());
        }
    }
}
