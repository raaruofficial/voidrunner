package com.voidrunner.app.wallet

import android.net.Uri
import android.util.Log
import com.solana.mobilewalletadapter.clientlib.ActivityResultSender
import com.solana.mobilewalletadapter.clientlib.ConnectionIdentity
import com.solana.mobilewalletadapter.clientlib.MobileWalletAdapter
import com.solana.mobilewalletadapter.clientlib.TransactionResult
import com.solana.mobilewalletadapter.clientlib.successPayload
import com.voidrunner.app.util.Base58
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.atomic.AtomicInteger

/**
 * UI-facing wallet state. Observed by Compose screens via [uiState].
 */
sealed interface WalletUiState {
    data object Disconnected : WalletUiState
    data object Working : WalletUiState
    data class Connected(val publicKeyBase58: String) : WalletUiState
    data class Error(val message: String) : WalletUiState
}

/**
 * Owns the Solana Mobile Wallet Adapter session.
 *
 * Uses the official `mobile-wallet-adapter-clientlib-ktx` (MWA 2.0):
 * - [MobileWalletAdapter.connect] for the connect/session flow
 * - [MobileWalletAdapter.transact] + `signMessagesDetached` for message signing
 * - [MobileWalletAdapter.disconnect] to revoke the session
 *
 * API reference: solana-mobile-docs, "Using Mobile Wallet Adapter"
 * (android-native). The auth token is managed in-memory by the MWA client;
 * persist [persistedAuthToken] (e.g. encrypted prefs) to skip the approval
 * dialog on later launches.
 *
 * v1.0.7 state-handling cures (REPORT_V106, §2.2 verdict on v1.0.6):
 * - KFC-007: the connected pubkey is captured into [sessionPublicKeyBase58]
 *   at connect time, and [restoreConnectedState] restores from that field.
 *   Previously restore read [publicKeyBase58], which derives from the live
 *   UI state — a state the transact paths have already overwritten with
 *   Working — so every sign (success or failure) landed on Disconnected
 *   even though the MWA session survived.
 * - KFC-008: every wallet request runs as a tracked, cancellable job with
 *   a bounded timeout backstop, and MainActivity's onResume calls
 *   [onReturnedToForeground] so a request the wallet abandoned (user
 *   backgrounded the app mid-approval and the wallet dropped the request)
 *   resolves to session truth instead of hanging in Working forever —
 *   the clientlib transact itself carries no timeout.
 *
 * v1.0.8 KFC-008 CORRECTION (REPORT_V107, §2.2 verdict on v1.0.7 —
 * VR-12 FAIL, replicated ×2 + 150 s diagnostic): the v1.0.7 shape's
 * foreground reconciliation cancelled the request Deferred and let the
 * state resolution happen behind `deferred.await()` in the caller's
 * coroutine. clientlib's connect/transact suspension is
 * non-cooperative: cancelling the Deferred does not wake the awaiter
 * while the underlying call is parked, so the app sat in Working
 * through the full 30 s cell window (first resolution at ~51 s
 * post-return, on clientlib's own cadence — not the grace cancel, not
 * the 120 s backstop). The reconciler now resolves the UI state
 * DIRECTLY from session truth after the grace window, generation-
 * guarded so neither the wrapper's late resolution nor a zombie
 * request's late failure write can overwrite it, and cancels the
 * request as best effort. Ported from HAUNT v0.1.16 (haunt-lane/repo
 * commit 40582dc), whose v0.1.15 verdict runtime-proved the identical
 * failure on this same cure shape.
 *
 * v1.0.9 KFC-008 COMBINED CURE (REPORT_V108, §2.2 verdict on v1.0.8 —
 * VR-12(a) resolution PASS ×3 and VR-12(c) sign branch PASS ×3, but
 * VR-12(b) the in-process TRY AGAIN retry leg INTERMITTENT: FAIL ×2
 * API 36, PASS ×1 API 35; v1.0.8 barred solely by the retry leg).
 * Ported from HAUNT v0.1.19 (haunt-lane/repo commit 2ff0500), the
 * final combined shape of the lineage 4a59e04 (v0.1.17) → 635bfc5
 * (v0.1.18) → 2ff0500 (v0.1.19), runtime-closed on HAUNT in
 * REPORT_V0119_WALLET (vr12 PASS ×2, vr12r PASS ×2). Three layers:
 * - ZOMBIE-SESSION HYGIENE (HAUNT v0.1.17, REPORT_V0116 addendum 2 +
 *   REPORT_V0117): the abandoned transact's MWA association survives
 *   app-side in the wallet, and the retry's own association cannot
 *   bind while the wallet serves the zombie. The adapter is now
 *   recreatable: every interruption resolution discards and recreates
 *   it (auth token carried across), and a connect following an
 *   interruption discards once more before transacting. (Proven
 *   insufficient ALONE — retained as hygiene; it costs nothing.)
 * - REFIRE LOOP (HAUNT v0.1.18, REPORT_V0117): the refined mechanism,
 *   corroborated by elimination, is that the retry's association
 *   INTENT is swallowed by the wallet while the zombie sheet is in
 *   flight (single-task intent handling; a fresh process works
 *   because its first intent lands on an idle wallet). A connect
 *   following an interruption ONLY therefore runs up to
 *   [INTERRUPTED_CONNECT_ATTEMPTS] attempts; a timed-out attempt is
 *   abandoned in a child scope (late result dropped, state writes
 *   generation-guarded) and the next attempt refires a fresh intent
 *   on a reset adapter. Normal connects are untouched.
 * - RECONCILER SCOPING + LOOP HARDENING (HAUNT v0.1.19,
 *   REPORT_V0118): the v1.0.8-shape reconciler armed on ANY pending
 *   request at resume and could not distinguish a request pending
 *   since before the backgrounding (abandoned — its design target)
 *   from one started in the foreground after the return (the retry —
 *   on HAUNT's bench the reconciler claimed and cancelled the retry
 *   itself at +5 s). The reconciler now resolves ONLY the generation
 *   snapshotted at backgrounding ([onAppBackgrounded], from
 *   MainActivity.onStop); the refire loop's generation is exempt
 *   outright (its sheet flows background the app by design; its own
 *   bounds resolve it). Loop hardening from the same evidence:
 *   clientlib's association budget is ~30 s (the swallowed attempt's
 *   knocks ran 30.6 s), so the attempt slot is 35 s, and inside the
 *   loop a SLOW outcome (>25 s: timeout, throw, or Failure) is the
 *   swallow signature and refires, while a FAST definitive answer
 *   ends the loop. Attempt-level Log.d (tag VoidrunnerWallet) added
 *   so the verdict grades on the loop's own wire markers.
 * - CLAIM SETTLEMENT (estate skill prove_wallet_abandonment_recovery;
 *   VR-specific addition, not in HAUNT's shape): where the reconciler
 *   claims a generation, the awaiting caller must receive exactly one
 *   failure result AT CLAIM TIME — not only a state write — so a
 *   bridge/promise waiter settles once and clears its guard. The bare
 *   wrapper cannot deliver that: its await is parked behind the
 *   non-cooperative clientlib call (the REPORT_V107 finding), so the
 *   wrapper additionally races the request against a per-generation
 *   claim signal the reconciler completes when it claims. The signal
 *   only wakes the wrapper into its existing generation-guarded tail:
 *   the claim being already taken, it returns the unwritten failure
 *   result and never re-invokes onInterrupted — settlement is exactly
 *   once, by the same claim that guards the state write.
 *
 * v1.0.10 KFC-008 SIGN-BRANCH CORRECTION (REPORT_V109, §2.2 verdict on
 * v1.0.9 — VR-12(a) PASS ×3, VR-12(b) PASS ×3 with the modelled
 * slow-refire choreography, scoping probes clean; but VR-12(c) FAIL
 * ×3 bars the build): the sign branch's resolution half restored
 * Connected+pubkey in 3–6 s in every rep, yet the FOLLOW-UP sign then
 * created exactly one fresh association that never established — the
 * interruption resolution's adapter reset (the v1.0.9 hygiene layer
 * above) discards the adapter instance the established session lives
 * on, so the follow-up sign is forced onto a fresh association, which
 * the wallet swallows while it still holds the zombie sign session;
 * the sign path carries no refire loop (connect-only, by design —
 * sign and sign-and-send are not idempotent, so a refire could
 * double-submit). On v1.0.8 — no resolution-time reset — the
 * follow-up sign reused the established session and VR-12(c) passed
 * ×3 (REPORT_V108; re-proven on v1.0.8 in REPORT_V109's control run,
 * VR-12S PASS). The cure is kind-scoped: interruption resolutions for
 * SIGN-kind requests no longer discard/recreate the adapter — the
 * session and its adapter stay exactly as established, so a follow-up
 * sign reuses the established session. CONNECT resolutions keep the
 * reset, and the connect path's own adapter choreography (the entry
 * discard and the per-attempt resets inside [performConnect]) is
 * byte-preserved: VR-12(b) passed ×3 with exactly that choreography,
 * and those resets fire only inside performConnect, which the sign
 * paths never enter.
 *
 * v1.0.11 KFC-008 ZOMBIE-CLEAR GATE (REPORT_V110, §2.2 verdict on
 * v1.0.10 — VR-12(a) PASS ×5, VR-12(b) PASS ×5, VR-12(c) FAIL ×5;
 * mechanism CORRECTED by that report's re-read of REPORT_V108's own
 * artefacts, superseding the v1.0.10 attribution above): a follow-up
 * `transact` creates a fresh association scenario on EVERY build —
 * the adapter reset never forced it, and v1.0.8's historical (c)
 * PASS was the zombie's late result landing on its never-claim-
 * settled original caller, an accident claim settlement (correctly,
 * per the estate skill) eliminates. The true layer: while the wallet
 * still holds the ZOMBIE sheet of a just-interrupted request, its
 * single-task intent handler swallows the follow-up transact's
 * association intent — no server starts, connects are ECONNREFUSED
 * for the scenario's life, the follow-up never establishes. The
 * zombie clears when its result is delivered / its session closes.
 * The connect branch survives the same swallow via its refire loop;
 * the sign path must NOT get a refire loop (sign-and-send is not
 * idempotent — a re-issued sign whose first attempt established late
 * could double-submit). The cure is therefore a bounded WAIT, not a
 * retry: an interruption resolution records a zombie-outstanding
 * marker for its generation; the marker clears when the interrupted
 * request's late resolution arrives (hooked in the generation-
 * suppressed tail of its own request wrapper — see
 * [runWalletRequest]) or on a bounded expiry timer; and the FIRST
 * sign request after an interruption awaits that clearance —
 * bounded by the association budget (~35 s, inside the 120 s
 * backstop) — before issuing its SINGLE transact exactly as before.
 * On expiry it proceeds anyway: pre-v1.0.11 behaviour is the floor.
 * The gate waits only: it claims nothing, settles nothing, writes no
 * connection state; with no marker outstanding it is a no-op, so an
 * ordinary sign is never delayed. The v1.0.10 kind-scoped adapter
 * reset stands as harmless hygiene (it preserves every v1.0.9 pass
 * but does not touch this layer). Gate events are Log.d under
 * [LOG_TAG] (wait-start / cleared-by-late-result / wait-expired) so
 * the verdict grades the gate from its own wire markers.
 */
