/// Models for the canonical menu_items <-> POS product mapping workflow.
///
///   canonical menu_items
///           <->
///   pos_product_mappings
///           <->
///   pos_products / pos_modifiers
///
/// These wrap rows this app only ever reads/writes through
/// [PosMappingRepository] (Supabase RLS is the real authorization boundary,
/// same convention as [CafeAdminRepository]/[MenuItemRecord]) — never a
/// duplicate of the POS catalog into menu_items itself.
library;

/// One `pos_connections` row, restricted to the columns a cafe_admin is
/// actually granted SELECT on (the OAuth secret-id columns are locked out
/// at the database's column-privilege level — see schema.sql — so this
/// model deliberately has no field for them).
class PosConnectionSummary {
  final String id;
  final String cafeId;
  final String provider;
  final String? locationId;
  final String status;

  const PosConnectionSummary({
    required this.id,
    required this.cafeId,
    required this.provider,
    required this.status,
    this.locationId,
  });

  factory PosConnectionSummary.fromJson(Map<String, dynamic> json) => PosConnectionSummary(
        id: json['id'] as String,
        cafeId: json['cafe_id'] as String,
        provider: json['provider'] as String,
        locationId: json['location_id'] as String?,
        status: json['status'] as String,
      );
}

/// One `pos_products` row — a single item synced from a café's POS catalog
/// (see `pos-square-sync`). Read-only from the app's perspective; only a
/// sync job writes these.
class PosProduct {
  final String id;
  final String cafeId;
  final String posConnectionId;
  final String externalProductId;
  final String name;
  final String? category;
  final double? price;
  final bool active;

  const PosProduct({
    required this.id,
    required this.cafeId,
    required this.posConnectionId,
    required this.externalProductId,
    required this.name,
    required this.active,
    this.category,
    this.price,
  });

  factory PosProduct.fromJson(Map<String, dynamic> json) => PosProduct(
        id: json['id'] as String,
        cafeId: json['cafe_id'] as String,
        posConnectionId: json['pos_connection_id'] as String,
        externalProductId: json['external_product_id'] as String,
        name: json['name'] as String,
        category: json['category'] as String?,
        price: (json['price'] as num?)?.toDouble(),
        active: json['active'] as bool? ?? true,
      );
}

/// One `pos_modifiers` row. Scoped to a POS connection, not to a specific
/// [PosProduct] — the schema deliberately doesn't model a per-product
/// modifier link yet (see schema.sql's comment on `pos_modifiers`), so this
/// is "every modifier available on this connection," not "every modifier
/// available on this specific product."
class PosModifier {
  final String id;
  final String cafeId;
  final String posConnectionId;
  final String externalModifierId;
  final String name;
  final double priceAdjustment;
  final bool active;

  const PosModifier({
    required this.id,
    required this.cafeId,
    required this.posConnectionId,
    required this.externalModifierId,
    required this.name,
    required this.priceAdjustment,
    required this.active,
  });

  factory PosModifier.fromJson(Map<String, dynamic> json) => PosModifier(
        id: json['id'] as String,
        cafeId: json['cafe_id'] as String,
        posConnectionId: json['pos_connection_id'] as String,
        externalModifierId: json['external_modifier_id'] as String,
        name: json['name'] as String,
        priceAdjustment: (json['price_adjustment'] as num?)?.toDouble() ?? 0,
        active: json['active'] as bool? ?? true,
      );
}

/// One `pos_product_mappings` row — the link between a canonical menu item
/// and one POS connection's product.
class PosProductMapping {
  final String id;
  final String menuItemId;
  final String posConnectionId;
  final String posProductId;
  final DateTime updatedAt;

  const PosProductMapping({
    required this.id,
    required this.menuItemId,
    required this.posConnectionId,
    required this.posProductId,
    required this.updatedAt,
  });

  factory PosProductMapping.fromJson(Map<String, dynamic> json) => PosProductMapping(
        id: json['id'] as String,
        menuItemId: json['menu_item_id'] as String,
        posConnectionId: json['pos_connection_id'] as String,
        posProductId: json['pos_product_id'] as String,
        updatedAt: DateTime.parse(json['updated_at'] as String),
      );
}

/// The fully-resolved mapping for one menu item on one POS connection: the
/// mapping row itself, the POS product it points at, and every modifier
/// available on that connection. This is the shape a future order-submission
/// step needs (resolve menu_item -> pos_product, and know what POS-specific
/// modifiers exist to match against) — see [PosMappingRepository.getEffectiveMapping].
class EffectivePosMapping {
  final PosProductMapping mapping;
  final PosProduct product;
  final List<PosModifier> availableModifiers;

  const EffectivePosMapping({
    required this.mapping,
    required this.product,
    required this.availableModifiers,
  });
}
