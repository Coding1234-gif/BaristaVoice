import 'package:supabase_flutter/supabase_flutter.dart';

import 'pos_mapping_models.dart';

/// Thrown when a mapping insert/update would duplicate an existing one —
/// either the same menu item mapped twice on the same connection, or the
/// same POS product mapped to two different menu items on the same
/// connection (both are enforced by unique indexes on `pos_product_mappings`
/// in schema.sql, not by this class — this only translates the resulting
/// Postgres error into something callers can catch by type).
class DuplicateMappingException implements Exception {
  final String message;
  const DuplicateMappingException(this.message);
  @override
  String toString() => 'DuplicateMappingException: $message';
}

/// Thrown when a mapping would link a menu item and a POS connection/product
/// that don't all belong to the same café, or a POS product that doesn't
/// belong to the given connection. Enforced server-side by the
/// `check_pos_product_mapping_cafe_match` trigger — this class only
/// recognizes that trigger's error and gives it a distinct Dart type.
class CrossCafeMappingException implements Exception {
  final String message;
  const CrossCafeMappingException(this.message);
  @override
  String toString() => 'CrossCafeMappingException: $message';
}

/// Thrown when a mapping's pos_product_id doesn't belong to its
/// pos_connection_id (same trigger as [CrossCafeMappingException], different
/// clause — see schema.sql's check_pos_product_mapping_cafe_match).
class InvalidMappingException implements Exception {
  final String message;
  const InvalidMappingException(this.message);
  @override
  String toString() => 'InvalidMappingException: $message';
}

/// Thrown when menu_item_id, pos_connection_id, or pos_product_id in a
/// mapping request doesn't reference an existing row (a foreign-key
/// violation) — most commonly a stale/incorrect POS product id.
class PosReferenceNotFoundException implements Exception {
  final String message;
  const PosReferenceNotFoundException(this.message);
  @override
  String toString() => 'PosReferenceNotFoundException: $message';
}

/// Thrown when an update/delete targets a mapping id that doesn't exist, OR
/// that belongs to a different café (RLS silently filters the latter to zero
/// rows rather than erroring — this turns that silent no-op into an
/// explicit, catchable signal instead of a caller wrongly believing their
/// update took effect).
class MappingNotFoundException implements Exception {
  final String message;
  const MappingNotFoundException(this.message);
  @override
  String toString() => 'MappingNotFoundException: $message';
}

/// Translates a Postgres error from a `pos_product_mappings` insert/update
/// into a typed Dart exception, by the Postgres error code (and, for the
/// trigger's raised exception, the message it raised — see
/// check_pos_product_mapping_cafe_match in schema.sql). A free (pure,
/// dependency-free) function so this mapping can be unit tested directly
/// without a live Supabase connection.
Exception translatePosMappingWriteError(PostgrestException e) {
  switch (e.code) {
    case '23505': // unique_violation — one of the two unique indexes on pos_product_mappings
      return DuplicateMappingException(e.message);
    case '23503': // foreign_key_violation
      if (e.message.contains('pos_product_id')) {
        return PosReferenceNotFoundException('The selected POS product does not exist: ${e.message}');
      }
      return PosReferenceNotFoundException(e.message);
    case 'P0001': // raise exception inside check_pos_product_mapping_cafe_match
      if (e.message.contains('must belong to the same cafe')) {
        return CrossCafeMappingException(e.message);
      }
      if (e.message.contains('must belong to pos_connection_id')) {
        return InvalidMappingException(e.message);
      }
      return InvalidMappingException(e.message);
    default:
      return e;
  }
}

/// All reads/writes for the canonical menu_item <-> POS product mapping
/// workflow. Every method here is a direct, RLS-scoped Supabase call — no
/// Edge Function is involved, because every rule this workflow needs
/// (café ownership, cross-cafe prevention, product/connection consistency,
/// duplicate prevention) is already enforced server-side by RLS policies,
/// unique indexes, and the check_pos_product_mapping_cafe_match trigger on
/// `pos_product_mappings` (see schema.sql). This class's only job is to
/// shape queries and translate the resulting Postgres errors into typed
/// Dart exceptions — exactly the same division of responsibility
/// [CafeAdminRepository] already uses for menu_items: "every query includes
/// cafe_id for query shaping, but the actual isolation boundary is Supabase
/// RLS, enforced server-side regardless of what this repository is called
/// with."
class PosMappingRepository {
  final SupabaseClient _client;

  PosMappingRepository(this._client);

  /// The café's POS connections (id/provider/status only — the OAuth
  /// secret-id columns are excluded from the `authenticated` grant at the
  /// database level, so selecting them here would error, not just be
  /// filtered).
  Future<List<PosConnectionSummary>> listConnections(String cafeId) async {
    final rows = await _client
        .from('pos_connections')
        .select('id, cafe_id, provider, location_id, status')
        .eq('cafe_id', cafeId)
        .order('created_at');
    return rows.map((r) => PosConnectionSummary.fromJson(r)).toList();
  }

