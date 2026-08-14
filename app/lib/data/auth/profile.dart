/// Mirrors the `profiles` table. `role`/`cafeId` are always read back from
/// the database (via RLS scoped to the caller's own row) — never trusted
/// from anything the client computed itself.
enum AppRole { customer, cafeAdmin, superAdmin;

  static AppRole fromDb(String value) => switch (value) {
        'cafe_admin' => AppRole.cafeAdmin,
        'super_admin' => AppRole.superAdmin,
        _ => AppRole.customer,
      };
}

class Profile {
  final String id;
  final AppRole role;
  final String? cafeId;
  final String? displayName;

  const Profile({
    required this.id,
    required this.role,
    this.cafeId,
    this.displayName,
  });

  bool get canAccessAdmin => role == AppRole.cafeAdmin || role == AppRole.superAdmin;

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
        id: json['id'] as String,
        role: AppRole.fromDb(json['role'] as String? ?? 'customer'),
        cafeId: json['cafe_id'] as String?,
        displayName: json['display_name'] as String?,
      );
}
