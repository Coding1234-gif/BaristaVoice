import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/menu.dart';
import 'menu_repository.dart';
import 'seed_menu.dart';

/// Reads the PUBLISHED menu for one cafe straight from `menu_items`. Works
/// unauthenticated (anon key) because RLS explicitly allows public SELECT of
/// `status = 'published'` rows only — draft/AI-extracted-but-unreviewed
/// items are never reachable from here regardless of what this class does,
/// the database itself won't return them.
class SupabaseMenuRepository implements MenuRepository {
  final SupabaseClient _client;
  final String _cafeId;

  SupabaseMenuRepository(this._client, this._cafeId);

  @override
  Future<CafeMenu> getActiveMenu() async {
    final cafeRow = await _client.from('cafes').select('name').eq('id', _cafeId).maybeSingle();
    final itemRows = await _client
        .from('menu_items')
        .select('data')
        .eq('cafe_id', _cafeId)
        .eq('status', 'published');

    final items = itemRows
        .map((row) => MenuItem.fromJson(row['data'] as Map<String, dynamic>))
        .where((item) => item.available)
        .toList();

    if (cafeRow == null && items.isEmpty) {
      // Misconfigured CAFE_ID (cafe deleted, or the demo hasn't published a
      // menu yet) — fall back to the seed menu rather than showing an empty
      // kiosk.
      return seedMenu;
    }

    return CafeMenu(cafeName: cafeRow?['name'] as String? ?? seedMenu.cafeName, items: items);
  }
}
