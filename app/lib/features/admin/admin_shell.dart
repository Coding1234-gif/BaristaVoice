import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/admin_theme.dart';
import '../../data/auth/profile.dart';
import '../../state/admin_providers.dart';
import '../../state/auth_providers.dart';
import 'widgets/admin_states.dart';

class _NavItem {
  final String label;
  final IconData icon;
  final String location;

  const _NavItem(this.label, this.icon, this.location);
}

const _navItems = [
  _NavItem('Overview', Icons.dashboard_outlined, '/admin'),
  _NavItem('Analytics', Icons.bar_chart_outlined, '/admin/analytics'),
  _NavItem('Menu', Icons.restaurant_menu_outlined, '/admin/menu'),
  _NavItem('Products', Icons.local_cafe_outlined, '/admin/products'),
  _NavItem('Settings', Icons.settings_outlined, '/admin/settings'),
];

/// Sidebar-nav SaaS shell wrapping every /admin/** screen. Applies its own
/// theme so it looks nothing like the customer kiosk.
class AdminShell extends ConsumerWidget {
  final String currentLocation;
  final Widget child;

  const AdminShell({super.key, required this.currentLocation, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(currentProfileProvider);
    final isWide = MediaQuery.of(context).size.width >= 900;

    return AdminThemeScope(
      child: Builder(builder: (context) {
        return profileAsync.when(
          loading: () => const Scaffold(body: AdminLoadingState()),
          error: (e, _) => Scaffold(body: AdminErrorState(message: 'Could not load account: $e')),
          data: (profile) {
            if (profile == null || !profile.canAccessAdmin) {
              // Router redirect should already prevent reaching here; this
              // is the belt-and-braces UI fallback.
              return const Scaffold(body: AdminErrorState(message: 'Access denied.'));
            }

            final content = _CafeGate(profile: profile, child: child);

            if (isWide) {
              return Scaffold(
                body: Row(
                  children: [
                    _Sidebar(profile: profile, currentLocation: currentLocation),
                    Expanded(child: content),
                  ],
                ),
              );
            }

            return Scaffold(
              appBar: AppBar(title: const Text('Café Admin')),
              drawer: Drawer(child: _SidebarContent(profile: profile, currentLocation: currentLocation)),
              body: content,
            );
          },
        );
      }),
    );
  }
}

class _Sidebar extends StatelessWidget {
  final Profile profile;
  final String currentLocation;

  const _Sidebar({required this.profile, required this.currentLocation});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 240,
      color: Colors.white,
      child: Column(
        children: [
          Expanded(child: _SidebarContent(profile: profile, currentLocation: currentLocation)),
        ],
      ),
    );
  }
}

class _SidebarContent extends ConsumerWidget {
  final Profile profile;
  final String currentLocation;

  const _SidebarContent({required this.profile, required this.currentLocation});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cafeAsync = ref.watch(activeCafeProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: adminSeedColor,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.storefront, color: Colors.white, size: 18),
              ),
              const SizedBox(width: 10),
              const Text('Café Admin', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: cafeAsync.when(
            loading: () => const SizedBox(height: 16),
            error: (_, __) => const SizedBox.shrink(),
            data: (cafe) => Text(
              cafe?.name ?? (profile.role == AppRole.superAdmin ? 'No café selected' : ''),
              style: const TextStyle(fontSize: 13, color: Colors.black54),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (profile.role == AppRole.superAdmin) const _CafeSwitcher(),
        const SizedBox(height: 8),
        const Divider(),
        const SizedBox(height: 8),
        for (final item in _navItems)
          _SidebarLink(
            item: item,
            selected: currentLocation == item.location,
          ),
        const Spacer(),
        const Divider(),
        _SidebarFooter(profile: profile),
      ],
    );
  }
}

class _SidebarLink extends StatelessWidget {
  final _NavItem item;
  final bool selected;

  const _SidebarLink({required this.item, required this.selected});

  @override
  Widget build(BuildContext context) {
    final color = selected ? adminSeedColor : Colors.black87;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: selected ? adminSeedColor.withValues(alpha: 0.08) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => context.go(item.location),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                Icon(item.icon, size: 20, color: color),
                const SizedBox(width: 12),
                Text(
                  item.label,
                  style: TextStyle(color: color, fontWeight: selected ? FontWeight.w700 : FontWeight.w500),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarFooter extends ConsumerWidget {
  final Profile profile;
  const _SidebarFooter({required this.profile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: adminSeedColor.withValues(alpha: 0.15),
            child: Text(
              (profile.displayName?.isNotEmpty == true ? profile.displayName![0] : '?').toUpperCase(),
              style: const TextStyle(color: adminSeedColor, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              profile.role == AppRole.superAdmin ? 'Super admin' : (profile.displayName ?? 'Café admin'),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout, size: 18),
            onPressed: () async {
              await ref.read(authServiceProvider)?.signOut();
              if (context.mounted) context.go('/admin/login');
            },
          ),
        ],
      ),
    );
  }
}

class _CafeSwitcher extends ConsumerWidget {
  const _CafeSwitcher();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cafesAsync = ref.watch(allCafesProvider);
    final selected = ref.watch(selectedCafeIdProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: cafesAsync.when(
        loading: () => const LinearProgressIndicator(),
        error: (_, __) => const Text('Could not load cafés', style: TextStyle(fontSize: 12)),
        data: (cafes) => DropdownButtonFormField<String>(
          initialValue: selected,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Managing café'),
          hint: const Text('Select a café'),
          items: [
            for (final cafe in cafes) DropdownMenuItem(value: cafe.id, child: Text(cafe.name)),
          ],
          onChanged: (id) => ref.read(selectedCafeIdProvider.notifier).state = id,
        ),
      ),
    );
  }
}

/// For a super_admin with no café selected yet, show a picker instead of the
/// requested screen (every admin data provider is keyed off activeCafeId).
class _CafeGate extends ConsumerWidget {
  final Profile profile;
  final Widget child;

  const _CafeGate({required this.profile, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (profile.role == AppRole.superAdmin) {
      final activeCafeId = ref.watch(activeCafeIdProvider);
      if (activeCafeId == null) {
        return const AdminEmptyState(
          icon: Icons.storefront_outlined,
          title: 'Select a café to manage',
          message: 'Use the switcher in the sidebar to choose which café\'s dashboard to view.',
        );
      }
    }
    return child;
  }
}
