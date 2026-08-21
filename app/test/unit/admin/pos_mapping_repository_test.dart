// Offline unit tests for the POS mapping data layer — no device, backend, or
// Supabase connection required (matches this project's existing test/unit/
// convention). These cover exactly the parts of the mapping workflow that
// are actual Dart logic:
//   - model JSON parsing (a valid mapping/product/modifier round-trips)
//   - translatePosMappingWriteError's classification of Postgres errors
//     into typed exceptions (invalid mapping, cross-cafe attempt, duplicate
//     mapping, missing POS product)
//
// The remaining required scenarios — cross-cafe RLS enforcement, the
// unique-index-backed duplicate rejection, updating/deleting a mapping
// (incl. one that isn't yours), and an unmapped menu item — are all
// enforced by Postgres itself (RLS policies, unique indexes, and the
// check_pos_product_mapping_cafe_match trigger), not by any Dart code, so
// they can't be meaningfully exercised without a live database. Those are
// covered by supabase/tests/pos_product_mappings_test.sql instead, which
// this project has no existing convention or tooling for running from
// `flutter test` (no local Postgres/Supabase CLI/Docker was available in
// this environment either — see that file's header for how to run it).
import 'package:barista_voice/data/admin/pos_mapping_models.dart';
import 'package:barista_voice/data/admin/pos_mapping_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postgrest/postgrest.dart';

void main() {
  group('model JSON parsing (valid mapping)', () {
    test('PosProductMapping.fromJson parses a valid mapping row', () {
      final mapping = PosProductMapping.fromJson({
        'id': 'map-1',
        'menu_item_id': 'item-1',
        'pos_connection_id': 'conn-1',
        'pos_product_id': 'prod-1',
        'updated_at': '2026-01-01T00:00:00Z',
      });

      expect(mapping.id, 'map-1');
      expect(mapping.menuItemId, 'item-1');
      expect(mapping.posConnectionId, 'conn-1');
      expect(mapping.posProductId, 'prod-1');
    });

    test('PosProduct.fromJson preserves the external (Square) product id', () {
      final product = PosProduct.fromJson({
        'id': 'prod-1',
        'cafe_id': 'cafe-1',
        'pos_connection_id': 'conn-1',
        'external_product_id': 'var_latte_small',
        'name': 'Latte - Small',
        'category': 'Espresso Drinks',
        'price': 4.25,
        'active': true,
      });

      expect(product.externalProductId, 'var_latte_small');
      expect(product.price, 4.25);
    });

    test('PosModifier.fromJson defaults active/priceAdjustment when absent', () {
      final modifier = PosModifier.fromJson({
        'id': 'mod-1',
        'cafe_id': 'cafe-1',
        'pos_connection_id': 'conn-1',
        'external_modifier_id': 'mod_no_charge',
        'name': 'No Foam',
      });

      expect(modifier.priceAdjustment, 0);
      expect(modifier.active, true);
    });
  });

  group('translatePosMappingWriteError', () {
    test('unique_violation (23505) -> DuplicateMappingException', () {
      const error = PostgrestException(
        message: 'duplicate key value violates unique constraint '
            '"pos_product_mappings_menu_item_connection_key"',
        code: '23505',
      );

      expect(
        translatePosMappingWriteError(error),
        isA<DuplicateMappingException>(),
      );
    });

    test('trigger rejection for cross-cafe mismatch -> CrossCafeMappingException', () {
      const error = PostgrestException(
        message: 'pos_product_mappings: menu_item_id and pos_connection_id '
            'must belong to the same cafe',
        code: 'P0001',
      );

      expect(
        translatePosMappingWriteError(error),
        isA<CrossCafeMappingException>(),
      );
    });

    test('trigger rejection for product/connection mismatch -> InvalidMappingException', () {
      const error = PostgrestException(
        message: 'pos_product_mappings: pos_product_id must belong to pos_connection_id',
        code: 'P0001',
      );

      expect(
        translatePosMappingWriteError(error),
        isA<InvalidMappingException>(),
      );
    });

    test('foreign_key_violation mentioning pos_product_id -> PosReferenceNotFoundException '
        '(missing POS product)', () {
      const error = PostgrestException(
        message: 'insert or update on table "pos_product_mappings" violates foreign key '
            'constraint "pos_product_mappings_pos_product_id_fkey"',
        code: '23503',
      );

      final translated = translatePosMappingWriteError(error);
      expect(translated, isA<PosReferenceNotFoundException>());
      expect(translated.toString(), contains('The selected POS product does not exist'));
    });

    test('an unrecognized error code is passed through unchanged', () {
      const error = PostgrestException(message: 'some other failure', code: '55000');
      expect(translatePosMappingWriteError(error), same(error));
    });
  });
}
