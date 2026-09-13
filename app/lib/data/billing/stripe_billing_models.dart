/// Models for the Stripe 5p-per-item usage billing lane — entirely
/// separate from RevenueCat's flat £79/month subscription (see
/// SubscriptionService/billing_providers.dart). Everything here is a
/// read-only projection of `stripe-billing-status`'s response; the server
/// (via calculate_cafe_usage() — see schema.sql) is always the source of
/// truth for the numbers, never anything computed client-side.
library;

enum CafeBillingStatus {
  noCustomer,
  pendingPaymentMethod,
  active,
  pastDue;

  static CafeBillingStatus fromDb(String? value) => switch (value) {
        'pending_payment_method' => CafeBillingStatus.pendingPaymentMethod,
        'active' => CafeBillingStatus.active,
        'past_due' => CafeBillingStatus.pastDue,
        _ => CafeBillingStatus.noCustomer,
      };
}

enum UsagePeriodStatus {
  calculated,
  invoiced,
  paid,
  paymentFailed;

  static UsagePeriodStatus fromDb(String? value) => switch (value) {
        'invoiced' => UsagePeriodStatus.invoiced,
        'paid' => UsagePeriodStatus.paid,
        'payment_failed' => UsagePeriodStatus.paymentFailed,
        _ => UsagePeriodStatus.calculated,
      };
}

class CafeBillingInfo {
  final CafeBillingStatus status;
  final String? stripeCustomerId;
  final bool hasPaymentMethod;

  const CafeBillingInfo({
    required this.status,
    required this.stripeCustomerId,
    required this.hasPaymentMethod,
  });

  factory CafeBillingInfo.fromJson(Map<String, dynamic> json) => CafeBillingInfo(
        status: CafeBillingStatus.fromDb(json['billing_status'] as String?),
        stripeCustomerId: json['stripe_customer_id'] as String?,
        hasPaymentMethod: json['stripe_default_payment_method_id'] != null,
      );
}

/// The still-open, not-yet-invoiced billing period — a live estimate,
/// never written to the database (see stripe-billing-status).
class CurrentUsagePeriod {
  final String label;
  final DateTime start;
  final DateTime end;
  final int itemCount;
  final int usagePence;
  final int baseSubscriptionPence;
  final int estimatedTotalPence;
  final int pencePerItem;

  const CurrentUsagePeriod({
    required this.label,
    required this.start,
    required this.end,
    required this.itemCount,
    required this.usagePence,
    required this.baseSubscriptionPence,
    required this.estimatedTotalPence,
    required this.pencePerItem,
  });

  double get usageGbp => usagePence / 100;
  double get baseSubscriptionGbp => baseSubscriptionPence / 100;
  double get estimatedTotalGbp => estimatedTotalPence / 100;

  factory CurrentUsagePeriod.fromJson(Map<String, dynamic> json) => CurrentUsagePeriod(
        label: json['label'] as String? ?? '',
        start: DateTime.parse(json['start'] as String),
        end: DateTime.parse(json['end'] as String),
        itemCount: json['itemCount'] as int? ?? 0,
        usagePence: json['usagePence'] as int? ?? 0,
        baseSubscriptionPence: json['baseSubscriptionPence'] as int? ?? 7900,
        estimatedTotalPence: json['estimatedTotalPence'] as int? ?? 7900,
        pencePerItem: json['pencePerItem'] as int? ?? 5,
      );
}

/// One already-reconciled (and usually invoiced) billing period — a
/// `cafe_usage` row.
class UsagePeriodRecord {
  final String id;
  final DateTime periodStart;
  final DateTime periodEnd;
  final int itemCount;
  final int usagePence;
  final UsagePeriodStatus status;
  final String? stripeInvoiceId;
  final DateTime? invoicedAt;
  final DateTime? paidAt;

  const UsagePeriodRecord({
    required this.id,
    required this.periodStart,
    required this.periodEnd,
    required this.itemCount,
    required this.usagePence,
    required this.status,
    required this.stripeInvoiceId,
    required this.invoicedAt,
    required this.paidAt,
  });

  double get usageGbp => usagePence / 100;

  /// £79 base + this period's usage — matches the business model's
  /// "Base subscription = £79.00 / Total = £141.00" example exactly.
  static const basePence = 7900;
  int get totalPence => basePence + usagePence;
  double get totalGbp => totalPence / 100;

  factory UsagePeriodRecord.fromJson(Map<String, dynamic> json) => UsagePeriodRecord(
        id: json['id'] as String,
        periodStart: DateTime.parse(json['billing_period_start'] as String),
        periodEnd: DateTime.parse(json['billing_period_end'] as String),
        itemCount: json['item_count'] as int? ?? 0,
        usagePence: json['usage_pence'] as int? ?? 0,
        status: UsagePeriodStatus.fromDb(json['status'] as String?),
        stripeInvoiceId: json['stripe_invoice_id'] as String?,
        invoicedAt: json['invoiced_at'] != null ? DateTime.parse(json['invoiced_at'] as String) : null,
        paidAt: json['paid_at'] != null ? DateTime.parse(json['paid_at'] as String) : null,
      );
}

class BillingStatus {
  final CafeBillingInfo cafeBilling;
  final CurrentUsagePeriod currentPeriod;
  final List<UsagePeriodRecord> history;

  const BillingStatus({
    required this.cafeBilling,
    required this.currentPeriod,
    required this.history,
  });

  factory BillingStatus.fromJson(Map<String, dynamic> json) => BillingStatus(
        cafeBilling: CafeBillingInfo.fromJson(Map<String, dynamic>.from(json['cafeBilling'] as Map)),
        currentPeriod: CurrentUsagePeriod.fromJson(Map<String, dynamic>.from(json['currentPeriod'] as Map)),
        history: (json['history'] as List? ?? [])
            .map((e) => UsagePeriodRecord.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}

class StripeBillingException implements Exception {
  final String message;
  const StripeBillingException(this.message);
  @override
  String toString() => message;
}
