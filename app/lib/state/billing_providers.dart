import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../data/billing/subscription_service.dart';

final subscriptionServiceProvider = Provider<SubscriptionService>((ref) {
  return SubscriptionService();
});

/// Whether the signed-in café admin has an active premium entitlement — a
/// live stream (RevenueCat's `addCustomerInfoUpdateListener` under the
/// hood), not a one-shot check, so a renewal/expiration/refund, or the
/// purchase made through the paywall itself, updates AnalyticsScreen without
/// needing a manual `ref.invalidate`. AsyncValue-compatible, so existing
/// `.when(...)` call sites needed no changes when this became a
/// StreamProvider.
final hasPremiumEntitlementProvider = StreamProvider<bool>((ref) {
  final service = ref.watch(subscriptionServiceProvider);
  return service.entitlementStream(premiumEntitlementId);
});

/// The "current" offering configured in the RevenueCat dashboard — null
/// before any Products/Offerings exist there yet, which PaywallScreen
/// treats as a normal (if unhelpful-to-the-user) empty state, not an error.
final currentOfferingProvider = FutureProvider<Offering?>((ref) async {
  final service = ref.watch(subscriptionServiceProvider);
  return service.getCurrentOffering();
});
