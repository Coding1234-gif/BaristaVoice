import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/agent/conversation_turn.dart';
import '../data/agent/order_agent_service.dart';
import '../data/agent/order_confirmation_speech.dart';
import '../data/order/order_submission_service.dart';
import '../data/payment/payment_service.dart';
import '../data/speech/speech_service.dart';
import '../models/menu.dart';
import '../models/order.dart';
import 'cafe_providers.dart';
import 'providers.dart';
import 'tts_playback_controller.dart';

const _uuid = Uuid();

enum ListeningStatus { idle, listening, thinking }

/// Where a confirmed order is in the POS-payment leg of the flow, once
/// `create-order` has already reported the order reached Square
/// (`sentToPos`). Deliberately separate from the local, pre-confirm
/// [OrderStatus] enum on [Order] — that one is about the cart itself before
/// confirmation; this one is the richer backend payment state, driven by
/// `pos-square-terminal-checkout`/`pos-square-order-pay`.
enum PaymentPhase {
  /// No payment leg in progress — either nothing's been confirmed yet, or
  /// the confirmed order never reached Square (see `posStatus` handling in
  /// [KioskController.confirmOrder]).
  none,

  /// [KioskController._beginPayment] is calling `pos-square-terminal-checkout`.
  startingCheckout,

  /// The Terminal checkout started; [KioskController] is polling
  /// `pos-square-order-pay` for the customer to complete payment.
  awaitingPayment,

  /// `pos-square-order-pay` confirmed the payment captured.
  paid,

  /// Starting the checkout failed, a poll returned a hard failure, or
  /// polling timed out without a payment. [KioskState.paymentError] carries
  /// the customer-safe reason. Recoverable via [KioskController.retryPayment]
  /// — retrying reuses the same canonical order, never creates a new one.
  failed,
}

class KioskState {
  final ListeningStatus listeningStatus;
  final String liveTranscript;
  final Order order;
  final List<ConversationTurn> history;
  final String? assistantReply;
  final String? errorMessage;

  /// IDs of menu items the latest assistant reply is actually about — drives
  /// the informational item cards shown below the conversation panel (see
  /// MentionedItemsStrip). Empty when the reply wasn't about any specific
  /// item(s), e.g. a clarifying question. Display-only: this never feeds
  /// [order], which only changes through the agent's own order result.
  /// Replaced by every agent reply, cleared when a deterministic message
  /// takes over the transcript (see [KioskController._say]) and by
  /// [KioskController.resetOrder].
  final List<String> mentionedItemIds;

  /// Whether the customer has tapped "Start Order" yet. That first tap is
  /// what lets [KioskController.startOrder] spend a user gesture unlocking
  /// autoplay (see `TtsPlaybackController.unlockAudio`) — before that, the
  /// UI shows the start screen instead of the ordering flow.
  final bool audioUnlocked;

  /// True while the deterministic order-confirmation summary is being
  /// spoken/shown and the customer hasn't said yes/no to it yet.
  final bool isReviewingOrder;

  /// True from the moment "Yes, confirm" is tapped until the server-side
  /// create-order call (see [KioskController.confirmOrder]) resolves either
  /// way. Drives the confirm button's loading state and blocks a second,
  /// overlapping submit.
  final bool isSubmittingOrder;

  /// Set once the server has actually created the canonical order. Null
  /// beforehand and on failure — this is the one thing in [KioskState] that
  /// reflects real backend state rather than optimistic local state.
  final String? confirmedOrderId;

  /// Generated the first time [KioskController.confirmOrder] is called for
  /// the current order and reused on every retry of that same confirm
  /// attempt, so a retry after a dropped/timed-out response is safe — the
  /// server's idempotency_key handling (see create_canonical_order() in
  /// schema.sql) turns a retry into "return the order already created"
  /// rather than a duplicate.
  final String? pendingIdempotencyKey;

  /// Where the POS-payment leg is for [confirmedOrderId] — see
  /// [PaymentPhase]. Stays [PaymentPhase.none] for any order that never
  /// reached Square in the first place.
  final PaymentPhase paymentPhase;

  /// Customer-safe reason the payment leg failed — set only alongside
  /// [PaymentPhase.failed]. Never a raw Square/Supabase error (see
  /// [PaymentServiceException]).
  final String? paymentError;

