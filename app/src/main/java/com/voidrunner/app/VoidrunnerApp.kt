package com.voidrunner.app

import android.app.Application
import com.voidrunner.app.wallet.WalletManager

/**
 * Application holder for app-scoped singletons.
 * The [WalletManager] lives here so the wallet session survives navigation
 * and configuration changes.
 */
class VoidrunnerApp : Application() {
    val walletManager: WalletManager by lazy { WalletManager() }
}
