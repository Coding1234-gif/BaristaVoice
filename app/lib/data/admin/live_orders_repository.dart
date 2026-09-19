import 'package:supabase_flutter/supabase_flutter.dart';

import 'live_orders_models.dart';

/// How many of the most recent orders the Live Orders dashboard keeps on
/// screen. Bounds both the realtime payload and the item lookup below —
/// there's no operational reason for a barista to scroll further back than
/// this on a live queue (older orders belong on the Analytics screen).
const liveOrdersLimit = 50;

/// Powers the admin "Live Orders" screen: a realtime feed of a cafe's
/// `orders` rows (new orders arriving, status/completed_at changing) joined
/// client-side with their `order_items`.
///
/// Same isolation model as [CafeAdminRepository]/[AnalyticsRepository]: the
/// cafeId shapes the query, but the actual boundary is Supabase RLS
/// (`orders_select_own`), which also governs what a realtime subscription is
/// allowed to receive — see supabase/schema.sql's REALTIME section.
class LiveOrdersRepository {
  final SupabaseClient _client;

  LiveOrdersRepository(this._client);

  /// Streams the cafe's most recent orders, each emission re-joined with its
  /// items. `order_items` has no realtime table of its own here — orders are
  /// never edited after creation in this app, so a plain fetch keyed off
  /// whichever order ids are currently on screen is enough to stay correct,
  /// without needing a second realtime subscription.
  Stream<List<LiveOrder>> watchLiveOrders(String cafeId) {
    return _client
        .from('orders')
        .stream(primaryKey: ['id'])
        .eq('cafe_id', cafeId)
        // NOTE: SupabaseStreamBuilder streams the whole row regardless of a
        // .select() (its own select() param controls realtime payload
        // columns, not this REST fetch) — `source` arrives without needing
        // to be listed explicitly, same as every other orders column
        // LiveOrder.fromJson reads.
        .order('created_at', ascending: false)
        .limit(liveOrdersLimit)
        .asyncMap((rows) async {
          if (rows.isEmpty) return const <LiveOrder>[];

          final orderIds = rows.map((r) => r['id'] as String).toList();
          final itemRows = await _client
              .from('order_items')
              .select('id, order_id, name, quantity, unit_price, metadata')
              .inFilter('order_id', orderIds);

          final itemIds = itemRows.map((r) => r['id'] as String).toList();
          final modifiersByItem = <String, List<LiveOrderModifier>>{};
          if (itemIds.isNotEmpty) {
            final modifierRows = await _client
                .from('order_item_modifiers')
                .select('order_item_id, name, price_adjustment')
                .inFilter('order_item_id', itemIds);
            for (final row in modifierRows) {
              modifiersByItem
                  .putIfAbsent(row['order_item_id'] as String, () => [])
                  .add(LiveOrderModifier.fromJson(row));
            }
          }

          final itemsByOrder = <String, List<LiveOrderItem>>{};
          for (final row in itemRows) {
            itemsByOrder.putIfAbsent(row['order_id'] as String, () => []).add(
                  LiveOrderItem.fromJson(row, modifiers: modifiersByItem[row['id']] ?? const []),
                );
          }

          return rows
              .map((r) => LiveOrder.fromJson(r, items: itemsByOrder[r['id']] ?? const []))
              .toList();
        });
  }

  /// Invokes the `mark-order-complete` Edge Function, which reads the
  /// order's own cafe_id server-side and checks it against the caller's
  /// profile — this call cannot be redirected to complete another cafe's
  /// order, and is a no-op if it's already complete.
  Future<void> markComplete(String orderId) async {
    final response = await _client.functions.invoke(
      'mark-order-complete',
      body: {'orderId': orderId},
    );

    final data = response.data as Map<String, dynamic>?;
    if (data != null && data['error'] != null) {
      throw Exception(data['error'] as String);
    }
  }
}
