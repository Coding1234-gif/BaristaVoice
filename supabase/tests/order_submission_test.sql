-- Tests for the DB-level guarantees pos-square-order-submit relies on but
-- cannot itself unit test (see index.test.ts for everything that IS pure
-- Deno logic — resolution, payload building, idempotency-key forwarding,
-- authorization decisions):
--
--   1. The atomic "claim" state machine: an UPDATE ... WHERE status IN
--      ('confirmed','pos_failed') ... RETURNING is what pos-square-order-submit
--      uses to make concurrent double-submission impossible without any
--      extra locking. This script proves the WHERE clause actually behaves
--      as a gate (claims an eligible order, refuses an ineligible one) —
--      it can't prove the CONCURRENT-safety property itself (that's a
--      property of a single atomic SQL statement, not something a
--      sequential script can race), but the gate logic is exactly what
--      makes it safe.
--   2. check_order_pos_connection_cafe_match (pre-existing trigger) — the
--      order-submit function deliberately does NOT re-verify that a
--      resolved pos_connection_id belongs to the order's own café,
--      trusting this trigger to have made that impossible at write time.
--      This confirms that trust is warranted.
--   3. orders_idempotency_key_key (pre-existing unique index) — the
--      backbone of requirement 9. Confirms it still holds.
--
-- HOW TO RUN: same as pos_product_mappings_test.sql — paste into the
-- Supabase SQL editor as one script, or `psql ... -f`. Runs in one
-- transaction that always rolls back; safe to re-run any number of times.

begin;

do $$
declare
  cafe_a uuid;
  cafe_b uuid;
  conn_a uuid;
  conn_b uuid;
  order_confirmed uuid;
  order_sent uuid;
  order_draft uuid;
  claimed_count int;
begin
  -- -------------------------------------------------------------------------
  -- Fixtures
  -- -------------------------------------------------------------------------
  insert into cafes (name) values ('Order Submit Test Cafe A') returning id into cafe_a;
  insert into cafes (name) values ('Order Submit Test Cafe B') returning id into cafe_b;

  insert into pos_connections (cafe_id, provider, status, location_id)
    values (cafe_a, 'square', 'active', 'loc_a') returning id into conn_a;
  insert into pos_connections (cafe_id, provider, status, location_id)
    values (cafe_b, 'square', 'active', 'loc_b') returning id into conn_b;

  insert into orders (cafe_id, status, total, idempotency_key)
    values (cafe_a, 'confirmed', 10.00, 'idem-confirmed-1') returning id into order_confirmed;
  insert into orders (cafe_id, status, total, idempotency_key, external_order_id, pos_provider)
    values (cafe_a, 'sent_to_pos', 10.00, 'idem-sent-1', 'sq-already-sent', 'square') returning id into order_sent;
  insert into orders (cafe_id, status, total, idempotency_key)
    values (cafe_a, 'draft', 10.00, 'idem-draft-1') returning id into order_draft;

  -- -------------------------------------------------------------------------
  -- 1a. Claim gate: a 'confirmed' order CAN be claimed.
  -- -------------------------------------------------------------------------
  update orders set status = 'sending_to_pos'
    where id = order_confirmed and status in ('confirmed', 'pos_failed');
  get diagnostics claimed_count = row_count;
  if claimed_count <> 1 then
    raise exception 'TEST FAILED: a confirmed order could not be claimed (% rows)', claimed_count;
  end if;
  raise notice 'PASS: a confirmed order can be claimed for submission';

  -- Put it back so later assertions about "eligible statuses" stay accurate
  -- if this script is extended.
  update orders set status = 'confirmed' where id = order_confirmed;

  -- -------------------------------------------------------------------------
  -- 1b. Claim gate: an already 'sent_to_pos' order CANNOT be re-claimed —
  --     this is what makes retrying pos-square-order-submit safe: the claim
  --     step itself refuses to touch an order that's already done.
  -- -------------------------------------------------------------------------
  update orders set status = 'sending_to_pos'
    where id = order_sent and status in ('confirmed', 'pos_failed');
  get diagnostics claimed_count = row_count;
  if claimed_count <> 0 then
    raise exception 'TEST FAILED: an already sent_to_pos order was re-claimed (% rows)', claimed_count;
  end if;
  raise notice 'PASS: an already-sent order cannot be re-claimed (idempotent retry guard)';

  -- -------------------------------------------------------------------------
  -- 1c. Claim gate: a 'draft' order (never confirmed by the customer)
  --     CANNOT be claimed either.
  -- -------------------------------------------------------------------------
  update orders set status = 'sending_to_pos'
    where id = order_draft and status in ('confirmed', 'pos_failed');
  get diagnostics claimed_count = row_count;
  if claimed_count <> 0 then
    raise exception 'TEST FAILED: a draft (unconfirmed) order was claimed (% rows)', claimed_count;
  end if;
  raise notice 'PASS: a draft order cannot be claimed for POS submission';

  -- -------------------------------------------------------------------------
  -- 2. check_order_pos_connection_cafe_match: an order cannot be linked to
  --    a POS connection belonging to a different café. pos-square-order-submit
  --    trusts this instead of re-checking it itself.
  -- -------------------------------------------------------------------------
  begin
    update orders set pos_connection_id = conn_b where id = order_confirmed; -- cafe_a order, cafe_b connection
    raise exception 'TEST FAILED: an order was linked to another cafe''s POS connection';
  exception
    when others then
      if sqlerrm like '%pos_connection_id must belong to the same cafe%' then
        raise notice 'PASS: an order cannot be linked to another cafe''s POS connection';
      else
        raise;
      end if;
  end;

  -- -------------------------------------------------------------------------
  -- 3. orders_idempotency_key_key: two orders cannot share an idempotency_key
  --    — the backbone of retry-safety (requirement 9).
  -- -------------------------------------------------------------------------
  begin
    insert into orders (cafe_id, status, total, idempotency_key)
      values (cafe_a, 'draft', 5.00, 'idem-confirmed-1'); -- reuses order_confirmed's key
    raise exception 'TEST FAILED: two orders were created with the same idempotency_key';
  exception
    when unique_violation then
      raise notice 'PASS: idempotency_key is unique across orders';
  end;

  raise notice 'ALL PASS: order submission DB-level guarantees hold';
end $$;

rollback;
