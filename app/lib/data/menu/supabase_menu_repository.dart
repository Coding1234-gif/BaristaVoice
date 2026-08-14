import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/menu.dart';
import 'menu_repository.dart';

/// Reads the PUBLISHED menu for one café straight from `menu_items`. Works
/// unauthenticated (anon key) because RLS explicitly allows public SELECT of
/// `status = 'published'` rows only — draft/AI-extracted-but-unreviewed
/// items are never reachable from here regardless of what this class does,
/// the database itself won't return them for any other status.
///
/// Deliberately has no "no café configured" fallback of its own — that
/// state is handled one layer up (activeMenuProvider / KioskScreen), so
/// this class is never asked to guess a café.
class SupabaseMenuRepository implements MenuRepository {
  final SupabaseClient _client;

  SupabaseMenuRepository(this._client);

  @override
  Future<CafeMenu> getActiveMenu(String cafeId) async {
    final cafeRow = await _client.from('cafes').select('name').eq('id', cafeId).maybeSingle();
    final itemRows = await _client
        .from('menu_items')
        .select('data')
        .eq('cafe_id', cafeId)
        .eq('status', 'published');

    final items = itemRows
        .map((row) => MenuItem.fromJson(row['data'] as Map<String, dynamic>))
        .where((item) => item.available)
        .toList();

    return CafeMenu(cafeName: cafeRow?['name'] as String? ?? '', items: items);
  }
}