class WalletManager {

    @Volatile
    private var walletAdapter: MobileWalletAdapter = newWalletAdapter()

    private fun newWalletAdapter(): MobileWalletAdapter = MobileWalletAdapter(
        connectionIdentity = ConnectionIdentity(
            identityUri = Uri.parse("https://voidrunner-2hm7p.ondigitalocean.app/"),
            // v1.0.5 cure (VR-1 defect, §2.2 verdict 2026-10-29): clientlib-ktx
            // treats iconUri as iconRelativeUri and throws "If non-null,
            // iconRelativeUri must be a relative Uri" on EVERY transact when
            // given an absolute URL — no wallet session could ever be
            // established. The icon must be RELATIVE; the wallet resolves it
            // against identityUri. This path is the logo the game build
            // itself ships at the identity origin (client build asset
            // `assets/voidrunner-logo-5bj5j5gp.webp`), so it resolves to the
            // exact URL the previous absolute value named.
            iconUri = Uri.parse("assets/voidrunner-logo-5bj5j5gp.webp"),
            identityName = "VOIDRUNNER"
        )
    )

    /**
     * v1.0.9 (HAUNT v0.1.17): set when a wallet request has been
     * resolved as interrupted (foreground reconciliation or the
     * timeout backstop). A CONNECT resolution itself already discarded
     * the adapter; a SIGN resolution deliberately did not (v1.0.10 —
     * the follow-up sign reuses the established session; see the class
     * header). Either way, a connect that follows an interruption
     * discards once more before transacting (see the class header),
     * so the retry never inherits any scenario state accumulated
     * since the interruption either.
     */
    @Volatile
    private var lastRequestInterrupted: Boolean = false

