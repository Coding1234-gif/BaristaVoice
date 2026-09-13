import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:purchases_ui_flutter/purchases_ui_flutter.dart';

import '../../../core/admin_theme.dart';
import '../../../data/admin/analytics_insights.dart';
import '../../../state/admin_providers.dart';
import '../billing/premium_gate.dart';
import '../widgets/admin_states.dart';

final _currency = NumberFormat.simpleCurrency(name: 'GBP');

/// The café-facing analytics dashboard: paid revenue/orders over the last
/// `analyticsWindowDays` days, top sellers, and a handful of plain-English
/// recommendations computed from that same data (see AnalyticsInsights) —
/// the thing meant to make a café feel the app is actively working for
/// them, not just taking orders. Gating itself is PremiumGate's job (see
/// router.dart) — this widget is always the real dashboard.
class AnalyticsScreen extends StatelessWidget {
  const AnalyticsScreen({super.key});

  @override
  Widget build(BuildContext context) => const PremiumGate(
        featureName: 'Café Analytics',
        featureDescription:
            'See daily revenue trends, your best sellers, and plain-English recommendations for your café.',
        child: _AnalyticsDashboard(),
      );
}

class _AnalyticsDashboard extends ConsumerWidget {
  const _AnalyticsDashboard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final insightsAsync = ref.watch(analyticsInsightsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Analytics'),
        actions: [
          IconButton(
            tooltip: 'Manage subscription',
            icon: const Icon(Icons.settings_outlined),
            // RevenueCat's own native UI for viewing/cancelling/managing the
            // subscription, upgrading/downgrading plans, and support flows —
            // only shown here (an already-entitled café admin), since
            // there's nothing to "manage" before subscribing.
            onPressed: () => RevenueCatUI.presentCustomerCenter(),
          ),
        ],
      ),
      body: insightsAsync.when(
        loading: () => const AdminLoadingState(),
        error: (e, _) => AdminErrorState(
          message: 'Could not load analytics: $e',
          onRetry: () {
            ref.invalidate(orderSummariesProvider);
            ref.invalidate(itemSalesProvider);
          },
        ),
        data: (insights) => _AnalyticsBody(insights: insights),
      ),
    );
  }
}

class _AnalyticsBody extends StatelessWidget {
  final AnalyticsInsights insights;
  const _AnalyticsBody({required this.insights});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              _StatCard(
                label: 'Revenue (last $analyticsWindowDays days)',
                value: _currency.format(insights.totalRevenue),
                icon: Icons.payments_outlined,
              ),
              _StatCard(
                label: 'Paid orders',
                value: '${insights.totalOrders}',
                icon: Icons.receipt_long_outlined,
              ),
              _StatCard(
                label: 'Average order value',
                value: _currency.format(insights.averageOrderValue),
                icon: Icons.trending_up,
              ),
              _TrendStatCard(change: insights.revenueChangeVsPriorWeek),
            ],
          ),
          const SizedBox(height: 20),
          if (insights.recommendations.isNotEmpty) ...[
            _RecommendationsCard(recommendations: insights.recommendations),
            const SizedBox(height: 20),
          ],
          _RevenueChartCard(dailySeries: insights.dailySeries),
          const SizedBox(height: 20),
          _TopItemsCard(items: insights.topItemsByQuantity),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color? accent;

  const _StatCard({required this.label, required this.value, required this.icon, this.accent});

  @override
  Widget build(BuildContext context) {
    final color = accent ?? adminSeedColor;
    return SizedBox(
      width: 220,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                    Text(label, style: const TextStyle(fontSize: 12, color: Colors.black54)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TrendStatCard extends StatelessWidget {
  final double? change;
  const _TrendStatCard({required this.change});

  @override
  Widget build(BuildContext context) {
    if (change == null) {
      return const _StatCard(
        label: 'vs last week',
        value: 'Not enough data',
        icon: Icons.show_chart,
      );
    }
    final up = change! >= 0;
    final pct = (change!.abs() * 100).round();
    return _StatCard(
      label: 'Revenue vs last week',
      value: '${up ? '+' : '-'}$pct%',
      icon: up ? Icons.arrow_upward : Icons.arrow_downward,
      accent: up ? adminSuccess : adminDanger,
    );
  }
}

class _RecommendationsCard extends StatelessWidget {
  final List<Recommendation> recommendations;
  const _RecommendationsCard({required this.recommendations});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.auto_awesome, size: 18, color: adminSeedColor),
                SizedBox(width: 8),
                Text('Recommendations', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              ],
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < recommendations.length; i++) ...[
              if (i > 0) const Divider(height: 24),
              _RecommendationTile(recommendation: recommendations[i]),
            ],
          ],
        ),
      ),
    );
  }
}

