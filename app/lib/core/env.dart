import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Central place secrets are read from. Values live in `.env` (gitignored,
/// see `.env.example`) and are never hardcoded in source.
class Env {
  static String get supabaseUrl => dotenv.env['SUPABASE_URL'] ?? '';
  static String get supabaseAnonKey => dotenv.env['SUPABASE_ANON_KEY'] ?? '';
  static String get revenueCatApiKeyAndroid =>
      dotenv.env['REVENUECAT_API_KEY_ANDROID'] ?? '';
  static String get revenueCatApiKeyIos => dotenv.env['REVENUECAT_API_KEY_IOS'] ?? '';

  /// Which cafe this kiosk install serves its (published) menu from. Optional
  /// — when unset the kiosk falls back to the hardcoded seed menu, so an
  /// unconfigured install behaves exactly as before this cafe existed.
  static String get cafeId => dotenv.env['CAFE_ID'] ?? '';

  static bool get isSupabaseConfigured =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  static bool get isCafeConfigured => isSupabaseConfigured && cafeId.isNotEmpty;
}
