import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';
import '../data/agent/llm_order_agent_service.dart';
import '../data/agent/order_agent_service.dart';
import '../data/menu/menu_repository.dart';
import '../data/menu/supabase_menu_repository.dart';
import '../data/speech/speech_service.dart';
import '../models/menu.dart';

/// Falls back to the hardcoded seed menu unless this kiosk install has both
/// Supabase and a CAFE_ID configured — an unconfigured install behaves
/// exactly as it did before the cafe admin dashboard existed.
final menuRepositoryProvider = Provider<MenuRepository>((ref) {
  if (Env.isCafeConfigured) {
    return SupabaseMenuRepository(Supabase.instance.client, Env.cafeId);
  }
  return SeedMenuRepository();
});

final activeMenuProvider = FutureProvider<CafeMenu>((ref) {
  return ref.watch(menuRepositoryProvider).getActiveMenu();
});

final orderAgentServiceProvider = Provider<OrderAgentService>((ref) {
  if (!Env.isSupabaseConfigured) {
    throw StateError(
      'Supabase is not configured yet. Add SUPABASE_URL and SUPABASE_ANON_KEY '
      'to app/.env — see .env.example.',
    );
  }
  return LlmOrderAgentService(Supabase.instance.client);
});

final speechServiceProvider = Provider<SpeechService>((ref) => SpeechService());
