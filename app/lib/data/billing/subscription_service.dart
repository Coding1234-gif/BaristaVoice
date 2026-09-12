import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:purchases_flutter/purchases_flutter.dart';

import '../../core/env.dart';

/// The RevenueCat entitlement identifier that unlocks café-facing premium
/// features (currently: the analytics dashboard). Must match an entitlement
/// of the same identifier configured in the RevenueCat dashboard — see
/// PaywallScreen's header comment for the exact dashboard setup this
/// expects.
const premiumEntitlementId = 'premium';

/// The RevenueCat Offering identifier the paywall reads its packages and
/// published Paywall design from. Looked up by this exact identifier rather
/// than relying on whichever offering the dashboard has marked "current" —
/// see [SubscriptionService.getCurrentOffering].
const defaultOfferingId = 'default_offering';

/// Thin wrapper around package:purchases_flutter — the only file in this
/// app that imports it directly, matching the seam pattern already used for
/// Square/Supabase (see PaymentService, OrderSubmissionService).
///
/// A deliberate no-op wherever RevenueCat can't actually run: the Shipaton
/// submission is the mobile (Android/iOS) app, but this same codebase also
/// runs as a web build for local dev/demo (see main.dart's usePathUrlStrategy
/// comment) — purchases_flutter has no web platform implementation at all.
/// Rather than every caller checking kIsWeb itself, [isSupported] is false
/// on web and every method degrades to a safe default, so the web build
/// keeps working (with premium features simply always unlocked there —
/// see [isEntitled]) instead of crashing.
class SubscriptionService {
  bool get isSupported => !kIsWeb && Env.isRevenueCatConfigured;

  /// Call once at startup, after Supabase is initialized (see main.dart).
  Future<void> configure() async {
    if (!isSupported) return;
    // The Test Store key works identically on either platform, so it takes
    // priority whenever it's set — the whole point of RevenueCat's Test
    // Store is exercising the purchase flow before real store products
    // exist. Leave REVENUECAT_API_KEY_TEST unset in a production `.env` to
    // fall back to the real per-platform key.
    final apiKey = Env.revenueCatApiKeyTest.isNotEmpty
        ? Env.revenueCatApiKeyTest
        : (Platform.isIOS ? Env.revenueCatApiKeyIos : Env.revenueCatApiKeyAndroid);
    if (apiKey.isEmpty) return;

    await Purchases.setLogLevel(LogLevel.warn);
    await Purchases.configure(PurchasesConfiguration(apiKey));
  }

  /// Ties RevenueCat's subscriber identity to the signed-in café admin's
  /// Supabase user id, so a subscription follows them across devices/sign-ins
  /// rather than staying anonymous. Call right after a successful sign-in or
  /// signup — see AuthService.
  Future<void> logIn(String appUserId) async {
    if (!isSupported) return;
    await Purchases.logIn(appUserId);
  }

  /// Call on sign-out so the next signed-in user (on a shared device) never
  /// inherits the previous admin's subscription state.
  Future<void> logOut() async {
    if (!isSupported) return;
    if (await Purchases.isConfigured) {
      await Purchases.logOut();
    }
  }

  /// Whether the current subscriber has an active [entitlementId]. Always
  /// true where RevenueCat isn't supported (web) — this app's Shipaton
  /// submission target is mobile, so the web build stays a fully-open dev
  /// convenience rather than needing its own paywall.
  Future<bool> isEntitled(String entitlementId) async {
    if (!isSupported) return true;
    final info = await Purchases.getCustomerInfo();
    return info.entitlements.active.containsKey(entitlementId);
  }

  /// Live version of [isEntitled] — RevenueCat's recommended pattern
  /// (`addCustomerInfoUpdateListener`) instead of a one-shot check, so a
  /// renewal, expiration, refund, or a purchase made elsewhere (another
  /// device, the RevenueCat dashboard) updates the UI without the customer
  /// needing to reopen the screen. Emits the current state immediately
  /// (the listener fires right away with the last-known CustomerInfo), then
  /// again on every subsequent change. Always just `true`, once, where
  /// RevenueCat isn't supported (web) — see [isSupported].
  Stream<bool> entitlementStream(String entitlementId) {
    if (!isSupported) return Stream.value(true);

    late final CustomerInfoUpdateListener listener;
    final controller = StreamController<bool>();
    listener = (CustomerInfo info) {
      controller.add(info.entitlements.active.containsKey(entitlementId));
    };
    controller.onListen = () => Purchases.addCustomerInfoUpdateListener(listener);
    controller.onCancel = () => Purchases.removeCustomerInfoUpdateListener(listener);
    return controller.stream;
  }

  /// The [defaultOfferingId] offering, falling back to whichever offering
  /// the dashboard has marked "current" if an offering with that exact
  /// identifier doesn't exist (e.g. local dev against a project that hasn't
  /// been set up yet). Null if RevenueCat isn't supported here or neither
  /// resolves to anything (e.g. before any Products/Offerings have been set
  /// up — see PaywallScreen, which handles that as a normal empty state,
  /// not an error).
  Future<Offering?> getCurrentOffering() async {
    if (!isSupported) return null;
    final offerings = await Purchases.getOfferings();
    return offerings.getOffering(defaultOfferingId) ?? offerings.current;
  }

  /// Uses the modern `purchase(PurchaseParams)` API — `purchasePackage()` is
  /// deprecated as of purchases_flutter 10.x in favor of this.
  Future<CustomerInfo> purchase(Package package) async {
    final result = await Purchases.purchase(PurchaseParams.package(package));
    return result.customerInfo;
  }

  Future<CustomerInfo> restore() => Purchases.restorePurchases();
}
