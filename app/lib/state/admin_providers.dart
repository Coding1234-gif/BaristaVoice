import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/admin/admin_models.dart';
import '../data/admin/analytics_insights.dart';
import '../data/admin/analytics_models.dart';
import '../data/admin/analytics_repository.dart';
import '../data/admin/cafe_admin_repository.dart';
import '../data/admin/live_orders_models.dart';
import '../data/admin/live_orders_repository.dart';
import '../data/admin/pos_mapping_repository.dart';
import '../data/auth/profile.dart';
import 'auth_providers.dart';

final cafeAdminRepositoryProvider = Provider<CafeAdminRepository>((ref) {
  return CafeAdminRepository(Supabase.instance.client);
});

final posMappingRepositoryProvider = Provider<PosMappingRepository>((ref) {
  return PosMappingRepository(Supabase.instance.client);
});

final analyticsRepositoryProvider = Provider<AnalyticsRepository>((ref) {
  return AnalyticsRepository(Supabase.instance.client);
});

final liveOrdersRepositoryProvider = Provider<LiveOrdersRepository>((ref) {
  return LiveOrdersRepository(Supabase.instance.client);
});

/// The cafe currently being managed. For a cafe_admin this is always their
/// own cafe_id from their profile. For a super_admin it's whichever cafe
/// they've picked from the switcher (null = none selected yet).
final selectedCafeIdProvider = StateProvider<String?>((ref) => null);

/// Resolves to the cafe id that admin screens should actually operate on:
/// the profile's own cafe_id for a cafe_admin, or the super_admin's current
/// selection. Screens should watch this rather than either provider
/// directly.
final activeCafeIdProvider = Provider<String?>((ref) {
  final profile = ref.watch(currentProfileProvider).valueOrNull;
  if (profile == null) return null;
  if (profile.role == AppRole.cafeAdmin) return profile.cafeId;
  if (profile.role == AppRole.superAdmin) return ref.watch(selectedCafeIdProvider);
  return null;
});

final activeCafeProvider = FutureProvider<Cafe?>((ref) async {
  final cafeId = ref.watch(activeCafeIdProvider);
  if (cafeId == null) return null;
  return ref.watch(cafeAdminRepositoryProvider).getCafe(cafeId);
});

final allCafesProvider = FutureProvider<List<Cafe>>((ref) {
  return ref.watch(cafeAdminRepositoryProvider).listAllCafes();
});

/// Auto-disposing + family-free: screens invalidate this after any mutation
/// (add/edit/delete/publish) to refetch. Kept simple over "realtime" since
/// admin edits are all user-initiated from this same dashboard.
final menuItemsProvider = FutureProvider<List<MenuItemRecord>>((ref) async {
  final cafeId = ref.watch(activeCafeIdProvider);
  if (cafeId == null) return [];
  return ref.watch(cafeAdminRepositoryProvider).getMenuItems(cafeId);
});

final menuUploadsProvider = FutureProvider<List<MenuUpload>>((ref) async {
  final cafeId = ref.watch(activeCafeIdProvider);
  if (cafeId == null) return [];
  return ref.watch(cafeAdminRepositoryProvider).getMenuUploads(cafeId);
});

/// How far back the analytics dashboard looks — long enough for a
/// meaningful daily chart and a week-over-week comparison, short enough to
/// stay a cheap query for a single café's order volume.
const analyticsWindowDays = 30;

/// Both raw row sets AND the computed [AnalyticsInsights] are exposed as
/// separate providers (rather than only the computed result) so a future
/// screen that just needs the raw numbers doesn't have to recompute
/// insights it won't use.
final orderSummariesProvider = FutureProvider<List<OrderSummaryRow>>((ref) async {
  final cafeId = ref.watch(activeCafeIdProvider);
  // Watched only as a re-run trigger (its value is unused): this provider is
  // a one-shot fetch that Riverpod caches forever, so without this a new or
  // newly-paid order never reached Analytics until the app was reloaded. Every
  // emission of the realtime orders feed — a new order, or its status moving
  // to 'paid' — now re-queries the analytics views.
  ref.watch(liveOrdersProvider);
  if (cafeId == null) return <OrderSummaryRow>[];
  final since = DateTime.now().subtract(const Duration(days: analyticsWindowDays));
  return ref.watch(analyticsRepositoryProvider).getOrderSummaries(cafeId: cafeId, since: since);
});

final itemSalesProvider = FutureProvider<List<ItemSaleRow>>((ref) async {
  final cafeId = ref.watch(activeCafeIdProvider);
  ref.watch(liveOrdersProvider); // re-run trigger only — see orderSummariesProvider
  if (cafeId == null) return <ItemSaleRow>[];
  final since = DateTime.now().subtract(const Duration(days: analyticsWindowDays));
  return ref.watch(analyticsRepositoryProvider).getItemSales(cafeId: cafeId, since: since);
});

/// Combines both raw providers into the pure, computed [AnalyticsInsights]
/// the analytics screen actually renders. Recomputes whenever either raw
/// provider refreshes; the computation itself (AnalyticsInsights.compute)
/// is synchronous and cheap, so no caching beyond Riverpod's own is needed.
final analyticsInsightsProvider = FutureProvider((ref) async {
  final orders = await ref.watch(orderSummariesProvider.future);
  final items = await ref.watch(itemSalesProvider.future);
  return AnalyticsInsights.compute(orders: orders, items: items, now: DateTime.now());
});

/// Realtime feed behind the Live Orders screen — unlike the FutureProviders
/// above, this stays open and pushes new orders/status changes as Postgres
/// emits them, rather than needing a manual invalidate after a mutation.
final liveOrdersProvider = StreamProvider<List<LiveOrder>>((ref) {
  final cafeId = ref.watch(activeCafeIdProvider);
  if (cafeId == null) return const Stream.empty();
  return ref.watch(liveOrdersRepositoryProvider).watchLiveOrders(cafeId);
});

/// The Overview screen's "today" stats — a pure computation over whatever
/// [liveOrdersProvider] already has loaded, not a separate query. Null while
/// that feed is still loading/errored; the Overview screen falls back to its
/// menu-only stats in that case rather than blocking on this.
final todaysOverviewProvider = Provider<TodaysOverview?>((ref) {
  final orders = ref.watch(liveOrdersProvider).valueOrNull;
  if (orders == null) return null;
  return TodaysOverview.compute(orders, DateTime.now());
});
