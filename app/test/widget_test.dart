// Smoke test: the kiosk boots and, with no backend configured, shows the
// setup-needed message instead of crashing.
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:barista_voice/core/theme.dart';
import 'package:barista_voice/features/kiosk/kiosk_screen.dart';

void main() {
  // Load a deterministic, empty env for this test rather than whatever the
  // developer's real .env happens to contain — the test asserts what the
  // kiosk shows when the backend is NOT configured.
  setUpAll(() {
    dotenv.testLoad(fileInput: '');
  });

  testWidgets('Kiosk screen shows setup-needed state without a backend',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: KioskScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Backend not connected yet'), findsOneWidget);
  });

  testWidgets('App theme builds without error', (WidgetTester tester) async {
    expect(buildAppTheme(), isNotNull);
  });
}
