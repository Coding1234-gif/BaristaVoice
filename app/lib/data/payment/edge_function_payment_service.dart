import 'payment_service.dart';
import 'payment_transport.dart';

/// Interprets [PaymentTransport]'s raw status/data into typed results or
/// [PaymentServiceException]s — the pure logic half of this seam, matching
/// [EdgeFunctionOrderSubmissionService]'s split.
class EdgeFunctionPaymentService implements PaymentService {
  final PaymentTransport _transport;

  EdgeFunctionPaymentService(this._transport);

  @override
  Future<TerminalCheckoutResult> startTerminalCheckout({required String orderId}) async {
    final result = await _transport.invoke('pos-square-terminal-checkout', {'orderId': orderId});

    final data = result.data;
    if (result.status == 200 && data is Map) {
      final map = Map<String, dynamic>.from(data);
      final checkoutId = map['checkoutId'] as String?;
      if (checkoutId == null) {
        throw const PaymentServiceException('Could not start payment. Please try again.');
      }
      return TerminalCheckoutResult(
        orderId: map['orderId'] as String? ?? orderId,
        checkoutId: checkoutId,
        checkoutStatus: map['status'] as String?,
      );
    }

    throw PaymentServiceException(_messageFor(result));
  }

  @override
  Future<PaymentPollResult> checkPayment({required String orderId}) async {
    final result = await _transport.invoke('pos-square-order-pay', {'orderId': orderId});

    final data = result.data;
    if (result.status == 200 && data is Map) {
      final map = Map<String, dynamic>.from(data);
      return PaymentPollResult(
        paid: map['paymentStatus'] == 'COMPLETED',
        paymentId: map['paymentId'] as String?,
        status: map['orderStatus'] as String?,
      );
    }

    throw PaymentServiceException(_messageFor(result));
  }

  String _messageFor(PaymentTransportResult result) {
    final data = result.data;
    if (data is Map && data['error'] is String) {
      return data['error'] as String;
    }
    if (result.status == 0) {
      return 'Could not reach the payment service. Check your connection.';
    }
    return 'Could not complete the payment. Please try again.';
  }
}
