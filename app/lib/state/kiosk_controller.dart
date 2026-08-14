import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/agent/conversation_turn.dart';
import '../data/agent/order_agent_service.dart';
import '../data/speech/speech_service.dart';
import '../models/menu.dart';
import '../models/order.dart';
import 'cafe_providers.dart';
import 'providers.dart';

enum ListeningStatus { idle, listening, thinking }

class KioskState {
  final ListeningStatus listeningStatus;
  final String liveTranscript;
  final Order order;
  final List<ConversationTurn> history;
  final String? assistantReply;
  final String? errorMessage;

  const KioskState({
    this.listeningStatus = ListeningStatus.idle,
    this.liveTranscript = '',
    this.order = const Order(),
    this.history = const [],
    this.assistantReply,
    this.errorMessage,
  });

  KioskState copyWith({
    ListeningStatus? listeningStatus,
    String? liveTranscript,
    Order? order,
    List<ConversationTurn>? history,
    String? assistantReply,
    String? errorMessage,
    bool clearError = false,
  }) {
    return KioskState(
      listeningStatus: listeningStatus ?? this.listeningStatus,
      liveTranscript: liveTranscript ?? this.liveTranscript,
      order: order ?? this.order,
      history: history ?? this.history,
      assistantReply: assistantReply ?? this.assistantReply,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// Drives the conversational ordering loop: mic -> transcript -> agent ->
/// updated order state. The structured [Order] is always what's rendered;
/// conversation text is only ever a means to change it.
class KioskController extends StateNotifier<KioskState> {
  final SpeechService _speech;
  final OrderAgentService _agent;
  final CafeMenu _menu;
  final String _cafeId;

  static const int _maxHistoryTurns = 12;

  KioskController(this._speech, this._agent, this._menu, this._cafeId)
      : super(const KioskState());

  Future<void> startListening() async {
    if (state.listeningStatus != ListeningStatus.idle) return;

    final available = await _speech.initialize(
      onStatus: (status) => debugPrint('[speech] status: $status'),
      onError: (error) {
        debugPrint('[speech] error: $error');
        // Stopping recognition after a final result can itself emit a
        // trailing error event (e.g. "aborted") on some platforms. Once
        // we've moved past the listening phase, a real reply is already in
        // flight or has landed — a stray error here must not clobber it.
        if (state.listeningStatus != ListeningStatus.listening) return;
        state = state.copyWith(
          listeningStatus: ListeningStatus.idle,
          errorMessage: "Sorry, I didn't quite catch that. Could you say that again?",
        );
      },
    );

    if (!available) {
      state = state.copyWith(
        errorMessage: 'Speech recognition is not available on this device.',
      );
      return;
    }

    state = state.copyWith(
      listeningStatus: ListeningStatus.listening,
      liveTranscript: '',
      clearError: true,
    );

    await _speech.startListening(
      onResult: (text, isFinal) {
        debugPrint('[speech] result: "$text" isFinal=$isFinal');
        state = state.copyWith(liveTranscript: text);
        if (isFinal && text.trim().isNotEmpty) {
          _submitTranscript(text.trim());
        }
      },
    );
  }

  Future<void> stopListening() async {
    await _speech.stop();
    if (state.listeningStatus == ListeningStatus.listening) {
      state = state.copyWith(listeningStatus: ListeningStatus.idle);
    }
  }

  Future<void> _submitTranscript(String transcript) async {
    await _speech.stop();

    final customerTurn = ConversationTurn(role: SpeakerRole.customer, text: transcript);
    state = state.copyWith(
      listeningStatus: ListeningStatus.thinking,
      history: [...state.history, customerTurn],
      clearError: true,
    );

    try {
      final result = await _agent.interpret(
        cafeId: _cafeId,
        transcript: transcript,
        currentOrder: state.order,
        menu: _menu,
        history: _recentHistory(),
      );

      final assistantTurn = ConversationTurn(role: SpeakerRole.assistant, text: result.reply);
      state = state.copyWith(
        listeningStatus: ListeningStatus.idle,
        order: result.order,
        assistantReply: result.reply,
        history: [...state.history, assistantTurn],
      );
    } catch (_) {
      state = state.copyWith(
        listeningStatus: ListeningStatus.idle,
        errorMessage:
            "Sorry, something went wrong understanding that. Could you try again?",
      );
    }
  }

  List<ConversationTurn> _recentHistory() {
    final h = state.history;
    if (h.length <= _maxHistoryTurns) return h;
    return h.sublist(h.length - _maxHistoryTurns);
  }

  void confirmOrder() {
    state = state.copyWith(order: state.order.copyWith(status: OrderStatus.confirmed));
  }

  void resetOrder() {
    state = const KioskState();
  }
}

/// Only ever mounted by KioskScreen once a café is selected and its menu has
/// loaded (see _KioskBody) — cafeId/menu here reflect whatever was current
/// at that point, and Riverpod rebuilds this (fresh controller, fresh state)
/// whenever currentCafeIdProvider changes, e.g. on "Change café".
final kioskControllerProvider =
    StateNotifierProvider<KioskController, KioskState>((ref) {
  final cafeId = ref.watch(currentCafeIdProvider) ?? '';
  final menuAsync = ref.watch(activeMenuProvider);
  final menu = menuAsync.value ?? const CafeMenu(cafeName: '', items: []);
  return KioskController(
    ref.watch(speechServiceProvider),
    ref.watch(orderAgentServiceProvider),
    menu,
    cafeId,
  );
});
