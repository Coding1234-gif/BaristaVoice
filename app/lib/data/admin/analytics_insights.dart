import 'analytics_models.dart';

/// Revenue for the dashboard only ever counts orders Square has actually
/// captured payment for — matching the canonical status model driven by
/// create-order/pos-square-terminal-checkout/pos-square-order-pay. Anything
/// still `payment_pending` is deliberately excluded rather than guessed at.
const _paidStatus = 'paid';

/// Orders that reached the payment leg at all (started a Terminal checkout
/// or beyond) — the denominator for [AnalyticsInsights.paymentFailureRate].
/// `pos_failed`/`cancelled` orders never reached this leg, so they're not
/// counted as a payment failure; a `payment_pending` order might just be
/// mid-flight, not failed, so it's excluded from both sides of the ratio.
const _paymentAttemptedStatuses = {'payment_pending', 'payment_failed', _paidStatus};

/// One day's worth of paid revenue/order-count, zero-filled — the chart's
/// x-axis always has one point per calendar day in the window, even on days
/// with zero paid orders, so a quiet day reads as "0", not a gap.
class DailyPoint {
  final DateTime day;
  final double revenue;
  final int orderCount;

  const DailyPoint({required this.day, required this.revenue, required this.orderCount});
}

/// One menu item's paid performance over the window.
class ItemPerformance {
  final String name;
  final int quantity;
  final double revenue;

  const ItemPerformance({required this.name, required this.quantity, required this.revenue});
}

enum RecommendationSeverity { warning, positive, info }

/// A single plain-English, actionable line for the "Recommendations" card.
/// Deliberately just a title/detail pair, not a raw stat dump — the whole
/// point is translating numbers into something a busy café owner can act on
/// without doing their own analysis.
class Recommendation {
  final String title;
  final String detail;
  final RecommendationSeverity severity;

  const Recommendation({required this.title, required this.detail, required this.severity});
}

/// Everything the analytics screen renders, computed once from the raw rows
/// [AnalyticsRepository] returns. Pure and synchronous — no I/O, no
/// Supabase/Flutter types — so it's unit-testable without a database, same
/// spirit as create-order's validateRequestShape/classifyRpcError.
class AnalyticsInsights {
  final List<DailyPoint> dailySeries;
  final List<ItemPerformance> topItemsByRevenue;
  final List<ItemPerformance> topItemsByQuantity;
  final double totalRevenue;
  final int totalOrders;
  final double averageOrderValue;

  /// Fractional change vs the prior 7-day period (0.18 == +18%). Null when
  /// the prior period had zero revenue — a percentage change from zero is
  /// meaningless, not "infinite growth".
  final double? revenueChangeVsPriorWeek;

  /// Local hour-of-day (0-23) with the most paid orders, or null with no
  /// paid orders in the window.
  final int? busiestHour;

  /// Fraction of orders that reached the payment leg but did NOT end up
  /// `paid` (0.0-1.0). 0 when no orders reached the payment leg at all.
  final double paymentFailureRate;

  final List<Recommendation> recommendations;

  const AnalyticsInsights({
    required this.dailySeries,
    required this.topItemsByRevenue,
    required this.topItemsByQuantity,
    required this.totalRevenue,
    required this.totalOrders,
    required this.averageOrderValue,
    required this.revenueChangeVsPriorWeek,
    required this.busiestHour,
    required this.paymentFailureRate,
    required this.recommendations,
  });

  factory AnalyticsInsights.compute({
    required List<OrderSummaryRow> orders,
    required List<ItemSaleRow> items,
    required DateTime now,
    int windowDays = 30,
  }) {
    final paidOrders = orders.where((o) => o.status == _paidStatus).toList();
    final paidItems = items.where((i) => i.orderStatus == _paidStatus).toList();

    final today = DateTime(now.year, now.month, now.day);
    final windowStart = today.subtract(Duration(days: windowDays - 1));

    final dailySeries = _buildDailySeries(paidOrders, windowStart, windowDays);

    final totalRevenue = paidOrders.fold<double>(0, (sum, o) => sum + o.total);
    final totalOrders = paidOrders.length;
    final averageOrderValue = totalOrders == 0 ? 0.0 : totalRevenue / totalOrders;

    final revenueChange = _weekOverWeekChange(paidOrders, today);
    final busiestHour = _busiestHour(paidOrders);
    final paymentFailureRate = _paymentFailureRate(orders);

    final (topByRevenue, topByQuantity) = _topItems(paidItems);

    final recommendations = _buildRecommendations(
      revenueChangeVsPriorWeek: revenueChange,
      paymentFailureRate: paymentFailureRate,
      topItemByQuantity: topByQuantity.isEmpty ? null : topByQuantity.first,
      busiestHour: busiestHour,
      totalOrders: totalOrders,
    );

    return AnalyticsInsights(
      dailySeries: dailySeries,
      topItemsByRevenue: topByRevenue,
      topItemsByQuantity: topByQuantity,
      totalRevenue: totalRevenue,
      totalOrders: totalOrders,
      averageOrderValue: averageOrderValue,
      revenueChangeVsPriorWeek: revenueChange,
      busiestHour: busiestHour,
      paymentFailureRate: paymentFailureRate,
      recommendations: recommendations,
    );
  }

