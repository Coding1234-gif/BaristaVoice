import 'package:flutter_test/flutter_test.dart';

import 'package:barista_voice/data/tts/text_chunker.dart';

void main() {
  group('chunkTextForSpeech', () {
    test('returns nothing for empty or whitespace-only text', () {
      expect(chunkTextForSpeech(''), isEmpty);
      expect(chunkTextForSpeech('   \n  '), isEmpty);
    });

    test('returns text unchanged as a single chunk when short enough', () {
      const reply = "Sure thing — one large oat latte, coming right up!";
      final chunks = chunkTextForSpeech(reply, maxChunkLength: 600);
      expect(chunks, [reply]);
    });

    test('splits long text at sentence boundaries, not mid-sentence', () {
      final sentence = 'This is a fairly long barista sentence about coffee options.';
      final text = List.filled(6, sentence).join(' ');

      final chunks = chunkTextForSpeech(text, maxChunkLength: 120);

      expect(chunks.length, greaterThan(1));
      // Every chunk boundary lands after sentence-ending punctuation, and
      // no chunk exceeds the requested length.
      for (final chunk in chunks) {
        expect(chunk.length, lessThanOrEqualTo(120));
        expect(chunk.trim().endsWith('.'), isTrue);
      }
      // Rejoining the chunks reproduces the original words, in order.
      expect(chunks.join(' '), text);
    });

    test('falls back to word boundaries for a single oversized sentence', () {
      final longSentence = List.generate(40, (i) => 'word$i').join(' ');

      final chunks = chunkTextForSpeech(longSentence, maxChunkLength: 50);

      expect(chunks.length, greaterThan(1));
      for (final chunk in chunks) {
        expect(chunk.length, lessThanOrEqualTo(50));
      }
      expect(chunks.join(' '), longSentence);
    });
  });
}
