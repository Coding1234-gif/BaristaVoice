import 'package:flutter/material.dart';

/// Clean, high-contrast, coffee-toned theme. Kept deliberately plain —
/// trustworthy beats flashy for a payment-adjacent kiosk.
ThemeData buildAppTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF6F4E37),
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
