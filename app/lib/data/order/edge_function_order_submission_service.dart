import '../../models/order.dart';
import 'order_submission_service.dart';
import 'order_submission_transport.dart';

/// Interprets [OrderSubmissionTransport]'s raw status/data into a typed
/// [OrderSubmissionResult] or [OrderSubmissionException] — the pure logic
/// half of this seam, unit-testable with a fake transport (same split as
/// `ElevenLabsTtsService`/`TtsTransport`).
class EdgeFunctionOrderSubmissionService implements OrderSubmissionService {
  final OrderSubmissionTransport _transport;

  EdgeFunctionOrderSubmissionService(this._transport);

  @override
  Future<OrderSubmissionResult> submitOrder({
    required String cafeId,
    required String idempotencyKey,
    required Order order,
  }) async {
    if (order.isEmpty) {
      throw const OrderSubmissionException('There is nothing to confirm yet.');
    }

    final result = await _transport.invoke({
      'cafeId': cafeId,
      'idempotencyKey': idempotencyKey,
      // Selections only — deliberately the same shape OrderItem.toJson()
      // already produces for the AI turn, which never includes a price.
      'items': order.items.map((e) => e.toJson()).toList(),
    });

    final data = result.data;
    if (result.status == 200 && data is Map) {
      final map = Map<String, dynamic>.from(data);
      final orderId = map['orderId'] as String?;
      final orderStatus = map['orderStatus'] as String?;
      if (orderId == null || orderStatus == null) {
        throw const OrderSubmissionException('Could not confirm the order. Please try again.');
      }

      final pos = map['pos'] as Map?;
      return OrderSubmissionResult(
        orderId: orderId,
        orderStatus: orderStatus,
        total: (map['total'] as num?)?.toDouble() ?? 0,
        posStatus: pos?['status'] as String?,
        posExternalOrderId: pos?['externalOrderId'] as String?,
        posError: pos?['error'] as String?,
      );
    }

    throw OrderSubmissionException(_messageFor(result));
  }

  String _messageFor(OrderSubmissionTransportResult result) {
    final data = result.data;
    if (data is Map && data['error'] is String) {
      return data['error'] as String;
    }
    if (result.status == 0) {
      return 'Could not reach the ordering service. Check your connection.';
    }
    return 'Could not confirm the order. Please try again.';
  }
}
