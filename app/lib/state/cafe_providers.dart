import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/cafe/cafe_repository.dart';
import '../data/history/visited_cafe.dart';
import '../data/history/visited_cafes_repository.dart';
import '../models/cafe.dart';

const _prefsKey = 'current_cafe_id';

/// The ONE source of truth for which café the customer is currently
/// viewing. Every café-scoped screen/provider (menu, AI assistant, header,
/// cart) reads from here — nothing independently guesses the café. Backed
/// by SharedPreferences so a kiosk tablet doesn't need re-scanning after a
/// restart; explicitly overridden in main.dart with whatever was persisted
/// (or the install's CAFE_ID default) before the widget tree is built.
class CurrentCafeController extends StateNotifier<String?> {
  CurrentCafeController(super.state);

  Future<void> setCafe(String cafeId) async {
    state = cafeId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, cafeId);
  }

  /// Explicit only — never called implicitly as a "fall back to demo" path.
  Future<void> clear() async {
    state = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }
}

final currentCafeIdProvider = StateNotifierProvider<CurrentCafeController, String?>((ref) {
  throw UnimplementedError('overridden in main() once SharedPreferences has loaded');
});

final cafeRepositoryProvider = Provider<CafeRepository>((ref) {
  return CafeRepository(Supabase.instance.client);
});

/// Null while no café is selected, or if the previously-selected café no
/// longer exists (e.g. deleted) — either way the UI must show the "scan a
/// café's QR code" state, never a stale/wrong menu.
final currentCafeProvider = FutureProvider<Cafe?>((ref) async {
  final cafeId = ref.watch(currentCafeIdProvider);
  if (cafeId == null) return null;
  return ref.watch(cafeRepositoryProvider).getCafe(cafeId);
});

final visitedCafesRepositoryProvider = Provider<VisitedCafesRepository>((ref) {
  return VisitedCafesRepository();
});

/// The customer's on-device "order again" history — see ProfileScreen.
/// Auto-disposing + family-free, same convention as the admin dashboard's
/// data providers: resolveAndSelectCafe invalidates this after recording a
/// new visit rather than this watching anything live.
final visitedCafesProvider = FutureProvider<List<VisitedCafe>>((ref) {
  return ref.watch(visitedCafesRepositoryProvider).getAll();
});

/// Resolves a scanned/typed café id-or-slug and, only on success, makes it
/// the current café. Shared by the QR/deep-link entry route and the manual
/// "enter a café code" fallback so there's exactly one place this happens.
/// Returns null (without changing currentCafeIdProvider) if the café
/// doesn't exist — callers show a friendly error rather than guessing.
Future<Cafe?> resolveAndSelectCafe(WidgetRef ref, String idOrSlug) async {
  final cafe = await ref.read(cafeRepositoryProvider).resolveCafe(idOrSlug);
  if (cafe != null) {
    await ref.read(currentCafeIdProvider.notifier).setCafe(cafe.id);
    await ref.read(visitedCafesRepositoryProvider).recordVisit(cafe);
    ref.invalidate(visitedCafesProvider);
  }
  return cafe;
}

/// Pulls the trailing path segment out of a pasted QR/deep-link URL
/// (`https://x.com/cafe/demo`, `baristavoice://cafe/demo`, `/cafe/demo`) or
/// just returns the input as-is if it's already a bare id/slug.
String extractCafeIdOrSlug(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return trimmed;
  final segments = trimmed.split('/').where((s) => s.isNotEmpty).toList();
  return segments.isEmpty ? trimmed : segments.last;
}
