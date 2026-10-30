package com.voidrunner.app.wallet

import android.net.Uri
import com.solana.mobilewalletadapter.clientlib.ActivityResultSender
import com.solana.mobilewalletadapter.clientlib.ConnectionIdentity
import com.solana.mobilewalletadapter.clientlib.MobileWalletAdapter
import com.solana.mobilewalletadapter.clientlib.TransactionResult
import com.solana.mobilewalletadapter.clientlib.successPayload
import com.voidrunner.app.util.Base58
import kotlinx.coroutines.CancellationException
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
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

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
 */
class WalletManager {

    private val walletAdapter = MobileWalletAdapter(
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
        runWalletRequest(onInterrupted = { fail(INTERRUPTED_MESSAGE) }) {
            performConnect(sender)
        }

    private suspend fun performConnect(sender: ActivityResultSender): Result<String> =
        withContext(Dispatchers.IO) {
            _uiState.value = WalletUiState.Working
            val result = runCatching { walletAdapter.connect(sender) }.getOrElse { e ->
                // Cancellation is the KFC-008 resolution path, not a
                // wallet failure: rethrow so this request completes as
                // cancelled and runWalletRequest resolves the UI state.
                if (e is CancellationException) throw e
                return@withContext fail(e.message ?: "Connection failed", e)
            }
            when (result) {
                is TransactionResult.Success -> {
                    val pubkeyBytes = result.authResult.accounts.firstOrNull()?.publicKey
                    if (pubkeyBytes == null) {
                        fail("Wallet returned no accounts")
                    } else {
                        val base58 = Base58.encode(pubkeyBytes)
                        // KFC-007: capture the session pubkey into its own
                        // field BEFORE publishing the Connected state —
                        // restore must never have to read it back out of
                        // the UI state.
                        sessionPublicKeyBase58 = base58
                        _uiState.value = WalletUiState.Connected(base58)
                        Result.success(base58)
                    }
                }
                is TransactionResult.NoWalletFound ->
                    fail("No MWA-compatible wallet found on this device")
                is TransactionResult.Failure ->
                    fail(result.e.message ?: "Wallet connection failed", result.e)
            }
        }

    /**
     * Ask the wallet to sign an arbitrary message (used for sign-in and for
     * the JS bridge's `signMessage`). Returns the Base58 signature.
     */
    suspend fun signMessage(sender: ActivityResultSender, message: String): Result<String> =
        runWalletRequest(
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
        val result = runCatching {
            walletAdapter.transact(sender) { authResult ->
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
        val result = runCatching {
            walletAdapter.transact(sender) {
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
        runCatching { walletAdapter.disconnect(sender) }
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
    fun onReturnedToForeground() {
        val job = pendingRequest ?: return
        if (!job.isActive) return
        requestScope.launch {
            delay(FOREGROUND_RECONCILE_GRACE_MS)
            // Identity check: cancel only the very request that was
            // pending at foreground time, and only if it never resolved.
            if (pendingRequest === job && job.isActive) {
                job.cancel()
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
        onInterrupted: () -> Result<T>,
        block: suspend () -> Result<T>
    ): Result<T> {
        val deferred: Deferred<Result<T>> = requestScope.async { block() }
        pendingRequest = deferred
        val result: Result<T>? = try {
            withTimeoutOrNull(WALLET_REQUEST_TIMEOUT_MS) { deferred.await() }
        } catch (e: CancellationException) {
            if (deferred.isCancelled) {
                // cancelPendingRequest() cancelled the request underneath
                // this await — fall through to the interrupted resolution.
                null
            } else {
                deferred.cancel()
                onInterrupted()
                throw e
            }
        } finally {
            if (pendingRequest === deferred) pendingRequest = null
        }
        if (result != null) return result
        // Interrupted: the timeout backstop fired (withTimeoutOrNull
        // returned null) or reconciliation cancelled the request. Make
        // sure the in-flight request is really stopped, then resolve.
        // (The request body performs no state writes on its cancellation
        // path — it rethrows CancellationException — so this resolution
        // is the single writer of the post-interruption state.)
        deferred.cancel()
        return onInterrupted()
    }

    private fun fail(message: String, cause: Throwable? = null): Result<String> {
        _uiState.value = WalletUiState.Error(message)
        return Result.failure(cause ?: IllegalStateException(message))
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
    }
}
