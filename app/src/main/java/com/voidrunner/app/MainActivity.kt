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

/**
 * Single-activity app. All navigation is native Compose Navigation —
 * the WebView is confined to the game screen and never drives app flow.
 */
class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
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
                                onExit = { navController.popBackStack() }
                            )
                        }
                        composable("wallet") { WalletScreen(navController) }
                        composable("settings") { SettingsScreen(navController) }
                    }
                }
            }
        }
    }
}
