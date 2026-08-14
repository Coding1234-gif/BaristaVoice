import 'package:flutter/material.dart';

/// Compact "what the AI heard / said" area. Deliberately small — the order
/// summary, not the chat, is the star of the screen.
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
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showTranscript) ...[
            Text('You said', style: theme.textTheme.labelSmall),
            const SizedBox(height: 4),
            Text('"$liveTranscript"', style: theme.textTheme.bodyLarge),
          ] else if (errorMessage != null) ...[
            Row(
              children: [
                Icon(Icons.info_outline, size: 18, color: theme.colorScheme.error),
                const SizedBox(width: 6),
                Text('Barista', style: theme.textTheme.labelSmall),
              ],
            ),
            const SizedBox(height: 4),
            Text(errorMessage!, style: theme.textTheme.bodyLarge),
          ] else if (assistantReply != null) ...[
            Text('Barista', style: theme.textTheme.labelSmall),
            const SizedBox(height: 4),
            Text(assistantReply!, style: theme.textTheme.bodyLarge),
          ] else ...[
            Text(
              'Tap the mic and ask for anything — "What\'s popular?" or '
              '"I\'ll have an iced oat latte."',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
