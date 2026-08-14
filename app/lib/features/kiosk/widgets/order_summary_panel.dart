import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../models/menu.dart';
import '../../../models/order.dart';

final _currency = NumberFormat.simpleCurrency(name: 'USD');

/// Always-visible, always-accurate order state. This is what the customer
/// trusts, not the transcript.
class OrderSummaryPanel extends StatelessWidget {
  final Order order;
  final CafeMenu menu;
  final VoidCallback onConfirm;

  const OrderSummaryPanel({
    super.key,
    required this.order,
    required this.menu,
    required this.onConfirm,
  });

  String _optionsLine(OrderItem item) {
    final parts = <String>[];
    if (item.size != null) parts.add(item.size!);
    if (item.temperature != null) parts.add(item.temperature!);
    if (item.milk != null) parts.add('${item.milk} milk');
    if (item.decaf) parts.add('decaf');
    parts.addAll(item.modifiers);
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = order.total(menu);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 12, offset: const Offset(0, -2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Your Order', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (order.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Nothing yet — just say what you\'d like.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: order.items.length,
                separatorBuilder: (_, _) => const Divider(height: 16),
                itemBuilder: (context, i) {
                  final item = order.items[i];
                  final optionsLine = _optionsLine(item);
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.quantity > 1
                                  ? '${item.quantity}× ${item.name}'
                                  : item.name,
                              style: theme.textTheme.bodyLarge
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            if (optionsLine.isNotEmpty)
                              Text(
                                optionsLine,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                      Text(
                        _currency.format(item.lineTotal(menu)),
                        style: theme.textTheme.bodyLarge,
                      ),
                    ],
                  );
                },
              ),
            ),
          const Divider(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Total', style: theme.textTheme.titleMedium),
              Text(
                _currency.format(total),
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: order.isEmpty ? null : onConfirm,
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
              child: const Text("That's everything — Confirm & Pay"),
            ),
          ),
        ],
      ),
    );
  }
}
