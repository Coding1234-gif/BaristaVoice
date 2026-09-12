/// One `order_summary` row — a single order with its item/quantity counts
/// already aggregated server-side. See supabase/schema.sql's
/// `order_summary` view.
class OrderSummaryRow {
  final String id;
  final String status;
  final double total;
  final DateTime createdAt;

  const OrderSummaryRow({
    required this.id,
    required this.status,
    required this.total,
    required this.createdAt,
  });

  factory OrderSummaryRow.fromJson(Map<String, dynamic> json) => OrderSummaryRow(
        id: json['id'] as String,
        status: json['status'] as String,
        total: (json['total'] as num).toDouble(),
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}

/// One `order_item_sales` row — a single order line, carrying enough of its
/// parent order (status/created_at) to filter and bucket without a second
/// query. See supabase/schema.sql's `order_item_sales` view.
class ItemSaleRow {
  final String name;
  final int quantity;
  final double lineTotal;
  final String orderStatus;
  final DateTime orderCreatedAt;

  const ItemSaleRow({
    required this.name,
    required this.quantity,
    required this.lineTotal,
    required this.orderStatus,
    required this.orderCreatedAt,
  });

  factory ItemSaleRow.fromJson(Map<String, dynamic> json) => ItemSaleRow(
        name: json['name'] as String,
        quantity: json['quantity'] as int,
        lineTotal: (json['line_total'] as num).toDouble(),
        orderStatus: json['order_status'] as String,
        orderCreatedAt: DateTime.parse(json['order_created_at'] as String),
      );
}