    /**
     * v1.0.9 zombie-session hygiene (HAUNT v0.1.17): discard the
     * current [MobileWalletAdapter] and replace it with a fresh
     * instance, so the abandoned transact's association scenario and
     * its local server die with the discarded instance and the next
     * request's association can bind cleanly. The MWA auth token is
     * carried across the swap. In-flight requests are unaffected —
     * they captured their adapter reference at entry.
     */
    @Synchronized
    private fun resetWalletAdapter() {
        val old = walletAdapter
        walletAdapter = newWalletAdapter().also { it.authToken = old.authToken }
    }

    private val _uiState = MutableStateFlow<WalletUiState>(WalletUiState.Disconnected)
    val uiState: StateFlow<WalletUiState> = _uiState.asStateFlow()

    val publicKeyBase58: String?
        get() = (_uiState.value as? WalletUiState.Connected)?.publicKeyBase58

    val isConnected: Boolean
        get() = _uiState.value is WalletUiState.Connected

    /**
     * KFC-007 cure: the session's public key (Base58), captured at connect
     * success and cleared only by [disconnect]. This field — never the
     * live UI state — is the restore source for [restoreConnectedState]:
     * the UI state is Working for the whole duration of a transact, so it
     * cannot testify about the session underneath it.
     */
    @Volatile
    private var sessionPublicKeyBase58: String? = null

    /**
     * KFC-008 cure: scope owning the in-flight wallet request so it can
     * be cancelled from outside the caller's own scope (the wallet screen
     * and the WebView bridge call in from different scopes; the request
     * must be cancellable regardless of which one started it).
     */
    private val requestScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** The in-flight wallet request (connect / sign / sign-and-send), if any. */
    @Volatile
    private var pendingRequest: Job? = null

    /** Which kind of request is in flight — the reconciler's direct
     *  resolution differs by kind (connect → Error; sign → restore). */
    private enum class RequestKind { CONNECT, SIGN }

    @Volatile
    private var pendingKind: RequestKind? = null

    /**
     * v1.0.8: request generation + resolution claim. Every request
     * takes the next generation; exactly one party — the wrapper on
     * its interrupted path, or the foreground reconciler — may claim
     * a generation's state resolution ([claimResolution]). A claimed
     * generation's late writes (the wrapper's onInterrupted, a zombie
     * connect's failure write) are suppressed: the state has already
     * been resolved by whoever claimed it.
     */
    private val generationCounter = AtomicInteger(0)

    @Volatile
    private var pendingGeneration: Int = 0

    @Volatile
    private var resolvedGeneration: Int = 0

    private val resolutionLock = Any()

    /** Claim generation [gen]'s state resolution. True exactly once per gen. */
    private fun claimResolution(gen: Int): Boolean = synchronized(resolutionLock) {
        if (resolvedGeneration == gen) false else {
            resolvedGeneration = gen
            true
        }
    }

    /**
     * v1.0.9 claim settlement (class header): the in-flight request's
     * claim signal. The wrapper races its request await against this
     * signal; the foreground reconciler completes it when it claims
     * the generation, so the awaiting caller settles at claim time
     * instead of whenever the parked clientlib call happens to return.
     * Completed at most once (CompletableDeferred), consumed only by
     * the wrapper that created it, and cleared by that wrapper's
     * finally — a stale completion can never wake a later request,
     * which creates its own signal.
     */
    @Volatile
    private var pendingClaimSignal: CompletableDeferred<Unit>? = null

    /**
     * v1.0.11 zombie-clear gate (class header): why a generation's
     * zombie marker cleared — the interrupted request's late
     * resolution arrived, or the bounded expiry fired first.
     */
    private enum class ZombieClearReason { LATE_RESULT, EXPIRED }

    /**
     * v1.0.11: the zombie-outstanding marker for one interrupted
     * generation. [signal] completes exactly once, with the clear
     * reason; [gateConsumed] is set by the first SIGN request that
     * waits on this marker, so exactly one sign is ever gated per
     * interruption (subsequent signs are ungated even if the zombie
     * is somehow still outstanding after that wait).
     */
    private class ZombieMarker(val generation: Int) {
        val signal = CompletableDeferred<ZombieClearReason>()

