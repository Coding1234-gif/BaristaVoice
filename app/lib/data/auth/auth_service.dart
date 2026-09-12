import 'package:supabase_flutter/supabase_flutter.dart';

import '../billing/subscription_service.dart';
import 'profile.dart';

/// Thin wrapper around Supabase Auth + the `profiles` table. This is the
/// project's only auth system — the cafe admin dashboard reuses it rather
/// than introducing a second one.
class AuthService {
  final SupabaseClient _client;
  final SubscriptionService _subscriptions;

  AuthService(this._client, this._subscriptions);

  Session? get currentSession => _client.auth.currentSession;

  Stream<AuthState> get onAuthStateChange => _client.auth.onAuthStateChange;

  Future<void> signIn({required String email, required String password}) async {
    await _client.auth.signInWithPassword(email: email, password: password);
    await _syncSubscriptionIdentity();
  }

  /// Signs up a new cafe owner AND provisions their cafe + cafe_admin
  /// profile via the `create_cafe_admin_account` RPC. That function runs
  /// SECURITY DEFINER on the server, hardcodes role='cafe_admin', and
  /// generates the cafe_id itself — this client only ever supplies the
  /// human-chosen cafe name.
  Future<void> signUpCafeAdmin({
    required String email,
    required String password,
    required String cafeName,
  }) async {
    await _client.auth.signUp(email: email, password: password);
    // signUp() leaves the session active (email confirmation disabled) or
    // requires confirmation depending on the project's Auth settings; only
    // provision the cafe once a session actually exists.
    if (_client.auth.currentSession != null) {
      await _client.rpc('create_cafe_admin_account', params: {'cafe_name': cafeName});
      await _syncSubscriptionIdentity();
    }
  }

  Future<void> signOut() async {
    // Log out of RevenueCat BEFORE Supabase — on a shared device, the next
    // sign-in must never briefly see the outgoing admin's subscription
    // state.
    await _subscriptions.logOut();
    await _client.auth.signOut();
  }

  Future<Profile?> fetchCurrentProfile() async {
    final user = _client.auth.currentUser;
    if (user == null) return null;
    final row = await _client.from('profiles').select().eq('id', user.id).maybeSingle();
    if (row == null) return null;
    return Profile.fromJson(row);
  }

  Future<void> _syncSubscriptionIdentity() async {
    final userId = _client.auth.currentUser?.id;
    if (userId != null) {
      await _subscriptions.logIn(userId);
    }
  }
}
