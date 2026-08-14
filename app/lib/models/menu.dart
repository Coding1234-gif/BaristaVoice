/// Structured café menu. This is the sole source of truth for products,
/// prices and available options — the conversational layer is only ever
/// allowed to reference what's here, never invent items or prices.
class PricedOption {
  final String name;
  final double priceDelta;

  const PricedOption({required this.name, this.priceDelta = 0});

  factory PricedOption.fromJson(Map<String, dynamic> json) => PricedOption(
        name: json['name'] as String,
        priceDelta: (json['priceDelta'] as num?)?.toDouble() ?? 0,
      );

  Map<String, dynamic> toJson() => {'name': name, 'priceDelta': priceDelta};
}

class MenuItem {
  final String id;
  final String name;
  final String description;
  final String category;
  final double basePrice;
  final bool popular;

  /// Public URL of the product photo, or null if none has been set yet.
  final String? imageUrl;

  /// In-stock toggle, independent of the menu's draft/published status.
  final bool available;

  /// Empty if the item has no size choice (e.g. a pastry).
  final List<PricedOption> sizes;

  /// Empty if the item has no milk (e.g. a plain espresso or a pastry).
  final List<PricedOption> milkOptions;

  final List<String> temperatureOptions; // e.g. ["hot", "iced"]
  final bool decafAvailable;
  final List<PricedOption> modifiers;
  final List<String> allergens;
  final List<String> dietaryTags;

  const MenuItem({
    required this.id,
    required this.name,
    required this.description,
    required this.category,
    required this.basePrice,
    this.popular = false,
    this.imageUrl,
    this.available = true,
    this.sizes = const [],
    this.milkOptions = const [],
    this.temperatureOptions = const [],
    this.decafAvailable = false,
    this.modifiers = const [],
    this.allergens = const [],
    this.dietaryTags = const [],
  });

  factory MenuItem.fromJson(Map<String, dynamic> json) => MenuItem(
        id: json['id'] as String,
        name: json['name'] as String,
        description: json['description'] as String? ?? '',
        category: json['category'] as String? ?? 'Other',
        basePrice: (json['basePrice'] as num).toDouble(),
        popular: json['popular'] as bool? ?? false,
        imageUrl: json['imageUrl'] as String?,
        available: json['available'] as bool? ?? true,
        sizes: (json['sizes'] as List<dynamic>? ?? [])
            .map((e) => PricedOption.fromJson(e as Map<String, dynamic>))
            .toList(),
        milkOptions: (json['milkOptions'] as List<dynamic>? ?? [])
            .map((e) => PricedOption.fromJson(e as Map<String, dynamic>))
            .toList(),
        temperatureOptions: (json['temperatureOptions'] as List<dynamic>? ?? [])
            .map((e) => e as String)
            .toList(),
        decafAvailable: json['decafAvailable'] as bool? ?? false,
        modifiers: (json['modifiers'] as List<dynamic>? ?? [])
            .map((e) => PricedOption.fromJson(e as Map<String, dynamic>))
            .toList(),
        allergens:
            (json['allergens'] as List<dynamic>? ?? []).map((e) => e as String).toList(),
        dietaryTags:
            (json['dietaryTags'] as List<dynamic>? ?? []).map((e) => e as String).toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'category': category,
        'basePrice': basePrice,
        'popular': popular,
        'imageUrl': imageUrl,
        'available': available,
        'sizes': sizes.map((e) => e.toJson()).toList(),
        'milkOptions': milkOptions.map((e) => e.toJson()).toList(),
        'temperatureOptions': temperatureOptions,
        'decafAvailable': decafAvailable,
        'modifiers': modifiers.map((e) => e.toJson()).toList(),
        'allergens': allergens,
        'dietaryTags': dietaryTags,
      };
}

class CafeMenu {
  final String cafeName;
  final List<MenuItem> items;

  const CafeMenu({required this.cafeName, required this.items});

  MenuItem? findById(String id) {
    for (final item in items) {
      if (item.id == id) return item;
    }
    return null;
  }

  List<MenuItem> get popularItems => items.where((i) => i.popular).toList();

  CafeMenu copyWith({String? cafeName, List<MenuItem>? items}) => CafeMenu(
        cafeName: cafeName ?? this.cafeName,
        items: items ?? this.items,
      );
}

/// A convenience `copyWith` for editing individual fields in the admin
/// dashboard without hand-rolling every constructor call.
extension MenuItemCopyWith on MenuItem {
  MenuItem copyWith({
    String? name,
    String? description,
    String? category,
    double? basePrice,
    bool? popular,
    Object? imageUrl = _unset,
    bool? available,
    List<PricedOption>? sizes,
    List<PricedOption>? milkOptions,
    List<String>? temperatureOptions,
    bool? decafAvailable,
    List<PricedOption>? modifiers,
    List<String>? allergens,
    List<String>? dietaryTags,
  }) {
    return MenuItem(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      category: category ?? this.category,
      basePrice: basePrice ?? this.basePrice,
      popular: popular ?? this.popular,
      imageUrl: identical(imageUrl, _unset) ? this.imageUrl : imageUrl as String?,
      available: available ?? this.available,
      sizes: sizes ?? this.sizes,
      milkOptions: milkOptions ?? this.milkOptions,
      temperatureOptions: temperatureOptions ?? this.temperatureOptions,
      decafAvailable: decafAvailable ?? this.decafAvailable,
      modifiers: modifiers ?? this.modifiers,
      allergens: allergens ?? this.allergens,
      dietaryTags: dietaryTags ?? this.dietaryTags,
    );
  }
}

const _unset = Object();
