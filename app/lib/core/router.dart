import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/admin/admin_shell.dart';
import '../features/admin/dashboard/admin_dashboard_screen.dart';
import '../features/admin/login/admin_login_screen.dart';
import '../features/admin/menu/menu_management_screen.dart';
import '../features/admin/menu/menu_upload_screen.dart';
import '../features/admin/products/products_screen.dart';
import '../features/admin/settings/admin_settings_screen.dart';
import '../features/kiosk/kiosk_screen.dart';
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
          GoRoute(path: '/admin', builder: (context, state) => const AdminDashboardScreen()),
          GoRoute(
            path: '/admin/menu',
            builder: (context, state) => const MenuManagementScreen(),
          ),
          GoRoute(
            path: '/admin/menu/upload',
            builder: (context, state) => const MenuUploadScreen(),
          ),
          GoRoute(path: '/admin/products', builder: (context, state) => const ProductsScreen()),
          GoRoute(
            path: '/admin/settings',
            builder: (context, state) => const AdminSettingsScreen(),
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
