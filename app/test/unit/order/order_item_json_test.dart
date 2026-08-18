import 'package:flutter_test/flutter_test.dart';

import 'package:barista_voice/models/order.dart';

void main() {
  group('OrderItem.specialRequest', () {
    test('round-trips through toJson/fromJson', () {
      final item = OrderItem(
        menuItemId: 'cappuccino',
        name: 'Cappuccino',
        specialRequest: 'extra hot, no lid',
      );

      final decoded = OrderItem.fromJson(item.toJson());

      expect(decoded.specialRequest, 'extra hot, no lid');
    });

    test('is null when absent from JSON', () {
      final decoded = OrderItem.fromJson({
        'menuItemId': 'cappuccino',
        'name': 'Cappuccino',
      });

      expect(decoded.specialRequest, isNull);
    });

    test('copyWith can set a special request', () {
      final item = OrderItem(menuItemId: 'cappuccino', name: 'Cappuccino');

      final updated = item.copyWith(specialRequest: 'light ice');

      expect(updated.specialRequest, 'light ice');
      expect(item.specialRequest, isNull); // original untouched
    });
  });
}
