import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/admin/admin_models.dart';
import '../data/admin/cafe_admin_repository.dart';
import '../data/auth/profile.dart';
import 'auth_providers.dart';

final cafeAdminRepositoryProvider = Provider<CafeAdminRepository>((ref) {
  return CafeAdminRepository(Supabase.instance.client);
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
