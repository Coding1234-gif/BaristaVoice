import 'package:flutter/material.dart';

/// Deliberately distinct from the kiosk's warm coffee theme (buildAppTheme
/// in theme.dart) — a neutral, dense, "modern SaaS" look so the admin
/// dashboard reads as its own product surface, not a hidden extension of
/// the customer app.
const adminSeedColor = Color(0xFF4F46E5); // indigo
const adminBackground = Color(0xFFF6F6FB);
const adminBorder = Color(0x14000000);
const adminSuccess = Color(0xFF16A34A);
const adminWarning = Color(0xFFD97706);
const adminDanger = Color(0xFFDC2626);

ThemeData buildAdminTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: adminSeedColor,
    brightness: Brightness.light,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: adminBackground,
    fontFamily: 'Roboto',
    cardTheme: CardThemeData(
      elevation: 0,
      color: Colors.white,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: adminBorder),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.white,
      foregroundColor: Colors.black87,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      surfaceTintColor: Colors.transparent,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        side: const BorderSide(color: adminBorder),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFFF2F2F7),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
      ),
    ),
    dividerTheme: const DividerThemeData(color: adminBorder, space: 1),
    chipTheme: ChipThemeData(
      backgroundColor: colorScheme.surfaceContainerHighest,
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    ),
  );
}

/// Wraps admin screens in [buildAdminTheme] regardless of the app-wide
/// theme, so the dashboard looks consistent even though it's mounted inside
/// the same MaterialApp as the kiosk.
class AdminThemeScope extends StatelessWidget {
  final Widget child;
  const AdminThemeScope({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Theme(data: buildAdminTheme(), child: child);
  }
}
