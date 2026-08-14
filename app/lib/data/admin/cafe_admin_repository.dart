import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../models/menu.dart';
import 'admin_models.dart';

const _uuid = Uuid();

/// All cafe_admin-facing reads/writes. Every query includes cafe_id, but
/// that's for query shaping only — the actual isolation boundary is Supabase
/// RLS (`cafe_id = current_cafe_id()`), enforced server-side regardless of
/// what cafeId this repository is called with. A malicious client editing
/// this code (or crafting raw requests) still cannot reach another cafe's
/// rows; the database itself refuses them.
class CafeAdminRepository {
  final SupabaseClient _client;

  CafeAdminRepository(this._client);

  Future<Cafe> getCafe(String cafeId) async {
    final row = await _client.from('cafes').select().eq('id', cafeId).single();
    return Cafe.fromJson(row);
  }

  Future<List<Cafe>> listAllCafes() async {
    final rows = await _client.from('cafes').select().order('name');
    return rows.map((r) => Cafe.fromJson(r)).toList();
  }

  Future<void> updateCafeName(String cafeId, String name) async {
    await _client.from('cafes').update({'name': name}).eq('id', cafeId);
  }

  Future<List<MenuItemRecord>> getMenuItems(String cafeId) async {
    final rows = await _client
        .from('menu_items')
        .select()
        .eq('cafe_id', cafeId)
        .order('updated_at', ascending: false);
    return rows.map((r) => MenuItemRecord.fromJson(r)).toList();
  }

  Future<void> addProduct(String cafeId, MenuItem item, {bool publish = true}) async {
    final id = item.id.isNotEmpty ? item.id : _uuid.v4();
    final data = item.toJson()..['id'] = id;

    await _client.from('menu_items').insert({
      'id': id,
      'cafe_id': cafeId,
      'status': publish ? 'published' : 'draft',
      'data': data,
    });
  }

  Future<void> updateProduct(String recordId, MenuItem updated) async {
    await _client.from('menu_items').update({
      'data': updated.toJson(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', recordId);
  }

  Future<void> deleteProduct(String recordId) async {
    await _client.from('menu_items').delete().eq('id', recordId);
  }

  Future<void> setStatus(String recordId, MenuItemStatus status) async {
    await _client.from('menu_items').update({
      'status': status.toDb,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', recordId);
  }

  /// Publishes every draft item for the cafe at once (the dashboard's
  /// "Publish Menu" action).
  Future<int> publishAllDrafts(String cafeId) async {
    final rows = await _client
        .from('menu_items')
        .update({'status': 'published', 'updated_at': DateTime.now().toUtc().toIso8601String()})
        .eq('cafe_id', cafeId)
        .eq('status', 'draft')
        .select('id');
    return rows.length;
  }

  Future<List<MenuUpload>> getMenuUploads(String cafeId) async {
    final rows = await _client
        .from('menu_uploads')
        .select()
        .eq('cafe_id', cafeId)
        .order('created_at', ascending: false);
    return rows.map((r) => MenuUpload.fromJson(r)).toList();
  }

  /// Uploads a raw PDF/image to the private `menu-uploads` bucket under
  /// `<cafeId>/...` and records a `menu_uploads` row for it. Returns the new
  /// upload's id so the caller can trigger extraction next.
  Future<String> uploadMenuFile({
    required String cafeId,
    required Uint8List bytes,
    required String filename,
    required String sourceType,
  }) async {
    final ext = filename.contains('.') ? filename.split('.').last : 'bin';
    final path = '$cafeId/${_uuid.v4()}.$ext';

    await _client.storage.from('menu-uploads').uploadBinary(path, bytes);

    final row = await _client
        .from('menu_uploads')
        .insert({'cafe_id': cafeId, 'source_type': sourceType, 'source_ref': path})
        .select()
        .single();

    return row['id'] as String;
  }

  /// Invokes the `menu-extractor` Edge Function, which reads the upload's
  /// own cafe_id server-side and checks it against the caller's profile —
  /// this call cannot be redirected to extract into a different cafe.
  Future<ExtractionResult> triggerExtraction(String uploadId) async {
    final response = await _client.functions.invoke(
      'menu-extractor',
      body: {'uploadId': uploadId},
    );

    final data = response.data as Map<String, dynamic>;
    if (data['error'] != null) {
      throw Exception(data['error'] as String);
    }

    final items = (data['items'] as List<dynamic>)
        .map((e) => MenuItem.fromJson(e as Map<String, dynamic>))
        .toList();
    return ExtractionResult(count: data['count'] as int? ?? items.length, items: items);
  }

  /// Uploads a product photo to the public `product-images` bucket under
  /// `<cafeId>/...` and returns its public URL.
  Future<String> uploadProductImage({
    required String cafeId,
    required Uint8List bytes,
    required String filename,
  }) async {
    final ext = filename.contains('.') ? filename.split('.').last : 'jpg';
    final path = '$cafeId/${_uuid.v4()}.$ext';

    await _client.storage.from('product-images').uploadBinary(path, bytes);
    return _client.storage.from('product-images').getPublicUrl(path);
  }
}
