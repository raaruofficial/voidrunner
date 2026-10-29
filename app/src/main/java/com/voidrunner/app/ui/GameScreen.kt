package com.voidrunner.app.ui

import android.annotation.SuppressLint
import android.view.View
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.navigation.NavController
import com.voidrunner.app.VoidrunnerApp
import com.voidrunner.app.game.GameConfig
import com.voidrunner.app.wallet.VoidrunnerWalletBridge
import com.solana.mobilewalletadapter.clientlib.ActivityResultSender

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
fun GameScreen(navController: NavController, sender: ActivityResultSender, onExit: () -> Unit) {
    val context = LocalContext.current
    val walletManager = remember { (context.applicationContext as VoidrunnerApp).walletManager }
    val webView = remember { mutableStateOf<WebView?>(null) }
    // v1.0.5 cure (KFC-003, runtime-confirmed 2026-10-29 — HAUNT N3 pattern):
    // a device with a disabled/missing WebView provider makes the WebView
    // constructor throw MissingWebViewPackageException. The factory below
    // catches it and this state swaps in a native fallback instead of
    // killing the process on PLAY.
    var webViewFailed by remember { mutableStateOf(false) }

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

    if (webViewFailed) {
        // KFC-003 fallback: stable native surface, never a crash.
        Column(
            modifier = Modifier.fillMaxSize().padding(32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            Text(
                text = "VOIDRUNNER needs Android WebView",
                fontSize = 20.sp,
                fontWeight = FontWeight.Black,
                color = MaterialTheme.colorScheme.primary,
                textAlign = TextAlign.Center
            )
            Spacer(Modifier.height(12.dp))
            Text(
                text = "The WebView component is unavailable or disabled on this device, so the game can't open. Enable or update Android System WebView, then try again.",
                fontSize = 14.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center
            )
            Spacer(Modifier.height(24.dp))
            Button(onClick = onExit) {
                Text(text = "Back", fontWeight = FontWeight.Bold)
            }
        }
    } else {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                try {
                    WebView(ctx).apply {
                        settings.javaScriptEnabled = true
                        settings.domStorageEnabled = true
                        settings.mediaPlaybackRequiresUserGesture = false
                        settings.loadWithOverviewMode = true
                        settings.useWideViewPort = true
                        // No browser chrome: the game handles its own navigation internally.
                        webViewClient = WebViewClient()
                        val bridge = VoidrunnerWalletBridge(
                            walletManager = walletManager,
                            sender = sender,
                            evaluateJs = { js -> post { evaluateJavascript(js, null) } }
                        )
                        addJavascriptInterface(bridge, GameConfig.BRIDGE_NAME)
                        loadUrl(GameConfig.GAME_URL)
                        webView.value = this
                    }
                } catch (e: Exception) {
                    // KFC-003: construction threw (missing/disabled WebView
                    // provider) — swap in the native fallback above.
                    webViewFailed = true
                    View(ctx)
                }
            }
        )
    }
}
