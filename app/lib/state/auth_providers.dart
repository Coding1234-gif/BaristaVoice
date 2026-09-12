import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';
import '../data/auth/auth_service.dart';
import '../data/auth/profile.dart';
import 'billing_providers.dart';

/// Null when Supabase isn't configured yet (see `app/.env.example`) — admin
/// routes fall back to a "backend not connected" message rather than
/// crashing on `Supabase.instance.client`, mirroring how the kiosk screen
/// already handles an unconfigured backend.
final authServiceProvider = Provider<AuthService?>((ref) {
  if (!Env.isSupabaseConfigured) return null;
  return AuthService(Supabase.instance.client, ref.watch(subscriptionServiceProvider));
});

/// Re-emits whenever Supabase's auth state changes, so anything watching
/// [currentProfileProvider] (including the router's redirect logic)
/// refreshes on sign-in/sign-out.
final authStateChangesProvider = StreamProvider<AuthState>((ref) {
  final service = ref.watch(authServiceProvider);
  if (service == null) return const Stream.empty();
  return service.onAuthStateChange;
});

/// The signed-in user's role/cafe, fetched fresh from `profiles` (subject to
/// RLS: a user can only ever read their own row). Null when signed out, when
/// Supabase isn't configured, or when no profile exists yet (a Supabase Auth
/// user who never completed cafe_admin signup).
final currentProfileProvider = FutureProvider<Profile?>((ref) async {
  ref.watch(authStateChangesProvider);
  final service = ref.watch(authServiceProvider);
  if (service == null) return null;
  return service.fetchCurrentProfile();
});
