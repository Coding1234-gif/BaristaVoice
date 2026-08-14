import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/admin_theme.dart';
import '../../../data/admin/admin_models.dart';
import '../../../state/admin_providers.dart';
import '../widgets/admin_states.dart';
import '../widgets/status_badge.dart';

class AdminDashboardScreen extends ConsumerWidget {
  const AdminDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cafeAsync = ref.watch(activeCafeProvider);
    final itemsAsync = ref.watch(menuItemsProvider);

    return Scaffold(
      appBar: AppBar(
        title: cafeAsync.when(
          data: (cafe) => Text(cafe?.name ?? 'Overview'),
          loading: () => const Text('Overview'),
          error: (_, __) => const Text('Overview'),
        ),
      ),
      body: itemsAsync.when(
        loading: () => const AdminLoadingState(),
        error: (e, _) => AdminErrorState(
          message: 'Could not load your menu: $e',
          onRetry: () => ref.invalidate(menuItemsProvider),
        ),
        data: (items) => _DashboardBody(items: items),
      ),
    );
  }
}

class _DashboardBody extends ConsumerWidget {
  final List<MenuItemRecord> items;
  const _DashboardBody({required this.items});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final total = items.length;
    final available = items.where((r) => r.item.available).length;
    final published = items.where((r) => r.status == MenuItemStatus.published).length;
    final drafts = total - published;
    final lastUpdated = items.isEmpty
        ? null
        : items.map((r) => r.updatedAt).reduce((a, b) => a.isAfter(b) ? a : b);

    final overallStatus = total == 0
        ? null
        : (drafts == 0 ? MenuItemStatus.published : MenuItemStatus.draft);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              _StatCard(label: 'Products', value: '$total', icon: Icons.local_cafe_outlined),
              _StatCard(label: 'Available', value: '$available', icon: Icons.check_circle_outline),
              _StatCard(
                label: 'Awaiting review',
                value: '$drafts',
                icon: Icons.fact_check_outlined,
                highlight: drafts > 0,
              ),
              _StatCard(
                label: 'Last updated',
                value: lastUpdated == null ? '—' : _relativeDay(lastUpdated),
                icon: Icons.history,
              ),
            ],
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('Menu status', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      const SizedBox(width: 12),
                      if (overallStatus == MenuItemStatus.published)
                        StatusBadge.published()
                      else if (overallStatus == MenuItemStatus.draft)
                        StatusBadge.draft()
                      else
                        const StatusBadge(label: 'No menu yet', color: Colors.grey),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    total == 0
                        ? 'Upload a menu to get started — customers see nothing until you publish.'
                        : drafts > 0
                            ? '$drafts item${drafts == 1 ? '' : 's'} detected and waiting for review before they go live.'
                            : 'Everything is published. Customers see your current menu.',
                    style: const TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton.icon(
                        onPressed: () => context.go('/admin/menu'),
                        icon: const Icon(Icons.restaurant_menu_outlined, size: 18),
                        label: const Text('Manage Menu'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => context.go('/admin/menu/upload'),
                        icon: const Icon(Icons.upload_file_outlined, size: 18),
                        label: const Text('Upload New Menu'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _relativeDay(DateTime dt) {
    final now = DateTime.now();
    final localDt = dt.toLocal();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(localDt.year, localDt.month, localDt.day);
    if (day == today) return 'Today';
    if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
    return DateFormat.yMMMd().format(localDt);
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final bool highlight;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: (highlight ? adminWarning : adminSeedColor).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: highlight ? adminWarning : adminSeedColor, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                    Text(label, style: const TextStyle(fontSize: 12, color: Colors.black54)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
