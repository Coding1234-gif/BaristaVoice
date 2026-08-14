import 'package:flutter/foundation.dart' show kIsWeb;

/// Builds the two forms of a café's stable, permanent QR/deep link. The
/// café's `id` (from `cafes.id`) never changes once created — the QR always
/// encodes it directly, so regenerating the QR never produces a new café.
class CafeLinks {
  /// The primary link encoded in the QR: works in any browser immediately,
  /// no install required. Uses the admin dashboard's own origin (wherever
  /// it's deployed) since that's also where the customer-facing web build
  /// lives — see README for the single-deployment setup.
  static String webUrl(String cafeId) {
    if (kIsWeb) return '${Uri.base.origin}/cafe/$cafeId';
    return 'https://YOUR-DEPLOYED-DOMAIN/cafe/$cafeId';
  }

  /// Opens the installed app directly via the custom scheme registered in
  /// AndroidManifest.xml / Info.plist. Not encoded in the QR itself (a QR
  /// can only hold one string, and the web URL works everywhere) — this is
  /// for testing/reference, e.g. `adb shell am start -a
  /// android.intent.action.VIEW -d "baristavoice://open/cafe/{id}"`.
  static String appLink(String cafeId) => 'baristavoice://open/cafe/$cafeId';
}
