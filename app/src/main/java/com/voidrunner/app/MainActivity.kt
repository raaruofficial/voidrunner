package com.voidrunner.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.voidrunner.app.ui.GameScreen
import com.voidrunner.app.ui.HomeScreen
import com.voidrunner.app.ui.SettingsScreen
import com.voidrunner.app.ui.SplashScreen
import com.voidrunner.app.ui.WalletScreen
import com.voidrunner.app.ui.theme.VoidrunnerTheme
import com.solana.mobilewalletadapter.clientlib.ActivityResultSender

/**
 * Single-activity app. All navigation is native Compose Navigation —
 * the WebView is confined to the game screen and never drives app flow.
 */
class MainActivity : ComponentActivity() {

    /**
     * The app's single MWA activity-result sender (v1.0.4 crash fix).
     * [ActivityResultSender] registers an activity-result launcher in
     * its constructor, and AndroidX permits registration only before
     * the owner lifecycle reaches STARTED — so the sender is created
     * here, in onCreate before setContent, and shared with the game
     * screen's wallet bridge and the wallet screen. The pre-fix build
     * constructed senders inline at interaction time — inside wallet
     * screen tap handlers and inside bridge methods invoked from the
     * WebView — when the activity is already RESUMED; registration
     * threw IllegalStateException and wallet interactions crashed
     * (the ActivityResultSender-at-RESUMED class that killed HAUNT
     * v0.1.7/v0.1.8 and Paper Moon v0.2.3/v0.2.4 in store review).
     */
    lateinit var activityResultSender: ActivityResultSender
        private set

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        activityResultSender = ActivityResultSender(this)
        enableEdgeToEdge()
        setContent {
            VoidrunnerTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    val navController = rememberNavController()
                    NavHost(navController = navController, startDestination = "splash") {
                        composable("splash") {
                            SplashScreen(onDone = {
                                navController.navigate("home") {
                                    popUpTo("splash") { inclusive = true }
                                }
                            })
                        }
                        composable("home") { HomeScreen(navController) }
                        composable("game") {
                            GameScreen(
                                navController = navController,
                                sender = activityResultSender,
                                onExit = { navController.popBackStack() }
                            )
                        }
                        composable("wallet") { WalletScreen(navController, activityResultSender) }
                        composable("settings") { SettingsScreen(navController) }
                    }
                }
            }
        }
    }
}
