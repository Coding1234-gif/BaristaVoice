import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/agent/conversation_turn.dart';
import '../data/agent/order_agent_service.dart';
import '../data/agent/order_confirmation_speech.dart';
import '../data/speech/speech_service.dart';
import '../models/menu.dart';
import '../models/order.dart';
import 'cafe_providers.dart';
import 'providers.dart';
import 'tts_playback_controller.dart';

enum ListeningStatus { idle, listening, thinking }

class KioskState {
  final ListeningStatus listeningStatus;
  final String liveTranscript;
  final Order order;
  final List<ConversationTurn> history;
  final String? assistantReply;
  final String? errorMessage;

  /// Whether the customer has tapped "Start Order" yet. That first tap is
  /// what lets [KioskController.startOrder] spend a user gesture unlocking
  /// autoplay (see `TtsPlaybackController.unlockAudio`) — before that, the
  /// UI shows the start screen instead of the ordering flow.
  final bool audioUnlocked;

  /// True while the deterministic order-confirmation summary is being
  /// spoken/shown and the customer hasn't said yes/no to it yet.
  final bool isReviewingOrder;

  const KioskState({
    this.listeningStatus = ListeningStatus.idle,
    this.liveTranscript = '',
    this.order = const Order(),
    this.history = const [],
    this.assistantReply,
    this.errorMessage,
    this.audioUnlocked = false,
    this.isReviewingOrder = false,
  });

  KioskState copyWith({
    ListeningStatus? listeningStatus,
    String? liveTranscript,
    Order? order,
    List<ConversationTurn>? history,
    String? assistantReply,
    String? errorMessage,
    bool clearError = false,
    bool? audioUnlocked,
    bool? isReviewingOrder,
  }) {
    return KioskState(
      listeningStatus: listeningStatus ?? this.listeningStatus,
      liveTranscript: liveTranscript ?? this.liveTranscript,
      order: order ?? this.order,
      history: history ?? this.history,
      assistantReply: assistantReply ?? this.assistantReply,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      audioUnlocked: audioUnlocked ?? this.audioUnlocked,
      isReviewingOrder: isReviewingOrder ?? this.isReviewingOrder,
    );
  }
}

/// Drives the conversational ordering loop: mic -> transcript -> agent ->
/// updated order state. The structured [Order] is always what's rendered;
/// conversation text is only ever a means to change it.
///
/// Also owns when the AI *speaks*: every reply auto-plays through
/// [TtsPlaybackController] as soon as it arrives (see [_submitTranscript]),
/// and starting to listen again always interrupts whatever is currently
/// playing first (see [startListening]) — that's the app's barge-in: tap
/// the mic while the AI is mid-sentence and it stops immediately.
class KioskController extends StateNotifier<KioskState> {
  final SpeechService _speech;
  final OrderAgentService _agent;
  final TtsPlaybackController _tts;
  final CafeMenu _menu;
  final String _cafeId;

  static const int _maxHistoryTurns = 12;

  KioskController(this._speech, this._agent, this._tts, this._menu, this._cafeId)
      : super(const KioskState());

  /// Spends the "Start Order" tap's user gesture on unlocking audio
  /// playback (see `TtsPlaybackController.unlockAudio`), then reveals the
  /// normal ordering UI. Safe to call more than once — only the first call
  /// does anything.
  Future<void> startOrder() async {
    if (state.audioUnlocked) return;
    await _tts.unlockAudio();
    state = state.copyWith(audioUnlocked: true);
  }

  Future<void> startListening() async {
    if (state.listeningStatus != ListeningStatus.idle) return;

    // Barge-in: tapping the mic while the AI is speaking (or about to
    // speak) means "stop talking, I have something to say" — interrupt
    // whatever TTS is doing before anything else.
    await _tts.stop();

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
      isReviewingOrder: false,
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

      // Auto-play: the customer never has to press play for a normal
      // reply. Not awaited — speech happens in the background while the
      // rest of the UI (order summary, transcript) is already updated.
      unawaited(_tts.speak(result.reply));
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

  /// Starts the confirm step: speaks a summary built directly from the
  /// structured order (never from LLM text, so it can't disagree with what's
  /// on screen) and waits for an explicit yes/no — see [confirmOrder] and
  /// [cancelOrderReview].
  void beginOrderReview() {
    if (state.order.isEmpty || state.isReviewingOrder) return;
    state = state.copyWith(isReviewingOrder: true);
    unawaited(_tts.speak(buildOrderConfirmationSpeech(state.order, _menu)));
  }

  /// Customer said "no" / tapped "keep editing" — back to normal ordering,
  /// order state untouched.
  void cancelOrderReview() {
    if (!state.isReviewingOrder) return;
    state = state.copyWith(isReviewingOrder: false);
  }

  /// Customer said "yes" / tapped "confirm" — only now does the order
  /// actually become final.
  void confirmOrder() {
    state = state.copyWith(
      order: state.order.copyWith(status: OrderStatus.confirmed),
      isReviewingOrder: false,
    );
    unawaited(_tts.speak("Great, that's confirmed! We'll get started on it right away."));
  }

  void resetOrder() {
    state = const KioskState();
  }
}

/// What the customer should understand is happening right now, combining
/// the conversational state above with TTS playback state — the UI's single
/// source of truth for the Listening/Thinking/Speaking indicator.
enum KioskPhase { idle, listening, thinking, speaking }

final kioskPhaseProvider = Provider<KioskPhase>((ref) {
  final listeningStatus = ref.watch(kioskControllerProvider).listeningStatus;
  if (listeningStatus == ListeningStatus.listening) return KioskPhase.listening;
  if (listeningStatus == ListeningStatus.thinking) return KioskPhase.thinking;

  final ttsStatus = ref.watch(ttsPlaybackControllerProvider).status;
  if (ttsStatus == TtsPlaybackStatus.speaking ||
      ttsStatus == TtsPlaybackStatus.loading ||
      ttsStatus == TtsPlaybackStatus.blocked) {
    return KioskPhase.speaking;
  }

  return KioskPhase.idle;
});

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
    ref.watch(ttsPlaybackControllerProvider.notifier),
    menu,
    cafeId,
  );
});
