package com.voidrunner.app.wallet

/**
 * The versioned VOIDRUNNER wallet-bridge contract (v1.0.13, CURE_PLAN §1b.1).
 *
 * The shell owns this contract; the served client must speak it exactly.
 * The wire protocol itself is unchanged from v1.0.12 — the shipped shell
 * was always conformant; what v1.0.13 adds is the contract as a named,
 * versioned, machine-checkable surface:
 *
 *  - [descriptorJson] is exposed to the page via the bridge's
 *    `getBridgeContract()` so any client can verify the shape at runtime.
 *  - The seal-time static conformance instrument (tools/bridge-conformance.py,
 *    fault class proposed in CURE_PLAN R-5) diffs the served bundle's
 *    bridge call sites + resolve-callback definition against the
 *    `@JavascriptInterface` signatures in VoidrunnerWalletBridge.kt and
 *    the method table below. Any drift fails the seal before submission.
 *
 * Pure Kotlin (no Android imports) so the descriptor is JVM-unit-testable.
 *
 * Protocol summary (the contract being versioned):
 *  - Async methods return ONLY an ack string: {"accepted":true,"requestId":…}.
 *  - Results arrive exclusively through the page-global callback
 *    window.__voidrunnerWalletResolve(requestId, resultJson), where
 *    resultJson is {"ok":true,"data":{…}} or {"ok":false,"error":"…"}.
 *  - A bridge dispatch failure that native can observe (resolve callback
 *    absent at result time, requestId collision, or a client-reported
 *    failure via reportBridgeFailure) is surfaced as a distinct logcat
 *    error (tag VoidrunnerWalletBridge, "BRIDGE_DISPATCH_FAILURE …")
 *    and as a named WebView error state: window.__VOIDRUNNER_BRIDGE_ERROR__.
 */
object BridgeContract {
    /** Bump when the method set, arities, or result/ack shapes change. */
    const val CONTRACT_VERSION = 1

    const val BRIDGE_NAME = "VoidrunnerWallet"
    const val RESOLVE_CALLBACK = "__voidrunnerWalletResolve"
    const val ERROR_STATE = "__VOIDRUNNER_BRIDGE_ERROR__"

    /** Failure codes carried by BRIDGE_DISPATCH_FAILURE / the error state. */
    const val FAIL_RESOLVE_CALLBACK_ABSENT = "RESOLVE_CALLBACK_ABSENT"
    const val FAIL_REQUEST_ID_COLLISION = "REQUEST_ID_COLLISION"

    /** Method name -> exact arity. Mirrors VoidrunnerWalletBridge's
     *  @JavascriptInterface set one-for-one (instrument-diffed). */
    val METHOD_ARITIES: Map<String, Int> = linkedMapOf(
        "getVersion" to 0,
        "isConnected" to 0,
        "getPublicKey" to 0,
        "getBridgeContract" to 0,
        "connectWallet" to 1,
        "signMessage" to 2,
        "signTransaction" to 2,
        "reportBridgeFailure" to 2,
    )

    /** Methods whose result arrives via the resolve callback (the rest
     *  return their value synchronously). */
    val ASYNC_METHODS: Set<String> = setOf("connectWallet", "signMessage", "signTransaction")

    /** The contract descriptor, as served to the page. Hand-built (no
     *  org.json) so it stays identical in JVM tests and on device. */
    fun descriptorJson(): String {
        val methods = METHOD_ARITIES.entries.joinToString(",") { (name, arity) ->
            "\"$name\":$arity"
        }
        val async = ASYNC_METHODS.joinToString(",") { "\"$it\"" }
        return "{" +
            "\"name\":\"$BRIDGE_NAME\"," +
            "\"contractVersion\":$CONTRACT_VERSION," +
            "\"resolveCallback\":\"$RESOLVE_CALLBACK\"," +
            "\"errorState\":\"$ERROR_STATE\"," +
            "\"ackShape\":\"{\\\"accepted\\\":true,\\\"requestId\\\":\\\"<id>\\\"}\"," +
            "\"resultShape\":\"{\\\"ok\\\":true,\\\"data\\\":{}}|{\\\"ok\\\":false,\\\"error\\\":\\\"\\\"}\"," +
            "\"methods\":{$methods}," +
            "\"asyncMethods\":[$async]" +
            "}"
    }
}
