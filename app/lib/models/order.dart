import 'package:uuid/uuid.dart';

import 'menu.dart';

const _uuid = Uuid();

enum OrderStatus { draft, confirmed, paid }

/// One line in the order. Prices are never trusted from the conversational
/// layer — [priceForMenu] always recomputes from the menu item it points at.
class OrderItem {
  final String id;
  final String menuItemId;
  final String name; // denormalized snapshot for display
  final int quantity;
  final String? size;
  final String? milk;
  final String? temperature;
  final bool decaf;
  final List<String> modifiers;
  final String? specialRequest;

  OrderItem({
    String? id,
    required this.menuItemId,
    required this.name,
    this.quantity = 1,
    this.size,
    this.milk,
    this.temperature,
    this.decaf = false,
    this.modifiers = const [],
    this.specialRequest,
  }) : id = id ?? _uuid.v4();

  OrderItem copyWith({
    int? quantity,
    String? size,
    String? milk,
    String? temperature,
    bool? decaf,
    List<String>? modifiers,
    String? specialRequest,
  }) {
    return OrderItem(
      id: id,
      menuItemId: menuItemId,
      name: name,
      quantity: quantity ?? this.quantity,
      size: size ?? this.size,
      milk: milk ?? this.milk,
      temperature: temperature ?? this.temperature,
      decaf: decaf ?? this.decaf,
      modifiers: modifiers ?? this.modifiers,
      specialRequest: specialRequest ?? this.specialRequest,
    );
  }

  /// Computes the unit + line price strictly from the menu item's data.
  double unitPrice(CafeMenu menu) {
    final item = menu.findById(menuItemId);
    if (item == null) return 0;
    double price = item.basePrice;
    if (size != null) {
      final match = item.sizes.where((s) => s.name == size);
      if (match.isNotEmpty) price += match.first.priceDelta;
    }
    if (milk != null) {
      final match = item.milkOptions.where((m) => m.name == milk);
      if (match.isNotEmpty) price += match.first.priceDelta;
    }
    for (final mod in modifiers) {
      final match = item.modifiers.where((m) => m.name == mod);
      if (match.isNotEmpty) price += match.first.priceDelta;
    }
    return price;
  }

  double lineTotal(CafeMenu menu) => unitPrice(menu) * quantity;

  Map<String, dynamic> toJson() => {
        'id': id,
        'menuItemId': menuItemId,
        'name': name,
        'quantity': quantity,
        'size': size,
        'milk': milk,
        'temperature': temperature,
        'decaf': decaf,
        'modifiers': modifiers,
        'specialRequest': specialRequest,
      };

  factory OrderItem.fromJson(Map<String, dynamic> json) => OrderItem(
        id: json['id'] as String?,
        menuItemId: json['menuItemId'] as String,
        name: json['name'] as String,
        quantity: json['quantity'] as int? ?? 1,
        size: json['size'] as String?,
        milk: json['milk'] as String?,
        temperature: json['temperature'] as String?,
        decaf: json['decaf'] as bool? ?? false,
        modifiers:
            (json['modifiers'] as List<dynamic>? ?? []).map((e) => e as String).toList(),
        specialRequest: json['specialRequest'] as String?,
      );
}

class Order {
  final List<OrderItem> items;
  final OrderStatus status;

  const Order({this.items = const [], this.status = OrderStatus.draft});

  Order copyWith({List<OrderItem>? items, OrderStatus? status}) => Order(
        items: items ?? this.items,
        status: status ?? this.status,
      );

  double total(CafeMenu menu) =>
      items.fold(0.0, (sum, item) => sum + item.lineTotal(menu));

  bool get isEmpty => items.isEmpty;

  Map<String, dynamic> toJson() => {
        'items': items.map((e) => e.toJson()).toList(),
        'status': status.name,
      };

  factory Order.fromJson(Map<String, dynamic> json) => Order(
        items: (json['items'] as List<dynamic>? ?? [])
            .map((e) => OrderItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        status: OrderStatus.values.firstWhere(
          (s) => s.name == json['status'],
          orElse: () => OrderStatus.draft,
        ),
      );
}
