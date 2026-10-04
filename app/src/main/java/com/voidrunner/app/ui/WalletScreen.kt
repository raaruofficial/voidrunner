package com.voidrunner.app.ui

import android.app.Activity
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavController
import com.solana.mobilewalletadapter.clientlib.ActivityResultSender
import com.voidrunner.app.VoidrunnerApp
import com.voidrunner.app.wallet.WalletUiState
import kotlinx.coroutines.launch

/**
 * Native wallet screen: connect / disconnect / sign, all through
 * Mobile Wallet Adapter against the Seeker's Seed Vault wallet.
 * No web content — this is what makes the app an app, not a wrapper.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WalletScreen(navController: NavController) {
    val context = LocalContext.current
    val activity = context as Activity
    val walletManager = (context.applicationContext as VoidrunnerApp).walletManager
    val state by walletManager.uiState.collectAsState()
    val scope = rememberCoroutineScope()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("WALLET", letterSpacing = 3.sp) },
                navigationIcon = {
                    IconButton(onClick = { navController.popBackStack() }) {
                        Icon(Icons.Filled.ArrowBack, contentDescription = "Back")
                    }
                }
            )
        }
    ) { inner ->
        Column(
            modifier = Modifier.fillMaxSize().padding(inner).padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            when (val s = state) {
                WalletUiState.Disconnected -> {
                    Text("Not connected", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.height(16.dp))
                    Button(
                        onClick = {
                            scope.launch {
                                walletManager.connect(ActivityResultSender(activity))
                            }
                        },
                        modifier = Modifier.fillMaxWidth(0.8f).height(52.dp)
                    ) { Text("CONNECT WALLET", fontWeight = FontWeight.Bold) }
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Opens your Seeker wallet to approve the connection.",
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                WalletUiState.Working -> {
                    CircularProgressIndicator(color = MaterialTheme.colorScheme.secondary)
                    Spacer(Modifier.height(12.dp))
                    Text("Waiting for wallet…", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                is WalletUiState.Connected -> {
                    Text(
                        "CONNECTED",
                        color = MaterialTheme.colorScheme.secondary,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 3.sp
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(
                        s.publicKeyBase58,
                        fontSize = 13.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(Modifier.height(24.dp))
                    OutlinedButton(
                        onClick = {
                            scope.launch {
                                walletManager.signMessage(
                                    ActivityResultSender(activity),
                                    "VOIDRUNNER sign-in"
                                )
                            }
                        },
                        modifier = Modifier.fillMaxWidth(0.8f).height(52.dp)
                    ) { Text("SIGN TEST MESSAGE") }
                    Spacer(Modifier.height(12.dp))
                    OutlinedButton(
                        onClick = {
                            scope.launch { walletManager.disconnect(ActivityResultSender(activity)) }
                        },
                        modifier = Modifier.fillMaxWidth(0.8f).height(52.dp)
                    ) { Text("DISCONNECT") }
                }
                is WalletUiState.Error -> {
                    Text("Error", color = MaterialTheme.colorScheme.error, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.height(8.dp))
                    Text(s.message, color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp)
                    Spacer(Modifier.height(16.dp))
                    Button(
                        onClick = {
                            scope.launch {
                                walletManager.connect(ActivityResultSender(activity))
                            }
                        },
                        modifier = Modifier.fillMaxWidth(0.8f).height(52.dp)
                    ) { Text("TRY AGAIN", fontWeight = FontWeight.Bold) }
                }
            }
        }
    }
}
