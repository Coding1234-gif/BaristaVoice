import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:barista_voice/core/theme.dart';
import 'package:barista_voice/features/kiosk/widgets/mentioned_items_strip.dart';
import 'package:barista_voice/models/menu.dart';

const _flatWhite = MenuItem(
  id: 'flat-white',
  name: 'Flat White',
  description: 'Espresso with silky steamed milk.',
  category: 'Coffee',
  basePrice: 3.2,
  imageUrl: 'https://example.invalid/flat-white.jpg',
);

const _croissant = MenuItem(
  id: 'croissant',
  name: 'Butter Croissant',
  description: 'Flaky and buttery.',
  category: 'Food',
  basePrice: 3.2,
  // no image
);

const _menu = CafeMenu(cafeName: 'Bean & Bloom', items: [
  _flatWhite,
  _croissant,
  MenuItem(id: 'a', name: 'Item A', description: 'A', category: 'X', basePrice: 1),
  MenuItem(id: 'b', name: 'Item B', description: 'B', category: 'X', basePrice: 1),
  MenuItem(id: 'c', name: 'Item C', description: 'C', category: 'X', basePrice: 1),
  MenuItem(id: 'd', name: 'Item D', description: 'D', category: 'X', basePrice: 1),
  MenuItem(id: 'e', name: 'Item E', description: 'E', category: 'X', basePrice: 1),
]);

Widget _host(List<String> ids, {CafeMenu menu = _menu}) => MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              const Text('transcript'),
              MentionedItemsStrip(itemIds: ids, menu: menu),
              const Text('cart'),
            ],
          ),
        ),
      ),
    );

double _opacityOf(WidgetTester tester, String text) =>
    tester.widget<Opacity>(find.ancestor(of: find.text(text), matching: find.byType(Opacity)).first).opacity;

