import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/billing/stripe_billing_models.dart';
import '../data/billing/stripe_billing_repository.dart';
import 'admin_providers.dart';

/// The Stripe 5p-per-item usage billing lane — kept in its own file,
/// separate from billing_providers.dart (RevenueCat's £79/month
/// subscription), so the two billing systems this app has never get
/// conflated. See UsageBillingScreen.
final stripeBillingRepositoryProvider = Provider<StripeBillingRepository>((ref) {
  return StripeBillingRepository(Supabase.instance.client);
});

/// Auto-disposing (default FutureProvider behaviour): the billing screen
/// invalidates this after starting payment-method setup or generating an
/// invoice, so it always refetches rather than trusting client-side state.
final billingStatusProvider = FutureProvider<BillingStatus?>((ref) async {
  final cafeId = ref.watch(activeCafeIdProvider);
  if (cafeId == null) return null;
  return ref.watch(stripeBillingRepositoryProvider).getBillingStatus(cafeId: cafeId);
});
