import 'dart:typed_data';

import 'tts_service.dart';
import 'tts_transport.dart';

/// Calls the `tts-speak` Supabase Edge Function, which holds the ElevenLabs
/// API key server-side and does the actual synthesis call. The client never
/// talks to ElevenLabs directly and doesn't need to know which voice is
/// configured — that's the `ELEVENLABS_VOICE_ID` secret on the server, and
/// the server never accepts a client-supplied override.
class ElevenLabsTtsService implements TtsService {
  final TtsTransport _transport;

  ElevenLabsTtsService(this._transport);

  @override
  Future<Uint8List> textToSpeech(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const TtsException('There is no text to speak.');
    }

    final result = await _transport.invoke(trimmed);

    if (result.status == 200 && result.data is Uint8List) {
      final bytes = result.data as Uint8List;
      if (bytes.isEmpty) {
        throw const TtsException('The speech service returned no audio.');
      }
      return bytes;
    }

    throw TtsException(_messageFor(result));
  }

  String _messageFor(TtsTransportResult result) {
    final data = result.data;
    if (data is Map && data['error'] is String) {
      return data['error'] as String;
    }
    if (result.status == 0) {
      return 'Could not reach the speech service. Check your connection.';
    }
    if (result.status == 429) {
      return 'The speech service is rate limited right now. Try again shortly.';
    }
    return 'The speech service failed (status ${result.status}).';
  }
}