class _RecommendationTile extends StatelessWidget {
  final Recommendation recommendation;
  const _RecommendationTile({required this.recommendation});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (recommendation.severity) {
      RecommendationSeverity.warning => (Icons.warning_amber_rounded, adminWarning),
      RecommendationSeverity.positive => (Icons.thumb_up_alt_outlined, adminSuccess),
      RecommendationSeverity.info => (Icons.lightbulb_outline, adminSeedColor),
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(color: color.withValues(alpha: 0.1), shape: BoxShape.circle),
          child: Icon(icon, size: 16, color: color),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(recommendation.title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(recommendation.detail, style: const TextStyle(color: Colors.black54, fontSize: 13)),
            ],
          ),
        ),
      ],
    );
  }
}

class _RevenueChartCard extends StatelessWidget {
  final List<DailyPoint> dailySeries;
  const _RevenueChartCard({required this.dailySeries});

  @override
  Widget build(BuildContext context) {
    final maxRevenue = dailySeries.fold<double>(0, (m, p) => p.revenue > m ? p.revenue : m);
    // Every ~5th day gets a label so 30 bars don't crowd the axis.
    final labelInterval = (dailySeries.length / 6).ceil().clamp(1, dailySeries.length);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Daily revenue', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 20),
            SizedBox(
              height: 220,
              child: dailySeries.isEmpty || maxRevenue == 0
                  ? const Center(
                      child: Text('No paid orders in this period yet.', style: TextStyle(color: Colors.black54)),
                    )
                  : BarChart(
                      BarChartData(
                        maxY: maxRevenue * 1.2,
                        gridData: const FlGridData(show: false),
                        borderData: FlBorderData(show: false),
                        titlesData: FlTitlesData(
                          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 28,
                              interval: 1,
                              getTitlesWidget: (value, meta) {
                                final index = value.toInt();
                                if (index < 0 || index >= dailySeries.length) return const SizedBox.shrink();
                                if (index % labelInterval != 0) return const SizedBox.shrink();
                                final day = dailySeries[index].day;
                                return Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text(
                                    DateFormat.Md().format(day),
                                    style: const TextStyle(fontSize: 10, color: Colors.black54),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                        barTouchData: BarTouchData(
                          touchTooltipData: BarTouchTooltipData(
                            getTooltipItem: (group, groupIndex, rod, rodIndex) {
                              final point = dailySeries[group.x.toInt()];
                              return BarTooltipItem(
                                '${DateFormat.MMMd().format(point.day)}\n${_currency.format(point.revenue)}',
                                const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                              );
                            },
                          ),
                        ),
                        barGroups: [
                          for (var i = 0; i < dailySeries.length; i++)
                            BarChartGroupData(
                              x: i,
                              barRods: [
                                BarChartRodData(
                                  toY: dailySeries[i].revenue,
                                  color: adminSeedColor,
                                  width: 10,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopItemsCard extends StatelessWidget {
  final List<ItemPerformance> items;
  const _TopItemsCard({required this.items});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Top sellers', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 16),
            if (items.isEmpty)
              const Text('No paid orders in this period yet.', style: TextStyle(color: Colors.black54))
            else
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) const Divider(height: 20),
                _TopItemRow(rank: i + 1, item: items[i]),
              ],
          ],
        ),
      ),
    );
  }
}

class _TopItemRow extends StatelessWidget {
  final int rank;
  final ItemPerformance item;
  const _TopItemRow({required this.rank, required this.item});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 24,
          child: Text('#$rank', style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.black54)),
        ),
        Expanded(
          child: Text(item.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        Text('${item.quantity} sold', style: const TextStyle(color: Colors.black54, fontSize: 13)),
        const SizedBox(width: 16),
        Text(_currency.format(item.revenue), style: const TextStyle(fontWeight: FontWeight.w700)),
      ],
    );
  }
}
