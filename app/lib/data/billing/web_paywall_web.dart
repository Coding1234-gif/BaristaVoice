import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Presents the Paywall published for [offeringId] in the RevenueCat
/// dashboard — the same design PaywallView renders natively on Android/iOS —
/// as a full-screen overlay above the Flutter app, and runs the purchase
/// through it (a Test Store purchase with a `test_` key).
///
/// purchases_ui_flutter has no web implementation, but purchases_flutter's
/// web plugin already loads RevenueCat's web SDK (purchases-js, as
/// `window.PurchasesHybridMappings`) and configures it in
/// `Purchases.configure`; that SDK can render dashboard paywalls itself, the
/// Flutter plugin just doesn't route a method to it. So call it directly on
/// the same configured instance.
///
/// Resolves to "PURCHASED", "USER_CANCELLED", "NOT_PRESENTED" or "ERROR"
/// (the SDK logs the underlying error to the browser console).
Future<String> presentWebPaywall(String offeringId) async {
  final mappings = globalContext['PurchasesHybridMappings'] as JSObject;
  final common = mappings['PurchasesCommon'] as JSObject;
  final instance = common.callMethod<JSObject>('getInstance'.toJS);
  final options = {'offeringIdentifier': offeringId}.jsify();
  final result = await instance.callMethod<JSPromise<JSString>>('presentPaywall'.toJS, options).toDart;
  return result.toDart;
}