  static List<DailyPoint> _buildDailySeries(
    List<OrderSummaryRow> paidOrders,
    DateTime windowStart,
    int windowDays,
  ) {
    final byDay = <DateTime, ({double revenue, int count})>{};
    for (final order in paidOrders) {
      final local = order.createdAt.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      final existing = byDay[day] ?? (revenue: 0.0, count: 0);
      byDay[day] = (revenue: existing.revenue + order.total, count: existing.count + 1);
    }

    return List.generate(windowDays, (i) {
      final day = windowStart.add(Duration(days: i));
      final bucket = byDay[day];
      return DailyPoint(day: day, revenue: bucket?.revenue ?? 0, orderCount: bucket?.count ?? 0);
    });
  }

  /// Compares the last 7 full days (yesterday back 7 days, so "today" — a
  /// partial day — never makes the current period look artificially down)
  /// against the 7 days before that.
  static double? _weekOverWeekChange(List<OrderSummaryRow> paidOrders, DateTime today) {
    final currentStart = today.subtract(const Duration(days: 7));
    final priorStart = today.subtract(const Duration(days: 14));

    double sumBetween(DateTime start, DateTime end) {
      return paidOrders
          .where((o) {
            final day = _localDay(o.createdAt);
            return !day.isBefore(start) && day.isBefore(end);
          })
          .fold<double>(0, (sum, o) => sum + o.total);
    }

    final current = sumBetween(currentStart, today);
    final prior = sumBetween(priorStart, currentStart);

    if (prior <= 0) return null;
    return (current - prior) / prior;
  }

  static int? _busiestHour(List<OrderSummaryRow> paidOrders) {
    if (paidOrders.isEmpty) return null;
    final counts = List<int>.filled(24, 0);
    for (final order in paidOrders) {
      counts[order.createdAt.toLocal().hour]++;
    }
    var best = 0;
    for (var hour = 1; hour < 24; hour++) {
      if (counts[hour] > counts[best]) best = hour;
    }
    return counts[best] == 0 ? null : best;
  }

  static double _paymentFailureRate(List<OrderSummaryRow> orders) {
    final attempted = orders.where((o) => _paymentAttemptedStatuses.contains(o.status)).toList();
    if (attempted.isEmpty) return 0;
    final failed = attempted.where((o) => o.status != _paidStatus).length;
    return failed / attempted.length;
  }

  static (List<ItemPerformance>, List<ItemPerformance>) _topItems(List<ItemSaleRow> paidItems) {
    final byName = <String, ({int quantity, double revenue})>{};
    for (final item in paidItems) {
      final existing = byName[item.name] ?? (quantity: 0, revenue: 0.0);
      byName[item.name] = (
        quantity: existing.quantity + item.quantity,
        revenue: existing.revenue + item.lineTotal,
      );
    }

    final performances = [
      for (final entry in byName.entries)
        ItemPerformance(name: entry.key, quantity: entry.value.quantity, revenue: entry.value.revenue),
    ];

    final byRevenue = [...performances]..sort((a, b) => b.revenue.compareTo(a.revenue));
    final byQuantity = [...performances]..sort((a, b) => b.quantity.compareTo(a.quantity));

    return (byRevenue.take(5).toList(), byQuantity.take(5).toList());
  }

  static List<Recommendation> _buildRecommendations({
    required double? revenueChangeVsPriorWeek,
    required double paymentFailureRate,
    required ItemPerformance? topItemByQuantity,
    required int? busiestHour,
    required int totalOrders,
  }) {
    final out = <Recommendation>[];

    if (totalOrders == 0) {
      out.add(const Recommendation(
        title: 'No paid orders yet',
        detail: "Share your café's QR code with customers to get your first orders flowing in.",
        severity: RecommendationSeverity.info,
      ));
      return out;
    }

    if (paymentFailureRate > 0.15) {
      out.add(Recommendation(
        title: '${(paymentFailureRate * 100).round()}% of payments didn\'t complete',
        detail: 'Check your Square Terminal connection — customers are starting checkout but not finishing it.',
        severity: RecommendationSeverity.warning,
      ));
    }

    if (revenueChangeVsPriorWeek != null) {
      final pct = (revenueChangeVsPriorWeek.abs() * 100).round();
      if (revenueChangeVsPriorWeek <= -0.10) {
        out.add(Recommendation(
          title: 'Revenue is down $pct% vs last week',
          detail: 'Consider a limited-time promo, or check whether any popular items went unavailable.',
          severity: RecommendationSeverity.warning,
        ));
      } else if (revenueChangeVsPriorWeek >= 0.10) {
        out.add(Recommendation(
          title: 'Revenue is up $pct% vs last week',
          detail: 'Whatever you changed is working — keep it up.',
          severity: RecommendationSeverity.positive,
        ));
      }
    }

    if (topItemByQuantity != null) {
      out.add(Recommendation(
        title: '"${topItemByQuantity.name}" is your best seller',
        detail: 'It sold ${topItemByQuantity.quantity} times this period — keep it stocked and featured.',
        severity: RecommendationSeverity.info,
      ));
    }

    if (busiestHour != null) {
      out.add(Recommendation(
        title: 'Busiest around ${_formatHour(busiestHour)}',
        detail: 'Consider prepping ahead or scheduling extra staff around that time.',
        severity: RecommendationSeverity.info,
      ));
    }

    return out.take(4).toList();
  }

  static DateTime _localDay(DateTime dt) {
    final local = dt.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  static String _formatHour(int hour) {
    final period = hour < 12 ? 'am' : 'pm';
    final twelve = hour % 12 == 0 ? 12 : hour % 12;
    return '$twelve$period';
  }
}