        @Volatile
        var gateConsumed: Boolean = false
    }

    private val zombieLock = Any()

    @Volatile
    private var zombieMarker: ZombieMarker? = null

    /**
     * v1.0.11: the last generation whose late resolution was observed
     * by its wrapper's tail AFTER a claim had already settled it
     * (see the finally hook in [runWalletRequest]). Guards the claim/
     * completion race: if the late result lands in the same instant
     * the claim settles and the tail runs before the resolution site
     * records the marker, the marker is never recorded at all — the
     * zombie it would have named is already gone.
     */
    @Volatile
    private var lateResolvedGeneration: Int = 0

    /**
     * v1.0.11: record the zombie-outstanding marker for [gen]. Called
     * at every interruption resolution site (the reconciler's claim
     * block, the wrapper's interrupted tail, the caller-cancelled
     * claim path) — idempotent per generation, so the sites may all
     * fire for one interruption without stacking markers or resetting
     * the expiry. The marker also arms its own bounded expiry: if
     * the late resolution never arrives, the expiry clears it, so a
     * marker can never wedge the app.
     */
    private fun markZombieOutstanding(gen: Int) {
        val marker = ZombieMarker(gen)
        synchronized(zombieLock) {
            if (zombieMarker?.generation == gen) return
            if (lateResolvedGeneration == gen) return
            zombieMarker = marker
        }
        Log.d(LOG_TAG, "zombie marker set gen=$gen")
        requestScope.launch {
            delay(ZOMBIE_MARKER_EXPIRY_MS)
            clearZombieMarker(gen, ZombieClearReason.EXPIRED)
        }
    }

    /**
     * v1.0.11: clear [gen]'s zombie marker, if it is the one
     * outstanding, completing its signal with [reason] so a gated
     * sign wakes. Called from the interrupted request's own late-
     * resolution tail (LATE_RESULT), from the marker's expiry timer
     * (EXPIRED), and from the gate itself when its local wait bound
     * fires first (EXPIRED). Any outcome of the late request —
     * success, failure, error, cancellation delivery — clears: what
     * frees the wallet is the zombie session closing, not the result.
     */
    private fun clearZombieMarker(gen: Int, reason: ZombieClearReason) {
        val marker = synchronized(zombieLock) {
            val current = zombieMarker
            if (current == null || current.generation != gen) null
            else {
                zombieMarker = null
                current
            }
        } ?: return
        if (reason == ZombieClearReason.EXPIRED && !marker.gateConsumed) {
            Log.d(LOG_TAG, "zombie marker expired gen=$gen")
        }
        marker.signal.complete(reason)
    }

    /**
     * v1.0.11: the sign-path gate. With no marker outstanding this
     * returns immediately — marker absent → zero wait, so an ordinary
     * sign is never delayed. Otherwise the FIRST sign after the
     * interruption consumes the gate and awaits the marker's
     * clearance, bounded by [ZOMBIE_GATE_WAIT_MS] (the ~35 s
     * association budget, comfortably inside the 120 s request
     * backstop that wraps this call). On late-result clearance it
     * proceeds at once; on expiry it proceeds anyway — today's
     * behaviour is the floor, never worse. The gate issues no
     * transact of its own and touches no state: the caller proceeds
     * to its single transact exactly as before, so no sign can ever
     * be double-submitted by waiting.
     */
    private suspend fun awaitZombieClearGate() {
        val marker = synchronized(zombieLock) {
            val current = zombieMarker
            if (current == null || current.gateConsumed) null
            else {
                current.gateConsumed = true
                current
            }
        } ?: return
        val waitStartMs = System.currentTimeMillis()
        Log.d(LOG_TAG, "zombie gate wait-start zombieGen=${marker.generation}")
        val reason = withTimeoutOrNull(ZOMBIE_GATE_WAIT_MS) { marker.signal.await() }
        val waitedMs = System.currentTimeMillis() - waitStartMs
        if (reason == ZombieClearReason.LATE_RESULT) {
            Log.d(
                LOG_TAG,
                "zombie gate cleared-by-late-result zombieGen=${marker.generation} waitedMs=$waitedMs"
            )
        } else {
            Log.d(
                LOG_TAG,
                "zombie gate wait-expired zombieGen=${marker.generation} waitedMs=$waitedMs"
            )
            // The local bound fired before the marker's own expiry
            // timer (or raced it): make sure the marker is gone.
            if (reason == null) clearZombieMarker(marker.generation, ZombieClearReason.EXPIRED)
        }
    }

    /** Get/set the MWA auth token so it can be persisted across restarts. */
    var persistedAuthToken: String?
        get() = walletAdapter.authToken
        set(value) {
            walletAdapter.authToken = value
        }

    /**
     * Connect to a wallet. Launches the MWA association intent via [sender]
     * (the calling Activity's single sender, created in its onCreate —
     * never construct an ActivityResultSender at call time).
     * Returns the wallet's Base58 public key on success.
     */
    suspend fun connect(sender: ActivityResultSender): Result<String> =
        runWalletRequest(RequestKind.CONNECT, onInterrupted = { fail(INTERRUPTED_MESSAGE) }) { gen ->
            performConnect(sender, gen)
        }

    /** One connect attempt's outcome: a definitive wallet answer, or a throw. */
    private sealed interface ConnectOutcome {
        // clientlib-ktx connect() returns TransactionResult<Unit>:
        // the Success carries the authorization in its authResult
        // property, not in the payload.
        data class Answered(
            val result: TransactionResult<Unit>
        ) : ConnectOutcome
        data class Threw(val error: Throwable) : ConnectOutcome
    }

