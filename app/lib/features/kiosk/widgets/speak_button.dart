import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/tts_playback_controller.dart';

/// "Play this reply out loud" control shown next to the barista's text
/// reply. Reflects [TtsPlaybackState.status] as loading/speaking/error, and
/// relies on [TtsPlaybackController] to guarantee only one clip plays at a
/// time — this button only ever starts or stops that single shared player.
class SpeakButton extends ConsumerWidget {
  final String text;

  const SpeakButton({super.key, required this.text});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(ttsPlaybackControllerProvider);
    final controller = ref.read(ttsPlaybackControllerProvider.notifier);
    final theme = Theme.of(context);

    switch (playback.status) {
      case TtsPlaybackStatus.loading:
        return const Padding(
          padding: EdgeInsets.all(8),
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      case TtsPlaybackStatus.speaking:
        return IconButton(
          icon: const Icon(Icons.stop_circle_outlined),
          color: theme.colorScheme.primary,
          tooltip: 'Stop speaking',
          onPressed: controller.stop,
        );
      case TtsPlaybackStatus.blocked:
        return TextButton.icon(
          onPressed: controller.retryBlockedPlayback,
          icon: const Icon(Icons.volume_off_outlined, size: 18),
          label: const Text('Enable Audio'),
        );
      case TtsPlaybackStatus.error:
        return IconButton(
          icon: Icon(Icons.error_outline, color: theme.colorScheme.error),
          tooltip: playback.errorMessage ?? 'Could not play speech.',
          onPressed: () => controller.speak(text),
        );
      case TtsPlaybackStatus.idle:
        return IconButton(
          icon: const Icon(Icons.volume_up_outlined),
          tooltip: 'Play speech',
          onPressed: () => controller.speak(text),
        );
    }
  }
}