  const KioskState({
    this.listeningStatus = ListeningStatus.idle,
    this.liveTranscript = '',
    this.order = const Order(),
    this.history = const [],
    this.assistantReply,
    this.errorMessage,
    this.mentionedItemIds = const [],
    this.audioUnlocked = false,
    this.isReviewingOrder = false,
    this.isSubmittingOrder = false,
    this.confirmedOrderId,
    this.pendingIdempotencyKey,
    this.paymentPhase = PaymentPhase.none,
    this.paymentError,
  });

  KioskState copyWith({
    ListeningStatus? listeningStatus,
    String? liveTranscript,
    Order? order,
    List<ConversationTurn>? history,
    String? assistantReply,
    String? errorMessage,
    bool clearError = false,
    List<String>? mentionedItemIds,
    bool? audioUnlocked,
    bool? isReviewingOrder,
    bool? isSubmittingOrder,
    String? confirmedOrderId,
    String? pendingIdempotencyKey,
    PaymentPhase? paymentPhase,
    String? paymentError,
    bool clearPaymentError = false,
  }) {
    return KioskState(
      listeningStatus: listeningStatus ?? this.listeningStatus,
      liveTranscript: liveTranscript ?? this.liveTranscript,
      order: order ?? this.order,
      history: history ?? this.history,
      assistantReply: assistantReply ?? this.assistantReply,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      mentionedItemIds: mentionedItemIds ?? this.mentionedItemIds,
      audioUnlocked: audioUnlocked ?? this.audioUnlocked,
      isReviewingOrder: isReviewingOrder ?? this.isReviewingOrder,
      isSubmittingOrder: isSubmittingOrder ?? this.isSubmittingOrder,
      confirmedOrderId: confirmedOrderId ?? this.confirmedOrderId,
      pendingIdempotencyKey: pendingIdempotencyKey ?? this.pendingIdempotencyKey,
      paymentPhase: paymentPhase ?? this.paymentPhase,
      paymentError: clearPaymentError ? null : (paymentError ?? this.paymentError),
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
  final OrderSubmissionService _orderSubmission;
  final PaymentService _payment;
  final CafeMenu _menu;
  final String _cafeId;

  static const int _maxHistoryTurns = 12;

  /// ~90s of polling at a 2s interval — long enough for a customer to
  /// tap/insert/approve a card on the Terminal without feeling rushed,
  /// short enough that the kiosk never looks hung if nobody pays.
  static const int _paymentPollMaxAttempts = 45;
  static const Duration _paymentPollInterval = Duration(seconds: 2);

  Timer? _paymentPollTimer;

  KioskController(
    this._speech,
    this._agent,
    this._tts,
    this._orderSubmission,
    this._payment,
    this._menu,
    this._cafeId,
  ) : super(const KioskState());

  /// Speaks `text` AND shows it as the "Barista" line in [ConversationPanel]
  /// — unlike an LLM turn (see `_submitTranscript`), every deterministic
  /// message in this controller (order confirmed, payment prompts, errors)
  /// used to only call `_tts.speak()` directly, so it played as audio but
  /// never appeared on screen (confirmed live 2026-09-18: "Great! We'll get
  /// started on that right away" was heard but never shown). Every such
  /// message must go through this instead of calling `_tts.speak` directly.
  void _say(String text) {
    // The item cards belong to the reply they were returned with; once a
    // different message (order review, payment prompt, ...) replaces it in
    // the transcript they would be describing a line that's no longer there.
    state = state.copyWith(assistantReply: text, mentionedItemIds: const []);
    unawaited(_tts.speak(text));
  }

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
      onStatus: (status) {
        debugPrint('[speech] status: $status');
        // The recognizer can end (`notListening`, then `done`) without ever
        // firing `onResult` with isFinal=true — expected, not a bug, on the
        // web backend specifically: the underlying speech_to_text plugin's
        // web implementation never marks a Web Speech API result as final
        // (see speech_to_text_web.dart's _onResult, which hardcodes
        // ResultType.partial), so `isFinal` is simply never true there, no
        // matter what was actually said.
        //
        // So: whatever the last partial transcript was IS the customer's
        // utterance — submit it ourselves rather than discarding it. Only
        // fall back to "I didn't catch anything" when nothing was
        // transcribed at all (genuine silence/misfire).
        if ((status == 'notListening' || status == 'done') &&
            state.listeningStatus == ListeningStatus.listening) {
          final captured = state.liveTranscript.trim();
          if (captured.isNotEmpty) {
            _submitTranscript(captured);
          } else {
            state = state.copyWith(
              listeningStatus: ListeningStatus.idle,
              errorMessage: "I didn't catch anything. Tap the mic to try again.",
            );
          }
        }
      },
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
      final permanentlyDenied = await _speech.isPermissionPermanentlyDenied;
      state = state.copyWith(
        errorMessage: permanentlyDenied
            ? 'Microphone access is turned off for this app. Enable it in your device Settings to order by voice.'
            : 'Speech recognition is not available on this device.',
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
        // The web backend can fire a LATE, synthesized "final" result (see
        // speech_to_text.dart's _onFinalTimeout, ~2s after the recognizer
        // already stopped) — after the `onStatus` handler above has
        // already submitted whatever was captured at end-of-listening.
        // Without this guard, that late event would submit the SAME
        // utterance a second time: two concurrent agent turns, two
        // `_tts.speak()` calls interrupting each other, and two
        // assistantReply/liveTranscript writes racing to update the UI —
        // exactly the "says two things and interrupts itself" symptom.
        // Once we've moved off `listening` (submitted, errored, or
        // recovered), no further result event may act.
        if (state.listeningStatus != ListeningStatus.listening) return;
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
    // Flip away from `listening` *before* stopping the recognizer: `stop()`
    // itself commonly fires a trailing status/error event (e.g. the web
    // Speech API backend emits a stray "aborted"/no-match error as it winds
    // down), and the `onError` guard in `startListening` only ignores that
    // event if `listeningStatus` has already moved off `listening` by the
    // time it arrives. Stopping first left a window where a good transcript
    // could be clobbered by that trailing error right after being captured.
    final customerTurn = ConversationTurn(role: SpeakerRole.customer, text: transcript);
    state = state.copyWith(
      listeningStatus: ListeningStatus.thinking,
      history: [...state.history, customerTurn],
      clearError: true,
    );

    await _speech.stop();

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
        mentionedItemIds: result.mentionedItemIds,
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
        mentionedItemIds: const [],
      );
    }
  }

