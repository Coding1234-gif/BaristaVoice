import 'package:flutter/material.dart';

/// The single brand seed both themes derive from — keeps light/dark
/// visually the same "app", not two different products.
const _seedColor = Color(0xFF6F4E37);

/// Clean, high-contrast, coffee-toned theme. Kept deliberately plain —
/// trustworthy beats flashy for a payment-adjacent kiosk.
ThemeData buildAppTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: _seedColor,
    brightness: Brightness.light,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: const Color(0xFFFAF7F2),
    appBarTheme: const AppBarTheme(centerTitle: false, elevation: 0),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );
}

/// "Warm coffee dark" — the same brand seed run through Material 3's dark
/// derivation, on a warm dark-roast background (not a stark black) so it
/// still reads as BaristaVoice rather than a generic dark theme.
ThemeData buildAppDarkTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: _seedColor,
    brightness: Brightness.dark,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: const Color(0xFF1C1714),
    appBarTheme: const AppBarTheme(centerTitle: false, elevation: 0),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );
}
