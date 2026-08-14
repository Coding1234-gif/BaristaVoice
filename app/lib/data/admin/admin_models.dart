import '../../models/menu.dart';

export '../../models/cafe.dart' show Cafe;

enum MenuItemStatus {
  draft,
  published;

  static MenuItemStatus fromDb(String value) =>
      value == 'published' ? MenuItemStatus.published : MenuItemStatus.draft;

  String get toDb => this == MenuItemStatus.published ? 'published' : 'draft';
}

/// One `menu_items` row: DB-level fields (status, ownership, timestamps)
/// wrapped around the product data itself (the reused [MenuItem] model).
class MenuItemRecord {
  final String id;
  final String cafeId;
  final String? menuUploadId;
  final MenuItemStatus status;
  final DateTime updatedAt;
  final MenuItem item;

  const MenuItemRecord({
    required this.id,
    required this.cafeId,
    required this.status,
    required this.updatedAt,
    required this.item,
    this.menuUploadId,
  });

  factory MenuItemRecord.fromJson(Map<String, dynamic> json) => MenuItemRecord(
        id: json['id'] as String,
        cafeId: json['cafe_id'] as String,
        menuUploadId: json['menu_upload_id'] as String?,
        status: MenuItemStatus.fromDb(json['status'] as String? ?? 'draft'),
        updatedAt: DateTime.parse(json['updated_at'] as String),
        item: MenuItem.fromJson(json['data'] as Map<String, dynamic>),
      );
}

enum UploadStatus {
  pending,
  structured,
  failed;

  static UploadStatus fromDb(String value) => switch (value) {
        'structured' => UploadStatus.structured,
        'failed' => UploadStatus.failed,
        _ => UploadStatus.pending,
      };
}

class MenuUpload {
  final String id;
  final String cafeId;
  final String sourceType;
  final String? sourceRef;
  final UploadStatus status;
  final DateTime createdAt;

  const MenuUpload({
    required this.id,
    required this.cafeId,
    required this.sourceType,
    required this.status,
    required this.createdAt,
    this.sourceRef,
  });

  factory MenuUpload.fromJson(Map<String, dynamic> json) => MenuUpload(
        id: json['id'] as String,
        cafeId: json['cafe_id'] as String,
        sourceType: json['source_type'] as String,
        sourceRef: json['source_ref'] as String?,
        status: UploadStatus.fromDb(json['status'] as String? ?? 'pending'),
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}

class ExtractionResult {
  final int count;
  final List<MenuItem> items;

  const ExtractionResult({required this.count, required this.items});
}
