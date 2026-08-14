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

  Future<void> startListening({
    required void Function(String text, bool isFinal) onResult,
    Duration listenFor = const Duration(seconds: 12),
    Duration pauseFor = const Duration(seconds: 3),
  }) async {
    await _speech.listen(
      onResult: (result) {
        onResult(result.recognizedWords, result.finalResult);
      },
      listenOptions: stt.SpeechListenOptions(
        partialResults: true,
        cancelOnError: true,
        listenMode: stt.ListenMode.confirmation,
        listenFor: listenFor,
        pauseFor: pauseFor,
      ),
    );
  }

  Future<void> stop() => _speech.stop();

  Future<void> cancel() => _speech.cancel();
}
