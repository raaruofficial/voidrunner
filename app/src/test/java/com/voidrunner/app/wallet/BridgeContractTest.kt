package com.voidrunner.app.wallet

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * v1.0.13 bridge-contract pins (CURE_PLAN §1b.1): the descriptor the
 * shell serves to the page must carry the versioned contract — the
 * exact method set + arities the conformance instrument diffs the
 * served client against. If the bridge's @JavascriptInterface set
 * changes, this test and BridgeContract must move together, and the
 * seal's static conformance run re-checks the pair against the
 * served bundle.
 */
class BridgeContractTest {

    @Test
    fun `descriptor carries the contract identity`() {
        val d = BridgeContract.descriptorJson()
        assertTrue(d.contains("\"name\":\"VoidrunnerWallet\""))
        assertTrue(d.contains("\"contractVersion\":1"))
        assertTrue(d.contains("\"resolveCallback\":\"__voidrunnerWalletResolve\""))
        assertTrue(d.contains("\"errorState\":\"__VOIDRUNNER_BRIDGE_ERROR__\""))
    }

    @Test
    fun `method arities are the shipped protocol`() {
        // The exact-arity table Android's JavascriptInterface dispatch
        // enforces. signMessage / signTransaction are the two-argument
        // calls whose shape the v1.0.12 rejection turned on.
        assertEquals(0, BridgeContract.METHOD_ARITIES["getVersion"])
        assertEquals(0, BridgeContract.METHOD_ARITIES["isConnected"])
        assertEquals(0, BridgeContract.METHOD_ARITIES["getPublicKey"])
        assertEquals(0, BridgeContract.METHOD_ARITIES["getBridgeContract"])
        assertEquals(1, BridgeContract.METHOD_ARITIES["connectWallet"])
        assertEquals(2, BridgeContract.METHOD_ARITIES["signMessage"])
        assertEquals(2, BridgeContract.METHOD_ARITIES["signTransaction"])
        assertEquals(2, BridgeContract.METHOD_ARITIES["reportBridgeFailure"])
        assertEquals(8, BridgeContract.METHOD_ARITIES.size)
    }

    @Test
    fun `descriptor method table matches the arity map`() {
        val d = BridgeContract.descriptorJson()
        for ((name, arity) in BridgeContract.METHOD_ARITIES) {
            assertTrue("descriptor missing $name:$arity", d.contains("\"$name\":$arity"))
        }
        assertEquals(
            setOf("connectWallet", "signMessage", "signTransaction"),
            BridgeContract.ASYNC_METHODS
        )
    }

    @Test
    fun `failure codes are stable strings`() {
        assertEquals("RESOLVE_CALLBACK_ABSENT", BridgeContract.FAIL_RESOLVE_CALLBACK_ABSENT)
        assertEquals("REQUEST_ID_COLLISION", BridgeContract.FAIL_REQUEST_ID_COLLISION)
    }
}
