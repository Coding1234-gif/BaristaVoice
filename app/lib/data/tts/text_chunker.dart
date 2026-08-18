/// Splits [text] into pieces no longer than [maxChunkLength], preferring to
/// break at sentence boundaries (falling back to word boundaries for a
/// single oversized sentence). This keeps each request to the `tts-speak`
/// function well within its per-call limit, and lets playback start on the
/// first chunk while later chunks are still being synthesized instead of
/// waiting for the whole reply.
List<String> chunkTextForSpeech(String text, {int maxChunkLength = 600}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const [];
  if (trimmed.length <= maxChunkLength) return [trimmed];

  final sentences = trimmed
      .split(RegExp(r'(?<=[.!?])\s+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty);

  final chunks = <String>[];
  final buffer = StringBuffer();

  void flush() {
    if (buffer.isNotEmpty) {
      chunks.add(buffer.toString().trim());
      buffer.clear();
    }
  }

  for (final sentence in sentences) {
    if (sentence.length > maxChunkLength) {
      flush();
      chunks.addAll(_splitLongSentence(sentence, maxChunkLength));
      continue;
    }
    if (buffer.length + sentence.length + 1 > maxChunkLength) {
      flush();
    }
    if (buffer.isNotEmpty) buffer.write(' ');
    buffer.write(sentence);
  }
  flush();

  return chunks;
}

/// Fallback for a single sentence longer than [maxChunkLength]: break at
/// word boundaries instead of mid-word.
List<String> _splitLongSentence(String sentence, int maxChunkLength) {
  final words = sentence.split(RegExp(r'\s+'));
  final chunks = <String>[];
  final buffer = StringBuffer();

  for (final word in words) {
    if (buffer.length + word.length + 1 > maxChunkLength && buffer.isNotEmpty) {
      chunks.add(buffer.toString().trim());
      buffer.clear();
    }
    if (buffer.isNotEmpty) buffer.write(' ');
    buffer.write(word);
  }
  if (buffer.isNotEmpty) chunks.add(buffer.toString().trim());

  return chunks;
}
