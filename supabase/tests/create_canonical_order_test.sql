-- Tests for create_canonical_order() — the sole pricing/validation
-- authority behind the create-order Edge Function (see
-- supabase/functions/create-order/index.ts, whose own tests cover the pure
-- request-shape/relay logic that sits in front of this function; everything
-- about whether an item/option/price is actually VALID is decided here,
-- against real menu_items rows, which is why it belongs in a DB-level test
-- rather than a Deno unit test — same reasoning as
-- pos_product_mappings_test.sql / order_submission_test.sql.
--
-- HOW TO RUN: paste into the Supabase SQL editor as one script, or
-- `psql ... -f`. Runs in one transaction that always rolls back at the end;
-- safe to re-run any number of times. Tests that expect create_canonical_order
-- to fail wrap the call in its own `begin ... exception ... end;` block —
-- that's a PL/pgSQL sub-transaction (implicit savepoint), not a bug: without
-- it, an expected failure would abort the whole script's outer transaction
-- and skip every later test.

begin;

do $$
declare
  cafe_a uuid;
  cafe_b uuid;
  latte_id uuid;
  muffin_id uuid;
  draft_item_id uuid;
  cafe_b_item_id uuid;
  result record;
  first_result record;
  second_result record;
  order_count int;
  item_count int;
  modifier_count int;
  computed_unit_price numeric;
  failed boolean;
begin
  -- -------------------------------------------------------------------------
  -- Fixtures: two cafés, a published item with size/milk/modifier/decaf
  -- options, a second published item with no options, a DRAFT item (should
  -- never be orderable), and an item belonging to a different café.
  -- -------------------------------------------------------------------------
  insert into cafes (name) values ('Order Creation Test Cafe A') returning id into cafe_a;
  insert into cafes (name) values ('Order Creation Test Cafe B') returning id into cafe_b;

  insert into menu_items (cafe_id, status, data) values (
    cafe_a, 'published',
    '{
      "name": "Latte", "description": "", "category": "Espresso Drinks",
      "basePrice": 4.25, "popular": true, "available": true,
      "sizes": [{"name": "Small", "priceDelta": 0}, {"name": "Large", "priceDelta": 1.0}],
      "milkOptions": [{"name": "Oat", "priceDelta": 0.6}],
      "temperatureOptions": ["hot", "iced"],
      "decafAvailable": true,
      "modifiers": [{"name": "Extra Shot", "priceDelta": 0.75}],
      "allergens": [], "dietaryTags": []
    }'::jsonb
  ) returning id into latte_id;

  insert into menu_items (cafe_id, status, data) values (
    cafe_a, 'published',
    '{
      "name": "Blueberry Muffin", "description": "", "category": "Bakery",
      "basePrice": 3.5, "popular": false, "available": true,
      "sizes": [], "milkOptions": [], "temperatureOptions": [],
      "decafAvailable": false, "modifiers": [], "allergens": [], "dietaryTags": []
    }'::jsonb
  ) returning id into muffin_id;

  insert into menu_items (cafe_id, status, data) values (
    cafe_a, 'draft',
    '{"name": "Unreleased Item", "description": "", "category": "Other", "basePrice": 5.0, "popular": false, "available": true, "sizes": [], "milkOptions": [], "temperatureOptions": [], "decafAvailable": false, "modifiers": [], "allergens": [], "dietaryTags": []}'::jsonb
  ) returning id into draft_item_id;

  insert into menu_items (cafe_id, status, data) values (
    cafe_b, 'published',
    '{"name": "Cafe B Item", "description": "", "category": "Other", "basePrice": 2.0, "popular": false, "available": true, "sizes": [], "milkOptions": [], "temperatureOptions": [], "decafAvailable": false, "modifiers": [], "allergens": [], "dietaryTags": []}'::jsonb
  ) returning id into cafe_b_item_id;

  -- -------------------------------------------------------------------------
  -- 1. Valid order, single plain item.
  -- -------------------------------------------------------------------------
  select * into result from create_canonical_order(jsonb_build_object(
    'cafe_id', cafe_a,
    'idempotency_key', 'test-valid-single',
    'items', jsonb_build_array(jsonb_build_object('menuItemId', muffin_id, 'quantity', 1))
  ));
  if result.status <> 'confirmed' or result.total <> 3.50 then
    raise exception 'TEST FAILED: valid single-item order — got status=%, total=%', result.status, result.total;
  end if;
  raise notice 'PASS: valid single-item order creates a confirmed order with the correct total';

  -- -------------------------------------------------------------------------
  -- 2. Multiple items.
  -- -------------------------------------------------------------------------
  select * into result from create_canonical_order(jsonb_build_object(
    'cafe_id', cafe_a,
    'idempotency_key', 'test-multi-item',
    'items', jsonb_build_array(
      jsonb_build_object('menuItemId', muffin_id, 'quantity', 2),
      jsonb_build_object('menuItemId', latte_id, 'quantity', 1, 'size', 'Small')
    )
  ));
  select count(*) into item_count from order_items where order_id = result.order_id;
  -- 2x muffin (3.50) + 1x latte small (4.25) = 11.25
  if item_count <> 2 or result.total <> 11.25 then
    raise exception 'TEST FAILED: multi-item order — got % items, total=%', item_count, result.total;
  end if;
  raise notice 'PASS: multi-item order creates one order_items row per line with the correct combined total';

  -- -------------------------------------------------------------------------
  -- 3. Modifiers, size, milk, decaf, temperature all priced/recorded together.
  -- -------------------------------------------------------------------------
  select * into result from create_canonical_order(jsonb_build_object(
    'cafe_id', cafe_a,
    'idempotency_key', 'test-modifiers',
    'items', jsonb_build_array(jsonb_build_object(
      'menuItemId', latte_id, 'quantity', 2, 'size', 'Large', 'milk', 'Oat',
      'temperature', 'iced', 'decaf', true, 'modifiers', jsonb_build_array('Extra Shot')
    ))
  ));
  select unit_price into computed_unit_price from order_items where order_id = result.order_id;
  select count(*) into modifier_count from order_item_modifiers oim
    join order_items oi on oi.id = oim.order_item_id where oi.order_id = result.order_id;
  -- unit_price = base 4.25 + size 1.0 + milk 0.6 = 5.85 (modifier priced separately)
  -- total = 2 * (5.85 + 0.75) = 13.20
  if computed_unit_price <> 5.85 or modifier_count <> 1 or result.total <> 13.20 then
    raise exception 'TEST FAILED: modifiers/size/milk pricing — unit_price=%, modifier_count=%, total=%',
      computed_unit_price, modifier_count, result.total;
  end if;
  raise notice 'PASS: size/milk/decaf/temperature/modifiers are all validated and priced correctly';

  -- -------------------------------------------------------------------------
  -- 4. Invalid (nonexistent) menu item is rejected — and rolls back cleanly.
  -- -------------------------------------------------------------------------
  failed := false;
  begin
    select * into result from create_canonical_order(jsonb_build_object(
      'cafe_id', cafe_a,
      'idempotency_key', 'test-invalid-item',
      'items', jsonb_build_array(jsonb_build_object('menuItemId', gen_random_uuid(), 'quantity', 1))
    ));
  exception when others then
    failed := true;
  end;
  if not failed then
    raise exception 'TEST FAILED: a nonexistent menu item was accepted';
  end if;
  if exists (select 1 from orders where idempotency_key = 'test-invalid-item') then
    raise exception 'TEST FAILED: a rejected order left a row behind';
  end if;
  raise notice 'PASS: a nonexistent menu item is rejected and leaves no order behind';

  -- -------------------------------------------------------------------------
  -- 5. Unpublished (draft) menu item is rejected exactly like a nonexistent one.
  -- -------------------------------------------------------------------------
  failed := false;
  begin
    select * into result from create_canonical_order(jsonb_build_object(
      'cafe_id', cafe_a,
      'idempotency_key', 'test-draft-item',
      'items', jsonb_build_array(jsonb_build_object('menuItemId', draft_item_id, 'quantity', 1))
    ));
  exception when others then
    failed := true;
  end;
  if not failed then
    raise exception 'TEST FAILED: an unpublished (draft) menu item was accepted';
  end if;
  raise notice 'PASS: an unpublished (draft) menu item is rejected';

  -- -------------------------------------------------------------------------
  -- 6. Invalid modifier name is rejected.
  -- -------------------------------------------------------------------------
  failed := false;
  begin
    select * into result from create_canonical_order(jsonb_build_object(
      'cafe_id', cafe_a,
      'idempotency_key', 'test-invalid-modifier',
      'items', jsonb_build_array(jsonb_build_object(
        'menuItemId', latte_id, 'quantity', 1, 'modifiers', jsonb_build_array('Nonexistent Syrup')
      ))
    ));
  exception when others then
    failed := true;
  end;
  if not failed then
    raise exception 'TEST FAILED: a modifier not on the menu item was accepted';
  end if;
  raise notice 'PASS: a modifier not offered by the item is rejected';

  -- -------------------------------------------------------------------------
  -- 7. Invalid quantity (zero, negative, absurdly large) is rejected.
  -- -------------------------------------------------------------------------
  failed := false;
  begin
    select * into result from create_canonical_order(jsonb_build_object(
      'cafe_id', cafe_a, 'idempotency_key', 'test-qty-zero',
      'items', jsonb_build_array(jsonb_build_object('menuItemId', muffin_id, 'quantity', 0))
    ));
  exception when others then
    failed := true;
  end;
  if not failed then raise exception 'TEST FAILED: quantity 0 was accepted'; end if;

  failed := false;
  begin
    select * into result from create_canonical_order(jsonb_build_object(
      'cafe_id', cafe_a, 'idempotency_key', 'test-qty-negative',
      'items', jsonb_build_array(jsonb_build_object('menuItemId', muffin_id, 'quantity', -3))
    ));
  exception when others then
    failed := true;
  end;
  if not failed then raise exception 'TEST FAILED: a negative quantity was accepted'; end if;

  failed := false;
  begin
    select * into result from create_canonical_order(jsonb_build_object(
      'cafe_id', cafe_a, 'idempotency_key', 'test-qty-huge',
      'items', jsonb_build_array(jsonb_build_object('menuItemId', muffin_id, 'quantity', 999))
    ));
  exception when others then
    failed := true;
  end;
  if not failed then raise exception 'TEST FAILED: an absurd quantity (999) was accepted'; end if;
  raise notice 'PASS: zero, negative, and absurdly large quantities are all rejected';

  -- -------------------------------------------------------------------------
  -- 8. A manipulated client-supplied price is silently ignored — the
  --    function never reads a price field from the payload at all, so the
  --    stored unit_price is always the canonical menu price regardless of
  --    what extra keys a tampered client includes.
  -- -------------------------------------------------------------------------
  select * into result from create_canonical_order(jsonb_build_object(
    'cafe_id', cafe_a,
    'idempotency_key', 'test-price-tamper',
    'items', jsonb_build_array(jsonb_build_object(
      'menuItemId', muffin_id, 'quantity', 1, 'unitPrice', 0.01, 'price', 0.01, 'total', 0.01
    ))
  ));
  select unit_price into computed_unit_price from order_items where order_id = result.order_id;
  if computed_unit_price <> 3.50 or result.total <> 3.50 then
    raise exception 'TEST FAILED: a client-supplied price leaked through (unit_price=%, total=%)',
      computed_unit_price, result.total;
  end if;
  raise notice 'PASS: a client-supplied price field is ignored; price is always computed from menu_items';

  -- -------------------------------------------------------------------------
  -- 9. Wrong/nonexistent café: an unknown cafe_id is rejected, and an item
  --    that belongs to a DIFFERENT café than the one specified is rejected
  --    exactly like a nonexistent item (no cross-cafe leak).
  -- -------------------------------------------------------------------------
  failed := false;
  begin
    select * into result from create_canonical_order(jsonb_build_object(
      'cafe_id', gen_random_uuid(),
      'idempotency_key', 'test-unknown-cafe',
      'items', jsonb_build_array(jsonb_build_object('menuItemId', muffin_id, 'quantity', 1))
    ));
  exception when others then
    failed := true;
  end;
  if not failed then raise exception 'TEST FAILED: an unknown cafe_id was accepted'; end if;

  failed := false;
  begin
    -- cafe_a's payload referencing cafe_b's item id.
    select * into result from create_canonical_order(jsonb_build_object(
      'cafe_id', cafe_a,
      'idempotency_key', 'test-cross-cafe-item',
      'items', jsonb_build_array(jsonb_build_object('menuItemId', cafe_b_item_id, 'quantity', 1))
    ));
  exception when others then
    failed := true;
  end;
  if not failed then raise exception 'TEST FAILED: an item belonging to a different cafe was accepted'; end if;
  raise notice 'PASS: an unknown cafe and a cross-cafe item are both rejected';

  -- -------------------------------------------------------------------------
  -- 10 & 11. Duplicate idempotency_key / retry behavior: a second call with
  --     the SAME key returns the SAME order — even with a different items
  --     payload — and never creates a second orders row.
  -- -------------------------------------------------------------------------
  select * into first_result from create_canonical_order(jsonb_build_object(
    'cafe_id', cafe_a,
    'idempotency_key', 'test-idempotent-retry',
    'items', jsonb_build_array(jsonb_build_object('menuItemId', muffin_id, 'quantity', 1))
  ));
  select * into second_result from create_canonical_order(jsonb_build_object(
    'cafe_id', cafe_a,
    'idempotency_key', 'test-idempotent-retry',
    -- Deliberately different (and by itself invalid) payload — proves the
    -- idempotency short-circuit returns the existing order WITHOUT
    -- re-validating or re-reading this payload at all.
    'items', jsonb_build_array(jsonb_build_object('menuItemId', gen_random_uuid(), 'quantity', 500))
  ));
  select count(*) into order_count from orders where idempotency_key = 'test-idempotent-retry';
  if second_result.order_id <> first_result.order_id or order_count <> 1 then
    raise exception 'TEST FAILED: retrying with the same idempotency_key did not return the original order';
  end if;
  raise notice 'PASS: retrying with the same idempotency_key returns the original order, never a duplicate';

  -- -------------------------------------------------------------------------
  -- 12. Transaction failure: one invalid item among several rolls back the
  --     ENTIRE order — no partial order_items/order_item_modifiers survive.
  -- -------------------------------------------------------------------------
  failed := false;
  begin
    select * into result from create_canonical_order(jsonb_build_object(
      'cafe_id', cafe_a,
      'idempotency_key', 'test-partial-rollback',
      'items', jsonb_build_array(
        jsonb_build_object('menuItemId', muffin_id, 'quantity', 1),
        jsonb_build_object('menuItemId', latte_id, 'quantity', 1, 'modifiers', jsonb_build_array('Nonexistent Syrup'))
      )
    ));
  exception when others then
    failed := true;
  end;
  if not failed then raise exception 'TEST FAILED: an order with one invalid line item was accepted'; end if;
  if exists (select 1 from orders where idempotency_key = 'test-partial-rollback') then
    raise exception 'TEST FAILED: a rejected multi-item order left an orders row behind';
  end if;
  if exists (
    select 1 from order_items oi join orders o on o.id = oi.order_id
    where o.idempotency_key = 'test-partial-rollback'
  ) then
    raise exception 'TEST FAILED: a rejected order left order_items behind (partial commit — not atomic)';
  end if;
  raise notice 'PASS: an order with one invalid line item rolls back completely (fully atomic, no partial commit)';

  raise notice 'ALL PASS: create_canonical_order() validation, pricing, idempotency, and atomicity all hold';
end $$;

rollback;
