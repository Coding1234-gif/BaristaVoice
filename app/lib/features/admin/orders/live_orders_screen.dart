import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/admin_theme.dart';
import '../../../data/admin/live_orders_models.dart';
import '../../../state/admin_providers.dart';
import '../billing/premium_gate.dart';
import '../widgets/admin_states.dart';

/// The barista-facing realtime order queue: new orders appear the moment
/// they're paid, with a one-tap "Mark complete" for handing them over. Gated
/// behind the subscription like every other admin tab except Overview (see
/// router.dart) — self-wrapped in PremiumGate the same way AnalyticsScreen
/// is, so this widget is always the real dashboard.
class LiveOrdersScreen extends StatelessWidget {
  const LiveOrdersScreen({super.key});

  @override
  Widget build(BuildContext context) => const PremiumGate(
        featureName: 'Live Orders',
        featureDescription: 'See new orders the moment they\'re paid, and mark them complete as you make them.',
        child: _LiveOrdersDashboard(),
      );
}

class _LiveOrdersDashboard extends ConsumerStatefulWidget {
  const _LiveOrdersDashboard();

  @override
  ConsumerState<_LiveOrdersDashboard> createState() => _LiveOrdersDashboardState();
}

class _LiveOrdersDashboardState extends ConsumerState<_LiveOrdersDashboard> {
  Timer? _clock;
  final _markingComplete = <String>{};

  @override
  void initState() {
    super.initState();
    // Nothing in the order list itself changes just because time passes —
    // this just forces the "JUST NOW" / "2 min ago" labels to re-render.
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  Future<void> _markComplete(LiveOrder order) async {
    setState(() => _markingComplete.add(order.id));
    try {
      await ref.read(liveOrdersRepositoryProvider).markComplete(order.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not mark #${order.orderNumber} complete: $e')));
      }
    } finally {
      if (mounted) setState(() => _markingComplete.remove(order.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ordersAsync = ref.watch(liveOrdersProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Orders'),
        actions: const [Padding(padding: EdgeInsets.only(right: 20), child: _LiveIndicator())],
      ),
      body: ordersAsync.when(
        loading: () => const AdminLoadingState(),
        error: (e, _) => AdminErrorState(
          message: 'Could not load live orders: $e',
          onRetry: () => ref.invalidate(liveOrdersProvider),
        ),
        data: (orders) {
          if (orders.isEmpty) {
            return const AdminEmptyState(
              icon: Icons.receipt_long_outlined,
              title: 'No orders yet',
              message: 'Orders will appear here the moment a customer pays.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(24),
            itemCount: orders.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, i) => _OrderCard(
              order: orders[i],
              marking: _markingComplete.contains(orders[i].id),
              onMarkComplete: () => _markComplete(orders[i]),
            ),
          );
        },
      ),
    );
  }
}

class _LiveIndicator extends StatelessWidget {
  const _LiveIndicator();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: const BoxDecoration(color: adminSuccess, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        const Text(
          'Live',
          style: TextStyle(color: adminSuccess, fontWeight: FontWeight.w700, fontSize: 13),
        ),
      ],
    );
  }
}

class _OrderCard extends StatelessWidget {
  final LiveOrder order;
  final bool marking;
  final VoidCallback onMarkComplete;

  const _OrderCard({required this.order, required this.marking, required this.onMarkComplete});

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.simpleCurrency(name: order.currency);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '#${order.orderNumber}',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                ),
                const Spacer(),
                Text(
                  _relativeTime(order.createdAt).toUpperCase(),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.black45,
                    letterSpacing: 0.4,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 12),
            for (final item in order.items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${item.quantity} × ${item.name}',
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                        ),
                        Text(currency.format(item.lineTotal), style: const TextStyle(fontSize: 13)),
                      ],
                    ),
                    if (item.optionsLine.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 14, top: 2),
                        child: Text(
                          item.optionsLine,
                          style: const TextStyle(fontSize: 12.5, color: Colors.black54),
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Text('Total', style: TextStyle(color: Colors.black54)),
                const Spacer(),
                Text(
                  currency.format(order.total),
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                _OrderStatusBadge(order: order),
                const Spacer(),
                if (order.isPaid && !order.isCompleted)
                  FilledButton(
                    onPressed: marking ? null : onMarkComplete,
                    child: marking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Mark complete'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _relativeTime(DateTime dt) {
    final local = dt.toLocal();
    final diff = DateTime.now().difference(local);
    if (diff.inSeconds < 45) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} hr ago';
    return DateFormat.MMMd().add_jm().format(local);
  }
}

class _OrderStatusBadge extends StatelessWidget {
  final LiveOrder order;
  const _OrderStatusBadge({required this.order});

  @override
  Widget build(BuildContext context) {
    if (order.isCompleted) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 16, color: adminSuccess),
          SizedBox(width: 6),
          Text('Completed', style: TextStyle(color: adminSuccess, fontWeight: FontWeight.w700, fontSize: 13)),
        ],
      );
    }

    if (order.isPaid) {
      return const _DotLabel(label: 'PAID', color: adminSuccess);
    }

    if (order.isFailedOrCancelled) {
      return _DotLabel(label: order.status == 'cancelled' ? 'CANCELLED' : 'FAILED', color: adminDanger);
    }

    return const _DotLabel(label: 'IN PROGRESS', color: adminWarning);
  }
}

class _DotLabel extends StatelessWidget {
  final String label;
  final Color color;
  const _DotLabel({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13)),
      ],
    );
  }
}
