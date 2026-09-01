import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:barista_voice/data/agent/conversation_turn.dart';
import 'package:barista_voice/data/agent/order_agent_service.dart';
import 'package:barista_voice/data/order/order_submission_service.dart';
import 'package:barista_voice/data/payment/payment_service.dart';
import 'package:barista_voice/data/speech/speech_service.dart';
import 'package:barista_voice/data/tts/tts_service.dart';
import 'package:barista_voice/models/menu.dart';
import 'package:barista_voice/models/order.dart';
import 'package:barista_voice/state/kiosk_controller.dart';
import 'package:barista_voice/state/tts_playback_controller.dart';

/// Never actually exercised by these tests (no test here drives the mic),
/// but KioskController's constructor needs a real instance.
class _UnusedOrderAgentService implements OrderAgentService {
  @override
  Future<AgentTurnResult> interpret({
    required String cafeId,
    required String transcript,
    required Order currentOrder,
    required CafeMenu menu,
    required List<ConversationTurn> history,
  }) {
    throw UnimplementedError('not exercised by kiosk_controller_test.dart');
  }
}

/// Synthesizes nothing real — just lets a genuine [TtsPlaybackController] be
/// constructed so KioskController's fire-and-forget `_tts.speak()`/`.stop()`
/// calls have somewhere safe to land.
class _SilentTtsService implements TtsService {
  @override
  Future<Uint8List> textToSpeech(String text) async => Uint8List(0);
}

class _FakeOrderSubmissionService implements OrderSubmissionService {
  final OrderSubmissionResult Function() respond;
  int callCount = 0;

  _FakeOrderSubmissionService(this.respond);

  @override
  Future<OrderSubmissionResult> submitOrder({
    required String cafeId,
    required String idempotencyKey,
    required Order order,
  }) async {
    callCount++;
    return respond();
  }
}

class _FakePaymentService implements PaymentService {
  Future<TerminalCheckoutResult> Function(String orderId)? onStartCheckout;
  Future<PaymentPollResult> Function(String orderId, int attempt)? onCheckPayment;

  int startCheckoutCallCount = 0;
  int checkPaymentCallCount = 0;
  final List<String> startCheckoutOrderIds = [];

  @override
  Future<TerminalCheckoutResult> startTerminalCheckout({required String orderId}) {
    startCheckoutCallCount++;
    startCheckoutOrderIds.add(orderId);
    final handler = onStartCheckout;
    if (handler != null) return handler(orderId);
    return Future.value(TerminalCheckoutResult(orderId: orderId, checkoutId: 'checkout-1'));
  }

