package com.voidrunner.app.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

// VOIDRUNNER brand palette: deep navy base, hot magenta primary,
// electric cyan secondary, gold tertiary. Hostile red is reserved for danger.
private val Navy = Color(0xFF070B16)
private val NavySurface = Color(0xFF0D1424)
private val Magenta = Color(0xFFFF2D78)
private val Cyan = Color(0xFF22D3EE)
private val Gold = Color(0xFFFFC53D)
private val Danger = Color(0xFFFF453A)
private val TextPrimary = Color(0xFFE8EDF7)
private val TextMuted = Color(0xFF8B94A7)

private val VoidrunnerColors = darkColorScheme(
    primary = Magenta,
    onPrimary = Color.White,
    secondary = Cyan,
    onSecondary = Color.Black,
    tertiary = Gold,
    background = Navy,
    onBackground = TextPrimary,
    surface = NavySurface,
    onSurface = TextPrimary,
    surfaceVariant = Color(0xFF141C30),
    onSurfaceVariant = TextMuted,
    error = Danger
)

@Composable
fun VoidrunnerTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = VoidrunnerColors, content = content)
}