    private suspend fun performConnect(sender: ActivityResultSender, gen: Int): Result<String> =
        withContext(Dispatchers.IO) {
            _uiState.value = WalletUiState.Working
            // v1.0.9: a connect following an interruption transacts on
            // a freshly discarded-and-recreated adapter (class header),
            // and runs the refire loop (class header) — attempts after
            // the first each reset again before firing.
            val followInterruption = lastRequestInterrupted
            if (followInterruption) {
                resetWalletAdapter()
                lastRequestInterrupted = false
                // v1.0.9: the reconciler must not resolve this
                // request (see loopGeneration).
                loopGeneration = gen
            }
            val maxAttempts = if (followInterruption) INTERRUPTED_CONNECT_ATTEMPTS else 1
            var attempt = 0
            var answered: ConnectOutcome? = null
            while (answered == null) {
                attempt++
                if (attempt > 1) {
                    resetWalletAdapter()
                    delay(INTERRUPTED_REFIRE_PAUSE_MS)
                }
                val adapter = walletAdapter
                val attemptStartMs = System.currentTimeMillis()
                val deferred = async {
                    try {
                        ConnectOutcome.Answered(adapter.connect(sender))
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Throwable) {
                        ConnectOutcome.Threw(e)
                    }
                }
                if (!followInterruption) {
                    answered = deferred.await()
                    break
                }
                val outcome = withTimeoutOrNull(INTERRUPTED_ATTEMPT_TIMEOUT_MS) { deferred.await() }
                val elapsedMs = System.currentTimeMillis() - attemptStartMs
                // v1.0.9 classification (class header): within the
                // refire loop, a SLOW outcome — the 35 s slot timeout,
                // or any answer/throw that consumed the ~30 s
                // association budget — is the swallowed-intent
                // signature and refires (while attempts remain). A
                // FAST definitive answer (a real wallet decline or
                // error, NoWalletFound at any speed, Success) ends
                // the loop. The previous attempt has always fully
                // exited before a refire: the slot outlives the
                // association budget, so no attempt ever fires into
                // its predecessor's still-parked association.
                val slow = outcome == null || elapsedMs > INTERRUPTED_SLOW_OUTCOME_MS
                val definitive = when (outcome) {
                    null -> false
                    is ConnectOutcome.Answered -> when (outcome.result) {
                        is TransactionResult.Success,
                        is TransactionResult.NoWalletFound -> true
                        is TransactionResult.Failure -> !slow
                    }
                    is ConnectOutcome.Threw -> !slow
                }
                Log.d(
                    LOG_TAG,
                    "connect attempt $attempt/$maxAttempts outcome=" +
                        (outcome?.javaClass?.simpleName ?: "timeout") +
                        " elapsedMs=$elapsedMs slow=$slow definitive=$definitive"
                )
                when {
                    definitive -> answered = outcome
                    attempt >= maxAttempts -> {
                        deferred.cancel()
                        return@withContext failIfCurrent(gen, INTERRUPTED_MESSAGE)
                    }
                    else -> {
                        // Swallowed intent: abandon the attempt (its
                        // late result is dropped unread) and refire.
                        deferred.cancel()
                        answered = null
                    }
                }
            }
            // The loop exits only with an answer or an early return;
            // the elvis satisfies the compiler, it cannot fire.
            val finalOutcome = answered
                ?: return@withContext failIfCurrent(gen, INTERRUPTED_MESSAGE)
            when (val outcome = finalOutcome) {
                is ConnectOutcome.Threw ->
                    // Cancellation is the KFC-008 resolution path, not a
                    // wallet failure (it is rethrown inside the attempt
                    // and never lands here): anything reaching this
                    // branch is a genuine connect failure.
                    return@withContext failIfCurrent(gen, outcome.error.message ?: "Connection failed", outcome.error)
                is ConnectOutcome.Answered -> when (val result = outcome.result) {
                    is TransactionResult.Success -> {
                        val pubkeyBytes = result.authResult.accounts.firstOrNull()?.publicKey
                        if (pubkeyBytes == null) {
                            failIfCurrent(gen, "Wallet returned no accounts")
                        } else {
                            val base58 = Base58.encode(pubkeyBytes)
                            // KFC-007: capture the session pubkey into its
                            // own field BEFORE publishing the Connected
                            // state — restore must never have to read it
                            // back out of the UI state.
                            sessionPublicKeyBase58 = base58
                            _uiState.value = WalletUiState.Connected(base58)
                            Result.success(base58)
                        }
                    }
                    is TransactionResult.NoWalletFound ->
                        failIfCurrent(gen, "No MWA-compatible wallet found on this device")
                    is TransactionResult.Failure ->
                        failIfCurrent(gen, result.e.message ?: "Wallet connection failed", result.e)
                }
            }
        }

    /**
     * Ask the wallet to sign an arbitrary message (used for sign-in and for
     * the JS bridge's `signMessage`). Returns the Base58 signature.
     */
    suspend fun signMessage(sender: ActivityResultSender, message: String): Result<String> =
        runWalletRequest(
            RequestKind.SIGN,
            onInterrupted = {
                restoreConnectedState()
                Result.failure(IllegalStateException(INTERRUPTED_MESSAGE))
            }
        ) { performSignMessage(sender, message) }

