// Offline unit tests for AnalyticsInsights.compute — pure Dart, no device,
// backend, or Supabase connection required (matches this project's existing
// test/unit/ convention). Row access/scoping itself is enforced by Postgres
// RLS on the underlying orders/order_items tables (see order_item_sales'
// comment in schema.sql), not by anything here — this only tests the
// arithmetic/ranking/recommendation logic once the rows already exist.
import 'package:barista_voice/data/admin/analytics_insights.dart';
import 'package:barista_voice/data/admin/analytics_models.dart';
import 'package:flutter_test/flutter_test.dart';

OrderSummaryRow _order({required String status, required double total, required DateTime createdAt}) {
  return OrderSummaryRow(id: 'o-${createdAt.microsecondsSinceEpoch}', status: status, total: total, createdAt: createdAt);
}

ItemSaleRow _item({
  required String name,
  required int quantity,
  required double lineTotal,
  String orderStatus = 'paid',
  required DateTime orderCreatedAt,
}) {
  return ItemSaleRow(
    name: name,
    quantity: quantity,
    lineTotal: lineTotal,
    orderStatus: orderStatus,
    orderCreatedAt: orderCreatedAt,
  );
}

void main() {
  final now = DateTime(2026, 9, 5, 12); // a fixed "today" so tests are deterministic

  group('revenue/order counting only includes paid orders', () {
    test('payment_pending, payment_failed, pos_failed, cancelled are all excluded from revenue', () {
      final insights = AnalyticsInsights.compute(
        orders: [
          _order(status: 'paid', total: 10, createdAt: now),
          _order(status: 'payment_pending', total: 99, createdAt: now),
          _order(status: 'payment_failed', total: 99, createdAt: now),
          _order(status: 'pos_failed', total: 99, createdAt: now),
          _order(status: 'cancelled', total: 99, createdAt: now),
        ],
        items: const [],
        now: now,
      );

      expect(insights.totalOrders, 1);
      expect(insights.totalRevenue, 10);
      expect(insights.averageOrderValue, 10);
    });

    test('zero paid orders means zero average, not a division-by-zero crash', () {
      final insights = AnalyticsInsights.compute(orders: const [], items: const [], now: now);
      expect(insights.totalOrders, 0);
      expect(insights.totalRevenue, 0);
      expect(insights.averageOrderValue, 0);
    });
  });

  group('daily series is zero-filled across the whole window', () {
    test('a 3-day window with one paid order on the middle day fills the other two with zeros', () {
      final middleDay = DateTime(now.year, now.month, now.day - 1);
      final insights = AnalyticsInsights.compute(
        orders: [_order(status: 'paid', total: 25, createdAt: middleDay.add(const Duration(hours: 9)))],
        items: const [],
        now: now,
        windowDays: 3,
      );

      expect(insights.dailySeries, hasLength(3));
      expect(insights.dailySeries[0].revenue, 0);
      expect(insights.dailySeries[1].revenue, 25);
      expect(insights.dailySeries[1].orderCount, 1);
      expect(insights.dailySeries[2].revenue, 0);
    });
  });

  group('week-over-week revenue change', () {
    test('current week double the prior week is +100%', () {
      final insights = AnalyticsInsights.compute(
        orders: [
          _order(status: 'paid', total: 200, createdAt: now.subtract(const Duration(days: 2))),
          _order(status: 'paid', total: 100, createdAt: now.subtract(const Duration(days: 10))),
        ],
        items: const [],
        now: now,
      );

      expect(insights.revenueChangeVsPriorWeek, closeTo(1.0, 0.0001));
    });

    test('zero revenue in the prior week is null, not an infinite/NaN percentage', () {
      final insights = AnalyticsInsights.compute(
        orders: [_order(status: 'paid', total: 50, createdAt: now.subtract(const Duration(days: 2)))],
        items: const [],
        now: now,
      );

      expect(insights.revenueChangeVsPriorWeek, isNull);
    });
  });

  group('busiest hour', () {
    test('picks the hour with the most paid orders', () {
      DateTime atHour(int h) => DateTime(now.year, now.month, now.day, h);
      final insights = AnalyticsInsights.compute(
        orders: [
          _order(status: 'paid', total: 5, createdAt: atHour(8)),
          _order(status: 'paid', total: 5, createdAt: atHour(9)),
          _order(status: 'paid', total: 5, createdAt: atHour(9)),
        ],
        items: const [],
        now: now,
      );

      expect(insights.busiestHour, 9);
    });

    test('no paid orders means no busiest hour', () {
      final insights = AnalyticsInsights.compute(orders: const [], items: const [], now: now);
      expect(insights.busiestHour, isNull);
    });
  });

  group('payment failure rate', () {
    test('counts only orders that reached the payment leg; pos_failed/cancelled never entered it', () {
      final insights = AnalyticsInsights.compute(
        orders: [
          _order(status: 'paid', total: 5, createdAt: now),
          _order(status: 'paid', total: 5, createdAt: now),
          _order(status: 'payment_failed', total: 5, createdAt: now),
          _order(status: 'pos_failed', total: 5, createdAt: now),
          _order(status: 'cancelled', total: 5, createdAt: now),
        ],
        items: const [],
        now: now,
      );

      // 1 failed out of 3 that reached the payment leg (2 paid + 1 failed).
      expect(insights.paymentFailureRate, closeTo(1 / 3, 0.0001));
    });

    test('no orders reached the payment leg at all -> 0, not NaN', () {
      final insights = AnalyticsInsights.compute(
        orders: [_order(status: 'pos_failed', total: 5, createdAt: now)],
        items: const [],
        now: now,
      );
      expect(insights.paymentFailureRate, 0);
    });
  });

  group('top items', () {
    test('ranks by revenue and by quantity independently, and only counts paid order lines', () {
      final insights = AnalyticsInsights.compute(
        orders: const [],
        items: [
          // Cheap but high-volume seller.
          _item(name: 'Drip Coffee', quantity: 10, lineTotal: 30, orderCreatedAt: now),
          // Expensive but low-volume seller.
          _item(name: 'Specialty Latte', quantity: 2, lineTotal: 40, orderCreatedAt: now),
          // Line from an order that never got paid — must be excluded entirely.
          _item(name: 'Ghost Item', quantity: 99, lineTotal: 999, orderStatus: 'cancelled', orderCreatedAt: now),
        ],
        now: now,
      );

      expect(insights.topItemsByQuantity.first.name, 'Drip Coffee');
      expect(insights.topItemsByRevenue.first.name, 'Specialty Latte');
      expect(
        insights.topItemsByQuantity.any((i) => i.name == 'Ghost Item'),
        isFalse,
        reason: 'a line from a non-paid order must not appear in top sellers',
      );
    });

    test('aggregates quantity/revenue for the same item across multiple orders', () {
      final insights = AnalyticsInsights.compute(
        orders: const [],
        items: [
          _item(name: 'Mocha', quantity: 1, lineTotal: 5, orderCreatedAt: now),
          _item(name: 'Mocha', quantity: 2, lineTotal: 10, orderCreatedAt: now),
        ],
        now: now,
      );

      final mocha = insights.topItemsByQuantity.single;
      expect(mocha.quantity, 3);
      expect(mocha.revenue, 15);
    });
  });

  group('recommendations', () {
    test('zero paid orders produces exactly one "get started" recommendation', () {
      final insights = AnalyticsInsights.compute(orders: const [], items: const [], now: now);
      expect(insights.recommendations, hasLength(1));
      expect(insights.recommendations.single.severity, RecommendationSeverity.info);
    });

    test('a high payment failure rate produces a warning recommendation', () {
      final insights = AnalyticsInsights.compute(
        orders: [
          _order(status: 'paid', total: 5, createdAt: now),
          _order(status: 'payment_failed', total: 5, createdAt: now),
          _order(status: 'payment_failed', total: 5, createdAt: now),
        ],
        items: const [],
        now: now,
      );

      expect(
        insights.recommendations.any((r) => r.severity == RecommendationSeverity.warning),
        isTrue,
      );
    });

    test('revenue up >=10% vs last week produces a positive recommendation', () {
      final insights = AnalyticsInsights.compute(
        orders: [
          _order(status: 'paid', total: 200, createdAt: now.subtract(const Duration(days: 2))),
          _order(status: 'paid', total: 100, createdAt: now.subtract(const Duration(days: 10))),
        ],
        items: const [],
        now: now,
      );

      expect(
        insights.recommendations.any((r) => r.severity == RecommendationSeverity.positive),
        isTrue,
      );
    });

    test('never returns more than 4 recommendations', () {
      final insights = AnalyticsInsights.compute(
        orders: [
          _order(status: 'paid', total: 200, createdAt: now.subtract(const Duration(days: 2))),
          _order(status: 'paid', total: 100, createdAt: now.subtract(const Duration(days: 10))),
          _order(status: 'payment_failed', total: 5, createdAt: now),
          _order(status: 'payment_failed', total: 5, createdAt: now),
        ],
        items: [_item(name: 'Mocha', quantity: 5, lineTotal: 25, orderCreatedAt: now)],
        now: now,
      );

      expect(insights.recommendations.length, lessThanOrEqualTo(4));
    });
  });
}
