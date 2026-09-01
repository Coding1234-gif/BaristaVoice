/// Result of successfully starting a Square Terminal checkout for an
/// already-submitted canonical order (see `pos-square-terminal-checkout`).
/// The canonical order's status is `payment_pending` once this succeeds.
class TerminalCheckoutResult {
  final String orderId;
  final String checkoutId;
  final String? checkoutStatus;

  const TerminalCheckoutResult({
    required this.orderId,
    required this.checkoutId,
    this.checkoutStatus,
  });
}

/// Result of one poll of `pos-square-order-pay`. [paid] is the only field
/// callers should branch on: `false` is a normal, expected "the customer
/// hasn't completed payment on the Terminal yet" outcome, not an error —
/// see that function's own header comment. [paymentId]/[status] are only
/// meaningful once [paid] is true.
class PaymentPollResult {
  final bool paid;
  final String? paymentId;
  final String? status;

  const PaymentPollResult({required this.paid, this.paymentId, this.status});
}

class PaymentServiceException implements Exception {
  final String message;
  const PaymentServiceException(this.message);
  @override
  String toString() => 'PaymentServiceException: $message';
}

/// Drives the two POS-payment steps after a canonical order has reached
/// Square: starting a Terminal checkout, then polling for its completion.
/// Implementations must never send or receive a Square access token,
/// location id, or product/modifier id — every POS-side detail is resolved
/// entirely server-side from the order id alone; see
/// `pos-square-terminal-checkout`/`pos-square-order-pay` in
/// supabase/functions.
abstract class PaymentService {
  Future<TerminalCheckoutResult> startTerminalCheckout({required String orderId});

  Future<PaymentPollResult> checkPayment({required String orderId});
}
