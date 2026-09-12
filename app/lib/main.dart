import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/env.dart';
import 'core/router.dart';
import 'core/theme.dart';
import 'data/billing/subscription_service.dart';
import 'state/cafe_providers.dart';
import 'state/theme_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Real paths (/admin/login, /cafe/abc123) instead of hash fragments — the
  // web form of a café QR/deep link needs a real path. No-op on mobile.
  usePathUrlStrategy();
  await dotenv.load(fileName: 'env');

  if (Env.isSupabaseConfigured) {
    await Supabase.initialize(
      url: Env.supabaseUrl,
      publishableKey: Env.supabaseAnonKey,
    );
  }

  // A no-op on web / without RevenueCat keys configured — see
  // SubscriptionService's header comment.
  await SubscriptionService().configure();

  // Whichever café this device last viewed, persisted across restarts —
  // falls back to CAFE_ID (a kiosk pinned to one café via .env) only if
  // nothing has been scanned/selected yet. Loaded before runApp so there is
  // no flash of "no café selected" on every launch.
  final prefs = await SharedPreferences.getInstance();
  final initialCafeId = prefs.getString('current_cafe_id') ??
      (Env.cafeId.isNotEmpty ? Env.cafeId : null);
  final initialThemeMode = (prefs.getBool('dark_mode_enabled') ?? false) ? ThemeMode.dark : ThemeMode.light;

  runApp(
    ProviderScope(
      overrides: [
        currentCafeIdProvider.overrideWith((ref) => CurrentCafeController(initialCafeId)),
        themeModeProvider.overrideWith((ref) => ThemeModeController(initialThemeMode)),
      ],
      child: const BaristaVoiceApp(),
    ),
  );
}

/// The customer kiosk still lives at `/` with its original UI untouched.
/// `/admin/**` is a separately themed cafe admin dashboard — see
/// core/router.dart and core/admin_theme.dart.
class BaristaVoiceApp extends ConsumerWidget {
  const BaristaVoiceApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      title: 'BaristaVoice',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      darkTheme: buildAppDarkTheme(),
      themeMode: themeMode,
      routerConfig: router,
    );
  }
}