  @override
  Future<PaymentPollResult> checkPayment({required String orderId}) {
    checkPaymentCallCount++;
    final handler = onCheckPayment;
    if (handler != null) return handler(orderId, checkPaymentCallCount);
    return Future.value(const PaymentPollResult(paid: false));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const cafeId = 'cafe-1';
  final order = Order(items: [OrderItem(menuItemId: 'latte', name: 'Latte', quantity: 1)]);

  KioskController buildController({
    required _FakeOrderSubmissionService orderSubmission,
    required _FakePaymentService payment,
  }) {
    final tts = TtsPlaybackController(_SilentTtsService());
    return KioskController(
      SpeechService(),
      _UnusedOrderAgentService(),
      tts,
      orderSubmission,
      payment,
      const CafeMenu(cafeName: '', items: []),
      cafeId,
    );
  }

  OrderSubmissionResult sentToPosResult({String orderId = 'order-1'}) => OrderSubmissionResult(
        orderId: orderId,
        orderStatus: 'confirmed',
        total: 4.25,
        posStatus: 'sent_to_pos',
        posExternalOrderId: 'sq-order-1',
      );

  group('confirmOrder — duplicate tap protection', () {
    test('a second confirmOrder call while the first is in flight submits only once', () {
      fakeAsync((async) {
        final orderSubmission = _FakeOrderSubmissionService(sentToPosResult);
        final payment = _FakePaymentService();
        final controller = buildController(orderSubmission: orderSubmission, payment: payment);
        controller.state = controller.state.copyWith(order: order);

        // Not awaited on purpose — this simulates two rapid taps racing.
        controller.confirmOrder();
        controller.confirmOrder();
        async.flushMicrotasks();

        expect(orderSubmission.callCount, 1);
      });
    });

    test('confirmOrder is a no-op once a payment phase has already started for this order', () {
      fakeAsync((async) {
        final orderSubmission = _FakeOrderSubmissionService(sentToPosResult);
        final payment = _FakePaymentService();
        final controller = buildController(orderSubmission: orderSubmission, payment: payment);
        controller.state = controller.state.copyWith(order: order);

        controller.confirmOrder();
        async.flushMicrotasks();
        expect(controller.state.paymentPhase, PaymentPhase.awaitingPayment);

        controller.confirmOrder();
        async.flushMicrotasks();

        expect(orderSubmission.callCount, 1);
      });
    });
  });

  group('payment polling — terminates on success', () {
    test('confirming a sent-to-pos order starts the checkout, then polls until paid', () {
      fakeAsync((async) {
        final orderSubmission = _FakeOrderSubmissionService(sentToPosResult);
        final payment = _FakePaymentService()
          ..onCheckPayment = (orderId, attempt) async =>
              PaymentPollResult(paid: attempt >= 3, paymentId: attempt >= 3 ? 'sq-pay-1' : null, status: null);
        final controller = buildController(orderSubmission: orderSubmission, payment: payment);
        controller.state = controller.state.copyWith(order: order);

        controller.confirmOrder();
        async.flushMicrotasks();

        expect(payment.startCheckoutCallCount, 1);
        expect(payment.startCheckoutOrderIds, ['order-1']);
        expect(controller.state.paymentPhase, PaymentPhase.awaitingPayment);

        // First two polls: not paid yet.
        async.elapse(const Duration(seconds: 2));
        expect(controller.state.paymentPhase, PaymentPhase.awaitingPayment);
        async.elapse(const Duration(seconds: 2));
        expect(controller.state.paymentPhase, PaymentPhase.awaitingPayment);

        // Third poll: paid.
        async.elapse(const Duration(seconds: 2));
        expect(controller.state.paymentPhase, PaymentPhase.paid);
        expect(payment.checkPaymentCallCount, 3);

        // The timer must actually be cancelled — advancing well past
        // several more intervals must not trigger any further polls.
        async.elapse(const Duration(seconds: 20));
        expect(payment.checkPaymentCallCount, 3);
      });
    });
  });

  group('payment polling — terminates on timeout', () {
    test('polling that never reports paid stops itself after the attempt budget and reports a failure', () {
      fakeAsync((async) {
        final orderSubmission = _FakeOrderSubmissionService(sentToPosResult);
        final payment = _FakePaymentService(); // always paid: false
        final controller = buildController(orderSubmission: orderSubmission, payment: payment);
        controller.state = controller.state.copyWith(order: order);

        controller.confirmOrder();
        async.flushMicrotasks();

        // 45 attempts * 2s = 90s is the documented budget.
        async.elapse(const Duration(seconds: 90));

        expect(controller.state.paymentPhase, PaymentPhase.failed);
        expect(controller.state.paymentError, isNotNull);
        final attemptsMade = payment.checkPaymentCallCount;
        expect(attemptsMade, lessThanOrEqualTo(45));

        // No further polling after giving up.
        async.elapse(const Duration(seconds: 20));
        expect(payment.checkPaymentCallCount, attemptsMade);
      });
    });
  });

  group('retryPayment', () {
    test('retrying after a failure reuses the SAME canonical order id, never creates a new order', () {
      fakeAsync((async) {
        final orderSubmission = _FakeOrderSubmissionService(sentToPosResult);
        final payment = _FakePaymentService()
          ..onStartCheckout = (orderId) async => throw const PaymentServiceException('boom');
        final controller = buildController(orderSubmission: orderSubmission, payment: payment);
        controller.state = controller.state.copyWith(order: order);

        controller.confirmOrder();
        async.flushMicrotasks();

        expect(controller.state.paymentPhase, PaymentPhase.failed);
        expect(orderSubmission.callCount, 1); // confirmOrder itself never re-runs

        payment.onStartCheckout = (orderId) async =>
            TerminalCheckoutResult(orderId: orderId, checkoutId: 'checkout-2');
        controller.retryPayment();
        async.flushMicrotasks();

        expect(orderSubmission.callCount, 1); // still just the one canonical order
        expect(payment.startCheckoutOrderIds, ['order-1', 'order-1']);
        expect(controller.state.paymentPhase, PaymentPhase.awaitingPayment);
      });
    });
  });

  group('dispose', () {
    test('cancels the poll timer — no further checkPayment calls after dispose', () {
      fakeAsync((async) {
        final orderSubmission = _FakeOrderSubmissionService(sentToPosResult);
        final payment = _FakePaymentService();
        final controller = buildController(orderSubmission: orderSubmission, payment: payment);
        controller.state = controller.state.copyWith(order: order);

        controller.confirmOrder();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
        final callsBeforeDispose = payment.checkPaymentCallCount;
        expect(callsBeforeDispose, greaterThan(0));

        controller.dispose();
        async.elapse(const Duration(seconds: 30));

        expect(payment.checkPaymentCallCount, callsBeforeDispose);
      });
    });
  });
}
