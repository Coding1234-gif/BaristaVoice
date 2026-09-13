import 'package:intl/intl.dart';

import '../../models/menu.dart';
import '../../models/order.dart';

final _currencyFormat = NumberFormat.simpleCurrency(name: 'GBP');

/// Builds a spoken order confirmation directly from the structured [order]
/// and [menu] — never from anything the LLM said — so the spoken summary
/// and the structured order can never disagree. Mirrors the wording
/// `OrderSummaryPanel` renders on screen (see `_optionsLine`).
String buildOrderConfirmationSpeech(Order order, CafeMenu menu) {
  final items = order.items.map(_describeItem).join(', ');
  final total = _currencyFormat.format(order.total(menu));
  return "Just to confirm: $items. Your total is $total. Is that correct?";
}

/// What to speak once the server has actually finished creating the order —
/// never before, and never claiming more than the backend reported.
/// [posStatus] is whatever `pos-square-order-submit` returned (via
/// `OrderSubmissionResult.posStatus`); only `'sent_to_pos'` means the order
/// genuinely reached the café's POS. Every other value — `pos_failed`, no
/// connection, or null — still means the order itself is safely confirmed
/// and persisted, so this never says anything false, just less specific.
String buildOrderConfirmedSpeech(String? posStatus) {
  if (posStatus == 'sent_to_pos') {
    return "Great, that's confirmed and sent to the kitchen! We'll get started on it right away.";
  }
  return "Great, that's confirmed! We'll get started on it right away.";
}

/// Spoken (and shown) when the server-side confirm call itself fails — the
/// order was NOT created, so this must never sound like a success.
const String orderConfirmationFailedSpeech =
    "Sorry, something went wrong confirming your order. Please try again.";

/// Spoken once the Terminal checkout has actually started — i.e. the order
/// itself is safe and the customer just needs to pay, not before (see
/// `KioskController._beginPayment`).
const String paymentPendingSpeech =
    "Please tap, insert, or swipe your card on the terminal to pay.";

/// Spoken once `pos-square-order-pay` reports the payment as captured —
/// never before that, so this can't say "paid" while Square hasn't actually
/// confirmed it.
const String paymentSucceededSpeech =
    "Payment received — thank you! We'll get your order ready.";

/// Spoken when starting the Terminal checkout fails, or when polling for
/// payment ends in a hard failure or times out. [reason] is always a
/// customer-safe message already produced by [PaymentServiceException] or
/// the poll timeout — never a raw Square/Supabase error.
String buildPaymentFailedSpeech(String reason) =>
    "Sorry, $reason";

String _describeItem(OrderItem item) {
  final options = <String>[];
  if (item.size != null) options.add(item.size!);
  if (item.temperature != null) options.add(item.temperature!);
  if (item.milk != null) options.add('${item.milk} milk');
  if (item.decaf) options.add('decaf');
  options.addAll(item.modifiers);
  if (item.specialRequest != null && item.specialRequest!.trim().isNotEmpty) {
    options.add(item.specialRequest!.trim());
  }

  final optionsText = options.isEmpty ? '' : ' with ${options.join(', ')}';
  final quantityText = item.quantity > 1 ? '${item.quantity} ' : '';
  return '$quantityText${item.name}$optionsText';
}
