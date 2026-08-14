-- BaristaVoice schema.
--
-- Kept intentionally simple: one row per cafe, menu items as flexible jsonb
-- for sizes/milk/modifiers (matches the Dart MenuItem model exactly), and
-- orders/order_items as the staff dashboard's source of truth.
--
-- Run this in the Supabase SQL editor (or `supabase db push`) — safe to
-- re-run on a project that already has an earlier version of this schema
-- (uses IF NOT EXISTS / IF EXISTS guards throughout).

create extension if not exists "uuid-ossp";

create table if not exists cafes (
  id uuid primary key default uuid_generate_v4(),
  name text not null,
  created_at timestamptz not null default now()
);

-- Public café-facing details (QR/deep-link header, admin's "Your Café QR
-- Code" section). `slug` is optional — real cafés are addressed by their
-- `id` (what the QR/deep link actually encodes); only the demo café uses a
-- human-friendly slug ('demo') so /cafe/demo is easy to type by hand.
alter table cafes add column if not exists logo_url text;
alter table cafes add column if not exists description text;
alter table cafes add column if not exists address text;
alter table cafes add column if not exists slug text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'cafes_slug_key') then
    alter table cafes add constraint cafes_slug_key unique (slug);
  end if;
end $$;

-- One row per authenticated Supabase Auth user. Created either by the
-- create_cafe_admin_account() RPC (cafe_admin signup) or manually in the SQL
-- editor for a super_admin. There is no self-serve customer signup today —
-- the kiosk app doesn't authenticate customers — so this table only ever
-- holds cafe_admin / super_admin rows in practice, but `customer` exists as
-- the safe default role.
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'customer' check (role in ('customer', 'cafe_admin', 'super_admin')),
  cafe_id uuid references cafes(id) on delete set null,
  display_name text,
  created_at timestamptz not null default now()
);

-- One row per uploaded menu source file/text, tracked through ingestion.
create table if not exists menu_uploads (
  id uuid primary key default uuid_generate_v4(),
  cafe_id uuid not null references cafes(id) on delete cascade,
  source_type text not null check (source_type in ('pdf', 'image', 'text', 'url')),
  source_ref text, -- storage path or URL
  raw_text text, -- extracted text before structuring
  status text not null default 'pending' check (status in ('pending', 'structured', 'failed')),
  created_at timestamptz not null default now()
);

-- The owner-reviewed structured menu. `data` mirrors the Dart
-- MenuItem.toJson() shape exactly (now including imageUrl/available) so the
-- app can read it with no mapping layer beyond CafeMenu/MenuItem.fromJson.
-- `status` replaces the old `is_active` boolean: AI-extracted rows land as
-- 'draft' and only become visible to customers once the cafe_admin
-- publishes them.
create table if not exists menu_items (
  id uuid primary key default uuid_generate_v4(),
  cafe_id uuid not null references cafes(id) on delete cascade,
  data jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table menu_items add column if not exists menu_upload_id uuid references menu_uploads(id) on delete set null;
alter table menu_items add column if not exists status text;

do $$
begin
  if exists (select 1 from information_schema.columns where table_name = 'menu_items' and column_name = 'is_active') then
    update menu_items set status = case when is_active then 'published' else 'draft' end where status is null;
    alter table menu_items drop column is_active;
  end if;
end $$;

update menu_items set status = 'draft' where status is null;
alter table menu_items alter column status set default 'draft';
alter table menu_items alter column status set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'menu_items_status_check'
  ) then
    alter table menu_items add constraint menu_items_status_check check (status in ('draft', 'published'));
  end if;
end $$;

create index if not exists idx_menu_items_cafe_status on menu_items (cafe_id, status);

create table if not exists orders (
  id uuid primary key default uuid_generate_v4(),
  cafe_id uuid not null references cafes(id) on delete cascade,
  order_number serial,
  status text not null default 'new' check (status in ('new', 'preparing', 'ready', 'completed')),
  total numeric(10, 2) not null,
  created_at timestamptz not null default now()
);

create table if not exists order_items (
  id uuid primary key default uuid_generate_v4(),
  order_id uuid not null references orders(id) on delete cascade,
  menu_item_id uuid references menu_items(id),
  name text not null,
  quantity integer not null default 1,
  size text,
  milk text,
  temperature text,
  decaf boolean not null default false,
  modifiers text[] not null default '{}',
  unit_price numeric(10, 2) not null,
  line_total numeric(10, 2) not null
);

-- Realtime for the staff dashboard.
alter publication supabase_realtime add table orders;
alter publication supabase_realtime add table order_items;

