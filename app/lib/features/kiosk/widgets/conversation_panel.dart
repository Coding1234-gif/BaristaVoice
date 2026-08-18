import 'package:flutter/material.dart';

import 'speak_button.dart';

/// Compact "what the AI heard / said" strip — kept for accessibility,
/// verification, and debugging (section 8 of the voice-first spec), but
/// deliberately styled as secondary: the mic/phase indicator above this is
/// the primary UI, this is just a quieter transcript underneath it, not a
/// chat log. The AI's replies are heard, not read.
class ConversationPanel extends StatelessWidget {
  final String liveTranscript;
  final String? assistantReply;
  final String? errorMessage;
  final bool isListening;

  const ConversationPanel({
    super.key,
    required this.liveTranscript,
    required this.assistantReply,
    required this.errorMessage,
    required this.isListening,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showTranscript = isListening && liveTranscript.isNotEmpty;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showTranscript) ...[
            Text('You said', style: theme.textTheme.labelSmall),
            const SizedBox(height: 2),
            Text(
              '"$liveTranscript"',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ] else if (errorMessage != null) ...[
            Row(
              children: [
                Icon(Icons.info_outline, size: 16, color: theme.colorScheme.error),
                const SizedBox(width: 6),
                Text('Barista', style: theme.textTheme.labelSmall),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              errorMessage!,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ] else if (assistantReply != null) ...[
            Row(
              children: [
                Text('Barista', style: theme.textTheme.labelSmall),
                const Spacer(),
                SpeakButton(text: assistantReply!),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              assistantReply!,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ] else ...[
            Text(
              'Tap the mic and ask for anything — "What\'s popular?" or '
              '"I\'ll have an iced oat latte."',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
