// Gates a premium café-admin feature behind a RevenueCat subscription — see
// PremiumGate, which wraps every gated screen in this one paywall.
//
// Renders RevenueCat's own hosted Paywall (purchases_ui_flutter's
// PaywallView) for the `default_offering` offering — its design/copy/pricing
// come from whatever Paywall template is published for that offering in the
// RevenueCat dashboard, not hardcoded here. IMPORTANT: PaywallView shows
// literally nothing (no error) if that offering has no *published* Paywall
// template — a separate dashboard step from just creating
// Products/Offerings/Packages. If this screen ever looks blank again,
// that's the first thing to check, not this code.
//
// RevenueCat dashboard setup this expects:
//   - A Product (e.g. a monthly/yearly "Café Pro" subscription) attached to
//     your Play Store/App Store app.
//   - An Entitlement identified exactly as `premiumEntitlementId`
//     ("premium" — see subscription_service.dart) granted by that product.
//   - An Offering identified exactly as `defaultOfferingId`
//     ("default_offering") containing a Package for that product, with a
//     Paywall designed AND PUBLISHED for it.
// Until that's configured, [currentOfferingProvider] resolves to null/empty
// and this screen shows a plain empty state instead of an empty native
// view — safe to ship before the dashboard side is finished.
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_ui_flutter/purchases_ui_flutter.dart';

import '../../../core/admin_theme.dart';
import '../../../data/billing/subscription_service.dart';
import '../../../data/billing/web_paywall.dart';
import '../../../state/billing_providers.dart';
import '../widgets/admin_states.dart';

class PaywallScreen extends ConsumerWidget {
  /// Shown only on the "not configured yet" empty state — the published
  /// Paywall template supplies the real copy/design otherwise.
  final String featureName;
  final String featureDescription;

  const PaywallScreen({
    super.key,
    this.featureName = 'Café Pro',
    this.featureDescription =
        'Unlock menu management, product photos, your QR code, and café analytics.',
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offeringAsync = ref.watch(currentOfferingProvider);

    return Scaffold(
      appBar: AppBar(title: Text(featureName)),
      body: offeringAsync.when(
        loading: () => const AdminLoadingState(),
        error: (e, _) => AdminErrorState(
          message: 'Could not load subscription plans: $e',
          onRetry: () => ref.invalidate(currentOfferingProvider),
        ),
        data: (offering) {
          final hasPackages = offering != null && offering.availablePackages.isNotEmpty;
          if (!hasPackages) {
            return _NotConfiguredYet(featureName: featureName, featureDescription: featureDescription);
          }

          // PaywallView is native-only; on web the same published Paywall is
          // rendered by RevenueCat's web SDK instead — see web_paywall_web.dart.
          if (kIsWeb) {
            return _WebPaywall(featureName: featureName, featureDescription: featureDescription);
          }

          // hasPremiumEntitlementProvider is a live stream (see
          // billing_providers.dart) — it picks up a successful
          // purchase/restore on its own, no manual invalidate needed here.
          return PaywallView(
            offering: offering,
            onPurchaseError: (error) => _showError(context, 'Could not complete the purchase. Please try again.'),
            onRestoreError: (error) => _showError(context, 'Could not restore purchases. Please try again.'),
          );
        },
      ),
    );
  }

  void _showError(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Opens RevenueCat's full-screen web paywall as soon as the gated screen is
/// shown (like the native PaywallView filling the screen), and leaves a
/// "View plans" button behind in case the customer closes it.
class _WebPaywall extends ConsumerStatefulWidget {
  final String featureName;
  final String featureDescription;
  const _WebPaywall({required this.featureName, required this.featureDescription});

  @override
  ConsumerState<_WebPaywall> createState() => _WebPaywallState();
}

class _WebPaywallState extends ConsumerState<_WebPaywall> {
  bool _presenting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _present());
  }

  Future<void> _present() async {
    if (_presenting) return;
    setState(() => _presenting = true);
    String result;
    try {
      result = await presentWebPaywall(defaultOfferingId);
    } catch (e) {
      result = 'ERROR';
      debugPrint('[paywall] web paywall failed: $e');
    }
    if (!mounted) return;
    setState(() => _presenting = false);
    if (result == 'PURCHASED' || result == 'NOT_PRESENTED') {
      // NOT_PRESENTED: already entitled — either way, re-check so
      // PremiumGate swaps this screen for the real one.
      ref.read(subscriptionServiceProvider).refreshEntitlements();
    } else if (result == 'ERROR') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not load subscription plans. Please try again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.workspace_premium_outlined, color: adminSeedColor, size: 40),
              const SizedBox(height: 16),
              Text(widget.featureName, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
              const SizedBox(height: 8),
              Text(widget.featureDescription,
                  style: const TextStyle(color: Colors.black54), textAlign: TextAlign.center),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _presenting ? null : _present,
                child: const Text('View plans'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NotConfiguredYet extends StatelessWidget {
  final String featureName;
  final String featureDescription;
  const _NotConfiguredYet({required this.featureName, required this.featureDescription});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: adminSeedColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.workspace_premium_outlined, color: adminSeedColor, size: 28),
              ),
              const SizedBox(height: 20),
              Text(featureName, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
              const SizedBox(height: 8),
              Text(featureDescription, style: const TextStyle(color: Colors.black54), textAlign: TextAlign.center),
              const SizedBox(height: 16),
              const Text(
                "Subscription plans aren't available yet. Please check back soon.",
                style: TextStyle(color: Colors.black54),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
