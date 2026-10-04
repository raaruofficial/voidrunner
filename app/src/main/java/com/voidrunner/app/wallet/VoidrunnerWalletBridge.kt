package com.voidrunner.app.wallet

import android.app.Activity
import android.webkit.JavascriptInterface
import com.solana.mobilewalletadapter.clientlib.ActivityResultSender
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * The seam between the game (running in the WebView) and the native
 * Solana wallet. Exposed to JavaScript as `window.VoidrunnerWallet`.
 *
 * Calling convention (the game side wires this in later):
 * ```js
 * // 1. Call a method with a unique requestId:
 * const res = JSON.parse(VoidrunnerWallet.connectWallet("req-123"));
 * // res = { accepted: true, requestId: "req-123" }
 *
 * // 2. Wait for the async result:
 * window.__voidrunnerWalletResolve = (requestId, resultJson) => {
 *   const result = JSON.parse(resultJson);
 *   // result = { ok: true, data: { publicKey: "..." } }
 *   //     or { ok: false, error: "..." }
 * };
 * ```
 *
 * Every `@JavascriptInterface` method runs on a WebView background thread;
 * results are always posted back onto the UI thread via [evaluateJs].
 * Nothing here ever touches a private key — signing happens inside the
 * Seeker's Seed Vault wallet through Mobile Wallet Adapter.
 */
class VoidrunnerWalletBridge(
    private val activity: Activity,
    private val walletManager: WalletManager,
    private val evaluateJs: (script: String) -> Unit
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    // ------------------------------------------------------------------
    // Synchronous getters (safe to call any time)
    // ------------------------------------------------------------------

    /** Bridge protocol version. The game can feature-detect on this. */
    @JavascriptInterface
    fun getVersion(): String = "1"

    @JavascriptInterface
    fun isConnected(): Boolean = walletManager.isConnected

    /** Base58 wallet address, or "" when not connected. */
    @JavascriptInterface
    fun getPublicKey(): String = walletManager.publicKeyBase58 ?: ""

    // ------------------------------------------------------------------
    // Async operations (ack immediately, resolve via __voidrunnerWalletResolve)
    // ------------------------------------------------------------------

    /**
     * Start the native MWA connect flow. Resolves with
     * `{ ok: true, data: { publicKey } }`.
     */
    @JavascriptInterface
    fun connectWallet(requestId: String): String {
        scope.launch {
            walletManager.connect(ActivityResultSender(activity)).fold(
                onSuccess = { pubkey ->
                    resolveOk(requestId, JSONObject().put("publicKey", pubkey))
                },
                onFailure = { e ->
                    resolveErr(requestId, e.message ?: "connect failed")
                }
            )
        }
        return ack(requestId)
    }

    /**
     * Ask the wallet to sign an arbitrary message. Resolves with
     * `{ ok: true, data: { signature } }` (Base58).
     */
    @JavascriptInterface
    fun signMessage(requestId: String, message: String): String {
        scope.launch {
            walletManager.signMessage(ActivityResultSender(activity), message).fold(
                onSuccess = { sig ->
                    resolveOk(requestId, JSONObject().put("signature", sig))
                },
                onFailure = { e ->
                    resolveErr(requestId, e.message ?: "sign failed")
                }
            )
        }
        return ack(requestId)
    }

    /**
     * Ask the wallet to sign (and send) a serialized Solana transaction.
     *
     * STUB in step 1 — resolves `{ ok: false, error: "not_implemented" }`.
     * Full implementation lands with the game wiring in step 2, using
     * MWA 2.0 `signAndSendTransactions` (the 2.0 spec deprecates
     * sign-only `signTransactions`).
     */
    @JavascriptInterface
    fun signTransaction(requestId: String, transactionBase64: String): String {
        scope.launch {
            resolveErr(requestId, "not_implemented: signTransaction lands in step 2 (game wiring)")
        }
        return ack(requestId)
    }

    // ------------------------------------------------------------------
    // Plumbing
    // ------------------------------------------------------------------

    private fun ack(requestId: String): String =
        JSONObject()
            .put("accepted", true)
            .put("requestId", requestId)
            .toString()

    private fun resolveOk(requestId: String, data: JSONObject) {
        val payload = JSONObject().put("ok", true).put("data", data).toString()
        postResolve(requestId, payload)
    }

    private fun resolveErr(requestId: String, error: String) {
        val payload = JSONObject().put("ok", false).put("error", error).toString()
        postResolve(requestId, payload)
    }

    private fun postResolve(requestId: String, resultJson: String) {
        // JSONObject.quote handles escaping; the game parses the string back.
        val script =
            "window.__voidrunnerWalletResolve && " +
                "window.__voidrunnerWalletResolve(${JSONObject.quote(requestId)}, ${JSONObject.quote(resultJson)});"
        evaluateJs(script)
    }
}