    private suspend fun performSignMessage(
        sender: ActivityResultSender,
        message: String
    ): Result<String> = withContext(Dispatchers.IO) {
        _uiState.value = WalletUiState.Working
        // v1.0.9: capture the adapter at entry — an interruption
        // resolution may discard+recreate the shared instance while
        // this request is in flight; the request keeps its own.
        val adapter = walletAdapter
        val result = runCatching {
            adapter.transact(sender) { authResult ->
                val account = authResult.accounts.first().publicKey
                signMessagesDetached(
                    arrayOf(message.toByteArray()),
                    arrayOf(account)
                )
            }
        }.getOrElse { e ->
            // Cancellation: see performConnect — runWalletRequest resolves.
            if (e is CancellationException) throw e
            restoreConnectedState()
            return@withContext Result.failure(e)
        }
        when (result) {
            is TransactionResult.Success -> {
                val sig = result.successPayload?.messages
                    ?.firstOrNull()?.signatures?.firstOrNull()
                restoreConnectedState()
                if (sig != null) Result.success(Base58.encode(sig))
                else Result.failure(IllegalStateException("Wallet returned an empty signature"))
            }
            is TransactionResult.NoWalletFound -> {
                restoreConnectedState()
                Result.failure(IllegalStateException("No MWA-compatible wallet found on this device"))
            }
            is TransactionResult.Failure -> {
                restoreConnectedState()
                Result.failure(result.e)
            }
        }
    }

    /**
     * Ask the wallet to sign and send already-built transactions, per the
     * MWA 2.0 spec (`signAndSendTransactions`; `signTransactions` is
     * deprecated). Callers supply serialized transactions; this returns the
     * Base58 signature of each, in order.
     */
    suspend fun signAndSendTransactions(
        sender: ActivityResultSender,
        serializedTransactions: List<ByteArray>
    ): Result<List<String>> =
        runWalletRequest(
            RequestKind.SIGN,
            onInterrupted = {
                restoreConnectedState()
                Result.failure(IllegalStateException(INTERRUPTED_MESSAGE))
            }
        ) { performSignAndSend(sender, serializedTransactions) }

    private suspend fun performSignAndSend(
        sender: ActivityResultSender,
        serializedTransactions: List<ByteArray>
    ): Result<List<String>> = withContext(Dispatchers.IO) {
        _uiState.value = WalletUiState.Working
        // v1.0.9: capture the adapter at entry, as in performSignMessage.
        val adapter = walletAdapter
        val result = runCatching {
            adapter.transact(sender) {
                signAndSendTransactions(serializedTransactions.toTypedArray())
            }
        }.getOrElse { e ->
            // Cancellation: see performConnect — runWalletRequest resolves.
            if (e is CancellationException) throw e
            restoreConnectedState()
            return@withContext Result.failure(e)
        }
        when (result) {
            is TransactionResult.Success -> {
                val sigs = result.successPayload?.signatures
                restoreConnectedState()
                if (sigs != null) Result.success(sigs.map { Base58.encode(it) })
                else Result.failure(IllegalStateException("Wallet returned no signatures"))
            }
            is TransactionResult.NoWalletFound -> {
                restoreConnectedState()
                Result.failure(IllegalStateException("No MWA-compatible wallet found on this device"))
            }
            is TransactionResult.Failure -> {
                restoreConnectedState()
                Result.failure(result.e)
            }
        }
    }

    /** Revoke the session; the next connect shows the approval dialog again. */
    suspend fun disconnect(sender: ActivityResultSender) {
        val adapter = walletAdapter
        runCatching { adapter.disconnect(sender) }
        // KFC-007: session teardown clears the stored session field too,
        // so a later restore can never resurrect a revoked session.
        sessionPublicKeyBase58 = null
        _uiState.value = WalletUiState.Disconnected
    }

    /**
     * KFC-008: cancel the in-flight wallet request, if any. The request's
     * own [runWalletRequest] wrapper observes the cancellation and
     * resolves the UI state from session truth (Connected if a session
     * exists, otherwise an interrupted Error with a retry affordance).
     * Cancelling when nothing is pending — or after the request already
     * completed — is a no-op.
     */
    fun cancelPendingRequest() {
        pendingRequest?.cancel()
    }

    /**
     * KFC-008 foreground reconciliation — called from MainActivity's
     * onResume. Reasoning: switching to the wallet during an approval
     * backgrounds this app; when the app comes back to the foreground, a
     * request that is STILL pending means the wallet interaction ended
     * without delivering a result — a delivered result completes the
     * transact through the activity-result path, in practice within
     * moments of foregrounding. So: give that normal completion path a
     * short grace window, and only if the same request is still pending
     * after it, cancel it as abandoned. A user who approved at the sheet
     * and returned normally is therefore never disturbed (their request
     * completes inside the grace window, and cancelling a completed job
     * is a no-op), while a user whose wallet dropped the request is
     * resolved to session truth instead of an eternal spinner. No
     * request is ever pending at first launch, so the launch-time
     * onResume is a no-op by construction.
     */
    /**
     * v1.0.9: the generation that was pending when the app was
     * backgrounded (snapshot by [onAppBackgrounded], called from
     * MainActivity.onStop). The foreground reconciler may resolve
     * ONLY this generation: it is the one the wallet may have
     * abandoned while the app was away. A request started in the
     * foreground after the return — the user's retry — is never a
     * candidate, however long it legitimately runs.
     */
    @Volatile
    private var backgroundedGeneration: Int = 0

    /** Snapshot the pending generation at backgrounding time. */
    fun onAppBackgrounded() {
        backgroundedGeneration = if (pendingRequest != null) pendingGeneration else 0
    }

    /**
     * v1.0.9: the generation currently running the post-interruption
     * refire loop (set by performConnect, cleared by runWalletRequest
     * when that generation finishes). The reconciler NEVER resolves
     * it: the loop's attempts background the app on every sheet by
     * design and legitimately run for tens of seconds after each
     * return, so the +5 s grace cannot distinguish them from an
     * abandonment — and it does not need to: the loop's own bounds
     * (3 x 35 s, inside the 120 s backstop) resolve it truthfully.
     */
    @Volatile
    private var loopGeneration: Int = 0

