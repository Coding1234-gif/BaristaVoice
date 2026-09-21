import 'package:flutter_test/flutter_test.dart';

import 'package:barista_voice/data/agent/llm_order_agent_service.dart';

void main() {
  group('parseMentionedItemIds', () {
    test('a missing field means no cards, exactly as before the field existed', () {
      expect(parseMentionedItemIds(null), isEmpty);
    });

    test('an empty array means no cards', () {
      expect(parseMentionedItemIds(<dynamic>[]), isEmpty);
    });

    test('one and several ids are kept in the order the AI gave them', () {
      expect(parseMentionedItemIds(['flat-white']), ['flat-white']);
      expect(parseMentionedItemIds(['latte', 'croissant']), ['latte', 'croissant']);
    });

    test('the same id repeated collapses to one', () {
      expect(parseMentionedItemIds(['latte', 'croissant', 'latte']), ['latte', 'croissant']);
    });

    test('a malformed value never throws — it just yields no cards', () {
      expect(parseMentionedItemIds('flat-white'), isEmpty);
      expect(parseMentionedItemIds({'id': 'flat-white'}), isEmpty);
      expect(parseMentionedItemIds(42), isEmpty);
    });

    test('non-string and empty entries are dropped, valid ones survive', () {
      expect(parseMentionedItemIds(['latte', null, 7, '', {'x': 1}, 'croissant']), ['latte', 'croissant']);
    });
  });
}
