-- ============================================================
-- BEAN & BLOOM CAFÉ — menu_items <-> pos_products mapping
-- ============================================================
--
-- Run this AFTER supabase/demo_cafe_square_catalog_sync.sh has completed
-- successfully (menu-square-sync then pos-square-sync) — this needs real
-- pos_products rows to match against. No admin UI creates
-- pos_product_mappings today (PosMappingRepository exists in the Dart app
-- but has no screen wired to it), so this is a one-off SQL auto-match by
-- name instead.
--
-- CORRECTED (confirmed live 2026-09-18, first version only matched 7/23):
-- pos-square-sync names a pos_products row "<item> - <variation>" whenever
-- a Square item has MORE THAN ONE variation (see its own comment: "named
-- '<item> - <variation>' when an item has more than one variation ...
-- and just '<item>' when it has exactly one"). menu-square-sync creates one
-- Square variation per size, literally named after each size's own name —
-- so a plain-name match only ever worked for the 7 items with no `sizes`
-- (single "Regular" variation, no suffix). Every sized item became
-- "<item> - Regular" / "<item> - Large" instead.
--
-- Since pos_product_mappings only allows ONE pos_product per menu_item per
-- connection (unique(menu_item_id, pos_connection_id) — no per-size
-- mapping exists at all), this picks one canonical variation per item,
-- preferring an exact name match, then "<item> - Regular", then any
-- variation as a last resort. Size/price is still handled correctly at
-- order time regardless of which variation is mapped — BaristaVoice always
-- sends its own computed unit_price to Square, never trusting the mapped
-- product's own catalog price (see resolveUnitPrices/computeUnitPrice in
-- create-order/index.ts).
-- ============================================================

with candidates as (
    select
        mi.id as menu_item_id,
        pp.id as pos_product_id,
        pp.pos_connection_id,
        case
            when pp.name = mi.data->>'name' then 0
            when pp.name = (mi.data->>'name') || ' - Regular' then 1
            when pp.name like (mi.data->>'name') || ' - %' then 2
            else 99
        end as match_rank
    from public.menu_items mi
    join public.pos_products pp
        on pp.cafe_id = mi.cafe_id
        and (
            pp.name = mi.data->>'name'
            or pp.name = (mi.data->>'name') || ' - Regular'
            or pp.name like (mi.data->>'name') || ' - %'
        )
    where mi.cafe_id = (select id from public.cafes where slug = 'demo')
      and pp.pos_connection_id = (
          select id from public.pos_connections
          where cafe_id = (select id from public.cafes where slug = 'demo')
            and provider = 'square'
            and status = 'active'
      )
),
best as (
    select distinct on (menu_item_id) menu_item_id, pos_product_id, pos_connection_id
    from candidates
    order by menu_item_id, match_rank asc, pos_product_id
)
insert into public.pos_product_mappings (menu_item_id, pos_connection_id, pos_product_id)
select menu_item_id, pos_connection_id, pos_product_id from best
on conflict (menu_item_id, pos_connection_id) do nothing;


-- ============================================================
-- SANITY CHECK — should be empty. If any rows come back, those menu items
-- didn't have a matching-by-name pos_products row (e.g. menu-square-sync
-- hasn't run yet, or Square altered the name on create) and still need a
-- manual mapping.
-- ============================================================

select mi.id as menu_item_id, mi.data->>'name' as menu_item_name
from public.menu_items mi
where mi.cafe_id = (select id from public.cafes where slug = 'demo')
  and not exists (
      select 1 from public.pos_product_mappings ppm where ppm.menu_item_id = mi.id
  );


-- ============================================================
-- Expect 23 mapped.
-- ============================================================

select count(*) as mapped_count
from public.pos_product_mappings ppm
join public.menu_items mi on mi.id = ppm.menu_item_id
where mi.cafe_id = (select id from public.cafes where slug = 'demo');
