import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../data/history/visited_cafe.dart';
import '../../state/cafe_providers.dart';
import '../../state/theme_providers.dart';

/// Customer-facing profile — no login, so this is entirely on-device state:
/// the "order again" history (see VisitedCafesRepository) of cafés this
/// customer has ordered from on this device. Reachable from the kiosk's
/// café-selection screen (see KioskScreen's _ProfileLink).
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visitedAsync = ref.watch(visitedCafesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: visitedAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not load your café history.', textAlign: TextAlign.center),
          ),
        ),
        data: (visited) => _ProfileBody(visited: visited),
      ),
    );
  }
}

class _ProfileBody extends ConsumerWidget {
  final List<VisitedCafe> visited;
  const _ProfileBody({required this.visited});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDarkMode = ref.watch(themeModeProvider) == ThemeMode.dark;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Text('Appearance', style: Theme.of(context).textTheme.titleMedium),
        ),
        Card(
          child: SwitchListTile(
            title: const Text('Dark mode'),
            secondary: const Icon(Icons.dark_mode_outlined),
            value: isDarkMode,
            onChanged: (enabled) => ref.read(themeModeProvider.notifier).setDarkMode(enabled),
          ),
        ),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Text('Your cafés', style: Theme.of(context).textTheme.titleMedium),
        ),
        if (visited.isEmpty)
          const _EmptyHistory()
        else
          for (final cafe in visited)
            _VisitedCafeTile(
              cafe: cafe,
              onOrderAgain: () async {
                await ref.read(currentCafeIdProvider.notifier).setCafe(cafe.id);
                if (context.mounted) context.go('/');
              },
              onRemove: () async {
                await ref.read(visitedCafesRepositoryProvider).remove(cafe.id);
                ref.invalidate(visitedCafesProvider);
              },
            ),
      ],
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Icon(Icons.storefront_outlined, size: 40, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            "You haven't ordered from a café yet.",
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _VisitedCafeTile extends StatelessWidget {
  final VisitedCafe cafe;
  final VoidCallback onOrderAgain;
  final VoidCallback onRemove;

  const _VisitedCafeTile({required this.cafe, required this.onOrderAgain, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: CircleAvatar(
          radius: 20,
          backgroundColor: theme.colorScheme.primaryContainer,
          backgroundImage: cafe.logoUrl != null ? NetworkImage(cafe.logoUrl!) : null,
          child: cafe.logoUrl == null
              ? Icon(Icons.storefront, color: theme.colorScheme.primary)
              : null,
        ),
        title: Text(cafe.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('Last visited ${_relativeDate(cafe.lastVisitedAt)}'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            OutlinedButton(onPressed: onOrderAgain, child: const Text('Order again')),
            IconButton(
              tooltip: 'Remove from history',
              icon: const Icon(Icons.close, size: 18),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }

  String _relativeDate(DateTime dt) {
    final now = DateTime.now();
    final local = dt.toLocal();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(local.year, local.month, local.day);
    if (day == today) return 'today';
    if (day == today.subtract(const Duration(days: 1))) return 'yesterday';
    return DateFormat.yMMMd().format(local);
  }
}
