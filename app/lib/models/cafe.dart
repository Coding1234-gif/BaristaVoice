/// One `cafes` row. Shared by the customer app (café header, QR/deep-link
/// resolution) and the cafe_admin dashboard — one model, one source of
/// truth for what a café "is", regardless of which side of the app is
/// reading it.
class Cafe {
  final String id;
  final String name;
  final String? logoUrl;
  final String? description;
  final String? address;
  final String? slug;

  const Cafe({
    required this.id,
    required this.name,
    this.logoUrl,
    this.description,
    this.address,
    this.slug,
  });

  factory Cafe.fromJson(Map<String, dynamic> json) => Cafe(
        id: json['id'] as String,
        name: json['name'] as String,
        logoUrl: json['logo_url'] as String?,
        description: json['description'] as String?,
        address: json['address'] as String?,
        slug: json['slug'] as String?,
      );
}
