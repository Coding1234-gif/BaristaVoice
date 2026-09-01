import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../models/menu.dart';
import '../../../models/order.dart';
import '../../../state/kiosk_controller.dart' show PaymentPhase;

final _currency = NumberFormat.simpleCurrency(name: 'USD');

/// Always-visible, always-accurate order state. This is what the customer
/// trusts, not the transcript.
///
/// Confirmation is a deliberate two-step: tapping the button below starts a
/// *review* (spoken + shown here, built directly from this same [order] so
/// it can never disagree with what's on screen) rather than immediately
/// finalizing — see `KioskController.beginOrderReview`/`confirmOrder`. Once
/// confirmed, [paymentPhase] takes over the bottom action area entirely —
/// see `KioskController._beginPayment`/`_startPollingForPayment` for what
/// drives each phase.
class OrderSummaryPanel extends StatelessWidget {
  final Order order;
  final CafeMenu menu;
  final bool isReviewing;
  final bool isSubmitting;
  final PaymentPhase paymentPhase;
  final String? paymentError;
  final VoidCallback onReview;
  final VoidCallback onConfirmYes;
  final VoidCallback onConfirmNo;
  final VoidCallback onRetryPayment;
  final VoidCallback onNewOrder;

  const OrderSummaryPanel({
    super.key,
    required this.order,
    required this.menu,
    required this.isReviewing,
    this.isSubmitting = false,
    this.paymentPhase = PaymentPhase.none,
    this.paymentError,
    required this.onReview,
    required this.onConfirmYes,
    required this.onConfirmNo,
    required this.onRetryPayment,
    required this.onNewOrder,
  });

  String _optionsLine(OrderItem item) {
    final parts = <String>[];
    if (item.size != null) parts.add(item.size!);
    if (item.temperature != null) parts.add(item.temperature!);
    if (item.milk != null) parts.add('${item.milk} milk');
    if (item.decaf) parts.add('decaf');
    parts.addAll(item.modifiers);
    if (item.specialRequest != null && item.specialRequest!.trim().isNotEmpty) {
      parts.add(item.specialRequest!.trim());
    }
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
          Row(
            children: [
              Text('Your Order', style: theme.textTheme.titleMedium),
              if (!order.isEmpty && !isReviewing && paymentPhase == PaymentPhase.none) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'Order ready',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onPrimaryContainer),
                  ),
                ),
              ],
            ],
          ),
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
          if (paymentPhase != PaymentPhase.none)
            _PaymentSection(
              phase: paymentPhase,
              error: paymentError,
              onRetry: onRetryPayment,
              onNewOrder: onNewOrder,
            )
          else if (isReviewing) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                "Is that correct?",
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onPrimaryContainer),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: isSubmitting ? null : onConfirmNo,
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                    child: const Text('No, keep editing'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: isSubmitting ? null : onConfirmYes,
                    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                    child: isSubmitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Yes, confirm'),
                  ),
                ),
              ],
            ),
          ] else
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: order.isEmpty ? null : onReview,
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                child: const Text("That's everything — Review & Confirm"),
              ),
            ),
        ],
      ),
    );
  }
}

/// The bottom action area once an order has been confirmed and reached
/// Square — one view per [PaymentPhase] (skips [PaymentPhase.none], which
/// [OrderSummaryPanel] never routes here for). Kept as its own widget
/// rather than more inline branches in [OrderSummaryPanel.build] since each
/// phase's content is unrelated to the others (spinner+prompt vs.
/// success vs. error+retry), not just a style variant of one shared layout.
class _PaymentSection extends StatelessWidget {
  final PaymentPhase phase;
  final String? error;
  final VoidCallback onRetry;
  final VoidCallback onNewOrder;

  const _PaymentSection({
    required this.phase,
    required this.error,
    required this.onRetry,
    required this.onNewOrder,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    switch (phase) {
      case PaymentPhase.none:
        return const SizedBox.shrink();

      case PaymentPhase.startingCheckout:
      case PaymentPhase.awaitingPayment:
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Please tap, insert, or swipe your card on the terminal to pay.',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onPrimaryContainer),
                ),
              ),
            ],
          ),
        );

      case PaymentPhase.paid:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.check_circle, color: theme.colorScheme.onPrimaryContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      "Payment received — thank you! We'll get your order ready.",
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onPrimaryContainer),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: onNewOrder,
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
              child: const Text('Start a New Order'),
            ),
          ],
        );

      case PaymentPhase.failed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: theme.colorScheme.onErrorContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      error ?? 'Something went wrong with payment.',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onErrorContainer),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onNewOrder,
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                    child: const Text('Start Over'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: onRetry,
                    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                    child: const Text('Try Again'),
                  ),
                ),
              ],
            ),
          ],
        );
    }
  }
}
