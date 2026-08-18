import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../data/tts/text_chunker.dart';
import '../data/tts/tts_service.dart';
import 'providers.dart';

/// Sentences shorter than this play back-to-back in one request; a reply
/// longer than this splits at sentence boundaries so the first sentence can
/// start playing while later ones are still being synthesized. Kept short
/// (most single-sentence barista replies are well under this) so pipelining
/// actually kicks in instead of only mattering for unusually long replies.
const _ttsChunkLength = 150;

/// Wraps a synthesized audio chunk as a data URI so just_audio can play it
/// straight from memory — no temp files, works the same on web and native.
AudioSource _audioSourceFor(Uint8List bytes, {String mimeType = 'audio/mpeg'}) =>
    AudioSource.uri(Uri.dataFromBytes(bytes, mimeType: mimeType));

/// A ~50ms silent WAV clip, built in code so there's no bundled asset. Used
/// only to "spend" a user gesture on browsers that require one before any
/// audio can play — see [TtsPlaybackController.unlockAudio].
Uint8List _silentWavBytes() {
  const sampleRate = 8000;
  const numSamples = 400;
  const bitsPerSample = 16;
  const numChannels = 1;
  const bytesPerSample = bitsPerSample ~/ 8;
  const dataSize = numSamples * numChannels * bytesPerSample;
  const byteRate = sampleRate * numChannels * bytesPerSample;
  const blockAlign = numChannels * bytesPerSample;

  final buffer = ByteData(44 + dataSize);
  void writeString(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      buffer.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  writeString(0, 'RIFF');
  buffer.setUint32(4, 36 + dataSize, Endian.little);
  writeString(8, 'WAVE');
  writeString(12, 'fmt ');
  buffer.setUint32(16, 16, Endian.little);
  buffer.setUint16(20, 1, Endian.little);
  buffer.setUint16(22, numChannels, Endian.little);
  buffer.setUint32(24, sampleRate, Endian.little);
  buffer.setUint32(28, byteRate, Endian.little);
  buffer.setUint16(32, blockAlign, Endian.little);
  buffer.setUint16(34, bitsPerSample, Endian.little);
  writeString(36, 'data');
  buffer.setUint32(40, dataSize, Endian.little);
  // Remaining bytes are already zero-initialized, i.e. silence.

  return buffer.buffer.asUint8List();
}

enum TtsPlaybackStatus {
  idle,
  loading,
  speaking,

  /// Synthesis succeeded but the browser refused to start playback without
  /// a fresh user gesture (autoplay policy). [TtsPlaybackController.retryBlockedPlayback]
  /// resumes the already-loaded audio.
  blocked,
  error,
}

class TtsPlaybackState {
  final TtsPlaybackStatus status;
  final String? errorMessage;

  const TtsPlaybackState({
    this.status = TtsPlaybackStatus.idle,
    this.errorMessage,
  });
}

/// Drives "play this reply out loud": fetches audio for [speak]'s text from
/// [TtsService], chunking long replies at sentence boundaries so playback of
/// the first chunk can start while later chunks are still being synthesized,
/// then queues them back-to-back on a single shared [AudioPlayer]. That one
/// shared player is what guarantees only one TTS stream is ever playing at a
/// time — a new [speak] call always stops whatever it was doing first, which
/// is also what makes tap-to-interrupt (barge-in) work.
class TtsPlaybackController extends StateNotifier<TtsPlaybackState> {
  final TtsService _tts;
  final AudioPlayer _player = AudioPlayer();
  int _requestId = 0;

  TtsPlaybackController(this._tts) : super(const TtsPlaybackState()) {
    _player.processingStateStream.listen((processingState) {
      if (processingState == ProcessingState.completed) {
        state = const TtsPlaybackState();
      }
    });
  }

  /// Plays and immediately stops a near-silent clip. Call this directly
  /// from a user gesture (e.g. the "Start Order" button's `onPressed`) —
  /// browsers only allow *programmatic* audio playback without a fresh
  /// gesture once a real playback has already succeeded inside one. This
  /// spends that gesture up front so automatic TTS playback later in the
  /// conversation isn't blocked. Returns false if even this failed, meaning
  /// the browser still requires a gesture per playback.
  Future<bool> unlockAudio() async {
    try {
      await _player.setAudioSources([
        _audioSourceFor(_silentWavBytes(), mimeType: 'audio/wav'),
      ]);
      await _player.play();
      await _player.stop();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> speak(String text) async {
    final requestId = ++_requestId;
    await _player.stop();

    final chunks = chunkTextForSpeech(text, maxChunkLength: _ttsChunkLength);
    if (chunks.isEmpty) {
      state = const TtsPlaybackState(
        status: TtsPlaybackStatus.error,
        errorMessage: 'There is no text to speak.',
      );
      return;
    }

    state = const TtsPlaybackState(status: TtsPlaybackStatus.loading);

    try {
      final firstBytes = await _tts.textToSpeech(chunks.first);
      if (requestId != _requestId) return;

      await _player.setAudioSources([_audioSourceFor(firstBytes)]);
      if (requestId != _requestId) return;

      state = const TtsPlaybackState(status: TtsPlaybackStatus.speaking);
      unawaited(_player.play().catchError((Object _) {
        // The source loaded fine, so a failure here is almost always the
        // browser's autoplay policy refusing playback outside a user
        // gesture, not a real playback error.
        if (requestId == _requestId) {
          state = const TtsPlaybackState(
            status: TtsPlaybackStatus.blocked,
            errorMessage: 'Tap "Enable Audio" to allow sound.',
          );
        }
      }));

      // Remaining chunks are appended while the first one is already
      // playing — the customer hears the reply start without waiting for
      // the whole thing to be synthesized.
      for (final chunk in chunks.skip(1)) {
        final bytes = await _tts.textToSpeech(chunk);
        if (requestId != _requestId) return;
        await _player.addAudioSources([_audioSourceFor(bytes)]);
      }
    } on TtsException catch (e) {
      if (requestId != _requestId) return;
      state = TtsPlaybackState(status: TtsPlaybackStatus.error, errorMessage: e.message);
    } catch (_) {
      if (requestId != _requestId) return;
      state = const TtsPlaybackState(
        status: TtsPlaybackStatus.error,
        errorMessage: 'Could not play speech.',
      );
    }
  }

  /// Resumes the audio already loaded from the last [speak] call after a
  /// [TtsPlaybackStatus.blocked] state — call from a fresh user gesture
  /// (the "Enable Audio" tap). No re-synthesis needed.
  Future<void> retryBlockedPlayback() async {
    if (state.status != TtsPlaybackStatus.blocked) return;
    final requestId = _requestId;
    try {
      await _player.play();
      if (requestId == _requestId) {
        state = const TtsPlaybackState(status: TtsPlaybackStatus.speaking);
      }
    } catch (_) {
      if (requestId == _requestId) {
        state = const TtsPlaybackState(
          status: TtsPlaybackStatus.blocked,
          errorMessage: 'Tap "Enable Audio" to allow sound.',
        );
      }
    }
  }

  Future<void> stop() async {
    _requestId++;
    await _player.stop();
    state = const TtsPlaybackState();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}

final ttsPlaybackControllerProvider =
    StateNotifierProvider<TtsPlaybackController, TtsPlaybackState>((ref) {
  final controller = TtsPlaybackController(ref.watch(ttsServiceProvider));
  ref.onDispose(controller.dispose);
  return controller;
});
