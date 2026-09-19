-- ============================================================
-- BEAN & BLOOM CAFÉ — demo café content seed
-- ============================================================
--
-- One-off script, NOT part of schema.sql's "safe to re-run any number of
-- times" contract — this DELETEs the existing demo café's menu items before
-- inserting the new menu, so re-running it is safe (idempotent for the end
-- state) but it is not meant to be pasted into schema.sql.
--
-- Written against the LIVE schema confirmed via a read-only introspection
-- query on 2026-09-15 (columns/constraints/RLS policies), not against
-- schema.sql, which is known to be stale for cafes/menu_items/orders/
-- pos_connections. Every column name and status/enum value below matches
-- what was actually confirmed live.
--
-- Run this whole file in one go in the Supabase Dashboard's SQL Editor.
-- ============================================================


-- ============================================================
-- STEP 0 — close the open RLS hole on cafes/menu_items/orders
-- ============================================================
--
-- These three policies were found via introspection: command ALL, role
-- public, using (true), with_check (true) — meaning any unauthenticated
-- caller with just the anon key could read/insert/update/delete ANY café's
-- rows in these tables. Every legitimate access path is already covered by
-- the other named policies on each table (public read cafes / public read
-- published menu_items / cafe admin reads own orders) or by service-role
-- Edge Functions, which bypass RLS entirely — so dropping these loses no
-- working functionality.
-- ============================================================

drop policy if exists "public read/write cafes" on public.cafes;
drop policy if exists "public read/write menu_items" on public.menu_items;
drop policy if exists "public read/write orders" on public.orders;


-- ============================================================
-- STEP 1 — rebrand the existing demo café (slug = 'demo')
-- ============================================================

update public.cafes
set
    name = 'Bean & Bloom Café',
    description = 'An independent specialty café serving thoughtfully sourced coffee, tea and matcha alongside a seasonal food menu.',
    address = '14 Wellington Grove, Bristol, BS1 4QP',
    updated_at = now()
where slug = 'demo';


