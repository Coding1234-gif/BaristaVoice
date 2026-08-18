import 'dart:typed_data';

/// Thrown for any TTS failure — empty text, missing server configuration,
/// provider errors, rate limits, or network failures. [message] is safe to
/// show to the user or log; it never contains the ElevenLabs API key.
class TtsException implements Exception {
  final String message;
  const TtsException(this.message);

  @override
  String toString() => 'TtsException: $message';
}

/// Converts text to spoken audio via the `tts-speak` Supabase Edge Function.
/// The ElevenLabs API key never reaches the client — only the server-side
/// function holds it.
abstract class TtsService {
  /// Synthesizes [text] and returns the raw audio bytes (MP3).
  ///
  /// Throws [TtsException] for empty text, missing server configuration,
  /// provider errors (including rate limiting), or network failures.
  Future<Uint8List> textToSpeech(String text);
}
