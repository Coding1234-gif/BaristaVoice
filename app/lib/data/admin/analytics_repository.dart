import 'package:supabase_flutter/supabase_flutter.dart';

import 'analytics_models.dart';

/// Reads the two reporting views schema.sql exposes with
/// `security_invoker = true` (`order_summary`, `order_item_sales`) — same
/// isolation model as [CafeAdminRepository]: cafeId shapes the query, but
/// the actual boundary is Supabase RLS on the underlying orders/order_items
/// tables, enforced server-side regardless of what this repository sends.
class AnalyticsRepository {
  final SupabaseClient _client;

  AnalyticsRepository(this._client);

  Future<List<OrderSummaryRow>> getOrderSummaries({
    required String cafeId,
    required DateTime since,
  }) async {
    final rows = await _client
        .from('order_summary')
        .select('id, status, total, created_at')
        .eq('cafe_id', cafeId)
        .gte('created_at', since.toUtc().toIso8601String())
        .order('created_at');
    return rows.map((r) => OrderSummaryRow.fromJson(r)).toList();
  }

  Future<List<ItemSaleRow>> getItemSales({
    required String cafeId,
    required DateTime since,
  }) async {
    final rows = await _client
        .from('order_item_sales')
        .select('name, quantity, line_total, order_status, order_created_at')
        .eq('cafe_id', cafeId)
        .gte('order_created_at', since.toUtc().toIso8601String())
        .order('order_created_at');
    return rows.map((r) => ItemSaleRow.fromJson(r)).toList();
  }
}
