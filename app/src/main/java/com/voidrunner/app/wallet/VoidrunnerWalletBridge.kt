package com.voidrunner.app.wallet

import android.util.Base64
import android.util.Log
import android.webkit.JavascriptInterface
import com.solana.mobilewalletadapter.clientlib.ActivityResultSender
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.util.Collections

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
 *
 * v1.0.13 (CURE_PLAN §1b): the protocol above is now a named, versioned
 * contract — see [BridgeContract] (exposed to the page via
 * [getBridgeContract], diffed against the served client by the seal-time
 * conformance instrument). Dispatch failures native can observe —
 * the resolve callback absent at result time, a requestId collision,
 * or a failure the client itself reports via [reportBridgeFailure] —
 * surface as a distinct logcat error ("BRIDGE_DISPATCH_FAILURE", tag
 * [TAG]) AND as a named WebView error state
 * (`window.__VOIDRUNNER_BRIDGE_ERROR__`), never only as a JS-side
 * generic failure copy. The wire protocol and all connect/sign
 * behaviour are unchanged from v1.0.12.
 */
class VoidrunnerWalletBridge(
    private val walletManager: WalletManager,
    private val sender: ActivityResultSender,
    private val evaluateJs: (script: String) -> Unit
) {
    // v1.0.4 crash fix: the sender is injected — it is constructed
    // once in MainActivity.onCreate. This class previously built a
    // new sender inline inside each operation method; those methods
    // run when the activity is RESUMED, so the sender constructor's
    // activity-result registration threw IllegalStateException and
    // wallet calls from the game crashed the process.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    /** requestIds with a result still owed to the page. A second call
     *  reusing an in-flight id is a dispatch failure (collision): it
     *  must never hijack the first call's result. */
    private val inFlight: MutableSet<String> =
        Collections.synchronizedSet(mutableSetOf())

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

    /**
     * The versioned bridge contract descriptor (see [BridgeContract]).
     * A client can verify the method set + arities it is about to call
     * before dispatching, instead of discovering a shape mismatch as a
     * silent in-WebView failure.
     */
    @JavascriptInterface
    fun getBridgeContract(): String = BridgeContract.descriptorJson()

    /**
     * Client-reported dispatch failure: the page calls this when a
     * bridge invocation fails on its side (e.g. its own conformance
     * check found no callable method of the expected shape). Native
     * cannot observe a JS call that never dispatched, so the contract
     * gives the client this reporting channel; the failure is then
     * surfaced identically to a native-observed one.
     */
    @JavascriptInterface
    fun reportBridgeFailure(requestId: String, code: String): String {
        dispatchFailure(requestId, code, reportedByClient = true)
        return ack(requestId)
    }

    // ------------------------------------------------------------------
    // Async operations (ack immediately, resolve via __voidrunnerWalletResolve)
    // ------------------------------------------------------------------

    /**
     * Start the native MWA connect flow. Resolves with
     * `{ ok: true, data: { publicKey } }`.
     */
    @JavascriptInterface
    fun connectWallet(requestId: String): String {
        if (!claimRequestId(requestId)) return collisionAck(requestId)
        scope.launch {
            walletManager.connect(sender).fold(
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
        if (!claimRequestId(requestId)) return collisionAck(requestId)
        scope.launch {
            walletManager.signMessage(sender, message).fold(
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
     * Ask the wallet to sign (and send) a serialized Solana transaction,
     * via MWA 2.0 `signAndSendTransactions` (the 2.0 spec deprecates
     * sign-only `signTransactions`). Resolves with
     * `{ ok: true, data: { signature } }` (Base58, first transaction).
     */
    @JavascriptInterface
    fun signTransaction(requestId: String, transactionBase64: String): String {
        if (!claimRequestId(requestId)) return collisionAck(requestId)
        scope.launch {
            val tx = runCatching { Base64.decode(transactionBase64, Base64.DEFAULT) }.getOrElse { e ->
                resolveErr(requestId, "invalid transaction encoding: ${e.message}")
                return@launch
            }
            walletManager.signAndSendTransactions(sender, listOf(tx)).fold(
                onSuccess = { sigs ->
                    resolveOk(requestId, JSONObject().put("signature", sigs.firstOrNull() ?: ""))
                },
                onFailure = { e ->
                    resolveErr(requestId, e.message ?: "sign-and-send failed")
                }
            )
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
        inFlight.remove(requestId)
        // JSONObject.quote handles escaping; the game parses the string back.
        // v1.0.13 failure visibility: if the resolve callback is absent
        // when the result arrives, the result must NOT vanish silently
        // (the pre-1.0.13 script's `&&` guard dropped it without a
        // trace). The fallback arm records the named WebView error
        // state and reports the failure back through the bridge, which
        // lands it in logcat as a distinct BRIDGE_DISPATCH_FAILURE.
        val id = JSONObject.quote(requestId)
        val script =
            "(function(){var cb=window.${BridgeContract.RESOLVE_CALLBACK};" +
                "if(typeof cb===\"function\"){cb($id, ${JSONObject.quote(resultJson)});}" +
                "else{window.${BridgeContract.ERROR_STATE}=" +
                "{code:\"${BridgeContract.FAIL_RESOLVE_CALLBACK_ABSENT}\",requestId:$id};" +
                "var b=window.${BridgeContract.BRIDGE_NAME};" +
                "if(b&&typeof b.reportBridgeFailure===\"function\"){" +
                "b.reportBridgeFailure($id,\"${BridgeContract.FAIL_RESOLVE_CALLBACK_ABSENT}\");}}})();"
        evaluateJs(script)
    }

    /** Register a requestId as owed a result; false = collision. */
    private fun claimRequestId(requestId: String): Boolean {
        if (inFlight.add(requestId)) return true
        dispatchFailure(requestId, BridgeContract.FAIL_REQUEST_ID_COLLISION, reportedByClient = false)
        return false
    }

    private fun collisionAck(requestId: String): String =
        JSONObject()
            .put("accepted", false)
            .put("requestId", requestId)
            .put("error", BridgeContract.FAIL_REQUEST_ID_COLLISION)
            .toString()

    /**
     * The failure-visibility surface (v1.0.13): a distinct logcat error
     * AND the named WebView error state. Any dispatch failure native
     * can observe funnels through here.
     */
    private fun dispatchFailure(requestId: String, code: String, reportedByClient: Boolean) {
        Log.e(
            TAG,
            "BRIDGE_DISPATCH_FAILURE code=$code requestId=$requestId" +
                if (reportedByClient) " reportedBy=client" else ""
        )
        val script =
            "window.${BridgeContract.ERROR_STATE}=" +
                "{code:${JSONObject.quote(code)},requestId:${JSONObject.quote(requestId)}};"
        evaluateJs(script)
    }

    companion object {
        const val TAG = "VoidrunnerWalletBridge"
    }
}
