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
}