-- ============================================================
-- STEP 2 — clear the old placeholder menu
-- ============================================================
--
-- The 6 existing rows are generic sample items from before the café had a
-- real identity (the café's own old description literally said "sample
-- menu") — replaced wholesale rather than left mixed in with the new menu.
-- ============================================================

delete from public.menu_items
where cafe_id = (select id from public.cafes where slug = 'demo');


-- ============================================================
-- STEP 3 — insert the Bean & Bloom menu (23 items, published + active)
-- ============================================================
--
-- `data` matches app/lib/models/menu.dart's MenuItem.toJson() shape
-- exactly. `status` uses the LIVE menu_items_status_check values
-- ('draft'/'published' — confirmed via introspection, schema.sql's
-- 'draft'/'active'/'archived' is stale and was never actually live).
-- No imageUrl is set for any item — upload real photos afterward through
-- the existing admin Products screen (writes to the public product-images
-- bucket and calls CafeAdminRepository.updateProduct), rather than this
-- script inventing image URLs.
-- ============================================================

insert into public.menu_items (id, cafe_id, status, is_active, data)
select v.id, (select id from public.cafes where slug = 'demo'), 'published', true, v.data
from (values

-- ---------------- COFFEE ----------------

('86912640-9b02-4572-a25d-e3debab6bdf2'::uuid, '{
  "id": "86912640-9b02-4572-a25d-e3debab6bdf2",
  "name": "Espresso",
  "description": "A concentrated shot of our house blend, pulled fresh to order.",
  "category": "Coffee",
  "basePrice": 2.60,
  "popular": false,
  "available": true,
  "sizes": [],
  "milkOptions": [],
  "temperatureOptions": ["hot"],
  "decafAvailable": true,
  "modifiers": [{"name": "Extra shot", "priceDelta": 0.60}],
  "allergens": [],
  "dietaryTags": ["vegan"]
}'::jsonb),

('1743f67e-3cde-417e-9c0d-7b8501fbeead'::uuid, '{
  "id": "1743f67e-3cde-417e-9c0d-7b8501fbeead",
  "name": "Americano",
  "description": "Espresso lengthened with hot water for a smooth, bold black coffee.",
  "category": "Coffee",
  "basePrice": 2.90,
  "popular": false,
  "available": true,
  "sizes": [{"name": "Regular", "priceDelta": 0}, {"name": "Large", "priceDelta": 0.40}],
  "milkOptions": [],
  "temperatureOptions": ["hot"],
  "decafAvailable": true,
  "modifiers": [{"name": "Extra shot", "priceDelta": 0.60}],
  "allergens": [],
  "dietaryTags": ["vegan"]
}'::jsonb),

('6fe5bd47-e1cc-41fc-990c-78e1229c9888'::uuid, '{
  "id": "6fe5bd47-e1cc-41fc-990c-78e1229c9888",
  "name": "Flat White",
  "description": "Espresso with silky steamed milk and a thin layer of microfoam.",
  "category": "Coffee",
  "basePrice": 3.20,
  "popular": true,
  "available": true,
  "sizes": [{"name": "Regular", "priceDelta": 0}, {"name": "Large", "priceDelta": 0.40}],
  "milkOptions": [
    {"name": "Dairy", "priceDelta": 0},
    {"name": "Oat", "priceDelta": 0.50},
    {"name": "Almond", "priceDelta": 0.50},
    {"name": "Soy", "priceDelta": 0.50}
  ],
  "temperatureOptions": ["hot"],
  "decafAvailable": true,
  "modifiers": [
    {"name": "Extra shot", "priceDelta": 0.60},
    {"name": "Vanilla syrup", "priceDelta": 0.50},
    {"name": "Caramel syrup", "priceDelta": 0.50},
    {"name": "Hazelnut syrup", "priceDelta": 0.50}
  ],
  "allergens": ["milk"],
  "dietaryTags": ["vegetarian"]
}'::jsonb),

('c3869c55-0f34-4d00-add5-7d6fa859d8f4'::uuid, '{
  "id": "c3869c55-0f34-4d00-add5-7d6fa859d8f4",
  "name": "Cappuccino",
  "description": "Equal parts espresso, steamed milk and airy foam, dusted with cocoa.",
  "category": "Coffee",
  "basePrice": 3.10,
  "popular": false,
  "available": true,
  "sizes": [{"name": "Regular", "priceDelta": 0}, {"name": "Large", "priceDelta": 0.40}],
  "milkOptions": [
    {"name": "Dairy", "priceDelta": 0},
    {"name": "Oat", "priceDelta": 0.50},
    {"name": "Almond", "priceDelta": 0.50},
    {"name": "Soy", "priceDelta": 0.50}
  ],
  "temperatureOptions": ["hot"],
  "decafAvailable": true,
  "modifiers": [
    {"name": "Extra shot", "priceDelta": 0.60},
    {"name": "Vanilla syrup", "priceDelta": 0.50},
    {"name": "Caramel syrup", "priceDelta": 0.50},
    {"name": "Hazelnut syrup", "priceDelta": 0.50}
  ],
  "allergens": ["milk"],
  "dietaryTags": ["vegetarian"]
}'::jsonb),

('8f872d97-f6e2-4daa-9314-d987c76dbe67'::uuid, '{
  "id": "8f872d97-f6e2-4daa-9314-d987c76dbe67",
  "name": "Latte",
  "description": "Espresso with steamed milk and a light layer of foam.",
  "category": "Coffee",
  "basePrice": 3.30,
  "popular": false,
  "available": true,
  "sizes": [{"name": "Regular", "priceDelta": 0}, {"name": "Large", "priceDelta": 0.40}],
  "milkOptions": [
    {"name": "Dairy", "priceDelta": 0},
    {"name": "Oat", "priceDelta": 0.50},
    {"name": "Almond", "priceDelta": 0.50},
    {"name": "Soy", "priceDelta": 0.50}
  ],
  "temperatureOptions": ["hot"],
  "decafAvailable": true,
  "modifiers": [
    {"name": "Extra shot", "priceDelta": 0.60},
    {"name": "Vanilla syrup", "priceDelta": 0.50},
    {"name": "Caramel syrup", "priceDelta": 0.50},
    {"name": "Hazelnut syrup", "priceDelta": 0.50}
  ],
  "allergens": ["milk"],
  "dietaryTags": ["vegetarian"]
}'::jsonb),

('f2bea4da-67b2-47b3-bf73-c554e4508d53'::uuid, '{
  "id": "f2bea4da-67b2-47b3-bf73-c554e4508d53",
  "name": "Mocha",
  "description": "Espresso, steamed milk and rich chocolate sauce, topped with cream.",
  "category": "Coffee",
  "basePrice": 3.60,
  "popular": false,
  "available": true,
  "sizes": [{"name": "Regular", "priceDelta": 0}, {"name": "Large", "priceDelta": 0.40}],
  "milkOptions": [
    {"name": "Dairy", "priceDelta": 0},
    {"name": "Oat", "priceDelta": 0.50},
    {"name": "Almond", "priceDelta": 0.50},
    {"name": "Soy", "priceDelta": 0.50}
  ],
  "temperatureOptions": ["hot"],
  "decafAvailable": true,
  "modifiers": [
    {"name": "Extra shot", "priceDelta": 0.60},
    {"name": "Hazelnut syrup", "priceDelta": 0.50}
  ],
  "allergens": ["milk"],
  "dietaryTags": ["vegetarian"]
}'::jsonb),

('3f5db89a-9dc9-4e97-a3f9-b865129ed519'::uuid, '{
  "id": "3f5db89a-9dc9-4e97-a3f9-b865129ed519",
  "name": "Caramel Latte",
  "description": "Our latte swirled with buttery caramel sauce.",
  "category": "Coffee",
  "basePrice": 3.70,
  "popular": true,
  "available": true,
  "sizes": [{"name": "Regular", "priceDelta": 0}, {"name": "Large", "priceDelta": 0.40}],
  "milkOptions": [
    {"name": "Dairy", "priceDelta": 0},
    {"name": "Oat", "priceDelta": 0.50},
    {"name": "Almond", "priceDelta": 0.50},
    {"name": "Soy", "priceDelta": 0.50}
  ],
  "temperatureOptions": ["hot"],
  "decafAvailable": true,
  "modifiers": [{"name": "Extra shot", "priceDelta": 0.60}],
  "allergens": ["milk"],
  "dietaryTags": ["vegetarian"]
}'::jsonb),

('3e10abe9-39eb-49c8-97d4-198d1795a2cc'::uuid, '{
  "id": "3e10abe9-39eb-49c8-97d4-198d1795a2cc",
  "name": "Vanilla Latte",
  "description": "Our latte with smooth vanilla syrup stirred through.",
  "category": "Coffee",
  "basePrice": 3.70,
  "popular": false,
  "available": true,
  "sizes": [{"name": "Regular", "priceDelta": 0}, {"name": "Large", "priceDelta": 0.40}],
  "milkOptions": [
    {"name": "Dairy", "priceDelta": 0},
    {"name": "Oat", "priceDelta": 0.50},
    {"name": "Almond", "priceDelta": 0.50},
    {"name": "Soy", "priceDelta": 0.50}
  ],
  "temperatureOptions": ["hot"],
  "decafAvailable": true,
  "modifiers": [{"name": "Extra shot", "priceDelta": 0.60}],
  "allergens": ["milk"],
  "dietaryTags": ["vegetarian"]
}'::jsonb),

-- ---------------- TEA & MATCHA ----------------

('45d83661-07fd-4d25-842f-5e9f32c5cd33'::uuid, '{
  "id": "45d83661-07fd-4d25-842f-5e9f32c5cd33",
  "name": "English Breakfast Tea",
  "description": "A classic, full-bodied black tea blend, brewed to order.",
  "category": "Tea & Matcha",
  "basePrice": 2.70,
  "popular": false,
  "available": true,
  "sizes": [{"name": "Regular", "priceDelta": 0}, {"name": "Large", "priceDelta": 0.30}],
  "milkOptions": [
    {"name": "Dairy", "priceDelta": 0},
    {"name": "Oat", "priceDelta": 0.50},
    {"name": "Almond", "priceDelta": 0.50},
    {"name": "Soy", "priceDelta": 0.50}
  ],
  "temperatureOptions": ["hot"],
  "decafAvailable": false,
  "modifiers": [],
  "allergens": [],
  "dietaryTags": ["vegan"]
}'::jsonb),

('55363d44-80f1-4326-9cde-b42ec09c2365'::uuid, '{
  "id": "55363d44-80f1-4326-9cde-b42ec09c2365",
  "name": "Earl Grey Tea",
  "description": "Black tea infused with fragrant bergamot oil.",
  "category": "Tea & Matcha",
  "basePrice": 2.70,
  "popular": false,
  "available": true,
  "sizes": [{"name": "Regular", "priceDelta": 0}, {"name": "Large", "priceDelta": 0.30}],
  "milkOptions": [
    {"name": "Dairy", "priceDelta": 0},
    {"name": "Oat", "priceDelta": 0.50},
    {"name": "Almond", "priceDelta": 0.50},
    {"name": "Soy", "priceDelta": 0.50}
  ],
  "temperatureOptions": ["hot"],
  "decafAvailable": false,
  "modifiers": [],
  "allergens": [],
  "dietaryTags": ["vegan"]
}'::jsonb),

('f648e5e8-a90c-4b96-953b-65927d0b0d08'::uuid, '{
  "id": "f648e5e8-a90c-4b96-953b-65927d0b0d08",
  "name": "Chai Latte",
  "description": "Spiced black tea, steamed milk and a touch of honey.",
  "category": "Tea & Matcha",
  "basePrice": 3.40,
  "popular": false,
  "available": true,
  "sizes": [{"name": "Regular", "priceDelta": 0}, {"name": "Large", "priceDelta": 0.40}],
  "milkOptions": [
    {"name": "Dairy", "priceDelta": 0},
    {"name": "Oat", "priceDelta": 0.50},
    {"name": "Almond", "priceDelta": 0.50},
    {"name": "Soy", "priceDelta": 0.50}
  ],
  "temperatureOptions": ["hot"],
  "decafAvailable": false,
  "modifiers": [],
  "allergens": ["milk"],
  "dietaryTags": ["vegetarian"]
}'::jsonb),

('744c8b77-ee2c-488b-894d-a82e9f40dbf7'::uuid, '{
  "id": "744c8b77-ee2c-488b-894d-a82e9f40dbf7",
  "name": "Matcha Latte",
  "description": "Ceremonial-grade matcha whisked with steamed milk.",
  "category": "Tea & Matcha",
  "basePrice": 3.80,
  "popular": false,
  "available": true,
  "sizes": [{"name": "Regular", "priceDelta": 0}, {"name": "Large", "priceDelta": 0.40}],
  "milkOptions": [
    {"name": "Dairy", "priceDelta": 0},
    {"name": "Oat", "priceDelta": 0.50},
    {"name": "Almond", "priceDelta": 0.50},
    {"name": "Soy", "priceDelta": 0.50}
  ],
  "temperatureOptions": ["hot"],
  "decafAvailable": false,
  "modifiers": [],
  "allergens": ["milk"],
  "dietaryTags": ["vegetarian"]
}'::jsonb),

('52a5e57f-7f6a-4ccc-bc63-14257319ff08'::uuid, '{
  "id": "52a5e57f-7f6a-4ccc-bc63-14257319ff08",
  "name": "Iced Matcha Latte",
  "description": "Ceremonial-grade matcha shaken with cold milk over ice.",
  "category": "Tea & Matcha",
  "basePrice": 4.10,
  "popular": true,
  "available": true,
  "sizes": [{"name": "Regular", "priceDelta": 0}, {"name": "Large", "priceDelta": 0.40}],
  "milkOptions": [
    {"name": "Dairy", "priceDelta": 0},
    {"name": "Oat", "priceDelta": 0.50},
    {"name": "Almond", "priceDelta": 0.50},
    {"name": "Soy", "priceDelta": 0.50}
  ],
  "temperatureOptions": ["iced"],
  "decafAvailable": false,
  "modifiers": [],
  "allergens": ["milk"],
  "dietaryTags": ["vegetarian"]
}'::jsonb),

-- ---------------- COLD DRINKS ----------------

('5ce7dfb8-c176-4572-9725-defde5ffd81a'::uuid, '{
  "id": "5ce7dfb8-c176-4572-9725-defde5ffd81a",
  "name": "Iced Latte",
  "description": "Espresso and cold milk poured over ice.",
  "category": "Cold Drinks",
  "basePrice": 3.60,
  "popular": false,
  "available": true,
  "sizes": [{"name": "Regular", "priceDelta": 0}, {"name": "Large", "priceDelta": 0.40}],
  "milkOptions": [
    {"name": "Dairy", "priceDelta": 0},
    {"name": "Oat", "priceDelta": 0.50},
    {"name": "Almond", "priceDelta": 0.50},
    {"name": "Soy", "priceDelta": 0.50}
  ],
  "temperatureOptions": ["iced"],
  "decafAvailable": true,
  "modifiers": [
    {"name": "Extra shot", "priceDelta": 0.60},
    {"name": "Vanilla syrup", "priceDelta": 0.50},
    {"name": "Caramel syrup", "priceDelta": 0.50}
  ],
  "allergens": ["milk"],
  "dietaryTags": ["vegetarian"]
}'::jsonb),

('7db94a34-3125-45d5-823b-6a7ca9aad574'::uuid, '{
  "id": "7db94a34-3125-45d5-823b-6a7ca9aad574",
  "name": "Iced Americano",
  "description": "Espresso and cold water over ice for a crisp, refreshing black coffee.",
  "category": "Cold Drinks",
  "basePrice": 3.20,
  "popular": false,
  "available": true,
  "sizes": [{"name": "Regular", "priceDelta": 0}, {"name": "Large", "priceDelta": 0.40}],
  "milkOptions": [],
  "temperatureOptions": ["iced"],
  "decafAvailable": true,
  "modifiers": [{"name": "Extra shot", "priceDelta": 0.60}],
  "allergens": [],
  "dietaryTags": ["vegan"]
}'::jsonb),

('1da0b12e-7ca6-4340-bcd7-bf215b1cc092'::uuid, '{
  "id": "1da0b12e-7ca6-4340-bcd7-bf215b1cc092",
  "name": "Strawberry Lemonade",
  "description": "Fresh strawberry purée with sparkling lemonade over ice.",
  "category": "Cold Drinks",
  "basePrice": 3.90,
  "popular": false,
  "available": true,
  "sizes": [{"name": "Regular", "priceDelta": 0}, {"name": "Large", "priceDelta": 0.40}],
  "milkOptions": [],
  "temperatureOptions": ["iced"],
  "decafAvailable": false,
  "modifiers": [],
  "allergens": [],
  "dietaryTags": ["vegan"]
}'::jsonb),

('66defba1-c6c3-4fcb-b349-ded8a977b8f9'::uuid, '{
  "id": "66defba1-c6c3-4fcb-b349-ded8a977b8f9",
  "name": "Sparkling Peach Iced Tea",
  "description": "Black tea, white peach and soda over ice.",
  "category": "Cold Drinks",
  "basePrice": 3.90,
  "popular": false,
  "available": true,
  "sizes": [{"name": "Regular", "priceDelta": 0}, {"name": "Large", "priceDelta": 0.40}],
  "milkOptions": [],
  "temperatureOptions": ["iced"],
  "decafAvailable": false,
  "modifiers": [],
  "allergens": [],
  "dietaryTags": ["vegan"]
}'::jsonb),

-- ---------------- FOOD ----------------

('e7744d94-8c9b-4871-8b8e-cbef26b5bf24'::uuid, '{
  "id": "e7744d94-8c9b-4871-8b8e-cbef26b5bf24",
  "name": "Butter Croissant",
  "description": "All-butter, flaky croissant baked fresh each morning.",
  "category": "Food",
  "basePrice": 3.20,
  "popular": true,
  "available": true,
  "sizes": [],
  "milkOptions": [],
  "temperatureOptions": [],
  "decafAvailable": false,
  "modifiers": [],
  "allergens": ["gluten", "milk", "egg"],
  "dietaryTags": ["vegetarian"]
}'::jsonb),

('eb8126e1-04ac-495f-a6ae-6da462b43ecc'::uuid, '{
  "id": "eb8126e1-04ac-495f-a6ae-6da462b43ecc",
  "name": "Pain au Chocolat",
  "description": "Buttery laminated pastry filled with dark chocolate batons.",
  "category": "Food",
  "basePrice": 3.40,
  "popular": false,
  "available": true,
  "sizes": [],
  "milkOptions": [],
  "temperatureOptions": [],
  "decafAvailable": false,
  "modifiers": [],
  "allergens": ["gluten", "milk", "egg"],
  "dietaryTags": ["vegetarian"]
}'::jsonb),

('14a3c6e0-533b-4ee2-81f4-79d4a6417c2c'::uuid, '{
  "id": "14a3c6e0-533b-4ee2-81f4-79d4a6417c2c",
  "name": "Blueberry Muffin",
  "description": "A moist muffin studded with plump blueberries.",
  "category": "Food",
  "basePrice": 3.10,
  "popular": false,
  "available": true,
  "sizes": [],
  "milkOptions": [],
  "temperatureOptions": [],
  "decafAvailable": false,
  "modifiers": [],
  "allergens": ["gluten", "milk", "egg"],
  "dietaryTags": ["vegetarian"]
}'::jsonb),

('5b4f003a-f72d-4872-97b8-6175bf0f4456'::uuid, '{
  "id": "5b4f003a-f72d-4872-97b8-6175bf0f4456",
  "name": "Avocado & Feta Toast",
  "description": "Smashed avocado, whipped feta and chilli flakes on sourdough.",
  "category": "Food",
  "basePrice": 6.50,
  "popular": true,
  "available": true,
  "sizes": [],
  "milkOptions": [],
  "temperatureOptions": [],
  "decafAvailable": false,
  "modifiers": [
    {"name": "Add egg", "priceDelta": 1.00},
    {"name": "Add bacon", "priceDelta": 1.50}
  ],
  "allergens": ["gluten", "milk"],
  "dietaryTags": ["vegetarian"]
}'::jsonb),

('519db25b-aff7-46ff-8329-3a55cdfc3623'::uuid, '{
  "id": "519db25b-aff7-46ff-8329-3a55cdfc3623",
  "name": "Bacon & Egg Brioche",
  "description": "Smoked bacon and a fried egg in a toasted brioche bun.",
  "category": "Food",
  "basePrice": 5.90,
  "popular": false,
  "available": true,
  "sizes": [],
  "milkOptions": [],
  "temperatureOptions": [],
  "decafAvailable": false,
  "modifiers": [],
  "allergens": ["gluten", "egg"],
  "dietaryTags": []
}'::jsonb),

('571a6721-0c30-4340-976e-95a116f79cc4'::uuid, '{
  "id": "571a6721-0c30-4340-976e-95a116f79cc4",
  "name": "Grilled Cheese Sandwich",
  "description": "Melted mature cheddar in toasted sourdough.",
  "category": "Food",
  "basePrice": 5.20,
  "popular": false,
  "available": true,
  "sizes": [],
  "milkOptions": [],
  "temperatureOptions": [],
  "decafAvailable": false,
  "modifiers": [
    {"name": "Add cheese", "priceDelta": 0.80},
    {"name": "Add bacon", "priceDelta": 1.50}
  ],
  "allergens": ["gluten", "milk"],
  "dietaryTags": ["vegetarian"]
}'::jsonb)

) as v(id, data);


-- ============================================================
-- STEP 4 — sanity check
-- ============================================================

select count(*) as bean_and_bloom_item_count
from public.menu_items
where cafe_id = (select id from public.cafes where slug = 'demo')
  and status = 'published';
-- expect 23
