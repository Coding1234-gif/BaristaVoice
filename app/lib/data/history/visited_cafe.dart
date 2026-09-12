/// One entry in the customer's locally-remembered café history — there's no
/// customer account/login in this app, so this is purely on-device (see
/// VisitedCafesRepository), not synced anywhere.
class VisitedCafe {
  final String id;
  final String name;
  final String? logoUrl;
  final DateTime lastVisitedAt;

  const VisitedCafe({
    required this.id,
    required this.name,
    this.logoUrl,
    required this.lastVisitedAt,
  });

  factory VisitedCafe.fromJson(Map<String, dynamic> json) => VisitedCafe(
        id: json['id'] as String,
        name: json['name'] as String,
        logoUrl: json['logoUrl'] as String?,
        lastVisitedAt: DateTime.parse(json['lastVisitedAt'] as String),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'logoUrl': logoUrl,
        'lastVisitedAt': lastVisitedAt.toIso8601String(),
      };
}
