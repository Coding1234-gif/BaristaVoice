import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/cafe.dart';

final _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// Customer-facing café lookups. Reads are public (RLS: `public read cafes`
/// allows SELECT of the whole table — café name/logo/description are
/// intentionally public, nothing sensitive lives on this row), but this
/// class only ever exposes what a customer is meant to see. It never
/// authorizes anything — a café's PRODUCTS are separately gated by
/// `menu_items`' own `status = 'published'` RLS policy regardless of what a
/// client passes here.
class CafeRepository {
  final SupabaseClient _client;

  CafeRepository(this._client);

  /// Resolves a QR/deep-link path segment to a café. Accepts either a real
  /// `cafes.id` (uuid) or a human `slug` (only the demo café has one today).
  /// Avoids ever comparing a non-uuid string against the uuid `id` column —
  /// PostgREST throws a 400 for an invalid uuid literal rather than just
  /// finding no match, so the lookup column is chosen up front.
  Future<Cafe?> resolveCafe(String idOrSlug) async {
    final trimmed = idOrSlug.trim();
    if (trimmed.isEmpty) return null;

    final column = _uuidPattern.hasMatch(trimmed) ? 'id' : 'slug';
    final row = await _client.from('cafes').select().eq(column, trimmed).maybeSingle();
    if (row == null) return null;
    return Cafe.fromJson(row);
  }

  Future<Cafe?> getCafe(String cafeId) async {
    final row = await _client.from('cafes').select().eq('id', cafeId).maybeSingle();
    if (row == null) return null;
    return Cafe.fromJson(row);
  }
}