    fun onReturnedToForeground() {
        val job = pendingRequest ?: return
        val gen = pendingGeneration
        val kind = pendingKind ?: return
        if (!job.isActive) return
        // v1.0.9: the refire loop's generation is exempt (see
        // loopGeneration) — its bounds resolve it, not the grace.
        if (gen == loopGeneration) return
        // v1.0.9: only the generation that was pending when the app
        // backgrounded can have been abandoned by the wallet. Any
        // other pending request started in the foreground and is
        // running with the user watching — leave it alone.
        if (gen != backgroundedGeneration) return
        backgroundedGeneration = 0
        requestScope.launch {
            delay(FOREGROUND_RECONCILE_GRACE_MS)
            // Identity check: act only on the very request that was
            // pending at foreground time, and only if it never resolved.
            if (pendingRequest !== job || pendingGeneration != gen || !job.isActive) return@launch
            // v1.0.8: resolve the UI state DIRECTLY from session truth.
            // Cancelling the request alone does not resolve anything in
            // a user-acceptable window — the wrapper's resolution sits
            // behind an await on a non-cooperative clientlib call (see
            // the class header). Claiming the generation first makes
            // this the single writer of the post-abandonment state: the
            // wrapper's late onInterrupted and the zombie request's
            // late failure writes are generation-suppressed.
            if (claimResolution(gen)) {
                when (kind) {
                    RequestKind.CONNECT ->
                        _uiState.value = WalletUiState.Error(INTERRUPTED_MESSAGE)
                    RequestKind.SIGN ->
                        restoreConnectedState()
                }
                // v1.0.9: the resolution that writes the state also
                // discards the adapter, so the zombie association the
                // cancelled request left behind dies here — seconds
                // before the user can even tap the retry (class
                // header). v1.0.10: SIGN resolutions are the exception
                // — discarding the adapter strands the follow-up sign
                // on a fresh association the wallet swallows while it
                // still holds the zombie sign session (REPORT_V109
                // §VR-12(c)); a SIGN resolution keeps the established
                // session's adapter exactly as it is.
                lastRequestInterrupted = true
                if (kind != RequestKind.SIGN) resetWalletAdapter()
                // v1.0.11: this claim leaves a zombie sheet in the
                // wallet — record its marker so the next SIGN
                // transact waits for the zombie to clear instead of
                // firing its association intent into the swallow
                // (class header). Idempotent with the wrapper tail's
                // own marking below.
                markZombieOutstanding(gen)
                // v1.0.9 claim settlement: wake the awaiting caller
                // NOW (class header). The wrapper races its request
                // against this signal; woken, it finds the claim taken
                // and returns the unwritten failure result exactly
                // once. The generation recheck confines the completion
                // to this request's own signal.
                if (pendingGeneration == gen) pendingClaimSignal?.complete(Unit)
            }
            job.cancel()
            if (pendingGeneration == gen) {
                pendingRequest = null
                pendingKind = null
            }
        }
    }

    /**
     * Runs one wallet request under the KFC-008 protections: the request
     * executes as a tracked job on [requestScope] (so [cancelPendingRequest]
     * can reach it from any caller), awaited under a bounded timeout
     * backstop. Three ways out:
     * - the request completes → its Result is returned unchanged;
     * - the request is cancelled (foreground reconciliation) or the
     *   timeout fires → [onInterrupted] resolves state and result from
     *   session truth (sign paths restore Connected from the stored
     *   session field; connect lands on the interrupted Error);
     * - our own CALLER is cancelled (e.g. the calling screen's scope went
     *   away) → the request is stopped, the state is still resolved via
     *   [onInterrupted] so the UI is never stranded in Working, and the
     *   cancellation propagates.
     */
    private suspend fun <T> runWalletRequest(
        kind: RequestKind,
        onInterrupted: () -> Result<T>,
        block: suspend (gen: Int) -> Result<T>
    ): Result<T> {
        val gen = generationCounter.incrementAndGet()
        val deferred: Deferred<Result<T>> = requestScope.async {
            try {
                // v1.0.11 zombie-clear gate (class header): a SIGN
                // request awaits any outstanding zombie's clearance
                // BEFORE its transact starts — inside the wrapper, so
                // the wait sits inside the 120 s backstop below, and
                // exactly one transact is ever issued per request,
                // after the wait. Connect requests are never gated
                // (their refire loop is their own cure).
                if (kind == RequestKind.SIGN) awaitZombieClearGate()
                block(gen)
            } finally {
                // v1.0.11 zombie-clear hook: this finally is the
                // generation-suppressed tail of THIS generation — it
                // runs after block's own post-transact processing
                // (failIfCurrent for connect, the restore paths for
                // sign, or a throw) at the moment the parked clientlib
                // call actually returns. That suspension is
                // non-cooperative (REPORT_V107), so for a claim-
                // settled generation this moment IS the late
                // resolution's arrival: the zombie's result has been
                // delivered / its session has closed in the wallet.
                // Any outcome clears. For a generation that was never
                // claim-settled the marker is absent (or names another
                // generation) and this is a no-op.
                if (resolvedGeneration == gen) lateResolvedGeneration = gen
                clearZombieMarker(gen, ZombieClearReason.LATE_RESULT)
            }
        }
        pendingRequest = deferred
        pendingKind = kind
        pendingGeneration = gen
        // v1.0.9 claim settlement: race the request await against this
        // generation's claim signal, so a reconciler claim settles the
        // awaiting caller at claim time (class header). The signal
        // carries no result — it only wakes the wrapper into the
        // generation-guarded resolution below.
        val claimSignal = CompletableDeferred<Unit>()
        pendingClaimSignal = claimSignal
        val result: Result<T>? = try {
            withTimeoutOrNull(WALLET_REQUEST_TIMEOUT_MS) {
                select<Result<T>?> {
                    deferred.onAwait { it }
                    claimSignal.onAwait { null }
                }
            }
        } catch (e: CancellationException) {
            if (deferred.isCancelled) {
                // cancelPendingRequest() cancelled the request underneath
                // this await — fall through to the interrupted resolution.
                null
            } else {
                deferred.cancel()
                if (claimResolution(gen)) {
                    // v1.0.11: an interrupted resolution leaves a
                    // zombie sheet in the wallet, this path included.
                    markZombieOutstanding(gen)
                    onInterrupted()
                }
                throw e
            }
        } finally {
            if (pendingRequest === deferred) {
                pendingRequest = null
                pendingKind = null
            }
            if (pendingClaimSignal === claimSignal) pendingClaimSignal = null
            if (loopGeneration == gen) loopGeneration = 0
        }
        if (result != null) return result
        // Interrupted: the timeout backstop fired (withTimeoutOrNull
        // returned null), reconciliation cancelled the request, or the
        // reconciler claimed the generation and fired the claim signal.
        // Make sure the in-flight request is really stopped, then
        // resolve — unless the foreground reconciler already claimed
        // this generation's resolution and wrote the state itself
        // (v1.0.8): then only the (failure) result is returned,
        // unwritten.
        deferred.cancel()
        // v1.0.11: record the zombie this interruption leaves in the
        // wallet (class header). When the reconciler claimed first,
        // its site already recorded the same generation's marker and
        // this call is an idempotent no-op; when this tail is the
        // resolution (timeout backstop / cancelPendingRequest), this
        // is the recording site.
        markZombieOutstanding(gen)
        // v1.0.9: an interrupted request (timeout backstop, or a
        // reconciliation whose claim the reconciler already took)
        // leaves a fresh adapter behind (class header). v1.0.10:
        // SIGN-kind interruptions are the exception, exactly as at
        // the reconciler's resolution site above — the established
        // session and its adapter are preserved so the follow-up sign
        // reuses the session (REPORT_V109 §VR-12(c)).
        lastRequestInterrupted = true
        if (kind != RequestKind.SIGN) resetWalletAdapter()
        return if (claimResolution(gen)) onInterrupted()
        else Result.failure(IllegalStateException(INTERRUPTED_MESSAGE))
    }

