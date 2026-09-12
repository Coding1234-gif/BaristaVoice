import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _prefsKey = 'dark_mode_enabled';

/// A plain on/off toggle (not a 3-way system/light/dark picker — matches
/// what was actually asked for), persisted across restarts the same way
/// CurrentCafeController persists the selected café: loaded in main.dart
/// before runApp, so there's no flash of the wrong theme on launch.
class ThemeModeController extends StateNotifier<ThemeMode> {
  ThemeModeController(super.state);

  Future<void> setDarkMode(bool enabled) async {
    state = enabled ? ThemeMode.dark : ThemeMode.light;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, enabled);
  }
}

final themeModeProvider = StateNotifierProvider<ThemeModeController, ThemeMode>((ref) {
  throw UnimplementedError('overridden in main() once SharedPreferences has loaded');
});
