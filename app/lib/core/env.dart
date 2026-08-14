import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Central place secrets are read from. Values live in `.env` (gitignored,
/// see `.env.example`) and are never hardcoded in source.
class Env {
  static String get supabaseUrl => dotenv.env['SUPABASE_URL'] ?? '';
  static String get supabaseAnonKey => dotenv.env['SUPABASE_ANON_KEY'] ?? '';
  static String get revenueCatApiKeyAndroid =>
      dotenv.env['REVENUECAT_API_KEY_ANDROID'] ?? '';
  static String get revenueCatApiKeyIos => dotenv.env['REVENUECAT_API_KEY_IOS'] ?? '';

  /// Default café this device opens to before any QR/deep link has been
  /// scanned — for a kiosk tablet permanently mounted at one café. Optional;
  /// leave blank for a device meant to be scanned into on first use. Once a
  /// café has actually been selected (scanned, deep-linked, or typed in),
  /// that persisted choice always wins over this on subsequent launches —
  /// see currentCafeIdProvider.
  static String get cafeId => dotenv.env['CAFE_ID'] ?? '';

  static bool get isSupabaseConfigured =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}
