import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/admin_theme.dart';
import '../../../data/billing/stripe_billing_models.dart';
import '../../../state/admin_providers.dart';
import '../../../state/billing_providers.dart';
import '../../../state/stripe_billing_providers.dart';
import '../widgets/admin_states.dart';
import 'premium_gate.dart';

final _currency = NumberFormat.simpleCurrency(name: 'GBP');
final _monthFormat = DateFormat.MMMM();

/// The café-facing Stripe usage billing dashboard: £79/month (RevenueCat,
/// shown for context only — never charged again from here, see the header
/// card) + 5p-per-item usage this month, plus payment method setup and
/// past periods. Gated the same way every other premium admin screen is
/// (see PremiumGate/router.dart).
class UsageBillingScreen extends StatelessWidget {
  const UsageBillingScreen({super.key});

  @override
  Widget build(BuildContext context) => const PremiumGate(
        featureName: 'Billing',
        featureDescription: 'See your usage charges, past invoices, and manage your payment method.',
        child: _UsageBillingDashboard(),
      );
}

class _UsageBillingDashboard extends ConsumerWidget {
  const _UsageBillingDashboard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(billingStatusProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Billing')),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(billingStatusProvider.future),
        child: statusAsync.when(
          loading: () => const AdminLoadingState(),
          error: (e, _) => AdminErrorState(
            message: 'Could not load billing: $e',
            onRetry: () => ref.invalidate(billingStatusProvider),
          ),
          data: (status) => status == null
              ? const AdminErrorState(message: 'No café selected.')
              : _BillingBody(status: status),
        ),
      ),
    );
  }
}

class _BillingBody extends ConsumerWidget {
  final BillingStatus status;
  const _BillingBody({required this.status});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SubscriptionCard(),
          const SizedBox(height: 20),
          _CurrentUsageCard(period: status.currentPeriod),
          const SizedBox(height: 20),
          _PaymentMethodCard(billing: status.cafeBilling),
          const SizedBox(height: 20),
          _HistoryCard(history: status.history),
        ],
      ),
    );
  }
}

class _SubscriptionCard extends ConsumerWidget {
  const _SubscriptionCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entitledAsync = ref.watch(hasPremiumEntitlementProvider);
    final active = entitledAsync.valueOrNull ?? false;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: adminSeedColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.workspace_premium_outlined, color: adminSeedColor, size: 22),
            ),
            const SizedBox(width: 16),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('BaristaVoice Pro', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  SizedBox(height: 2),
                  Text('£79.00 / month · billed via RevenueCat', style: TextStyle(color: Colors.black54, fontSize: 13)),
                ],
              ),
            ),
            _StatusChip(label: active ? 'Active' : 'Inactive', color: active ? adminSuccess : adminWarning),
          ],
        ),
      ),
    );
  }
}

class _CurrentUsageCard extends StatelessWidget {
  final CurrentUsagePeriod period;
  const _CurrentUsageCard({required this.period});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Current usage — ${period.label}',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 4),
            Text(
              '${period.pencePerItem}p per item ordered through BaristaVoice',
              style: const TextStyle(color: Colors.black54, fontSize: 13),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: _MetricColumn(label: 'Items so far', value: '${period.itemCount}'),
                ),
                Expanded(
                  child: _MetricColumn(label: 'Usage charge', value: _currency.format(period.usageGbp)),
                ),
                Expanded(
                  child: _MetricColumn(
                    label: 'Estimated total',
                    value: _currency.format(period.estimatedTotalGbp),
                    emphasize: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Estimated total = £${(period.baseSubscriptionPence / 100).toStringAsFixed(2)} subscription + usage so far. Finalized once the month closes.',
              style: const TextStyle(color: Colors.black45, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricColumn extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasize;
  const _MetricColumn({required this.label, required this.value, this.emphasize = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: emphasize ? 22 : 18,
            fontWeight: FontWeight.w800,
            color: emphasize ? adminSeedColor : Colors.black87,
          ),
        ),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: Colors.black54, fontSize: 12)),
      ],
    );
  }
}

