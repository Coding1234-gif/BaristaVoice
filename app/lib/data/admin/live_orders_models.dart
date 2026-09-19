/// One `order_item_modifiers` row — a single named adjustment on a line
/// (e.g. "Oat milk", "Extra shot"), with the price it added.
class LiveOrderModifier {
  final String name;
  final double priceAdjustment;

  const LiveOrderModifier({required this.name, this.priceAdjustment = 0});

  factory LiveOrderModifier.fromJson(Map<String, dynamic> json) => LiveOrderModifier(
        name: json['name'] as String,
        priceAdjustment: (json['price_adjustment'] as num?)?.toDouble() ?? 0,
      );
}

/// One `order_items` row, trimmed to what the Live Orders card displays.
class LiveOrderItem {
  final String name;
  final int quantity;
  final double unitPrice;
  final List<LiveOrderModifier> modifiers;

  /// The customer's non-modifier selections, persisted by `create-order` into
  /// `order_items.metadata` (see buildRpcPayload) — all null/false when the
  /// order predates that, or the customer chose nothing.
  final String? size;
  final String? milk;
  final String? temperature;
  final bool decaf;
  final String? specialRequest;

  const LiveOrderItem({
    required this.name,
    required this.quantity,
    this.unitPrice = 0,
    this.modifiers = const [],
    this.size,
    this.milk,
    this.temperature,
    this.decaf = false,
    this.specialRequest,
  });

  double get lineTotal => unitPrice * quantity;

  /// Everything the barista needs to make the drink beyond its name, in the
  /// same order and wording as the kiosk's OrderSummaryPanel (`_optionsLine`)
  /// so the customer's screen and the café's screen never disagree.
  /// Empty string when there's nothing to show.
  String get optionsLine {
    final parts = <String>[];
    if (size != null && size!.trim().isNotEmpty) parts.add(size!.trim());
    if (temperature != null && temperature!.trim().isNotEmpty) parts.add(temperature!.trim());
    if (milk != null && milk!.trim().isNotEmpty) parts.add('${milk!.trim()} milk');
    if (decaf) parts.add('decaf');
    parts.addAll(modifiers.map((m) => m.name));
    if (specialRequest != null && specialRequest!.trim().isNotEmpty) {
      parts.add(specialRequest!.trim());
    }
    return parts.join(' · ');
  }

  factory LiveOrderItem.fromJson(Map<String, dynamic> json, {List<LiveOrderModifier> modifiers = const []}) {
    final meta = json['metadata'];
    final m = meta is Map ? Map<String, dynamic>.from(meta) : const <String, dynamic>{};
    return LiveOrderItem(
      name: json['name'] as String,
      quantity: json['quantity'] as int? ?? 1,
      unitPrice: (json['unit_price'] as num?)?.toDouble() ?? 0,
      modifiers: modifiers,
      size: m['size'] as String?,
      milk: m['milk'] as String?,
      temperature: m['temperature'] as String?,
      decaf: m['decaf'] == true,
      specialRequest: m['specialRequest'] as String?,
    );
  }
}

/// One `orders` row plus its items, as shown on the admin Live Orders
/// dashboard. `status` mirrors the raw DB value (see the `orders.status`
/// check constraint) rather than an enum, since the live payment/POS pipeline
/// uses more values (`paid`, `confirmed`, `payment_pending`, ...) than the
/// stale enum-ish CHECK in schema.sql — see analytics_insights.dart, which
/// treats status the same way.
class LiveOrder {
  final String id;
  final int orderNumber;
  final String status;
  final double total;
  final String currency;
  final DateTime createdAt;
  final DateTime? completedAt;
  final List<LiveOrderItem> items;
  final String source;

  const LiveOrder({
    required this.id,
    required this.orderNumber,
    required this.status,
    required this.total,
    required this.currency,
    required this.createdAt,
    required this.items,
    required this.source,
    this.completedAt,
  });

  bool get isPaid => status == 'paid';
  bool get isCompleted => completedAt != null;
  bool get isFailedOrCancelled =>
      status == 'payment_failed' || status == 'pos_failed' || status == 'cancelled';

  factory LiveOrder.fromJson(Map<String, dynamic> json, {List<LiveOrderItem> items = const []}) {
    return LiveOrder(
      id: json['id'] as String,
      orderNumber: json['order_number'] as int,
      status: json['status'] as String,
      total: (json['total'] as num).toDouble(),
      currency: json['currency'] as String? ?? 'GBP',
      createdAt: DateTime.parse(json['created_at'] as String),
      completedAt:
          json['completed_at'] == null ? null : DateTime.parse(json['completed_at'] as String),
      items: items,
      source: json['source'] as String? ?? 'voice',
    );
  }
}

class PopularProduct {
  final String name;
  final int quantity;

  const PopularProduct({required this.name, required this.quantity});
}

/// Today's-activity stats for the admin Overview screen — derived entirely
/// from whatever [LiveOrdersRepository.watchLiveOrders] already has loaded
/// (the same realtime feed Live Orders renders), rather than a separate
/// query. Revenue/AOV/popular products only ever count `status == 'paid'`
/// orders, same convention as AnalyticsInsights.compute() — an order that
/// never paid never counts as revenue.
class TodaysOverview {
  final int orderCount;
  final double revenue;
  final double averageOrderValue;
  final int voiceOrderCount;
  final List<PopularProduct> popularProducts;
  final List<LiveOrder> recentOrders;

  const TodaysOverview({
    required this.orderCount,
    required this.revenue,
    required this.averageOrderValue,
    required this.voiceOrderCount,
    required this.popularProducts,
    required this.recentOrders,
  });

  factory TodaysOverview.compute(List<LiveOrder> orders, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    bool isToday(DateTime dt) {
      final local = dt.toLocal();
      return local.year == today.year && local.month == today.month && local.day == today.day;
    }

    final todays = orders.where((o) => isToday(o.createdAt)).toList();
    final todaysPaid = todays.where((o) => o.isPaid).toList();

    final revenue = todaysPaid.fold(0.0, (sum, o) => sum + o.total);
    final voiceCount = todays.where((o) => o.source == 'voice').length;

    final quantityByName = <String, int>{};
    for (final order in todaysPaid) {
      for (final item in order.items) {
        quantityByName.update(item.name, (q) => q + item.quantity, ifAbsent: () => item.quantity);
      }
    }
    final popular = quantityByName.entries.map((e) => PopularProduct(name: e.key, quantity: e.value)).toList()
      ..sort((a, b) => b.quantity.compareTo(a.quantity));

    return TodaysOverview(
      orderCount: todays.length,
      revenue: revenue,
      averageOrderValue: todaysPaid.isEmpty ? 0 : revenue / todaysPaid.length,
      voiceOrderCount: voiceCount,
      popularProducts: popular.take(5).toList(),
      recentOrders: orders.take(5).toList(),
    );
  }
}
