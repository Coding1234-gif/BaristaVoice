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

/// Replays scripted results (or throws scripted exceptions) and records the
/// history and cart each request was sent with.
class _ScriptedAgent implements OrderAgentService {
  final List<Object> script;
  final List<List<String>> historySeen = [];
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
    historySeen.add(history.map((h) => '${h.role.name}: ${h.text}').toList());
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

class _RecordingTts extends TtsPlaybackController {
  final List<String> spoken = [];
  _RecordingTts() : super(_SilentTtsService());

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stop() async {}
}

class _Unused implements OrderSubmissionService, PaymentService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

const _busy = "I'm a little busy right now — give me a few seconds and try that again.";

Order _cartWith(String id) => Order(items: [OrderItem(menuItemId: id, name: id)]);

AgentTurnResult _busyReply({Order order = const Order()}) =>
    AgentTurnResult(reply: _busy, order: order, needsClarification: true, retryable: true);

AgentTurnResult _ok(String reply, {Order order = const Order(), List<String> mentioned = const []}) =>
    AgentTurnResult(reply: reply, order: order, mentionedItemIds: mentioned);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingTts tts;
  KioskController build(_ScriptedAgent agent) => KioskController(
        SpeechService(),
        agent,
        tts = _RecordingTts(),
        _Unused(),
        _Unused(),
        const CafeMenu(cafeName: 'x', items: []),
        'cafe-1',
      );

  group('a turn the server could not answer (retryable)', () {
    test('shows and speaks the message, but keeps the customer\'s cart and leaves history clean', () async {
      final controller = build(_ScriptedAgent([
        _ok('Got it, one latte.', order: _cartWith('latte')),
        // The server hands back an EMPTY order here; the app must not adopt it.
        _busyReply(),
      ]));

      await controller.submitTypedText('a latte');
      await controller.submitTypedText('and a croissant');

      expect(controller.state.assistantReply, _busy);
      expect(tts.spoken.last, _busy);
      expect(controller.state.order.items.single.menuItemId, 'latte', reason: 'cart must survive a failed turn');
      expect(controller.state.listeningStatus, ListeningStatus.idle);
      expect(controller.state.errorMessage, isNull);
      expect(controller.state.mentionedItemIds, isEmpty);
      expect(
        controller.state.history.map((h) => h.text),
        ['a latte', 'Got it, one latte.'],
        reason: 'the failed exchange must not be recorded',
      );
    });

    test('repeated failures do not pile up: the next request carries no trace of them', () async {
      final agent = _ScriptedAgent([
        _busyReply(),
        _busyReply(),
        _busyReply(),
        _ok('One flat white, coming up.', order: _cartWith('flat-white')),
      ]);
      final controller = build(agent);

      for (var i = 0; i < 4; i++) {
        await controller.submitTypedText('a flat white');
      }

      // Every request was sent with an empty history — no stack of unanswered
      // "a flat white" lines and apologies.
      expect(agent.historySeen, everyElement(isEmpty));
      expect(controller.state.order.items.single.menuItemId, 'flat-white');
      expect(controller.state.history.map((h) => h.text), ['a flat white', 'One flat white, coming up.']);
    });

    test('a failure in the middle of a conversation keeps the earlier turns intact', () async {
      final agent = _ScriptedAgent([
        _ok('Hello!'),
        _busyReply(),
        _ok('Sure.'),
      ]);
      final controller = build(agent);

      await controller.submitTypedText('hi');
      await controller.submitTypedText('a latte');
      await controller.submitTypedText('a latte');

      expect(agent.historySeen[1], ['customer: hi', 'assistant: Hello!']);
      expect(agent.historySeen[2], ['customer: hi', 'assistant: Hello!']);
    });
  });

  group('a turn that throws (network error etc.)', () {
    test('keeps the cart, shows the error, and does not leave the failed line in history', () async {
      final agent = _ScriptedAgent([
        _ok('Got it, one latte.', order: _cartWith('latte')),
        Exception('offline'),
        _ok('Added.', order: _cartWith('latte')),
      ]);
      final controller = build(agent);

      await controller.submitTypedText('a latte');
      await controller.submitTypedText('a croissant');

      expect(controller.state.errorMessage, isNotNull);
      expect(controller.state.order.items.single.menuItemId, 'latte');
      expect(controller.state.history.map((h) => h.text), ['a latte', 'Got it, one latte.']);

      await controller.submitTypedText('a croissant');
      expect(agent.historySeen[2], ['customer: a latte', 'assistant: Got it, one latte.']);
    });
  });

  test('a normal reply is recorded and adopted exactly as before', () async {
    final controller = build(_ScriptedAgent([_ok('Got it.', order: _cartWith('latte'))]));
    await controller.submitTypedText('a latte');

    expect(controller.state.order.items.single.menuItemId, 'latte');
    expect(controller.state.history.map((h) => h.text), ['a latte', 'Got it.']);
    expect(tts.spoken, ['Got it.']);
  });
}
