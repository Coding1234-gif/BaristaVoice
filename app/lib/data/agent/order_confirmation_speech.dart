import 'package:intl/intl.dart';

import '../../models/menu.dart';
import '../../models/order.dart';

final _currencyFormat = NumberFormat.simpleCurrency(name: 'USD');

/// Builds a spoken order confirmation directly from the structured [order]
/// and [menu] — never from anything the LLM said — so the spoken summary
/// and the structured order can never disagree. Mirrors the wording
/// `OrderSummaryPanel` renders on screen (see `_optionsLine`).
String buildOrderConfirmationSpeech(Order order, CafeMenu menu) {
  final items = order.items.map(_describeItem).join(', ');
  final total = _currencyFormat.format(order.total(menu));
  return "Just to confirm: $items. Your total is $total. Is that correct?";
}

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