void main() {
  group('content', () {
    testWidgets('no ids: renders no card and no text', (tester) async {
      await tester.pumpWidget(_host(const []));
      await tester.pumpAndSettle();

      expect(find.text('Flat White'), findsNothing);
      expect(find.byIcon(Icons.local_cafe_outlined), findsNothing);
      expect(tester.getSize(find.byType(MentionedItemsStrip)).height, 0);
    });

    testWidgets('one product: shows name, description and £ price from the menu item', (tester) async {
      await tester.pumpWidget(_host(const ['flat-white']));
      await tester.pumpAndSettle();

      expect(find.text('Flat White'), findsOneWidget);
      expect(find.text('Espresso with silky steamed milk.'), findsOneWidget);
      expect(find.text('£3.20'), findsOneWidget);
    });

    testWidgets('two products: both cards, in the order the AI mentioned them', (tester) async {
      await tester.pumpWidget(_host(const ['croissant', 'flat-white']));
      await tester.pumpAndSettle();

      expect(find.text('Flat White'), findsOneWidget);
      expect(find.text('Butter Croissant'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Butter Croissant')).dx,
        lessThan(tester.getTopLeft(find.text('Flat White')).dx),
      );
    });

    testWidgets('an id that is not on the loaded menu is ignored; the rest still render', (tester) async {
      await tester.pumpWidget(_host(const ['does-not-exist', 'flat-white']));
      await tester.pumpAndSettle();

      expect(find.text('Flat White'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('only unknown ids: renders nothing', (tester) async {
      await tester.pumpWidget(_host(const ['nope', 'also-nope']));
      await tester.pumpAndSettle();

      expect(tester.getSize(find.byType(MentionedItemsStrip)).height, 0);
    });

    testWidgets('9. the same product repeated is one card, not a growing list', (tester) async {
      await tester.pumpWidget(_host(const ['flat-white', 'flat-white', 'flat-white']));
      await tester.pumpAndSettle();

      expect(find.text('Flat White'), findsOneWidget);
    });

    testWidgets('never shows more than four cards', (tester) async {
      await tester.pumpWidget(_host(const ['a', 'b', 'c', 'd', 'e']));
      await tester.pumpAndSettle();

      expect(find.text('Item A'), findsOneWidget);
      expect(find.text('Item D'), findsOneWidget);
      expect(find.text('Item E'), findsNothing);
    });

    testWidgets('an item with no description shows name and price without a blank line', (tester) async {
      const menu = CafeMenu(cafeName: 'x', items: [
        MenuItem(id: 'plain', name: 'Plain', description: '', category: 'X', basePrice: 2),
      ]);
      await tester.pumpWidget(_host(const ['plain'], menu: menu));
      await tester.pumpAndSettle();

      expect(find.text('Plain'), findsOneWidget);
      expect(find.text('£2.00'), findsOneWidget);
    });
  });

  group('images', () {
    testWidgets('4. a product with an image URL renders an Image for it', (tester) async {
      await tester.pumpWidget(_host(const ['flat-white']));
      await tester.pump();

      final image = tester.widget<Image>(find.byType(Image));
      expect((image.image as NetworkImage).url, _flatWhite.imageUrl);
    });

    testWidgets('5. a product with no image falls back to the placeholder, no Image widget', (tester) async {
      await tester.pumpWidget(_host(const ['croissant']));
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.local_cafe_outlined), findsOneWidget);
      expect(find.text('Butter Croissant'), findsOneWidget);
    });

    testWidgets('an image that fails to load falls back to the placeholder instead of breaking', (tester) async {
      // Under flutter_test every network request fails, which is exactly a
      // broken/unreachable image URL.
      await tester.pumpWidget(_host(const ['flat-white']));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.local_cafe_outlined), findsOneWidget);
      expect(find.text('Flat White'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('informational only — not a second cart', () {
    testWidgets('has no buttons, ink, chevron or add/quantity controls', (tester) async {
      await tester.pumpWidget(_host(const ['flat-white', 'croissant']));
      await tester.pumpAndSettle();

      final strip = find.byType(MentionedItemsStrip);
      for (final type in <Type>[
        InkWell,
        InkResponse,
        GestureDetector,
        IconButton,
        TextButton,
        OutlinedButton,
        ElevatedButton,
        FilledButton,
        FloatingActionButton,
        Chip,
        ListTile,
      ]) {
        expect(find.descendant(of: strip, matching: find.byType(type)), findsNothing, reason: '$type');
      }
      expect(find.descendant(of: strip, matching: find.byIcon(Icons.chevron_right)), findsNothing);
      expect(find.descendant(of: strip, matching: find.byIcon(Icons.arrow_forward_ios)), findsNothing);
      expect(find.descendant(of: strip, matching: find.byIcon(Icons.add)), findsNothing);
      expect(find.descendant(of: strip, matching: find.textContaining('Add')), findsNothing);
    });

    testWidgets('tapping a card does nothing: no sheet, no dialog, no navigation', (tester) async {
      await tester.pumpWidget(_host(const ['flat-white']));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Flat White'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('Add to order'), findsNothing);
      expect(find.byType(MentionedItemsStrip), findsOneWidget);
    });

    testWidgets('layout order: transcript, then cards, then cart', (tester) async {
      await tester.pumpWidget(_host(const ['flat-white']));
      await tester.pumpAndSettle();

      final transcriptY = tester.getTopLeft(find.text('transcript')).dy;
      final cardY = tester.getTopLeft(find.text('Flat White')).dy;
      final cartY = tester.getTopLeft(find.text('cart')).dy;
      expect(transcriptY, lessThan(cardY));
      expect(cardY, lessThan(cartY));
    });
  });

  group('entrance animation', () {
    testWidgets('a new card fades in over ~240ms, then rests fully opaque', (tester) async {
      await tester.pumpWidget(_host(const ['flat-white']));
      expect(_opacityOf(tester, 'Flat White'), 0);

      await tester.pump(const Duration(milliseconds: 100));
      final mid = _opacityOf(tester, 'Flat White');
      expect(mid, greaterThan(0));
      expect(mid, lessThan(1));

      await tester.pump(const Duration(milliseconds: 200));
      expect(_opacityOf(tester, 'Flat White'), 1);
    });

    testWidgets('a card that stays mentioned does not replay; a newly added one animates', (tester) async {
      await tester.pumpWidget(_host(const ['flat-white']));
      await tester.pumpAndSettle();

      await tester.pumpWidget(_host(const ['flat-white', 'croissant']));
      await tester.pump(const Duration(milliseconds: 50));

      expect(_opacityOf(tester, 'Flat White'), 1, reason: 'existing card must not flicker');
      expect(_opacityOf(tester, 'Butter Croissant'), lessThan(1));
      await tester.pumpAndSettle();
      expect(_opacityOf(tester, 'Butter Croissant'), 1);
    });

    testWidgets('the same product mentioned again keeps its card without replaying', (tester) async {
      await tester.pumpWidget(_host(const ['flat-white']));
      await tester.pumpAndSettle();

      await tester.pumpWidget(_host(const ['flat-white']));
      await tester.pump();

      expect(_opacityOf(tester, 'Flat White'), 1);
    });

    testWidgets('a different product replaces the old card and animates in', (tester) async {
      await tester.pumpWidget(_host(const ['flat-white']));
      await tester.pumpAndSettle();

      await tester.pumpWidget(_host(const ['croissant']));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Flat White'), findsNothing);
      expect(_opacityOf(tester, 'Butter Croissant'), lessThan(1));
    });

    testWidgets('clearing the list removes the cards', (tester) async {
      await tester.pumpWidget(_host(const ['flat-white']));
      await tester.pumpAndSettle();

      await tester.pumpWidget(_host(const []));
      await tester.pumpAndSettle();

      expect(find.text('Flat White'), findsNothing);
    });

    testWidgets('respects the system "reduce motion" setting: cards appear instantly', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

      await tester.pumpWidget(_host(const ['flat-white']));
      await tester.pump(const Duration(milliseconds: 1));

      expect(_opacityOf(tester, 'Flat White'), 1);
    });
  });

  group('layout', () {
    testWidgets('two cards fit without overflow on a narrow phone, and text scale 1.6 does not overflow', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(const ['flat-white', 'croissant']));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(_host(const ['flat-white', 'croissant']));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
