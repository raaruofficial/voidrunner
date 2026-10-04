package com.voidrunner.app.ui

import android.annotation.SuppressLint
import android.app.Activity
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.navigation.NavController
import com.voidrunner.app.VoidrunnerApp
import com.voidrunner.app.game.GameConfig
import com.voidrunner.app.wallet.VoidrunnerWalletBridge

/**
 * The game screen. The *game* renders in a WebView, but everything around it
 * is native: navigation, wallet, menus, and lifecycle are all Android.
 *
 * The [VoidrunnerWalletBridge] (JS name `window.VoidrunnerWallet`) is the seam
 * where the native Mobile Wallet Adapter session meets the game — connect,
 * sign, and identity flow through it. The game side wires into the bridge
 * in step 2.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun GameScreen(navController: NavController, onExit: () -> Unit) {
    val context = LocalContext.current
    val activity = context as Activity
    val walletManager = remember { (context.applicationContext as VoidrunnerApp).walletManager }
    val webView = remember { mutableStateOf<WebView?>(null) }

    // Back: step back through game history first, exit the screen at the root.
    BackHandler {
        val wv = webView.value
        if (wv != null && wv.canGoBack()) wv.goBack() else onExit()
    }

    // Pause/resume/destroy the WebView with the Activity lifecycle so the game
    // loop never runs away in the background.
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_PAUSE -> webView.value?.onPause()
                Lifecycle.Event.ON_RESUME -> webView.value?.onResume()
                Lifecycle.Event.ON_DESTROY -> webView.value?.destroy()
                else -> {}
            }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }

    AndroidView(
        modifier = Modifier.fillMaxSize(),
        factory = { ctx ->
            WebView(ctx).apply {
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.mediaPlaybackRequiresUserGesture = false
                settings.loadWithOverviewMode = true
                settings.useWideViewPort = true
                // No browser chrome: the game handles its own navigation internally.
                webViewClient = WebViewClient()
                val bridge = VoidrunnerWalletBridge(
                    activity = activity,
                    walletManager = walletManager,
                    evaluateJs = { js -> post { evaluateJavascript(js, null) } }
                )
                addJavascriptInterface(bridge, GameConfig.BRIDGE_NAME)
                loadUrl(GameConfig.GAME_URL)
                webView.value = this
            }
        }
    )
}
