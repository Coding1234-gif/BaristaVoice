import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Thin wrapper around `speech_to_text` (native STT on iOS/Android, Web
/// Speech API on web) so the rest of the app depends on a small interface
/// instead of the plugin directly.
class SpeechService {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isInitialized = false;

  Future<bool> initialize({
    required void Function(String status) onStatus,
    required void Function(String error) onError,
  }) async {
    if (_isInitialized) return true;
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

  Future<void> startListening({
    required void Function(String text, bool isFinal) onResult,
    Duration listenFor = const Duration(seconds: 12),
    Duration? pauseFor,
  }) async {
    pauseFor ??= kIsWeb ? _webPauseFor : _nativePauseFor;
    await _speech.listen(
      onResult: (result) {
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
        pauseFor: pauseFor,
      ),
    );
  }

  Future<void> stop() => _speech.stop();

  Future<void> cancel() => _speech.cancel();
}
