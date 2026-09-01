import 'package:flutter_test/flutter_test.dart';

import 'package:barista_voice/data/payment/edge_function_payment_service.dart';
import 'package:barista_voice/data/payment/payment_service.dart';
import 'package:barista_voice/data/payment/payment_transport.dart';

/// Hand-rolled fake transport — no edge function is ever actually called
/// from these tests. Mirrors the pattern already established by
/// `edge_function_order_submission_service_test.dart`'s `_FakeTransport`.
class _FakeTransport implements PaymentTransport {
  final PaymentTransportResult Function(String functionName, Map<String, dynamic> body) respond;
  String? lastFunctionName;
  Map<String, dynamic>? lastBody;
  int callCount = 0;

  _FakeTransport(this.respond);

  @override
  Future<PaymentTransportResult> invoke(String functionName, Map<String, dynamic> body) async {
    callCount++;
    lastFunctionName = functionName;
    lastBody = body;
    return respond(functionName, body);
  }
}

void main() {
  group('EdgeFunctionPaymentService.startTerminalCheckout', () {
    test('calls pos-square-terminal-checkout with only the orderId, and returns a typed result', () async {
      final transport = _FakeTransport(
        (_, _) => const PaymentTransportResult(
          status: 200,
          data: {
            'orderId': 'order-1',
            'checkoutId': 'checkout-1',
            'status': 'PENDING',
            'orderStatus': 'payment_pending',
          },
        ),
      );
      final service = EdgeFunctionPaymentService(transport);

      final result = await service.startTerminalCheckout(orderId: 'order-1');

      expect(transport.lastFunctionName, 'pos-square-terminal-checkout');
      expect(transport.lastBody, {'orderId': 'order-1'});
      expect(result.orderId, 'order-1');
      expect(result.checkoutId, 'checkout-1');
      expect(result.checkoutStatus, 'PENDING');
    });

    test('a 200 with no checkoutId still throws rather than returning a bogus result', () async {
      final transport = _FakeTransport(
        (_, _) => const PaymentTransportResult(status: 200, data: {'orderId': 'order-1'}),
      );
      final service = EdgeFunctionPaymentService(transport);

      expect(
        () => service.startTerminalCheckout(orderId: 'order-1'),
        throwsA(isA<PaymentServiceException>()),
      );
    });

    test('a POS-side error (e.g. no active Square connection) surfaces the server message, not a generic one', () async {
      final transport = _FakeTransport(
        (_, _) => const PaymentTransportResult(
          status: 400,
          data: {'error': 'No active Square connection for this cafe.'},
        ),
      );
      final service = EdgeFunctionPaymentService(transport);

      await expectLater(
        service.startTerminalCheckout(orderId: 'order-1'),
        throwsA(
          isA<PaymentServiceException>().having(
            (e) => e.message,
            'message',
            'No active Square connection for this cafe.',
          ),
        ),
      );
    });

    test('a network failure (status 0) is reported, not swallowed as success', () async {
      final transport = _FakeTransport(
        (_, _) => const PaymentTransportResult(status: 0, data: null),
      );
      final service = EdgeFunctionPaymentService(transport);

      await expectLater(
        service.startTerminalCheckout(orderId: 'order-1'),
        throwsA(
          isA<PaymentServiceException>().having(
            (e) => e.message,
            'message',
            'Could not reach the payment service. Check your connection.',
          ),
        ),
      );
    });
  });

  group('EdgeFunctionPaymentService.checkPayment', () {
    test('calls pos-square-order-pay with only the orderId', () async {
      final transport = _FakeTransport(
        (_, _) => const PaymentTransportResult(status: 200, data: {'orderId': 'order-1', 'paid': false}),
      );
      final service = EdgeFunctionPaymentService(transport);

      await service.checkPayment(orderId: 'order-1');

      expect(transport.lastFunctionName, 'pos-square-order-pay');
      expect(transport.lastBody, {'orderId': 'order-1'});
    });

    test('paid: false is a normal result, not an exception — the customer just hasn\'t paid yet', () async {
      final transport = _FakeTransport(
        (_, _) => const PaymentTransportResult(status: 200, data: {'orderId': 'order-1', 'paid': false}),
      );
      final service = EdgeFunctionPaymentService(transport);

      final result = await service.checkPayment(orderId: 'order-1');

      expect(result.paid, isFalse);
      expect(result.paymentId, isNull);
    });

    test('paid: true carries the payment id through', () async {
      final transport = _FakeTransport(
        (_, _) => const PaymentTransportResult(
          status: 200,
          data: {'orderId': 'order-1', 'paid': true, 'paymentId': 'sq-pay-1', 'status': 'paid'},
        ),
      );
      final service = EdgeFunctionPaymentService(transport);

      final result = await service.checkPayment(orderId: 'order-1');

      expect(result.paid, isTrue);
      expect(result.paymentId, 'sq-pay-1');
      expect(result.status, 'paid');
    });

    test('a hard payment failure (non-200) throws with the server-provided customer-safe message', () async {
      final transport = _FakeTransport(
        (_, _) => const PaymentTransportResult(
          status: 502,
          data: {'error': 'Square reported success but the payment did not capture.'},
        ),
      );
      final service = EdgeFunctionPaymentService(transport);

      await expectLater(
        service.checkPayment(orderId: 'order-1'),
        throwsA(isA<PaymentServiceException>()),
      );
    });
  });
}