-- ---------------------------------------------------------------------------
-- Auth helpers
--
-- SECURITY DEFINER so they can read `profiles` regardless of the caller's
-- RLS grants (avoids recursive-policy issues), but they only ever return the
-- CALLER's own role/cafe_id (derived from auth.uid()) — never a value the
-- client supplies. All RLS policies below key off these, never off a
-- client-provided cafe_id.
-- ---------------------------------------------------------------------------

create or replace function public.current_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles where id = auth.uid();
$$;

create or replace function public.current_cafe_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select cafe_id from public.profiles where id = auth.uid();
$$;

-- Self-serve cafe_admin signup. Role is hardcoded, cafe_id is generated
-- server-side from a brand-new cafe row, and the profile id is forced to
-- auth.uid() — a client can never pass in a role or an existing cafe_id.
create or replace function public.create_cafe_admin_account(cafe_name text)
returns table (cafe_id uuid, role text)
language plpgsql
security definer
set search_path = public
as $$
declare
  new_cafe_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if exists (select 1 from public.profiles where id = auth.uid()) then
    raise exception 'A profile already exists for this account';
  end if;

  if coalesce(trim(cafe_name), '') = '' then
    raise exception 'Cafe name is required';
  end if;

  insert into public.cafes (name) values (trim(cafe_name)) returning id into new_cafe_id;

  insert into public.profiles (id, role, cafe_id, display_name)
  values (auth.uid(), 'cafe_admin', new_cafe_id, trim(cafe_name));

  return query select new_cafe_id, 'cafe_admin'::text;
end;
$$;

grant execute on function public.create_cafe_admin_account(text) to authenticated;

-- Keeps a non-super_admin from escalating their own role or reassigning
-- themselves to a different cafe via a direct profile update.
create or replace function public.protect_profile_privileges()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.current_role() <> 'super_admin' then
    new.role := old.role;
    new.cafe_id := old.cafe_id;
  end if;
  return new;
end;
$$;

drop trigger if exists protect_profile_privileges on profiles;
create trigger protect_profile_privileges
  before update on profiles
  for each row execute function public.protect_profile_privileges();

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------

alter table profiles enable row level security;
alter table cafes enable row level security;
alter table menu_uploads enable row level security;
alter table menu_items enable row level security;
alter table orders enable row level security;
alter table order_items enable row level security;

-- profiles: everyone can read their own row; super_admin can read/update all.
drop policy if exists "read own profile" on profiles;
create policy "read own profile" on profiles for select using (id = auth.uid());

drop policy if exists "super admin reads all profiles" on profiles;
create policy "super admin reads all profiles" on profiles for select using (public.current_role() = 'super_admin');

drop policy if exists "update own profile" on profiles;
create policy "update own profile" on profiles for update
  using (id = auth.uid() or public.current_role() = 'super_admin')
  with check (id = auth.uid() or public.current_role() = 'super_admin');

-- cafes: name/basic info is public (the kiosk app needs to read its own
-- cafe's name with the anon key); only the owning cafe_admin or a
-- super_admin can change it.
drop policy if exists "public read/write cafes" on cafes;
drop policy if exists "public read cafes" on cafes;
create policy "public read cafes" on cafes for select using (true);

drop policy if exists "cafe admin updates own cafe" on cafes;
create policy "cafe admin updates own cafe" on cafes for update
  using (public.current_role() = 'super_admin' or (public.current_role() = 'cafe_admin' and id = public.current_cafe_id()))
  with check (public.current_role() = 'super_admin' or (public.current_role() = 'cafe_admin' and id = public.current_cafe_id()));

drop policy if exists "super admin inserts cafes" on cafes;
create policy "super admin inserts cafes" on cafes for insert
  with check (public.current_role() = 'super_admin');

drop policy if exists "super admin deletes cafes" on cafes;
create policy "super admin deletes cafes" on cafes for delete
  using (public.current_role() = 'super_admin');

-- menu_uploads: cafe_admin/super_admin only, strictly scoped to their own
-- cafe_id. No public access — customers never see raw uploads.
drop policy if exists "public read/write menu_uploads" on menu_uploads;
drop policy if exists "cafe admin manages own menu_uploads" on menu_uploads;
create policy "cafe admin manages own menu_uploads" on menu_uploads for all
  using (public.current_role() = 'super_admin' or (public.current_role() = 'cafe_admin' and cafe_id = public.current_cafe_id()))
  with check (public.current_role() = 'super_admin' or (public.current_role() = 'cafe_admin' and cafe_id = public.current_cafe_id()));

-- menu_items: anyone (including anon customers) can read PUBLISHED items.
-- cafe_admin can read/write ALL of their own cafe's items (draft +
-- published); super_admin can read/write everything. cafe_id is always
-- checked against current_cafe_id(), never trusted from the client.
drop policy if exists "public read/write menu_items" on menu_items;

