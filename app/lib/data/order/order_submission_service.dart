import '../../models/order.dart';

/// Result of successfully creating a canonical order server-side.
/// [posStatus]/[posExternalOrderId]/[posError] reflect whatever
/// pos-square-order-submit actually reported — [posStatus] is only ever
/// `'sent_to_pos'` when the order genuinely reached Square; any other value
/// (including null, e.g. a café with no active POS connection) means it did
/// not, and callers must not tell the customer otherwise.
class OrderSubmissionResult {
  final String orderId;
  final String orderStatus;
  final double total;
  final String? posStatus;
  final String? posExternalOrderId;
  final String? posError;

  const OrderSubmissionResult({
    required this.orderId,
    required this.orderStatus,
    required this.total,
    this.posStatus,
    this.posExternalOrderId,
    this.posError,
  });

  bool get sentToPos => posStatus == 'sent_to_pos';
}

class OrderSubmissionException implements Exception {
  final String message;
  const OrderSubmissionException(this.message);
  @override
  String toString() => 'OrderSubmissionException: $message';
}

/// Creates the canonical, server-priced order for a confirmed [Order] and
/// (server-side) submits it to the café's POS if one is connected.
/// Implementations must never send a price for anything — the server is the
/// only source of truth for what an order costs; see `create-order` and
/// `create_canonical_order()` in schema.sql.
abstract class OrderSubmissionService {
  Future<OrderSubmissionResult> submitOrder({
    required String cafeId,
    required String idempotencyKey,
    required Order order,
  });
}
