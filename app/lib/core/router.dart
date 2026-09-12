import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/admin/admin_shell.dart';
import '../features/admin/analytics/analytics_screen.dart';
import '../features/admin/billing/premium_gate.dart';
import '../features/admin/dashboard/admin_dashboard_screen.dart';
import '../features/admin/login/admin_login_screen.dart';
import '../features/admin/menu/menu_management_screen.dart';
import '../features/admin/menu/menu_upload_screen.dart';
import '../features/admin/products/products_screen.dart';
import '../features/admin/settings/admin_settings_screen.dart';
import '../features/kiosk/cafe_entry_screen.dart';
import '../features/kiosk/kiosk_screen.dart';
import '../features/kiosk/profile_screen.dart';
import '../state/auth_providers.dart';

/// IMPORTANT: this redirect logic is a navigation convenience only — it
/// decides which SCREEN to show, not what data is reachable. The actual
/// security boundary is Supabase RLS (see supabase/schema.sql): even if this
/// logic were buggy, disabled, or bypassed by editing the client, the
/// database itself refuses to return another cafe's rows or any row at all
/// to a non-admin. A customer manually navigating to /admin gets bounced
/// here for UX reasons, but would also get empty results from every admin
/// query even if they somehow reached the dashboard widgets.
final routerProvider = Provider<GoRouter>((ref) {
  final authService = ref.watch(authServiceProvider);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: GoRouterRefreshStream(
      authService?.onAuthStateChange ?? const Stream.empty(),
    ),
    redirect: (context, state) async {
      final loc = state.matchedLocation;
      if (!loc.startsWith('/admin')) return null;

      final onLoginPage = loc == '/admin/login';

      if (authService == null || authService.currentSession == null) {
        return onLoginPage ? null : '/admin/login';
      }

      final profile = await authService.fetchCurrentProfile();
      if (profile == null || !profile.canAccessAdmin) {
        return onLoginPage ? null : '/admin/login?denied=1';
      }

      return onLoginPage ? '/admin' : null;
    },
    routes: [
      GoRoute(path: '/', builder: (context, state) => const KioskScreen()),
      GoRoute(path: '/profile', builder: (context, state) => const ProfileScreen()),
      GoRoute(
        path: '/cafe/:cafeId',
        builder: (context, state) =>
            CafeEntryScreen(cafeIdOrSlug: state.pathParameters['cafeId']!),
      ),
      GoRoute(
        path: '/admin/login',
        builder: (context, state) => AdminLoginScreen(
          accessDenied: state.uri.queryParameters['denied'] == '1',
        ),
      ),
      ShellRoute(
        builder: (context, state, child) =>
            AdminShell(currentLocation: state.matchedLocation, child: child),
        routes: [
          // Overview is the only free admin screen — every other tab is
          // gated behind the premium subscription (see PremiumGate), so a
          // non-paying café can sign in and look around but can't upload a
          // menu, edit products, see their QR code, or view analytics.
          GoRoute(path: '/admin', builder: (context, state) => const AdminDashboardScreen()),
          GoRoute(path: '/admin/analytics', builder: (context, state) => const AnalyticsScreen()),
          GoRoute(
            path: '/admin/menu',
            builder: (context, state) => const PremiumGate(
              featureName: 'Menu Management',
              featureDescription: 'Add, edit, and publish your café\'s menu items.',
              child: MenuManagementScreen(),
            ),
          ),
          GoRoute(
            path: '/admin/menu/upload',
            builder: (context, state) => const PremiumGate(
              featureName: 'Menu Upload',
              featureDescription: 'Upload a menu PDF or photo and let AI turn it into structured menu items.',
              child: MenuUploadScreen(),
            ),
          ),
          GoRoute(
            path: '/admin/products',
            builder: (context, state) => const PremiumGate(
              featureName: 'Products',
              featureDescription: 'Manage individual product photos, pricing, and availability.',
              child: ProductsScreen(),
            ),
          ),
          GoRoute(
            path: '/admin/settings',
            builder: (context, state) => const PremiumGate(
              featureName: 'Café Settings',
              featureDescription: 'Manage your café profile and download your ordering QR code.',
              child: AdminSettingsScreen(),
            ),
          ),
        ],
      ),
    ],
  );
});

/// Bridges a broadcast Stream (Supabase's auth state changes) to a
/// [Listenable] go_router can use to re-run `redirect` on sign-in/out.
class GoRouterRefreshStream extends ChangeNotifier {
  late final StreamSubscription<dynamic> _subscription;

  GoRouterRefreshStream(Stream<dynamic> stream) {
    _subscription = stream.asBroadcastStream().listen((_) => notifyListeners());
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
