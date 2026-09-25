import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Thin wrapper around `speech_to_text` (native STT on iOS/Android, Web
/// Speech API on web) so the rest of the app depends on a small interface
/// instead of the plugin directly.
class SpeechService {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isInitialized = false;

  /// Requests mic/speech permission BEFORE handing off to speech_to_text's
  /// own `initialize()`, rather than letting that call trigger the OS
  /// permission prompt itself. Without this, the very first "Start Order" ->
  /// tap-mic on a fresh install races the permission dialog: initialize()
  /// (and the listen() right after it) can return false/fail while the
  /// prompt is still on screen, so the customer has to tap the mic again
  /// once they've actually granted it — the "had to try 2-3 times" symptom.
  /// `Permission.speech` is the one to request here, not
  /// `Permission.microphone` — the permission_handler docs are explicit that
  /// on iOS this requests actual speech-recognition access (not just mic
  /// access), which is what `speech_to_text` needs there; on Android it's
  /// equivalent to requesting the microphone permission. No-op on web: the
  /// browser handles its own permission prompt synchronously inside the Web
  /// Speech API call, and permission_handler doesn't support web anyway.
  Future<bool> _ensurePermission() async {
    if (kIsWeb) return true;
    final status = await Permission.speech.request();
    return status.isGranted;
  }

  /// True only when the customer has already said "don't allow" once before
  /// — re-requesting won't show the OS prompt again in that case, so the UI
  /// needs a different message pointing them at Settings instead of just
  /// "tap the mic to try again".
  Future<bool> get isPermissionPermanentlyDenied async {
    if (kIsWeb) return false;
    return Permission.speech.isPermanentlyDenied;
  }

  Future<bool> initialize({
    required void Function(String status) onStatus,
    required void Function(String error) onError,
  }) async {
    if (_isInitialized) return true;

    final permitted = await _ensurePermission();
    if (!permitted) return false;

    _isInitialized = await _speech.initialize(
      onStatus: onStatus,
      onError: (error) => onError(error.errorMsg),
    );
    return _isInitialized;
  }

  bool get isAvailable => _isInitialized;
  bool get isListening => _speech.isListening;

  // How long the recognizer waits in silence before treating the utterance
  // as finished. Implemented entirely in the `speech_to_text` package's
  // shared Dart layer (speech_to_text.dart's _setupListenAndPause/
  // _stopOnPauseOrListen) — NOT per-platform — so it applies identically on
  // web: a timer resets on every distinct interim result and calls stop()
  // once it elapses with no new one.
  //
  // Native platforms recognize locally (or with a fast, low-latency cloud
  // round-trip) and emit interim results in a steady stream as the user
  // speaks, so a short pause reliably means "the customer paused" rather
  // than "the recognizer is still working." The web backend (Chrome's Web
  // Speech API) is materially slower and chunkier — interim results can be
  // seconds apart even while the customer is actively mid-sentence — so the
  // same short pause fires on ordinary recognition latency, not a real
  // pause, and cuts the order off almost immediately (confirmed via
  // [speech] debug logs: `pauseFor` elapsing ~1.3s after only an initial
  // empty interim result, well before the customer finished speaking).
  static const Duration _nativePauseFor = Duration(milliseconds: 1300);
  static const Duration _webPauseFor = Duration(milliseconds: 3500);

  // speech_to_text starts the `pauseFor` countdown the moment listening
  // begins, not when the customer starts talking — so with the 1.3s native
  // pause, anyone who took longer than ~1.3s to start speaking (or a
  // recognizer slow to emit its first partial, e.g. the Android emulator's)
  // was cut off with "I didn't catch anything" before saying a word
  // (confirmed 2026-09-24 via `dumpsys audio`: every recognizer session
  // lasted 1.0-1.3s while Google Assistant on the same emulator worked).
  // So allow a long silence before the first words, then tighten to the
  // normal end-of-utterance pause via `changePauseFor` once speech arrives.
  static const Duration _initialPauseFor = Duration(seconds: 6);

  Future<void> startListening({
    required void Function(String text, bool isFinal) onResult,
    Duration listenFor = const Duration(seconds: 12),
    Duration? pauseFor,
  }) async {
    final speakingPauseFor = pauseFor ?? (kIsWeb ? _webPauseFor : _nativePauseFor);
    final initialPauseFor =
        speakingPauseFor > _initialPauseFor ? speakingPauseFor : _initialPauseFor;
    var heardSpeech = false;
    await _speech.listen(
      onResult: (result) {
        if (!heardSpeech && result.recognizedWords.trim().isNotEmpty) {
          heardSpeech = true;
          if (_speech.isListening) _speech.changePauseFor(speakingPauseFor);
        }
        onResult(result.recognizedWords, result.finalResult);
      },
      listenOptions: stt.SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        // `dictation`, not `confirmation`: a café order is a full sentence
        // ("a large oat milk latte with an extra shot"), not a short
        // yes/no/maybe. `confirmation` biases the recognizer's endpointing
        // toward short utterances, which was cutting orders off or
        // mis-hearing them mid-sentence.
        listenMode: stt.ListenMode.dictation,
        listenFor: listenFor,
        pauseFor: initialPauseFor,
      ),
    );
  }

  Future<void> stop() => _speech.stop();

  Future<void> cancel() => _speech.cancel();
}
