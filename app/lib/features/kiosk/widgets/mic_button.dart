import 'package:flutter/material.dart';

import '../../../state/kiosk_controller.dart';

/// The primary "what's happening right now" indicator, per
/// `KioskPhase` — this is the big, glanceable state the customer reads
/// instead of the transcript. Tapping while [KioskPhase.speaking] is the
/// app's barge-in: it interrupts the AI and starts listening (see
/// `KioskController.startListening`, which stops TTS playback first).
class MicButton extends StatelessWidget {
  final KioskPhase phase;
  final VoidCallback onTap;

  const MicButton({super.key, required this.phase, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final Color color;
    final IconData icon;
    final String label;

    switch (phase) {
      case KioskPhase.idle:
        color = Theme.of(context).colorScheme.primary;
        icon = Icons.mic;
        label = 'Tap to talk';
        break;
      case KioskPhase.listening:
        color = Colors.redAccent;
        icon = Icons.graphic_eq;
        label = 'Listening…';
        break;
      case KioskPhase.thinking:
        color = Colors.orangeAccent;
        icon = Icons.hourglass_top;
        label = 'Thinking…';
        break;
      case KioskPhase.speaking:
        color = Colors.deepPurpleAccent;
        icon = Icons.campaign;
        label = 'Speaking… tap to interrupt';
        break;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: phase == KioskPhase.thinking ? null : onTap,
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
                  blurRadius: phase == KioskPhase.listening || phase == KioskPhase.speaking ? 24 : 8,
                  spreadRadius: phase == KioskPhase.listening || phase == KioskPhase.speaking ? 4 : 0,
                ),
              ],
            ),
            child: phase == KioskPhase.thinking
                ? const Padding(
                    padding: EdgeInsets.all(28.0),
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
                  )
                : Icon(icon, color: Colors.white, size: 40),
          ),
        ),
        const SizedBox(height: 12),
        Text(label, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
      ],
    );
  }
}
