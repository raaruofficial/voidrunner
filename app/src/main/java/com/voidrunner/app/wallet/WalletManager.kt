package com.voidrunner.app.wallet

import android.net.Uri
import com.solana.mobilewalletadapter.clientlib.ActivityResultSender
import com.solana.mobilewalletadapter.clientlib.ConnectionIdentity
import com.solana.mobilewalletadapter.clientlib.MobileWalletAdapter
import com.solana.mobilewalletadapter.clientlib.TransactionResult
import com.voidrunner.app.util.Base58
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext

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
 */
class WalletManager {

    private val walletAdapter = MobileWalletAdapter(
        connectionIdentity = ConnectionIdentity(
            identityUri = Uri.parse("https://voidrunner.app"),
            iconUri = Uri.parse("favicon.ico"), // resolves against identityUri
            identityName = "VOIDRUNNER"
        )
    )

    private val _uiState = MutableStateFlow<WalletUiState>(WalletUiState.Disconnected)
    val uiState: StateFlow<WalletUiState> = _uiState.asStateFlow()

    val publicKeyBase58: String?
        get() = (_uiState.value as? WalletUiState.Connected)?.publicKeyBase58

    val isConnected: Boolean
        get() = _uiState.value is WalletUiState.Connected

    /** Get/set the MWA auth token so it can be persisted across restarts. */
    var persistedAuthToken: String?
        get() = walletAdapter.authToken
        set(value) {
            walletAdapter.authToken = value
        }

    /**
     * Connect to a wallet. Launches the MWA association intent via [sender]
     * (pass `ActivityResultSender(activity)` from the calling Activity).
     * Returns the wallet's Base58 public key on success.
     */
    suspend fun connect(sender: ActivityResultSender): Result<String> =
        withContext(Dispatchers.IO) {
            _uiState.value = WalletUiState.Working
            val result = runCatching { walletAdapter.connect(sender) }.getOrElse { e ->
                return@withContext fail(e.message ?: "Connection failed", e)
            }
            when (result) {
                is TransactionResult.Success -> {
                    val pubkeyBytes = result.authResult.accounts.firstOrNull()?.publicKey
                    if (pubkeyBytes == null) {
                        fail("Wallet returned no accounts")
                    } else {
                        val base58 = Base58.encode(pubkeyBytes)
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
        withContext(Dispatchers.IO) {
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
     * Sign Solana transactions. STUB for step 1: the transaction-building code
     * (web3-style builders) lands with the game wiring in step 2. The MWA call
     * itself is `signAndSendTransactions` per the 2.0 spec (`signTransactions`
     * is deprecated).
     */
    suspend fun signAndSendTransactions(
        sender: ActivityResultSender,
        serializedTransactions: List<ByteArray>
    ): Result<List<String>> {
        // TODO(step 2): build real transactions, then:
        //   walletAdapter.transact(sender) { signAndSendTransactions(serializedTransactions.toTypedArray()) }
        //   -> result.successPayload?.signatures -> Base58.encode each
        return Result.failure(UnsupportedOperationException("signAndSendTransactions lands in step 2 (game wiring)"))
    }

    /** Revoke the session; the next connect shows the approval dialog again. */
    suspend fun disconnect(sender: ActivityResultSender) {
        runCatching { walletAdapter.disconnect(sender) }
        _uiState.value = WalletUiState.Disconnected
    }

    private fun fail(message: String, cause: Throwable? = null): Result<String> {
        _uiState.value = WalletUiState.Error(message)
        return Result.failure(cause ?: IllegalStateException(message))
    }

    private fun restoreConnectedState() {
        val pk = publicKeyBase58
        _uiState.value = if (pk != null) WalletUiState.Connected(pk) else WalletUiState.Disconnected
    }
}
