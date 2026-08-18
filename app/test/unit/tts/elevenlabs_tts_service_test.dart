import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:barista_voice/data/tts/elevenlabs_tts_service.dart';
import 'package:barista_voice/data/tts/tts_service.dart';
import 'package:barista_voice/data/tts/tts_transport.dart';

/// Hand-rolled fake transport — the ElevenLabs API is never called from
/// these tests. Mirrors what `SupabaseTtsTransport` would return for each
/// scenario without touching Supabase or the network.
class _FakeTransport implements TtsTransport {
  final TtsTransportResult Function(String text) respond;
  String? lastText;
  int callCount = 0;

  _FakeTransport(this.respond);

  @override
  Future<TtsTransportResult> invoke(String text) async {
    callCount++;
    lastText = text;
    return respond(text);
  }
}

void main() {
  group('ElevenLabsTtsService.textToSpeech', () {
    test('returns audio bytes on a successful call', () async {
      final audioBytes = Uint8List.fromList([1, 2, 3, 4]);
      final transport = _FakeTransport(
        (text) => TtsTransportResult(status: 200, data: audioBytes),
      );
      final service = ElevenLabsTtsService(transport);

      final result = await service.textToSpeech('One oat latte, coming up!');

      expect(result, audioBytes);
      expect(transport.lastText, 'One oat latte, coming up!');
      expect(transport.callCount, 1);
    });

    test('trims text before sending it', () async {
      final audioBytes = Uint8List.fromList([9]);
      final transport = _FakeTransport(
        (text) => TtsTransportResult(status: 200, data: audioBytes),
      );
      final service = ElevenLabsTtsService(transport);

      await service.textToSpeech('  hello  ');

      expect(transport.lastText, 'hello');
    });

    test('throws without calling the transport for empty text', () async {
      final transport = _FakeTransport(
        (text) => throw StateError('should not be called'),
      );
      final service = ElevenLabsTtsService(transport);

      await expectLater(
        () => service.textToSpeech(''),
        throwsA(isA<TtsException>()),
      );
      await expectLater(
        () => service.textToSpeech('   '),
        throwsA(isA<TtsException>()),
      );
      expect(transport.callCount, 0);
    });

    test('surfaces the server error message for missing configuration', () async {
      final transport = _FakeTransport(
        (text) => const TtsTransportResult(
          status: 500,
          data: {'error': 'ELEVENLABS_API_KEY is not configured on the server.'},
        ),
      );
      final service = ElevenLabsTtsService(transport);

      await expectLater(
        () => service.textToSpeech('hi'),
        throwsA(
          isA<TtsException>().having(
            (e) => e.message,
            'message',
            'ELEVENLABS_API_KEY is not configured on the server.',
          ),
        ),
      );
    });

    test('maps a rate-limit status to a friendly message', () async {
      final transport = _FakeTransport(
        (text) => const TtsTransportResult(status: 429, data: null),
      );
      final service = ElevenLabsTtsService(transport);

      await expectLater(
        () => service.textToSpeech('hi'),
        throwsA(
          isA<TtsException>().having(
            (e) => e.message,
            'message',
            contains('rate limited'),
          ),
        ),
      );
    });

    test('maps a network failure (status 0) to a connectivity message', () async {
      final transport = _FakeTransport(
        (text) => const TtsTransportResult(status: 0, data: null),
      );
      final service = ElevenLabsTtsService(transport);

      await expectLater(
        () => service.textToSpeech('hi'),
        throwsA(
          isA<TtsException>().having(
            (e) => e.message,
            'message',
            contains('connection'),
          ),
        ),
      );
    });

    test('rejects an empty audio response from a provider error', () async {
      final transport = _FakeTransport(
        (text) => TtsTransportResult(status: 200, data: Uint8List(0)),
      );
      final service = ElevenLabsTtsService(transport);

      await expectLater(
        () => service.textToSpeech('hi'),
        throwsA(isA<TtsException>()),
      );
    });

    test(
        'streaming (chunk-by-chunk) failure: an error on a later chunk '
        'still surfaces as a TtsException', () async {
      // Mirrors what TtsPlaybackController does for a long reply split into
      // multiple chunks by chunkTextForSpeech: request each chunk in turn
      // and stop as soon as one fails.
      var call = 0;
      final transport = _FakeTransport((text) {
        call++;
        if (call == 1) {
          return TtsTransportResult(status: 200, data: Uint8List.fromList([1]));
        }
        return const TtsTransportResult(
          status: 502,
          data: {'error': 'The speech provider returned an error.'},
        );
      });
      final service = ElevenLabsTtsService(transport);

      final firstChunkBytes = await service.textToSpeech('First sentence.');
      expect(firstChunkBytes, isNotEmpty);

      await expectLater(
        () => service.textToSpeech('Second sentence.'),
        throwsA(isA<TtsException>()),
      );
      expect(transport.callCount, 2);
    });
  });
}
