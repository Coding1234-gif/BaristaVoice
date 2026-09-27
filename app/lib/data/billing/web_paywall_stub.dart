/// Non-web builds use purchases_ui_flutter's native PaywallView instead —
/// see PaywallScreen. Never called there.
Future<String> presentWebPaywall(String offeringId) =>
    throw UnsupportedError('presentWebPaywall is web-only');
