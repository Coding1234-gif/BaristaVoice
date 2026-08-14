import 'package:flutter/material.dart';

import '../../../state/kiosk_controller.dart';

class MicButton extends StatelessWidget {
  final ListeningStatus status;
  final VoidCallback onTap;

  const MicButton({super.key, required this.status, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final Color color;
    final IconData icon;
    final String label;

    switch (status) {
      case ListeningStatus.idle:
        color = Theme.of(context).colorScheme.primary;
        icon = Icons.mic;
        label = 'Tap to talk';
        break;
      case ListeningStatus.listening:
        color = Colors.redAccent;
        icon = Icons.graphic_eq;
        label = 'Listening…';
        break;
      case ListeningStatus.thinking:
        color = Colors.orangeAccent;
        icon = Icons.hourglass_top;
        label = 'Thinking…';
        break;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: status == ListeningStatus.thinking ? null : onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.35),
                  blurRadius: status == ListeningStatus.listening ? 24 : 8,
                  spreadRadius: status == ListeningStatus.listening ? 4 : 0,
                ),
              ],
            ),
            child: status == ListeningStatus.thinking
                ? const Padding(
                    padding: EdgeInsets.all(28.0),
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
                  )
                : Icon(icon, color: Colors.white, size: 40),
          ),
        ),
        const SizedBox(height: 12),
        Text(label, style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }
}
