import 'package:flutter/material.dart';

import '../../../core/admin_theme.dart';

class StatusBadge extends StatelessWidget {
  final String label;
  final Color color;

  const StatusBadge({super.key, required this.label, required this.color});

  factory StatusBadge.published() =>
      const StatusBadge(label: 'Published', color: adminSuccess);

  factory StatusBadge.draft() => const StatusBadge(label: 'Draft', color: adminWarning);

  factory StatusBadge.unavailable() =>
      const StatusBadge(label: 'Unavailable', color: adminDanger);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700),
      ),
    );
  }
}