  /// Same pipeline as a spoken utterance, for the typed-text fallback (see
  /// KioskScreen's input mode toggle) — `_submitTranscript` doesn't care
  /// where the text came from.
  Future<void> submitTypedText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || state.listeningStatus != ListeningStatus.idle) return;
    await _submitTranscript(trimmed);
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
    _say(buildOrderConfirmationSpeech(state.order, _menu));
  }

  /// Customer said "no" / tapped "keep editing" — back to normal ordering,
  /// order state untouched.
  void cancelOrderReview() {
    if (!state.isReviewingOrder) return;
    state = state.copyWith(isReviewingOrder: false);
  }

  /// Customer said "yes" / tapped "confirm" — creates the canonical order
  /// server-side (validated and priced entirely from the database's own
  /// menu data, never from anything this client sends — see
  /// create_canonical_order() in schema.sql) and, if that succeeds, the
  /// server automatically attempts POS submission. Only a server response
  /// makes the order final; nothing here is optimistic. Safe to call again
  /// after a failure — the same idempotency key is reused, so a retry can
  /// never create a duplicate order.
  Future<void> confirmOrder() async {
    if (state.order.isEmpty || state.isSubmittingOrder || state.paymentPhase != PaymentPhase.none) {
      return;
    }

    final idempotencyKey = state.pendingIdempotencyKey ?? _uuid.v4();
    state = state.copyWith(
      isSubmittingOrder: true,
      pendingIdempotencyKey: idempotencyKey,
      clearError: true,
    );

    try {
      final result = await _orderSubmission.submitOrder(
        cafeId: _cafeId,
        idempotencyKey: idempotencyKey,
        order: state.order,
      );

      state = state.copyWith(
        order: state.order.copyWith(status: OrderStatus.confirmed),
        isReviewingOrder: false,
        isSubmittingOrder: false,
        confirmedOrderId: result.orderId,
      );

      // Only an order that genuinely reached Square has a payment leg to
      // run — anything else (no POS connection, pos_failed, ...) is still
      // a safely confirmed order, just with nothing further to pay here.
      if (result.sentToPos) {
        unawaited(_beginPayment(result.orderId));
      } else {
        _say(buildOrderConfirmedSpeech(result.posStatus));
      }
    } catch (_) {
      // The order was NOT created — leave the order itself untouched (still
      // editable) so the customer can simply tap confirm again, reusing the
      // same idempotency key above.
      state = state.copyWith(
        isSubmittingOrder: false,
        isReviewingOrder: false,
        errorMessage: orderConfirmationFailedSpeech,
      );
      _say(orderConfirmationFailedSpeech);
    }
  }

  /// Starts (or re-starts, via [retryPayment]) the Terminal-checkout leg for
  /// an order that has already reached Square. Guarded so a duplicate call
  /// while one is already in flight is a no-op — `pos-square-terminal-checkout`
  /// is additionally idempotent server-side (deterministic idempotency key),
  /// so even a race here can never start two checkouts.
  Future<void> _beginPayment(String orderId) async {
    if (state.paymentPhase == PaymentPhase.startingCheckout ||
        state.paymentPhase == PaymentPhase.awaitingPayment) {
      return;
    }

    _paymentPollTimer?.cancel();
    state = state.copyWith(paymentPhase: PaymentPhase.startingCheckout, clearPaymentError: true);

    try {
      await _payment.startTerminalCheckout(orderId: orderId);
    } catch (e) {
      final message = e is PaymentServiceException
          ? e.message
          : 'Could not start payment. Please try again.';
      state = state.copyWith(paymentPhase: PaymentPhase.failed, paymentError: message);
      _say(buildPaymentFailedSpeech(message));
      return;
    }

    state = state.copyWith(paymentPhase: PaymentPhase.awaitingPayment);
    _say(paymentPendingSpeech);
    _startPollingForPayment(orderId);
  }

  /// Polls `pos-square-order-pay` (via [_payment]) until it reports the
  /// payment captured, a hard failure, or the attempt budget runs out.
  /// Every exit path cancels [_paymentPollTimer] first — this must never be
  /// left running once the controller has moved past [PaymentPhase.awaitingPayment].
  void _startPollingForPayment(String orderId) {
    var attempts = 0;
    _paymentPollTimer = Timer.periodic(_paymentPollInterval, (timer) async {
      attempts++;

      final PaymentPollResult result;
      try {
        result = await _payment.checkPayment(orderId: orderId);
      } catch (e) {
        timer.cancel();
        final message = e is PaymentServiceException
            ? e.message
            : 'Could not confirm payment. Please try again.';
        state = state.copyWith(paymentPhase: PaymentPhase.failed, paymentError: message);
        _say(buildPaymentFailedSpeech(message));
        return;
      }

      if (result.paid) {
        timer.cancel();
        state = state.copyWith(paymentPhase: PaymentPhase.paid);
        _say(paymentSucceededSpeech);
        return;
      }

      if (attempts >= _paymentPollMaxAttempts) {
        timer.cancel();
        const message = 'That took too long. Please try again.';
        state = state.copyWith(paymentPhase: PaymentPhase.failed, paymentError: message);
        _say(buildPaymentFailedSpeech(message));
      }
    });
  }

  /// Customer tapped "Try Again" after [PaymentPhase.failed]. Re-runs the
  /// checkout on the SAME canonical order (same order id, same deterministic
  /// idempotency key server-side) — never creates a second order.
  Future<void> retryPayment() async {
    final orderId = state.confirmedOrderId;
    if (orderId == null || state.paymentPhase != PaymentPhase.failed) return;
    unawaited(_beginPayment(orderId));
  }

  void resetOrder() {
    _paymentPollTimer?.cancel();
    state = const KioskState();
  }

  @override
  void dispose() {
    _paymentPollTimer?.cancel();
    super.dispose();
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
    ref.watch(orderSubmissionServiceProvider),
    ref.watch(paymentServiceProvider),
    menu,
    cafeId,
  );
});
