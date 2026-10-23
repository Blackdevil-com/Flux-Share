package com.fluxshare.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable

private val MonochromeLightColorScheme = lightColorScheme(
    primary = MonoBlack,
    onPrimary = MonoWhite,
    primaryContainer = MonoGray200,
    onPrimaryContainer = MonoBlack,
    secondary = MonoGray700,
    onSecondary = MonoWhite,
    secondaryContainer = MonoGray100,
    onSecondaryContainer = MonoGray900,
    tertiary = MonoGray600,
    onTertiary = MonoWhite,
    background = MonoWhite,
    onBackground = MonoBlack,
    surface = MonoGray50,
    onSurface = MonoBlack,
    surfaceVariant = MonoGray100,
    onSurfaceVariant = MonoGray800,
    outline = MonoGray300,
    outlineVariant = MonoGray200
)

private val MonochromeDarkColorScheme = darkColorScheme(
    primary = MonoWhite,
    onPrimary = MonoBlack,
    primaryContainer = MonoGray700,
    onPrimaryContainer = MonoWhite,
    secondary = MonoGray300,
    onSecondary = MonoBlack,
    secondaryContainer = MonoGray800,
    onSecondaryContainer = MonoWhite,
    tertiary = MonoGray400,
    onTertiary = MonoBlack,
    background = MonoGray900,
    onBackground = MonoWhite,
    surface = MonoGray800,
    onSurface = MonoWhite,
    surfaceVariant = MonoGray700,
    onSurfaceVariant = MonoGray200,
    outline = MonoGray600,
    outlineVariant = MonoGray700
)

@Composable
fun FluxShareTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    val colorScheme = if (darkTheme) MonochromeDarkColorScheme else MonochromeLightColorScheme

    MaterialTheme(
        colorScheme = colorScheme,
        typography = Typography,
        content = content
    )
}
