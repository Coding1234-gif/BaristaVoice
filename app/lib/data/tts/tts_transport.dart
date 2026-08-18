import 'package:supabase_flutter/supabase_flutter.dart';

/// Raw result of calling the `tts-speak` edge function, before
/// [ElevenLabsTtsService] (see `elevenlabs_tts_service.dart`) turns it into
/// bytes or a `TtsException`. Kept as its own seam so the service can be
/// unit tested with a hand-rolled fake instead of a real [SupabaseClient].
class TtsTransportResult {
  final int status;
  final Object? data;

  const TtsTransportResult({required this.status, required this.data});
}

abstract class TtsTransport {
  Future<TtsTransportResult> invoke(String text);
}

/// Calls the `tts-speak` edge function the same way [LlmOrderAgentService]
/// calls `order-agent` — through the Supabase client, which attaches the
/// project's auth headers. The function responds with
/// `application/octet-stream` on success, which the Supabase functions
/// client hands back as raw bytes (`Uint8List`) rather than decoding it.
///
/// No voice id is ever sent — the café's voice is a server-side secret
/// (`ELEVENLABS_VOICE_ID`), not something a client call can override.
class SupabaseTtsTransport implements TtsTransport {
  final SupabaseClient _client;

  SupabaseTtsTransport(this._client);

  @override
  Future<TtsTransportResult> invoke(String text) async {
    try {
      final response = await _client.functions.invoke(
        'tts-speak',
        body: {'text': text},
      );
      return TtsTransportResult(status: response.status, data: response.data);
    } on FunctionException catch (e) {
      return TtsTransportResult(status: e.status, data: e.details);
    }
  }
}
