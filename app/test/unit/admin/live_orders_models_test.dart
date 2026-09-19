import 'package:flutter_test/flutter_test.dart';

import 'package:barista_voice/data/admin/live_orders_models.dart';

void main() {
  group('LiveOrderItem.optionsLine', () {
    test('matches the kiosk wording and order: size, temperature, milk, decaf, modifiers, note', () {
      final item = LiveOrderItem.fromJson(
        {
          'name': 'Latte',
          'quantity': 1,
          'unit_price': 4.8,
          'metadata': {
            'size': 'Large',
            'temperature': 'iced',
            'milk': 'Oat',
            'decaf': true,
            'specialRequest': 'no whip',
          },
        },
        modifiers: const [LiveOrderModifier(name: 'Extra shot')],
      );

      expect(item.optionsLine, 'Large · iced · Oat milk · decaf · Extra shot · no whip');
    });

    test('an order from before metadata was persisted still shows its modifier names', () {
      final item = LiveOrderItem.fromJson(
        {'name': 'Latte', 'quantity': 1, 'unit_price': 3.3},
        modifiers: const [LiveOrderModifier(name: 'Extra shot')],
      );

      expect(item.optionsLine, 'Extra shot');
    });

    test('nothing selected produces an empty line, not stray separators', () {
      final item = LiveOrderItem.fromJson({
        'name': 'Butter Croissant',
        'quantity': 2,
        'unit_price': 3.2,
        'metadata': {'size': null, 'milk': null, 'temperature': null, 'decaf': false, 'specialRequest': null},
      });

      expect(item.optionsLine, '');
    });

    test('blank/whitespace-only selections are ignored', () {
      final item = LiveOrderItem.fromJson({
        'name': 'Latte',
        'quantity': 1,
        'unit_price': 3.3,
        'metadata': {'size': '  ', 'milk': '', 'specialRequest': ' '},
      });

      expect(item.optionsLine, '');
    });

    test('a non-map metadata value (e.g. null) does not throw', () {
      expect(
        () => LiveOrderItem.fromJson({'name': 'Latte', 'quantity': 1, 'unit_price': 3.3, 'metadata': null}),
        returnsNormally,
      );
    });
  });
}
