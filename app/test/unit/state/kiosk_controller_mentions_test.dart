import 'dart:typed_data';

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

/// Replays scripted agent replies, one per turn, and records what the
/// controller sent it — so each test can say exactly what the "AI" returned.
class _ScriptedAgent implements OrderAgentService {
  final List<Object> script; // AgentTurnResult, or an Exception to throw
  final List<Order> ordersSeen = [];
  int _next = 0;

  _ScriptedAgent(this.script);

  @override
  Future<AgentTurnResult> interpret({
    required String cafeId,
    required String transcript,
    required Order currentOrder,
    required CafeMenu menu,
    required List<ConversationTurn> history,
  }) async {
    ordersSeen.add(currentOrder);
    final step = script[_next++];
    if (step is Exception) throw step;
    return step as AgentTurnResult;
  }
}

class _SilentTtsService implements TtsService {
  @override
  Future<Uint8List> textToSpeech(String text) async => Uint8List(0);
}

/// Records what would be spoken instead of touching the just_audio platform
/// plugin (which doesn't exist under `flutter test`).
class _RecordingTts extends TtsPlaybackController {
  final List<String> spoken = [];

  _RecordingTts() : super(_SilentTtsService());

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stop() async {}
}

class _NeverCalledOrderSubmission implements OrderSubmissionService {
  @override
  Future<OrderSubmissionResult> submitOrder({
    required String cafeId,
    required String idempotencyKey,
    required Order order,
  }) =>
      throw UnimplementedError();
}

class _NeverCalledPayment implements PaymentService {
  @override
  Future<TerminalCheckoutResult> startTerminalCheckout({required String orderId}) =>
      throw UnimplementedError();

  @override
  Future<PaymentPollResult> checkPayment({required String orderId}) => throw UnimplementedError();
}

const _menu = CafeMenu(cafeName: 'Bean & Bloom', items: [
  MenuItem(id: 'flat-white', name: 'Flat White', description: 'Espresso and silky milk.', category: 'Coffee', basePrice: 3.2),
  MenuItem(id: 'croissant', name: 'Butter Croissant', description: 'Flaky and buttery.', category: 'Food', basePrice: 3.2),
]);

Order _orderOf(List<String> menuItemIds) => Order(
      items: [for (final id in menuItemIds) OrderItem(menuItemId: id, name: id)],
    );