    private fun fail(message: String, cause: Throwable? = null): Result<String> {
        _uiState.value = WalletUiState.Error(message)
        return Result.failure(cause ?: IllegalStateException(message))
    }

    /**
     * v1.0.8: [fail], generation-guarded — a connect request whose
     * generation has been resolved (foreground reconciliation) or
     * superseded by a newer request returns its failure WITHOUT
     * writing the Error state over the state that replaced it.
     */
    private fun failIfCurrent(gen: Int, message: String, cause: Throwable? = null): Result<String> {
        return if (resolvedGeneration == gen || pendingGeneration != gen) {
            Result.failure(cause ?: IllegalStateException(message))
        } else {
            fail(message, cause)
        }
    }

    private fun restoreConnectedState() {
        // KFC-007: restore from the stored session field captured at
        // connect time — NOT from publicKeyBase58, which derives from
        // the live UI state. The transact paths set that state to
        // Working before transacting, so the getter was necessarily null
        // here and every sign landed on Disconnected.
        val pk = sessionPublicKeyBase58
        _uiState.value = if (pk != null) WalletUiState.Connected(pk) else WalletUiState.Disconnected
    }

    companion object {
        /**
         * KFC-008 backstop: no wallet request may hang longer than this.
         * Generous on purpose — the foreground reconciliation is the
         * primary cure; this only bounds the never-returned case (e.g.
         * the wallet process died without answering).
         */
        private const val WALLET_REQUEST_TIMEOUT_MS = 120_000L

        /**
         * KFC-008: after the app returns to the foreground, a pending
         * wallet request gets this long to complete through the normal
         * activity-result path before it is treated as abandoned.
         */
        private const val FOREGROUND_RECONCILE_GRACE_MS = 5_000L

        private const val INTERRUPTED_MESSAGE =
            "Wallet request was interrupted - the wallet did not respond. Please try again."

        /**
         * v1.0.9 (HAUNT v0.1.18/v0.1.19): attempts for a connect that
         * follows an interruption (see the class header's refire-loop
         * note). Healthy MWA associations establish in ~2 s; the 35 s
         * attempt slot outlives clientlib's ~30 s association budget,
         * so an attempt usually completes naturally inside it, and an
         * outcome that consumed >25 s (or hit the slot timeout) is the
         * swallowed-intent signature and refires. 3 attempts x 35 s +
         * pauses stays inside the 120 s request backstop.
         */
        private const val INTERRUPTED_CONNECT_ATTEMPTS = 3
        private const val INTERRUPTED_ATTEMPT_TIMEOUT_MS = 35_000L
        private const val INTERRUPTED_SLOW_OUTCOME_MS = 25_000L
        private const val INTERRUPTED_REFIRE_PAUSE_MS = 500L

        /**
         * v1.0.11 zombie-clear gate bounds (class header). The gate
         * wait is the association budget — the same ~35 s a swallowed
         * connect attempt consumes (see INTERRUPTED_ATTEMPT_TIMEOUT_MS)
         * — so a wallet that frees on zombie-result delivery (seconds,
         * in the observed choreography) wakes the gate almost at once,
         * while a zombie that never clears costs one slot and the sign
         * then proceeds exactly as pre-v1.0.11. The wait runs inside
         * the wrapper, so 35 s sits comfortably inside the 120 s
         * backstop and still leaves the transact its full budget in
         * practice. The marker's own expiry is the same bound,
         * measured from the interruption: a marker can never outlive
         * one association budget, gated on or not.
         */
        private const val ZOMBIE_GATE_WAIT_MS = 35_000L
        private const val ZOMBIE_MARKER_EXPIRY_MS = 35_000L
        private const val LOG_TAG = "VoidrunnerWallet"
    }
}
