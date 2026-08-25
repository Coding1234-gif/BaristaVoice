import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';
import '../data/agent/llm_order_agent_service.dart';
import '../data/agent/order_agent_service.dart';
import '../data/menu/menu_repository.dart';
import '../data/menu/supabase_menu_repository.dart';
import '../data/order/edge_function_order_submission_service.dart';
import '../data/order/order_submission_service.dart';
import '../data/order/order_submission_transport.dart';
import '../data/speech/speech_service.dart';
import '../data/tts/elevenlabs_tts_service.dart';
import '../data/tts/tts_service.dart';
import '../data/tts/tts_transport.dart';
import '../models/menu.dart';
import 'cafe_providers.dart';

final menuRepositoryProvider = Provider<MenuRepository>((ref) {
  return SupabaseMenuRepository(Supabase.instance.client);
});

/// Null whenever no café is selected — this is the ONLY menu provider the
/// customer app reads from, and it always resolves through
/// currentCafeIdProvider. There is deliberately no code path here that
/// returns a menu without a café id, so nothing can silently display a
/// global/default menu.
final activeMenuProvider = FutureProvider<CafeMenu?>((ref) async {
  final cafeId = ref.watch(currentCafeIdProvider);
  if (cafeId == null) return null;
  return ref.watch(menuRepositoryProvider).getActiveMenu(cafeId);
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

/// Creates the canonical order (and, server-side, submits it to the café's
/// POS) when the customer confirms — see `create-order` and
/// `create_canonical_order()` in schema.sql.
final orderSubmissionServiceProvider = Provider<OrderSubmissionService>((ref) {
  if (!Env.isSupabaseConfigured) {
    throw StateError(
      'Supabase is not configured yet. Add SUPABASE_URL and SUPABASE_ANON_KEY '
      'to app/.env — see .env.example.',
    );
  }
  return EdgeFunctionOrderSubmissionService(
    SupabaseOrderSubmissionTransport(Supabase.instance.client),
  );
});

final speechServiceProvider = Provider<SpeechService>((ref) => SpeechService());

/// Calls the `tts-speak` Supabase Edge Function, which holds the ElevenLabs
/// API key server-side (see [TtsService]) — the client never sees it.
final ttsServiceProvider = Provider<TtsService>((ref) {
  if (!Env.isSupabaseConfigured) {
    throw StateError(
      'Supabase is not configured yet. Add SUPABASE_URL and SUPABASE_ANON_KEY '
      'to app/.env — see .env.example.',
    );
  }
  return ElevenLabsTtsService(SupabaseTtsTransport(Supabase.instance.client));
});
