import 'package:supabase_flutter/supabase_flutter.dart';

import 'stripe_billing_models.dart';

/// Success/cancel redirect targets for the Stripe Checkout (setup mode)
/// payment-method flow — a custom-scheme deep link back into this app's
/// own `/admin/billing` route (see AndroidManifest.xml's intent-filter,
/// which matches any path under the `baristavoice://open` host). Stripe
/// collects the card entirely on its hosted page; this app never sees it.
const stripeSetupSuccessUrl = 'baristavoice://open/admin/billing?stripe_setup=success';
const stripeSetupCancelUrl = 'baristavoice://open/admin/billing?stripe_setup=cancel';

/// Thin wrapper around the three `stripe-*` Edge Functions — same seam
/// pattern as PaymentTransport/EdgeFunctionPaymentService: this app never
/// talks to Stripe directly, and never sees a Stripe secret key.
class StripeBillingRepository {
  final SupabaseClient _client;

  StripeBillingRepository(this._client);

  Future<BillingStatus> getBillingStatus({required String cafeId}) async {
    final result = await _invoke('stripe-billing-status', {'cafeId': cafeId});
    return BillingStatus.fromJson(Map<String, dynamic>.from(result));
  }

  /// Returns the Stripe Checkout URL to open externally (see
  /// UsageBillingScreen — this app never collects card details itself).
  Future<String> startPaymentMethodSetup({required String cafeId}) async {
    final result = await _invoke('stripe-setup-payment-method', {
      'cafeId': cafeId,
      'successUrl': stripeSetupSuccessUrl,
      'cancelUrl': stripeSetupCancelUrl,
    });
    final url = result['url'] as String?;
    if (url == null) throw const StripeBillingException('Could not start payment method setup.');
    return url;
  }

  /// Manually triggers usage-invoice generation for a period (defaults to
  /// last calendar month, Europe/London — see the Edge Function). This is
  /// the MVP's stand-in for a scheduled monthly job: safe to call more
  /// than once for the same period, since the Edge Function is idempotent
  /// (see its own header comment and cafe_usage's unique constraint).
  Future<UsagePeriodRecord> generateUsageInvoice({required String cafeId, String? periodStartDate}) async {
    final result = await _invoke('stripe-generate-usage-invoice', {
      'cafeId': cafeId,
      if (periodStartDate != null) 'periodStartDate': periodStartDate,
    });
    final usage = result['usage'];
    if (usage is! Map) throw const StripeBillingException('Could not generate usage invoice.');
    return UsagePeriodRecord.fromJson(Map<String, dynamic>.from(usage));
  }

  Future<Map<String, dynamic>> _invoke(String functionName, Map<String, dynamic> body) async {
    try {
      final response = await _client.functions.invoke(functionName, body: body);
      final data = response.data;
      if (response.status == 200 && data is Map) {
        return Map<String, dynamic>.from(data);
      }
      throw StripeBillingException(_errorMessage(data));
    } on FunctionException catch (e) {
      throw StripeBillingException(_errorMessage(e.details));
    }
  }

  String _errorMessage(Object? data) {
    if (data is Map && data['error'] is String) return data['error'] as String;
    return 'Something went wrong. Please try again.';
  }
}
