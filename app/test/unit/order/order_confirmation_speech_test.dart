import 'package:flutter_test/flutter_test.dart';

import 'package:barista_voice/data/agent/order_confirmation_speech.dart';
import 'package:barista_voice/models/menu.dart';
import 'package:barista_voice/models/order.dart';

void main() {
  const menu = CafeMenu(
    cafeName: 'Test Café',
    items: [
      MenuItem(
        id: 'cappuccino',
        name: 'Cappuccino',
        description: '',
        category: 'Drinks',
        basePrice: 4.0,
        popular: true,
        sizes: [PricedOption(name: 'Large', priceDelta: 1.0)],
        milkOptions: [PricedOption(name: 'Oat', priceDelta: 0.5)],
        temperatureOptions: ['hot', 'iced'],
        decafAvailable: true,
        modifiers: [],
      ),
      MenuItem(
        id: 'croissant',
        name: 'Chocolate Croissant',
        description: '',
        category: 'Food',
        basePrice: 3.5,
        popular: false,
        sizes: [],
        milkOptions: [],
        temperatureOptions: [],
        decafAvailable: false,
        modifiers: [],
      ),
    ],
  );

  test('describes a single plain item and the total', () {
    final order = Order(items: [
      OrderItem(menuItemId: 'croissant', name: 'Chocolate Croissant'),
    ]);

    final speech = buildOrderConfirmationSpeech(order, menu);

    expect(speech, 'Just to confirm: Chocolate Croissant. Your total is \$3.50. Is that correct?');
  });

  test('includes size, milk, and quantity for a customized drink', () {
    final order = Order(items: [
      OrderItem(
        menuItemId: 'cappuccino',
        name: 'Cappuccino',
        quantity: 2,
        size: 'Large',
        milk: 'Oat',
      ),
    ]);

    final speech = buildOrderConfirmationSpeech(order, menu);

    expect(speech, contains('2 Cappuccino with Large, Oat milk'));
    // (4.0 base + 1.0 large + 0.5 oat) * 2 = 11.00
    expect(speech, contains('\$11.00'));
  });

  test('includes a special request verbatim', () {
    final order = Order(items: [
      OrderItem(
        menuItemId: 'cappuccino',
        name: 'Cappuccino',
        specialRequest: 'extra hot',
      ),
    ]);

    final speech = buildOrderConfirmationSpeech(order, menu);

    expect(speech, contains('Cappuccino with extra hot'));
  });

  test('joins multiple items and ends with the confirmation question', () {
    final order = Order(items: [
      OrderItem(menuItemId: 'cappuccino', name: 'Cappuccino', size: 'Large'),
      OrderItem(menuItemId: 'croissant', name: 'Chocolate Croissant'),
    ]);

    final speech = buildOrderConfirmationSpeech(order, menu);

    expect(speech, startsWith('Just to confirm: Cappuccino with Large, Chocolate Croissant.'));
    expect(speech, endsWith('Is that correct?'));
  });

  group('buildOrderConfirmedSpeech', () {
    test('claims the order reached the kitchen only when posStatus is sent_to_pos', () {
      final speech = buildOrderConfirmedSpeech('sent_to_pos');
      expect(speech, contains('sent to the kitchen'));
    });

    test('does not claim POS success when posStatus is pos_failed', () {
      final speech = buildOrderConfirmedSpeech('pos_failed');
      expect(speech, isNot(contains('kitchen')));
      expect(speech, contains("that's confirmed"));
    });

    test('does not claim POS success when posStatus is null (no POS connection attempted)', () {
      final speech = buildOrderConfirmedSpeech(null);
      expect(speech, isNot(contains('kitchen')));
      expect(speech, contains("that's confirmed"));
    });

    test('does not claim POS success for any status other than sent_to_pos', () {
      for (final status in ['confirmed', 'sending_to_pos', 'unknown', '']) {
        final speech = buildOrderConfirmedSpeech(status);
        expect(speech, isNot(contains('kitchen')), reason: 'status "$status" must not claim POS success');
      }
    });
  });

  test('orderConfirmationFailedSpeech never sounds like a success', () {
    expect(orderConfirmationFailedSpeech.toLowerCase(), isNot(contains('confirmed')));
    expect(orderConfirmationFailedSpeech.toLowerCase(), contains('wrong'));
  });
}
