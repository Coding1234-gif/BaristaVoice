import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../models/cafe.dart';
import 'visited_cafe.dart';

const _prefsKey = 'visited_cafes';

/// Caps how far back the "order again" list goes — this is a convenience
/// history, not an archive.
const _maxVisitedCafes = 20;

/// On-device record of which cafés this customer has ordered from before —
/// there's no customer account in this app (see cafe_providers.dart's
/// CurrentCafeController for the same SharedPreferences-backed pattern this
/// follows), so "history" only ever means "on this device".
class VisitedCafesRepository {
  Future<List<VisitedCafe>> getAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_prefsKey) ?? const [];
    final visits = raw
        .map((s) => VisitedCafe.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
    visits.sort((a, b) => b.lastVisitedAt.compareTo(a.lastVisitedAt));
    return visits;
  }

  /// Call whenever a café is actually selected (see
  /// cafe_providers.dart's resolveAndSelectCafe) — moves it to the top if
  /// already present rather than creating a duplicate entry.
  Future<void> recordVisit(Cafe cafe) async {
    final existing = await getAll();
    final withoutThisCafe = existing.where((v) => v.id != cafe.id);
    final updated = [
      VisitedCafe(id: cafe.id, name: cafe.name, logoUrl: cafe.logoUrl, lastVisitedAt: DateTime.now()),
      ...withoutThisCafe,
    ].take(_maxVisitedCafes).toList();
    await _save(updated);
  }

  Future<void> remove(String cafeId) async {
    final existing = await getAll();
    await _save(existing.where((v) => v.id != cafeId).toList());
  }

  Future<void> _save(List<VisitedCafe> visits) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, visits.map((v) => jsonEncode(v.toJson())).toList());
  }
}
