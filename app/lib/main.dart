import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/env.dart';
import 'core/router.dart';
import 'core/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Real paths (/admin/login) instead of hash fragments (/#/admin/login) —
  // no-op on mobile.
  usePathUrlStrategy();
  await dotenv.load(fileName: '.env');

  if (Env.isSupabaseConfigured) {
    await Supabase.initialize(
      url: Env.supabaseUrl,
      publishableKey: Env.supabaseAnonKey,
    );
  }

  runApp(const ProviderScope(child: BaristaVoiceApp()));
}

/// The customer kiosk still lives at `/` with its original UI untouched.
/// `/admin/**` is a separately themed cafe admin dashboard — see
/// core/router.dart and core/admin_theme.dart.
class BaristaVoiceApp extends ConsumerWidget {
  const BaristaVoiceApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'BaristaVoice',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      routerConfig: router,
    );
  }
}