  /// Requirement 1: the POS products belonging to the current café,
  /// available to be mapped. Scoped by cafe_id for query shaping (matches
  /// the rest of this app's repositories); RLS independently refuses to
  /// return another café's rows regardless.
  Future<List<PosProduct>> listProducts({
    required String cafeId,
    String? posConnectionId,
  }) async {
    var query = _client.from('pos_products').select().eq('cafe_id', cafeId);
    if (posConnectionId != null) {
      query = query.eq('pos_connection_id', posConnectionId);
    }
    final rows = await query.order('name');
    return rows.map((r) => PosProduct.fromJson(r)).toList();
  }

  /// Requirement 6 (supporting): the modifiers available on one POS
  /// connection, surfaced so a caller can associate them where relevant —
  /// see [EffectivePosMapping] and the class-level note on why this is
  /// connection-scoped rather than product-scoped.
  Future<List<PosModifier>> listModifiers(String posConnectionId) async {
    final rows = await _client
        .from('pos_modifiers')
        .select()
        .eq('pos_connection_id', posConnectionId)
        .order('name');
    return rows.map((r) => PosModifier.fromJson(r)).toList();
  }

  /// Requirement 2: associate a canonical menu item with a POS product.
  /// Cross-cafe and product/connection-mismatch mappings are rejected
  /// server-side (see class doc); this only translates that rejection.
  Future<PosProductMapping> createMapping({
    required String menuItemId,
    required String posConnectionId,
    required String posProductId,
  }) async {
    try {
      final row = await _client
          .from('pos_product_mappings')
          .insert({
            'menu_item_id': menuItemId,
            'pos_connection_id': posConnectionId,
            'pos_product_id': posProductId,
          })
          .select()
          .single();
      return PosProductMapping.fromJson(row);
    } on PostgrestException catch (e) {
      throw translatePosMappingWriteError(e);
    }
  }

  /// Requirement 3: repoint an existing mapping at a different POS product
  /// (e.g. correcting a wrong match) without deleting/recreating it.
  Future<PosProductMapping> updateMapping({
    required String mappingId,
    required String posProductId,
  }) async {
    try {
      final rows = await _client
          .from('pos_product_mappings')
          .update({'pos_product_id': posProductId})
          .eq('id', mappingId)
          .select();
      if (rows.isEmpty) {
        throw const MappingNotFoundException('Mapping not found, or you do not have access to it.');
      }
      return PosProductMapping.fromJson(rows.first);
    } on PostgrestException catch (e) {
      throw translatePosMappingWriteError(e);
    }
  }

  /// Requirement 3: remove a mapping. Safe to call on a mapping that
  /// doesn't exist or isn't yours (RLS-invisible) — throws
  /// [MappingNotFoundException] rather than silently doing nothing, so a
  /// caller can't mistake "no-op" for "deleted."
  Future<void> deleteMapping(String mappingId) async {
    final rows = await _client.from('pos_product_mappings').delete().eq('id', mappingId).select();
    if (rows.isEmpty) {
      throw const MappingNotFoundException('Mapping not found, or you do not have access to it.');
    }
  }

  /// All mappings for one menu item (a menu item can be mapped once per POS
  /// connection — see the unique index in schema.sql — so this is normally
  /// zero or one entry per café, more only if a café has multiple
  /// connections). Empty list means "unmapped."
  Future<List<PosProductMapping>> getMappingsForMenuItem(String menuItemId) async {
    final rows = await _client.from('pos_product_mappings').select().eq('menu_item_id', menuItemId);
    return rows.map((r) => PosProductMapping.fromJson(r)).toList();
  }

  /// Requirement 7: the fully-resolved mapping a future order-submission
  /// step needs for one menu item on one POS connection — the mapped
  /// product plus every modifier available on that connection. Returns
  /// null when the menu item isn't mapped on that connection yet, rather
  /// than throwing — "unmapped" is an expected, ordinary state (most menu
  /// items will have no POS connection at all, or none yet configured).
  Future<EffectivePosMapping?> getEffectiveMapping({
    required String menuItemId,
    required String posConnectionId,
  }) async {
    final row = await _client
        .from('pos_product_mappings')
        .select('*, pos_products(*)')
        .eq('menu_item_id', menuItemId)
        .eq('pos_connection_id', posConnectionId)
        .maybeSingle();

    if (row == null) return null;

    final productJson = row['pos_products'] as Map<String, dynamic>?;
    if (productJson == null) {
      // pos_product_id -> pos_products is ON DELETE CASCADE, so this
      // shouldn't be reachable in practice (the mapping row would be gone
      // too), but a mapping without its product isn't "effective."
      return null;
    }

    final modifiers = await listModifiers(posConnectionId);

    return EffectivePosMapping(
      mapping: PosProductMapping.fromJson(row),
      product: PosProduct.fromJson(productJson),
      availableModifiers: modifiers,
    );
  }
}
