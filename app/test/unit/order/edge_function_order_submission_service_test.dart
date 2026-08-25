import 'package:flutter_test/flutter_test.dart';

import 'package:barista_voice/data/order/edge_function_order_submission_service.dart';
import 'package:barista_voice/data/order/order_submission_service.dart';
import 'package:barista_voice/data/order/order_submission_transport.dart';
import 'package:barista_voice/models/order.dart';

/// Hand-rolled fake transport — create-order is never actually called from
/// these tests. Mirrors what `SupabaseOrderSubmissionTransport` would
/// return for each scenario, matching the pattern already established by
/// elevenlabs_tts_service_test.dart's `_FakeTransport`.
class _FakeTransport implements OrderSubmissionTransport {
  final OrderSubmissionTransportResult Function(Map<String, dynamic> body) respond;
  Map<String, dynamic>? lastBody;
  int callCount = 0;

  _FakeTransport(this.respond);

  @override
  Future<OrderSubmissionTransportResult> invoke(Map<String, dynamic> body) async {
    callCount++;
    lastBody = body;
    return respond(body);
  }
}

void main() {
  final order = Order(items: [OrderItem(menuItemId: 'latte', name: 'Latte', quantity: 2)]);

  group('EdgeFunctionOrderSubmissionService.submitOrder', () {
    test('returns a typed result and sends only selections, never a price', () async {
      final transport = _FakeTransport(
        (body) => const OrderSubmissionTransportResult(
          status: 200,
          data: {
            'orderId': 'order-1',
            'orderStatus': 'confirmed',
            'total': 8.50,
            'pos': {'status': 'sent_to_pos', 'externalOrderId': 'sq-1', 'error': null},
          },
        ),
      );
      final service = EdgeFunctionOrderSubmissionService(transport);

      final result = await service.submitOrder(
        cafeId: 'cafe-1',
        idempotencyKey: 'idem-1',
        order: order,
      );

      expect(result.orderId, 'order-1');
      expect(result.orderStatus, 'confirmed');
      expect(result.total, 8.50);
      expect(result.posStatus, 'sent_to_pos');
      expect(result.sentToPos, isTrue);
      expect(result.posExternalOrderId, 'sq-1');

      expect(transport.lastBody!['cafeId'], 'cafe-1');
      expect(transport.lastBody!['idempotencyKey'], 'idem-1');
      final items = transport.lastBody!['items'] as List;
      expect(items, hasLength(1));
      expect((items.first as Map)['menuItemId'], 'latte');
      expect((items.first as Map).containsKey('unitPrice'), isFalse);
      expect((items.first as Map).containsKey('price'), isFalse);
    });

    test('sentToPos is false when the backend reports pos_failed', () async {
      final transport = _FakeTransport(
        (body) => const OrderSubmissionTransportResult(
          status: 200,
          data: {
            'orderId': 'order-1',
            'orderStatus': 'confirmed',
            'total': 8.50,
            'pos': {'status': null, 'externalOrderId': null, 'error': 'No active Square connection for this cafe.'},
          },
        ),
      );
      final service = EdgeFunctionOrderSubmissionService(transport);

      final result = await service.submitOrder(cafeId: 'cafe-1', idempotencyKey: 'idem-1', order: order);

      expect(result.sentToPos, isFalse);
      expect(result.posError, 'No active Square connection for this cafe.');
      // Order creation itself still succeeded — this is a valid outcome,
      // not an exception.
      expect(result.orderId, 'order-1');
    });

    test('throws without calling the transport for an empty order', () async {
      final transport = _FakeTransport((body) => throw StateError('should not be called'));
      final service = EdgeFunctionOrderSubmissionService(transport);

      await expectLater(
        () => service.submitOrder(cafeId: 'cafe-1', idempotencyKey: 'idem-1', order: const Order()),
        throwsA(isA<OrderSubmissionException>()),
      );
      expect(transport.callCount, 0);
    });

    test('surfaces the server error message on a validation failure (400)', () async {
      final transport = _FakeTransport(
        (body) => const OrderSubmissionTransportResult(
          status: 400,
          data: {'error': 'Invalid size "Huge" for "Latte".'},
        ),
      );
      final service = EdgeFunctionOrderSubmissionService(transport);

      await expectLater(
        () => service.submitOrder(cafeId: 'cafe-1', idempotencyKey: 'idem-1', order: order),
        throwsA(
          isA<OrderSubmissionException>().having(
            (e) => e.message,
            'message',
            'Invalid size "Huge" for "Latte".',
          ),
        ),
      );
    });

    test('maps a network failure (status 0) to a connectivity message', () async {
      final transport = _FakeTransport(
        (body) => const OrderSubmissionTransportResult(status: 0, data: null),
      );
      final service = EdgeFunctionOrderSubmissionService(transport);

      await expectLater(
        () => service.submitOrder(cafeId: 'cafe-1', idempotencyKey: 'idem-1', order: order),
        throwsA(
          isA<OrderSubmissionException>().having(
            (e) => e.message,
            'message',
            contains('connection'),
          ),
        ),
      );
    });

    test('throws a generic exception for a malformed success response', () async {
      final transport = _FakeTransport(
        (body) => const OrderSubmissionTransportResult(status: 200, data: {'unexpected': true}),
      );
      final service = EdgeFunctionOrderSubmissionService(transport);

      await expectLater(
        () => service.submitOrder(cafeId: 'cafe-1', idempotencyKey: 'idem-1', order: order),
        throwsA(isA<OrderSubmissionException>()),
      );
    });
  });
}