drop policy if exists "public read published menu_items" on menu_items;
create policy "public read published menu_items" on menu_items for select
  using (status = 'published');

drop policy if exists "cafe admin reads own menu_items" on menu_items;
create policy "cafe admin reads own menu_items" on menu_items for select
  using (public.current_role() = 'super_admin' or (public.current_role() = 'cafe_admin' and cafe_id = public.current_cafe_id()));

drop policy if exists "cafe admin writes own menu_items" on menu_items;
create policy "cafe admin writes own menu_items" on menu_items for insert
  with check (public.current_role() = 'super_admin' or (public.current_role() = 'cafe_admin' and cafe_id = public.current_cafe_id()));

drop policy if exists "cafe admin updates own menu_items" on menu_items;
create policy "cafe admin updates own menu_items" on menu_items for update
  using (public.current_role() = 'super_admin' or (public.current_role() = 'cafe_admin' and cafe_id = public.current_cafe_id()))
  with check (public.current_role() = 'super_admin' or (public.current_role() = 'cafe_admin' and cafe_id = public.current_cafe_id()));

drop policy if exists "cafe admin deletes own menu_items" on menu_items;
create policy "cafe admin deletes own menu_items" on menu_items for delete
  using (public.current_role() = 'super_admin' or (public.current_role() = 'cafe_admin' and cafe_id = public.current_cafe_id()));

-- orders / order_items: unchanged from the original MVP-permissive policies.
-- Not part of the cafe admin dashboard scope — tighten separately when the
-- staff order dashboard is built.
drop policy if exists "public read/write orders" on orders;
create policy "public read/write orders" on orders for all using (true) with check (true);

drop policy if exists "public read/write order_items" on order_items;
create policy "public read/write order_items" on order_items for all using (true) with check (true);

-- ---------------------------------------------------------------------------
-- Storage: product images (public bucket) and raw menu uploads (private).
-- Object paths are always `<cafe_id>/<filename>` — policies check that first
-- path segment against current_cafe_id(), never against a client-supplied
-- value in the request body.
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public)
values ('product-images', 'product-images', true)
on conflict (id) do nothing;

insert into storage.buckets (id, name, public)
values ('menu-uploads', 'menu-uploads', false)
on conflict (id) do nothing;

drop policy if exists "public read product images" on storage.objects;
create policy "public read product images" on storage.objects for select
  using (bucket_id = 'product-images');

drop policy if exists "cafe admin writes own product images" on storage.objects;
create policy "cafe admin writes own product images" on storage.objects for insert
  with check (
    bucket_id = 'product-images'
    and (public.current_role() = 'super_admin' or (public.current_role() = 'cafe_admin' and (storage.foldername(name))[1] = public.current_cafe_id()::text))
  );

drop policy if exists "cafe admin updates own product images" on storage.objects;
create policy "cafe admin updates own product images" on storage.objects for update
  using (
    bucket_id = 'product-images'
    and (public.current_role() = 'super_admin' or (public.current_role() = 'cafe_admin' and (storage.foldername(name))[1] = public.current_cafe_id()::text))
  );

drop policy if exists "cafe admin deletes own product images" on storage.objects;
create policy "cafe admin deletes own product images" on storage.objects for delete
  using (
    bucket_id = 'product-images'
    and (public.current_role() = 'super_admin' or (public.current_role() = 'cafe_admin' and (storage.foldername(name))[1] = public.current_cafe_id()::text))
  );

drop policy if exists "cafe admin manages own menu upload files" on storage.objects;
create policy "cafe admin manages own menu upload files" on storage.objects for all
  using (
    bucket_id = 'menu-uploads'
    and (public.current_role() = 'super_admin' or (public.current_role() = 'cafe_admin' and (storage.foldername(name))[1] = public.current_cafe_id()::text))
  )
  with check (
    bucket_id = 'menu-uploads'
    and (public.current_role() = 'super_admin' or (public.current_role() = 'cafe_admin' and (storage.foldername(name))[1] = public.current_cafe_id()::text))
  );

