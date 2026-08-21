-- Tests for the canonical menu_items <-> POS product mapping workflow
-- (pos_product_mappings), specifically the trigger and unique-index layer
-- this change relies on: check_pos_product_mapping_cafe_match (which now
-- also verifies pos_product_id belongs to pos_connection_id, not just
-- "same cafe" as before) plus the two unique indexes that make a mapping
-- irreducibly one-to-one in both directions per connection.
--
-- HOW TO RUN: paste this whole file into the Supabase SQL editor (or
-- `psql <connection-string> -f this_file.sql`) against a project that
-- already has supabase/schema.sql applied. Run it as one script, not
-- statement-by-statement. It runs entirely inside one transaction that is
-- always ROLLED BACK at the end (see the last line), so it never leaves
-- fixture rows behind and is safe to re-run any number of times.
--
-- A failed assertion raises an exception with a "TEST FAILED:" prefix,
-- which aborts the whole script at that point (the transaction rolls back
-- regardless, so nothing needs cleaning up) — fix the issue and re-run.
-- Every passing assertion prints a "PASS: ..." NOTICE, so a clean run
-- prints exactly one PASS line per test below and nothing else unusual.
--
-- WHAT THIS FILE DOES NOT COVER: the RLS layer itself (that a cafe_admin
-- session literally cannot write another café's mapping) needs a real
-- authenticated session — two actual cafe_admin accounts created through
-- the app's normal signup flow (create_cafe_admin_account), then Supabase's
-- `set local role authenticated; set local request.jwt.claims = ...`
-- mechanism to run queries as each one. That RLS policy
-- ("cafe admin manages own pos_product_mappings", scoped by
-- can_manage_cafe()) is pre-existing, not new in this change; what IS new
-- here is the trigger's product/connection check, which is RLS-independent
-- by design (see its comment in schema.sql: "even from trusted server-side
-- code with a bug") and is exactly what's exercised below by connecting as
-- the ordinary SQL editor role, which bypasses RLS but not triggers or
-- constraints.

begin;

do $$
declare
  cafe_a uuid;
  cafe_b uuid;
  conn_a uuid;
  conn_b uuid;
  item_a uuid;
  item_a2 uuid;
  item_a3 uuid;
  item_b uuid;
  unmapped_item uuid;
  product_a1 uuid;
  product_a2 uuid;
  product_b1 uuid;
  mapping_id uuid;
  new_product uuid;
  mapping_count int;
begin
  -- -------------------------------------------------------------------------
  -- Fixtures: two cafés, one Square connection each, a couple of POS
  -- products per connection, and a few menu items.
  -- -------------------------------------------------------------------------
  insert into cafes (name) values ('POS Mapping Test Cafe A') returning id into cafe_a;
  insert into cafes (name) values ('POS Mapping Test Cafe B') returning id into cafe_b;

  insert into pos_connections (cafe_id, provider, status)
    values (cafe_a, 'square', 'active') returning id into conn_a;
  insert into pos_connections (cafe_id, provider, status)
    values (cafe_b, 'square', 'active') returning id into conn_b;

  insert into menu_items (cafe_id, status, data)
    values (cafe_a, 'published', '{"id":"latte-a","name":"Latte"}'::jsonb) returning id into item_a;
  insert into menu_items (cafe_id, status, data)
    values (cafe_b, 'published', '{"id":"latte-b","name":"Latte"}'::jsonb) returning id into item_b;

  insert into pos_products (cafe_id, pos_connection_id, external_product_id, name)
    values (cafe_a, conn_a, 'sq_latte_a', 'Latte (Square A)') returning id into product_a1;
  insert into pos_products (cafe_id, pos_connection_id, external_product_id, name)
    values (cafe_a, conn_a, 'sq_muffin_a', 'Muffin (Square A)') returning id into product_a2;
  insert into pos_products (cafe_id, pos_connection_id, external_product_id, name)
    values (cafe_b, conn_b, 'sq_latte_b', 'Latte (Square B)') returning id into product_b1;

  -- -------------------------------------------------------------------------
  -- 1. Valid mapping
  -- -------------------------------------------------------------------------
  insert into pos_product_mappings (menu_item_id, pos_connection_id, pos_product_id)
    values (item_a, conn_a, product_a1)
    returning id into mapping_id;

  if mapping_id is null then
    raise exception 'TEST FAILED: valid mapping was not created';
  end if;
  raise notice 'PASS: valid mapping created';

  -- -------------------------------------------------------------------------
  -- 2. Invalid mapping — pos_product_id (product_b1, on connection_b)
  --    does not belong to pos_connection_id (conn_a).
  -- -------------------------------------------------------------------------
  begin
    insert into pos_product_mappings (menu_item_id, pos_connection_id, pos_product_id)
      values (item_a, conn_a, product_b1);
    raise exception 'TEST FAILED: mapping with a mismatched connection/product was NOT rejected';
  exception
    when others then
      if sqlerrm like '%pos_product_id must belong to pos_connection_id%' then
        raise notice 'PASS: mismatched connection/product mapping rejected';
      else
        raise;
      end if;
  end;

  -- -------------------------------------------------------------------------
  -- 3. Cross-cafe attempt — menu_item from cafe A, POS connection from cafe B.
  -- -------------------------------------------------------------------------
  begin
    insert into pos_product_mappings (menu_item_id, pos_connection_id, pos_product_id)
      values (item_a, conn_b, product_b1);
    raise exception 'TEST FAILED: cross-cafe mapping was NOT rejected';
  exception
    when others then
      if sqlerrm like '%must belong to the same cafe%' then
        raise notice 'PASS: cross-cafe mapping rejected';
      else
        raise;
      end if;
  end;

  -- -------------------------------------------------------------------------
  -- 4a. Duplicate mapping — same (menu_item_id, pos_connection_id) twice.
  -- -------------------------------------------------------------------------
  begin
    insert into pos_product_mappings (menu_item_id, pos_connection_id, pos_product_id)
      values (item_a, conn_a, product_a2); -- item_a is already mapped on conn_a
    raise exception 'TEST FAILED: duplicate (menu_item_id, pos_connection_id) mapping was NOT rejected';
  exception
    when unique_violation then
      raise notice 'PASS: duplicate (menu_item_id, pos_connection_id) mapping rejected';
  end;

  -- -------------------------------------------------------------------------
  -- 4b. Duplicate mapping — same (pos_connection_id, pos_product_id) from a
  --     second, different menu item.
  -- -------------------------------------------------------------------------
  insert into menu_items (cafe_id, status, data)
    values (cafe_a, 'published', '{"id":"latte2-a","name":"Latte 2"}'::jsonb)
    returning id into item_a2;

  begin
    insert into pos_product_mappings (menu_item_id, pos_connection_id, pos_product_id)
      values (item_a2, conn_a, product_a1); -- product_a1 is already mapped (to item_a)
    raise exception 'TEST FAILED: duplicate (pos_connection_id, pos_product_id) mapping was NOT rejected';
  exception
    when unique_violation then
      raise notice 'PASS: duplicate (pos_connection_id, pos_product_id) mapping rejected';
  end;

  -- -------------------------------------------------------------------------
  -- 5. Missing POS product — pos_product_id references a row that doesn't exist.
  -- -------------------------------------------------------------------------
  insert into menu_items (cafe_id, status, data)
    values (cafe_a, 'published', '{"id":"latte3-a","name":"Latte 3"}'::jsonb)
    returning id into item_a3;

  begin
    insert into pos_product_mappings (menu_item_id, pos_connection_id, pos_product_id)
      values (item_a3, conn_a, '00000000-0000-0000-0000-000000000000');
    raise exception 'TEST FAILED: mapping to a nonexistent pos_product_id was NOT rejected';
  exception
    when foreign_key_violation then
      raise notice 'PASS: mapping to a nonexistent POS product rejected';
  end;

  -- -------------------------------------------------------------------------
  -- 6. Update then delete the original valid mapping.
  -- -------------------------------------------------------------------------
  update pos_product_mappings set pos_product_id = product_a2
    where id = mapping_id
    returning pos_product_id into new_product;

  if new_product is distinct from product_a2 then
    raise exception 'TEST FAILED: update did not repoint the mapping to product_a2';
  end if;
  raise notice 'PASS: mapping updated to a different POS product';

  delete from pos_product_mappings where id = mapping_id;
  if exists (select 1 from pos_product_mappings where id = mapping_id) then
    raise exception 'TEST FAILED: mapping still exists after delete';
  end if;
  raise notice 'PASS: mapping deleted';

  -- -------------------------------------------------------------------------
  -- 7. Unmapped menu item — a brand-new menu item has zero mappings.
  -- -------------------------------------------------------------------------
  insert into menu_items (cafe_id, status, data)
    values (cafe_a, 'published', '{"id":"never-mapped","name":"Never Mapped"}'::jsonb)
    returning id into unmapped_item;

  select count(*) into mapping_count from pos_product_mappings where menu_item_id = unmapped_item;
  if mapping_count <> 0 then
    raise exception 'TEST FAILED: a brand-new menu item already has a mapping';
  end if;
  raise notice 'PASS: unmapped menu item has zero pos_product_mappings rows';

  raise notice 'ALL PASS: pos_product_mappings tests completed successfully';
end $$;

rollback;