AgentTurnResult _reply(String text, {Order order = const Order(), List<String> mentioned = const []}) =>
    AgentTurnResult(reply: text, order: order, mentionedItemIds: mentioned);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingTts tts;

  KioskController build(_ScriptedAgent agent) => KioskController(
        SpeechService(),
        agent,
        tts = _RecordingTts(),
        _NeverCalledOrderSubmission(),
        _NeverCalledPayment(),
        _menu,
        'cafe-1',
      );

  group('mentioned-item cards — driven by the AI reply, separate from the cart', () {
    test('1. a reply that mentions no product shows no cards', () async {
      final controller = build(_ScriptedAgent([_reply('Sure — what would you like?')]));
      await controller.submitTypedText('hi');

      expect(controller.state.mentionedItemIds, isEmpty);
      expect(controller.state.assistantReply, 'Sure — what would you like?');
    });

    test('13. the reply is still spoken and shown exactly as before, whatever it mentions', () async {
      final controller = build(_ScriptedAgent([
        _reply('The Flat White is lovely.', mentioned: ['flat-white']),
        _reply('Anything else?'),
      ]));

      await controller.submitTypedText('flat white?');
      expect(controller.state.assistantReply, 'The Flat White is lovely.');
      await controller.submitTypedText('no');
      expect(controller.state.assistantReply, 'Anything else?');

      expect(tts.spoken, ['The Flat White is lovely.', 'Anything else?']);
      expect(controller.state.history.map((t) => t.text),
          ['flat white?', 'The Flat White is lovely.', 'no', 'Anything else?']);
    });

    test('2/6. a product that is mentioned but NOT ordered gets a card and leaves the cart empty', () async {
      final controller = build(_ScriptedAgent([
        _reply('Our Flat White is espresso with velvety milk.', mentioned: ['flat-white']),
      ]));
      await controller.submitTypedText('tell me about the flat white');

      expect(controller.state.mentionedItemIds, ['flat-white']);
      expect(controller.state.order.isEmpty, isTrue);
    });

    test('3. a reply mentioning two products keeps both, in order', () async {
      final controller = build(_ScriptedAgent([
        _reply('The Flat White or the Croissant are both popular.', mentioned: ['flat-white', 'croissant']),
      ]));
      await controller.submitTypedText("what's popular?");

      expect(controller.state.mentionedItemIds, ['flat-white', 'croissant']);
    });

    test('7. a product both mentioned AND ordered: the card and the cart are independent', () async {
      final controller = build(_ScriptedAgent([
        _reply('Our Flat White is velvety.', mentioned: ['flat-white']),
        _reply('Got it, one flat white.', order: _orderOf(['flat-white'])),
      ]));

      await controller.submitTypedText('what is a flat white?');
      expect(controller.state.mentionedItemIds, ['flat-white']);
      expect(controller.state.order.isEmpty, isTrue, reason: 'describing something must not order it');

      await controller.submitTypedText("I'll take one");
      expect(controller.state.order.items.single.menuItemId, 'flat-white');
      expect(controller.state.mentionedItemIds, isEmpty, reason: 'a plain confirmation is not a product mention');
    });

    test('8. ordering a product without the AI describing it shows no card, but is in the cart', () async {
      final controller = build(_ScriptedAgent([
        _reply('Got it, one croissant.', order: _orderOf(['croissant'])),
      ]));
      await controller.submitTypedText('one croissant please');

      expect(controller.state.mentionedItemIds, isEmpty);
      expect(controller.state.order.items.single.menuItemId, 'croissant');
    });

    test('9. the same product mentioned on consecutive replies is replaced, never accumulated', () async {
      final controller = build(_ScriptedAgent([
        _reply('The Flat White is lovely.', mentioned: ['flat-white']),
        _reply('Yes, the Flat White really is lovely.', mentioned: ['flat-white']),
      ]));

      await controller.submitTypedText('flat white?');
      await controller.submitTypedText('is it good?');

      expect(controller.state.mentionedItemIds, ['flat-white']);
    });

    test('a later reply about a different product replaces the earlier card', () async {
      final controller = build(_ScriptedAgent([
        _reply('The Flat White is lovely.', mentioned: ['flat-white']),
        _reply('The Croissant is fresh today.', mentioned: ['croissant']),
      ]));

      await controller.submitTypedText('flat white?');
      await controller.submitTypedText('and something to eat?');

      expect(controller.state.mentionedItemIds, ['croissant']);
    });

    test('the agent still receives the real cart — a mention never alters what is sent', () async {
      final agent = _ScriptedAgent([
        _reply('Got it, one croissant.', order: _orderOf(['croissant'])),
        _reply('The Flat White is lovely.', order: _orderOf(['croissant']), mentioned: ['flat-white']),
        _reply('Anything else?', order: _orderOf(['croissant'])),
      ]);
      final controller = build(agent);

      await controller.submitTypedText('a croissant');
      await controller.submitTypedText('tell me about the flat white');
      await controller.submitTypedText('no thanks');

      expect(agent.ordersSeen[1].items.map((i) => i.menuItemId), ['croissant']);
      expect(agent.ordersSeen[2].items.map((i) => i.menuItemId), ['croissant'],
          reason: 'the mention of the flat white must not have leaked into the cart');
    });

    test('10. starting a new conversation clears the cards along with everything else', () async {
      final controller = build(_ScriptedAgent([
        _reply('The Flat White is lovely.', mentioned: ['flat-white']),
      ]));
      await controller.submitTypedText('flat white?');
      expect(controller.state.mentionedItemIds, isNotEmpty);

      controller.resetOrder();

      expect(controller.state.mentionedItemIds, isEmpty);
      expect(controller.state.assistantReply, isNull);
      expect(controller.state.order.isEmpty, isTrue);
    });

    test('an agent error clears stale cards and keeps the cart (existing error handling)', () async {
      final controller = build(_ScriptedAgent([
        _reply('Got it, one croissant.', order: _orderOf(['croissant'])),
        _reply('The Flat White is lovely.', order: _orderOf(['croissant']), mentioned: ['flat-white']),
        Exception('boom'),
      ]));

      await controller.submitTypedText('a croissant');
      await controller.submitTypedText('flat white?');
      expect(controller.state.mentionedItemIds, ['flat-white']);

      await controller.submitTypedText('something');
      expect(controller.state.mentionedItemIds, isEmpty);
      expect(controller.state.errorMessage, isNotNull);
      expect(controller.state.order.items.single.menuItemId, 'croissant');
    });

    test('order review (a deterministic spoken message) clears cards but leaves the cart untouched', () async {
      final controller = build(_ScriptedAgent([
        _reply('The Flat White is lovely.', order: _orderOf(['croissant']), mentioned: ['flat-white']),
      ]));
      await controller.submitTypedText('flat white?');
      expect(controller.state.mentionedItemIds, ['flat-white']);

      controller.beginOrderReview();

      expect(controller.state.isReviewingOrder, isTrue);
      expect(controller.state.mentionedItemIds, isEmpty);
      expect(controller.state.order.items.single.menuItemId, 'croissant');
    });
  });
}