-- ---------------------------------------------------------------------------
-- Demo café: a REAL published café reachable at /cafe/demo exactly like any
-- other café's /cafe/{id} — there is no separate hardcoded "default menu"
-- code path anywhere in the app. Idempotent: only seeds menu_items the first
-- time (won't duplicate rows or clobber owner edits on re-run).
-- ---------------------------------------------------------------------------

insert into cafes (name, slug, description)
values ('Demo Café', 'demo', 'Try the AI ordering assistant with a sample menu.')
on conflict (slug) do nothing;

do $$
declare
  demo_cafe_id uuid;
begin
  select id into demo_cafe_id from cafes where slug = 'demo';

  if demo_cafe_id is not null and not exists (select 1 from menu_items where cafe_id = demo_cafe_id) then
    insert into menu_items (cafe_id, status, data) values
      (demo_cafe_id, 'published', '{"id":"latte","name":"Latte","description":"Espresso with steamed milk and a thin layer of foam.","category":"Espresso Drinks","basePrice":4.25,"popular":true,"available":true,"imageUrl":null,"sizes":[{"name":"Small","priceDelta":0},{"name":"Medium","priceDelta":0.5},{"name":"Large","priceDelta":1.0}],"milkOptions":[{"name":"Whole","priceDelta":0},{"name":"Oat","priceDelta":0.6},{"name":"Almond","priceDelta":0.6},{"name":"Skim","priceDelta":0}],"temperatureOptions":["hot","iced"],"decafAvailable":true,"modifiers":[{"name":"Extra Shot","priceDelta":0.75},{"name":"Vanilla Syrup","priceDelta":0.5}],"allergens":[],"dietaryTags":[]}'::jsonb),
      (demo_cafe_id, 'published', '{"id":"cold_brew","name":"Cold Brew","description":"Slow-steeped for 18 hours, smooth and naturally low-acid. Not too sweet.","category":"Cold Drinks","basePrice":4.0,"popular":true,"available":true,"imageUrl":null,"sizes":[{"name":"Medium","priceDelta":0},{"name":"Large","priceDelta":0.75}],"milkOptions":[{"name":"None","priceDelta":0},{"name":"Whole","priceDelta":0},{"name":"Oat","priceDelta":0.6}],"temperatureOptions":["iced"],"decafAvailable":false,"modifiers":[{"name":"Vanilla Syrup","priceDelta":0.5}],"allergens":[],"dietaryTags":["dairy-free option"]}'::jsonb),
      (demo_cafe_id, 'published', '{"id":"cappuccino","name":"Cappuccino","description":"Equal parts espresso, steamed milk, and thick milk foam.","category":"Espresso Drinks","basePrice":4.0,"popular":false,"available":true,"imageUrl":null,"sizes":[{"name":"Small","priceDelta":0},{"name":"Medium","priceDelta":0.5},{"name":"Large","priceDelta":1.0}],"milkOptions":[{"name":"Whole","priceDelta":0},{"name":"Oat","priceDelta":0.6}],"temperatureOptions":["hot"],"decafAvailable":true,"modifiers":[{"name":"Extra Shot","priceDelta":0.75}],"allergens":[],"dietaryTags":[]}'::jsonb),
      (demo_cafe_id, 'published', '{"id":"chai_latte","name":"Chai Latte","description":"Spiced black tea concentrate with steamed milk.","category":"Tea","basePrice":4.25,"popular":false,"available":true,"imageUrl":null,"sizes":[{"name":"Small","priceDelta":0},{"name":"Medium","priceDelta":0.5},{"name":"Large","priceDelta":1.0}],"milkOptions":[{"name":"Whole","priceDelta":0},{"name":"Oat","priceDelta":0.6}],"temperatureOptions":["hot","iced"],"decafAvailable":false,"modifiers":[],"allergens":[],"dietaryTags":[]}'::jsonb),
      (demo_cafe_id, 'published', '{"id":"chocolate_croissant","name":"Chocolate Croissant","description":"Buttery, flaky croissant filled with dark chocolate.","category":"Bakery","basePrice":3.75,"popular":false,"available":true,"imageUrl":null,"sizes":[],"milkOptions":[],"temperatureOptions":[],"decafAvailable":false,"modifiers":[],"allergens":["gluten","dairy","egg"],"dietaryTags":["vegetarian"]}'::jsonb),
      (demo_cafe_id, 'published', '{"id":"blueberry_muffin","name":"Blueberry Muffin","description":"Moist muffin loaded with blueberries.","category":"Bakery","basePrice":3.5,"popular":false,"available":true,"imageUrl":null,"sizes":[],"milkOptions":[],"temperatureOptions":[],"decafAvailable":false,"modifiers":[],"allergens":["gluten","dairy","egg"],"dietaryTags":["vegetarian"]}'::jsonb);
  end if;
end $$;

-- To create a super_admin: sign a user up normally via Supabase Auth (or the
-- dashboard), then run:
--   insert into profiles (id, role) values ('<auth-user-uuid>', 'super_admin')
--   on conflict (id) do update set role = 'super_admin';
