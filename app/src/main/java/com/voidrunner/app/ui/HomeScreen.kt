package com.voidrunner.app.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavController
import com.voidrunner.app.BuildConfig
import com.voidrunner.app.VoidrunnerApp
import com.voidrunner.app.wallet.WalletUiState

/** Native main menu. The arcade cabinet front panel. */
@Composable
fun HomeScreen(navController: NavController) {
    val app = LocalContext.current.applicationContext as VoidrunnerApp
    val walletState by app.walletManager.uiState.collectAsState()

    Column(
        modifier = Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text(
            text = "VOIDRUNNER",
            fontSize = 40.sp,
            fontWeight = FontWeight.Black,
            color = MaterialTheme.colorScheme.primary,
            letterSpacing = 5.sp
        )
        Spacer(Modifier.height(6.dp))
        Text(
            text = "pay-per-play bullet hell · 25¢ / play",
            fontSize = 13.sp,
            letterSpacing = 2.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(Modifier.height(40.dp))

        MenuButton("▶  PLAY", onClick = { navController.navigate("game") })

        Spacer(Modifier.height(12.dp))
        val walletLabel = when (val s = walletState) {
            is WalletUiState.Connected ->
                "WALLET · ${s.publicKeyBase58.take(4)}…${s.publicKeyBase58.takeLast(4)}"
            WalletUiState.Working -> "WALLET · …"
            else -> "WALLET"
        }
        MenuButton(walletLabel, onClick = { navController.navigate("wallet") }, outlined = true)

        Spacer(Modifier.height(12.dp))
        MenuButton("SETTINGS", onClick = { navController.navigate("settings") }, outlined = true)

        Spacer(Modifier.height(40.dp))
        Text(
            text = "v${BuildConfig.VERSION_NAME}",
            fontSize = 11.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
private fun MenuButton(text: String, onClick: () -> Unit, outlined: Boolean = false) {
    if (outlined) {
        OutlinedButton(
            onClick = onClick,
            modifier = Modifier.fillMaxWidth(0.8f).height(56.dp)
        ) { Text(text, letterSpacing = 2.sp) }
    } else {
        Button(
            onClick = onClick,
            modifier = Modifier.fillMaxWidth(0.8f).height(56.dp),
            colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary)
        ) { Text(text, letterSpacing = 2.sp, fontWeight = FontWeight.Bold) }
    }
}