class _PaymentMethodCard extends ConsumerStatefulWidget {
  final CafeBillingInfo billing;
  const _PaymentMethodCard({required this.billing});

  @override
  ConsumerState<_PaymentMethodCard> createState() => _PaymentMethodCardState();
}

class _PaymentMethodCardState extends ConsumerState<_PaymentMethodCard> {
  bool _starting = false;

  Future<void> _startSetup() async {
    final cafeId = ref.read(activeCafeIdProvider);
    if (cafeId == null) return;

    setState(() => _starting = true);
    try {
      final url = await ref.read(stripeBillingRepositoryProvider).startPaymentMethodSetup(cafeId: cafeId);
      final uri = Uri.parse(url);
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        _showError('Could not open the Stripe payment page.');
      }
    } catch (e) {
      if (mounted) _showError('$e');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final billing = widget.billing;
    final isActive = billing.status == CafeBillingStatus.active && billing.hasPaymentMethod;
    final isPastDue = billing.status == CafeBillingStatus.pastDue;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: (isPastDue ? adminDanger : adminSeedColor).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                isActive ? Icons.credit_card : Icons.credit_card_outlined,
                color: isPastDue ? adminDanger : adminSeedColor,
                size: 22,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isActive ? 'Payment method connected' : 'No payment method yet',
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isPastDue
                        ? 'Your last usage invoice failed to pay — please update your payment method.'
                        : isActive
                            ? 'Your usage charge is billed to this card automatically each month.'
                            : 'Connect a card so BaristaVoice can bill your monthly usage charge.',
                    style: TextStyle(color: isPastDue ? adminDanger : Colors.black54, fontSize: 13),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _starting
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : OutlinedButton(
                    onPressed: _startSetup,
                    child: Text(isActive ? 'Update' : 'Connect'),
                  ),
          ],
        ),
      ),
    );
  }
}

class _HistoryCard extends ConsumerStatefulWidget {
  final List<UsagePeriodRecord> history;
  const _HistoryCard({required this.history});

  @override
  ConsumerState<_HistoryCard> createState() => _HistoryCardState();
}

class _HistoryCardState extends ConsumerState<_HistoryCard> {
  bool _generating = false;

  Future<void> _generateLastMonth() async {
    final cafeId = ref.read(activeCafeIdProvider);
    if (cafeId == null) return;

    setState(() => _generating = true);
    try {
      await ref.read(stripeBillingRepositoryProvider).generateUsageInvoice(cafeId: cafeId);
      ref.invalidate(billingStatusProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Last month's usage invoice has been generated.")),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Previous billing periods', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                ),
                // Stand-in for a scheduled monthly job (this repo has none
                // wired up yet — see stripe-generate-usage-invoice's header
                // comment). Safe to tap more than once: idempotent per
                // period.
                TextButton.icon(
                  onPressed: _generating ? null : _generateLastMonth,
                  icon: _generating
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.receipt_long, size: 16),
                  label: const Text('Generate last month'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (widget.history.isEmpty)
              const Text('No billing periods yet.', style: TextStyle(color: Colors.black54))
            else
              for (var i = 0; i < widget.history.length; i++) ...[
                if (i > 0) const Divider(height: 24),
                _HistoryRow(record: widget.history[i]),
              ],
          ],
        ),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  final UsagePeriodRecord record;
  const _HistoryRow({required this.record});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (record.status) {
      UsagePeriodStatus.paid => ('Paid', adminSuccess),
      UsagePeriodStatus.invoiced => ('Invoiced', adminWarning),
      UsagePeriodStatus.paymentFailed => ('Payment failed', adminDanger),
      UsagePeriodStatus.calculated => ('Calculated', Colors.black54),
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(_monthFormat.format(record.periodStart), style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${record.itemCount} items · ${_currency.format(record.usageGbp)} usage'),
              const SizedBox(height: 2),
              Text('Total ${_currency.format(record.totalGbp)}', style: const TextStyle(color: Colors.black54, fontSize: 13)),
            ],
          ),
        ),
        _StatusChip(label: label, color: color),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
      child: Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }
}
