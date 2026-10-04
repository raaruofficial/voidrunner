package com.voidrunner.app.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay

/** Splash: brand moment, then hands off to home. No web content here. */
@Composable
fun SplashScreen(onDone: () -> Unit) {
    LaunchedEffect(Unit) {
        delay(1200)
        onDone()
    }
    Column(
        modifier = Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text(
            text = "VOIDRUNNER",
            fontSize = 44.sp,
            fontWeight = FontWeight.Black,
            color = MaterialTheme.colorScheme.primary,
            letterSpacing = 6.sp
        )
        Spacer(Modifier.height(12.dp))
        Text(
            text = "INSERT COIN · 25¢ / PLAY",
            fontSize = 14.sp,
            letterSpacing = 3.sp,
            color = MaterialTheme.colorScheme.secondary
        )
    }
}
