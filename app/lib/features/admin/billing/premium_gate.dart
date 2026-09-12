import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/billing_providers.dart';
import '../widgets/admin_states.dart';
import 'paywall_screen.dart';

/// Wraps a whole admin screen so it can't be used at all without an active
/// `premium` subscription — shows [PaywallScreen] in its place rather than
/// the real screen. Used for every /admin/** route except Overview itself
/// (see router.dart), so a non-paying café can look around but can't upload
/// a menu, edit products, see their QR code, or view analytics.
class PremiumGate extends ConsumerWidget {
  final Widget child;
  final String featureName;
  final String featureDescription;

  const PremiumGate({
    super.key,
    required this.child,
    required this.featureName,
    required this.featureDescription,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entitledAsync = ref.watch(hasPremiumEntitlementProvider);

    return entitledAsync.when(
      loading: () => const Scaffold(body: AdminLoadingState()),
      error: (e, _) => Scaffold(body: AdminErrorState(message: 'Could not check your subscription: $e')),
      data: (entitled) =>
          entitled ? child : PaywallScreen(featureName: featureName, featureDescription: featureDescription),
    );
  }
}
