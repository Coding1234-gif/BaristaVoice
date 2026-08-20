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

-- Realtime for the staff dashboard. Guarded (unlike a bare `alter
-- publication ... add table`, which errors on a second run once the table
-- is already a member) so this file stays safe to re-run in full, per the
-- header comment above.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'orders'
  ) then
    alter publication supabase_realtime add table orders;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'order_items'
  ) then
    alter publication supabase_realtime add table order_items;
  end if;
end $$;

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

-- =============================================================================
-- POS INTEGRATION LAYER — multi-provider POS support (Square, Lightspeed,
-- Epos Now, SumUp, Clover, Toast, Zettle, ...).
--
-- Core principle: BaristaVoice owns a POS-independent "universal order"
-- model (orders / order_items / order_item_modifiers), built on top of the
-- existing `menu_items` canonical menu above — the same table the AI
-- (order-agent) already treats as the only source of truth for what can be
-- ordered. A café's imported POS catalog (pos_products / pos_modifiers) and
-- the mapping from a canonical menu item to a specific POS's product
-- (pos_product_mappings) are the only POS-shaped data in the system.
-- Nothing about the AI, the order model, or the kiosk app needs to know
-- which POS (if any) a café uses. Adding a new provider later means adding
-- an adapter — an Edge Function that reads a pos_connections row plus
-- pos_product_mappings and calls that provider's API — not redesigning
-- this schema.
--
-- Idempotent / safe to re-run, matching the rest of this file's convention.
-- =============================================================================

-- gen_random_uuid() has been part of Postgres core since v13 (every
-- supported Supabase project), so this is a defensive no-op, not a real
-- dependency. New tables below use gen_random_uuid() rather than this
-- file's existing uuid_generate_v4() (uuid-ossp) purely because it needs no
-- extension at all on current Postgres — existing tables are left as-is,
-- there's no reason to churn a working default.
create extension if not exists pgcrypto;

-- Supabase Vault (for POS OAuth credential storage, see pos_connections
-- below) ships enabled by default on hosted Supabase projects. This is
-- wrapped so the migration doesn't hard-fail on an environment where it's
-- already enabled a different way, or unavailable (e.g. some self-hosted
-- setups) — the pos_connections columns below are plain uuid columns
-- either way; only the *use* of Vault to fill them requires the extension.
do $$
begin
  create extension if not exists supabase_vault with schema vault;
exception when others then
  raise notice 'supabase_vault extension not available/creatable in this environment — expected on hosted Supabase. If Vault is already enabled a different way this is safe to ignore; otherwise see the POS credential security notes below for the fallback.';
end $$;

-- ---------------------------------------------------------------------------
-- Reusable updated_at trigger. Tables above (menu_items etc.) set
-- updated_at's *default* on insert but nothing previously kept it current
-- on UPDATE — every table below uses this instead of trusting the client.
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- cafes was missing updated_at entirely; add it now for parity with every
-- other table in this file (additive, safe on an existing table).
alter table cafes add column if not exists updated_at timestamptz not null default now();

drop trigger if exists set_cafes_updated_at on cafes;
create trigger set_cafes_updated_at
  before update on cafes
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- RLS helper: café-scoped admin check, reused by every policy below.
--
-- Deliberately reuses the existing cafe_admin/super_admin + current_cafe_id()
-- membership model (used above by cafes/menu_items/menu_uploads) instead of
-- introducing a second, parallel `cafe_members` table. The app's current
-- membership model is one profile (role + cafe_id) per user — sufficient to
-- establish café isolation, which is all this layer needs. Two competing
-- authorization systems on the same database would be a bigger security
-- risk than the one this task is trying to close (they could drift out of
-- sync). If/when BaristaVoice grows a multi-staff-per-café invite flow,
-- that's the point to introduce cafe_members (owner/manager/staff) and
-- migrate ALL tables to it in one dedicated migration — not just these.
-- ---------------------------------------------------------------------------
create or replace function public.can_manage_cafe(target_cafe_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.current_role() = 'super_admin'
      or (public.current_role() = 'cafe_admin' and public.current_cafe_id() = target_cafe_id);
$$;

comment on function public.can_manage_cafe(uuid) is
  'True if the caller is super_admin, or is the cafe_admin of target_cafe_id. Central RLS check for the POS layer — keeps café-isolation logic in one place instead of duplicated per policy.';

-- Shared by pos_products/pos_modifiers below: forces cafe_id to always
-- match the row's pos_connection_id, regardless of what a caller supplies.
-- Makes cafe_id effectively a trusted, server-derived cache column rather
-- than client-asserted data — a client (or buggy server code) cannot make
-- a POS product/modifier appear to belong to the wrong café.
create or replace function public.derive_pos_row_cafe_id()
returns trigger
language plpgsql
as $$
begin
  select cafe_id into new.cafe_id from pos_connections where id = new.pos_connection_id;
  if new.cafe_id is null then
    raise exception 'pos_connection_id % does not reference an existing pos_connections row', new.pos_connection_id;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- pos_connections — one row per café-to-POS-location link.
--
-- CREDENTIAL SECURITY (read this before wiring up OAuth):
-- This table NEVER stores a raw access_token or refresh_token. A
-- service-role Edge Function writes OAuth secrets to Supabase Vault
-- (`select vault.create_secret(token, 'label')`) and stores only the
-- returned secret UUID here, in access_token_secret_id/refresh_token_secret_id.
-- Reading the actual token back requires querying `vault.decrypted_secrets`,
-- which is only reachable with the service_role key — the Flutter client
-- never holds that key and never talks to the vault schema.
--
-- Even so, the two secret-id columns are ALSO locked down below with
-- column-level REVOKE/GRANT so `authenticated` cannot SELECT them at all.
-- This matters because RLS is row-level, not column-level: an RLS policy
-- that lets a cafe_admin read "their" pos_connections row would otherwise
-- still let them read every column in it, including a secret UUID that a
-- future bug elsewhere might make more useful than it should be. Defense
-- in depth, not reliance on Vault alone.
-- ---------------------------------------------------------------------------
create table if not exists pos_connections (
  id uuid primary key default gen_random_uuid(),
  cafe_id uuid not null references cafes(id) on delete cascade,
  provider text not null check (provider in (
    'square', 'lightspeed', 'epos_now', 'sumup', 'clover', 'toast', 'zettle', 'other'
  )),
  location_id text,
  status text not null default 'pending' check (status in ('pending', 'active', 'error', 'disconnected')),
  access_token_secret_id uuid,
  refresh_token_secret_id uuid,
  token_expires_at timestamptz,
  last_synced_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table pos_connections is
  'A café''s link to one external POS location. Never holds raw OAuth tokens — see column comments and the RLS/grants section below.';
comment on column pos_connections.access_token_secret_id is
  'References a Supabase Vault secret (vault.secrets.id) holding the real token. Written only by service-role (Edge Function) code — never by the Flutter client.';
comment on column pos_connections.refresh_token_secret_id is
  'References a Supabase Vault secret (vault.secrets.id) holding the real token. Written only by service-role (Edge Function) code — never by the Flutter client.';
comment on column pos_connections.provider is
  'Constrained via CHECK rather than a native Postgres enum: adding a new provider later is a single-statement ALTER TABLE ... DROP/ADD CONSTRAINT (one migration, one transaction) instead of the two-step, cross-transaction dance ALTER TYPE ... ADD VALUE requires. ''other'' is a deliberate escape hatch so a brand-new provider can be onboarded before it has a formal name here.';

-- A café can have multiple POS connections (e.g. two Square locations), but
-- not two rows for the exact same location.
create unique index if not exists pos_connections_cafe_provider_location_key
  on pos_connections (cafe_id, provider, location_id)
  where location_id is not null;

create index if not exists idx_pos_connections_cafe_id on pos_connections (cafe_id);

drop trigger if exists set_pos_connections_updated_at on pos_connections;
create trigger set_pos_connections_updated_at
  before update on pos_connections
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- pos_products — a café's product catalog as imported from one POS
-- connection. This is a read-mostly mirror kept fresh by periodic sync, not
-- something a cafe_admin edits directly (see EXTERNAL POS SYNCHRONISATION
-- fields below: active / last_synced_at / external_updated_at).
-- ---------------------------------------------------------------------------
create table if not exists pos_products (
  id uuid primary key default gen_random_uuid(),
  cafe_id uuid not null references cafes(id) on delete cascade,
  pos_connection_id uuid not null references pos_connections(id) on delete cascade,
  external_product_id text not null,
  name text not null,
  category text,
  price numeric(12, 2),
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  external_updated_at timestamptz,
  last_synced_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table pos_products is
  'Cached mirror of one POS connection''s product catalog. price/category/metadata are as reported by the POS, not authoritative for an already-placed order — see order_items.name/unit_price for the historical snapshot.';

-- The same external product must not be imported twice for one connection.
create unique index if not exists pos_products_connection_external_id_key
  on pos_products (pos_connection_id, external_product_id);

create index if not exists idx_pos_products_cafe_id on pos_products (cafe_id);

drop trigger if exists derive_pos_products_cafe_id on pos_products;
create trigger derive_pos_products_cafe_id
  before insert or update of pos_connection_id on pos_products
  for each row execute function public.derive_pos_row_cafe_id();

drop trigger if exists set_pos_products_updated_at on pos_products;
create trigger set_pos_products_updated_at
  before update on pos_products
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- pos_modifiers — a café's modifier catalog as imported from one POS
-- connection. Scoped to pos_connection_id (not cafe-global and not tied to
-- a specific pos_product) because the same external modifier id can exist
-- under different meanings in different POS systems, and because most POS
-- APIs expose modifiers as a flat catalog rather than nested under a
-- product. Associating specific modifiers with specific products is a real
-- future need but not required for the initial database foundation —
-- flagged here rather than built now.
-- ---------------------------------------------------------------------------
create table if not exists pos_modifiers (
  id uuid primary key default gen_random_uuid(),
  cafe_id uuid not null references cafes(id) on delete cascade,
  pos_connection_id uuid not null references pos_connections(id) on delete cascade,
  external_modifier_id text not null,
  name text not null,
  price_adjustment numeric(12, 2) not null default 0,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  external_updated_at timestamptz,
  last_synced_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists pos_modifiers_connection_external_id_key
  on pos_modifiers (pos_connection_id, external_modifier_id);

create index if not exists idx_pos_modifiers_cafe_id on pos_modifiers (cafe_id);

drop trigger if exists derive_pos_modifiers_cafe_id on pos_modifiers;
create trigger derive_pos_modifiers_cafe_id
  before insert or update of pos_connection_id on pos_modifiers
  for each row execute function public.derive_pos_row_cafe_id();

drop trigger if exists set_pos_modifiers_updated_at on pos_modifiers;
create trigger set_pos_modifiers_updated_at
  before update on pos_modifiers
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- pos_product_mappings — the missing link between BaristaVoice's own
-- canonical menu and a specific POS connection's product.
--
-- menu_items (above) is already the AI-facing source of truth: order-agent
-- fetches it server-side and constrains the model to it by id. Without this
-- table, actually sending an order to a POS would require the AI/kiosk to
-- know which POS a café uses and what its product ids are — exactly what
-- the Universal Order Model -> POS Adapter architecture exists to avoid.
-- With it: the AI only ever deals in menu_items ids; a POS adapter resolves
-- menu_item_id -> pos_product_id (per café + connection) at send-time, by
-- looking here. Introducing a *new* "canonical menu_items" table was
-- explicitly considered and rejected — one already exists and is already
-- load-bearing for the AI; this table only adds the mapping it was missing.
-- ---------------------------------------------------------------------------
create table if not exists pos_product_mappings (
  id uuid primary key default gen_random_uuid(),
  menu_item_id uuid not null references menu_items(id) on delete cascade,
  pos_connection_id uuid not null references pos_connections(id) on delete cascade,
  pos_product_id uuid not null references pos_products(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- One mapping per (menu item, POS connection); a given POS product maps to
-- at most one canonical menu item per connection (keeps the adapter's
-- reverse lookup — "which menu item does this POS product belong to" —
-- unambiguous).
create unique index if not exists pos_product_mappings_menu_item_connection_key
  on pos_product_mappings (menu_item_id, pos_connection_id);
create unique index if not exists pos_product_mappings_connection_product_key
  on pos_product_mappings (pos_connection_id, pos_product_id);
create index if not exists idx_pos_product_mappings_menu_item on pos_product_mappings (menu_item_id);
create index if not exists idx_pos_product_mappings_connection on pos_product_mappings (pos_connection_id);

drop trigger if exists set_pos_product_mappings_updated_at on pos_product_mappings;
create trigger set_pos_product_mappings_updated_at
  before update on pos_product_mappings
  for each row execute function public.set_updated_at();

-- Defense in depth: guarantees a mapping can never link a menu item from
-- one café to a POS connection belonging to another café, even from
-- trusted server-side code with a bug — RLS alone only checks the *caller*,
-- not that the two referenced rows agree with each other.
create or replace function public.check_pos_product_mapping_cafe_match()
returns trigger
language plpgsql
as $$
declare
  menu_item_cafe uuid;
  connection_cafe uuid;
begin
  select cafe_id into menu_item_cafe from menu_items where id = new.menu_item_id;
  select cafe_id into connection_cafe from pos_connections where id = new.pos_connection_id;
  if menu_item_cafe is null or connection_cafe is null or menu_item_cafe <> connection_cafe then
    raise exception 'pos_product_mappings: menu_item_id and pos_connection_id must belong to the same cafe';
  end if;
  return new;
end;
$$;

drop trigger if exists check_pos_product_mapping_cafe_match on pos_product_mappings;
create trigger check_pos_product_mapping_cafe_match
  before insert or update on pos_product_mappings
  for each row execute function public.check_pos_product_mapping_cafe_match();

-- ---------------------------------------------------------------------------
-- orders / order_items / order_item_modifiers — the POS-independent
-- universal order model, replacing the placeholder MVP `orders`/`order_items`
-- tables defined at the top of this file.
--
-- Those tables are unused today: no client code anywhere in the app queries
-- `orders` or `order_items` (the kiosk's order-agent flow doesn't persist
-- orders yet — see order-agent/index.ts), and their RLS was already marked
-- "MVP-permissive... tighten separately". They're safe to replace outright
-- rather than migrate row by row. The guard immediately below makes that
-- assumption explicit and refuses to proceed destructively if it's wrong
-- for your database — it will not silently drop real data.
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.orders') is not null and exists (select 1 from orders limit 1) then
    raise exception 'orders already has rows — this migration replaces its schema for the new POS-independent order model and refuses to drop non-empty data. Export/migrate existing rows first, then re-run this file.';
  end if;
end $$;

drop table if exists order_items cascade;
drop table if exists orders cascade;

-- IDEMPOTENCY: idempotency_key is set once by the client/Edge Function the
-- first time an order is created (e.g. a UUID generated when the customer
-- confirms), before any POS call is made. If a "create order" request is
-- retried (timeout, dropped response, customer double-tap), the retry
-- reuses the same key; the partial unique index below turns a duplicate
-- insert attempt into a conflict the caller can catch and resolve to "fetch
-- the existing order" instead of creating a second one. The same key can
-- also be forwarded as the Idempotency-Key on the outbound POS API call for
-- POS providers that support one (Square does) — see the data-flow notes.
-- The (pos_connection_id, external_order_id) unique index is the second,
-- independent guard: it stops the *POS-send* step from ever recording two
-- BaristaVoice orders as the same external order, even if idempotency_key
-- handling has a bug somewhere upstream.
create table orders (
  id uuid primary key default gen_random_uuid(),
  cafe_id uuid not null references cafes(id) on delete restrict,
  order_number bigint generated always as identity,
  status text not null default 'draft' check (status in (
    'draft', 'confirmed', 'sending_to_pos', 'sent_to_pos',
    'payment_pending', 'paid', 'cancelled', 'pos_failed', 'payment_failed'
  )),
  source text not null default 'voice' check (source in ('voice', 'manual', 'web', 'api')),
  total numeric(12, 2) not null default 0 check (total >= 0),
  currency text not null default 'USD' check (char_length(currency) = 3),
  pos_connection_id uuid references pos_connections(id) on delete set null,
  pos_provider text,
  external_order_id text,
  idempotency_key text,
  last_pos_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table orders is
  'The universal, POS-independent order. cafe_id ON DELETE RESTRICT is deliberate: a café with order history cannot be hard-deleted (accounting/legal retention) — see the migration-safety notes for why soft-deleting cafes was left out of scope here.';
comment on column orders.pos_provider is
  'Denormalized copy of pos_connections.provider at send-time. Kept even though pos_connection_id can be set null (e.g. the café later disconnects that POS) so a historical order never loses the fact of which POS actually processed it.';
comment on column orders.total is
  'Set explicitly by application/Edge Function code (not a generated column), since it may include tax/service-charge rules beyond a pure sum of order_items — that business logic belongs in the app, not a DB trigger.';

create unique index orders_idempotency_key_key on orders (idempotency_key) where idempotency_key is not null;
create unique index orders_connection_external_order_key on orders (pos_connection_id, external_order_id) where external_order_id is not null;
create index idx_orders_cafe_id on orders (cafe_id);
create index idx_orders_status on orders (status);
create index idx_orders_created_at on orders (created_at desc);
create index idx_orders_external_order_id on orders (external_order_id) where external_order_id is not null;

drop trigger if exists set_orders_updated_at on orders;
create trigger set_orders_updated_at
  before update on orders
  for each row execute function public.set_updated_at();

-- Same cross-tenant guard as pos_product_mappings: if pos_connection_id is
-- set, it must belong to the same café as the order.
create or replace function public.check_order_pos_connection_cafe_match()
returns trigger
language plpgsql
as $$
declare
  connection_cafe uuid;
begin
  if new.pos_connection_id is not null then
    select cafe_id into connection_cafe from pos_connections where id = new.pos_connection_id;
    if connection_cafe is null or connection_cafe <> new.cafe_id then
      raise exception 'orders: pos_connection_id must belong to the same cafe as the order';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists check_order_pos_connection_cafe_match on orders;
create trigger check_order_pos_connection_cafe_match
  before insert or update on orders
  for each row execute function public.check_order_pos_connection_cafe_match();

-- menu_item_id / pos_product_id are both nullable with ON DELETE SET NULL,
-- and name/unit_price are captured as a snapshot at order time (not looked
-- up live) — an order_item must stay meaningful even if the menu item is
-- later edited/removed or the POS catalog is later resynced. Money uses
-- numeric(12,2), never float/real/double precision: floating point cannot
-- represent currency amounts exactly (e.g. 0.1 + 0.2 != 0.3 in IEEE 754),
-- which is unacceptable for anything that gets summed into a customer's
-- total. numeric(12,2) gives exact base-10 arithmetic with room up to
-- 9,999,999,999.99 — far beyond any single order.
create table order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  menu_item_id uuid references menu_items(id) on delete set null,
  pos_product_id uuid references pos_products(id) on delete set null,
  name text not null,
  quantity integer not null default 1 check (quantity > 0),
  unit_price numeric(12, 2) not null check (unit_price >= 0),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on column order_items.metadata is
  'Selected-but-not-separately-priced choices (size, milk, temperature, decaf, specialRequest — matching order-agent''s OrderItemIn shape). Priced add-ons belong in order_item_modifiers, not here.';
comment on column order_items.unit_price is
  'Base item price before modifiers. Line total = quantity * (unit_price + sum(order_item_modifiers.price_adjustment)) — computed at read time (see example queries), not stored, to avoid a triggered derived column drifting out of sync.';

create index idx_order_items_order_id on order_items (order_id);
create index idx_order_items_menu_item_id on order_items (menu_item_id) where menu_item_id is not null;
create index idx_order_items_pos_product_id on order_items (pos_product_id) where pos_product_id is not null;

drop trigger if exists set_order_items_updated_at on order_items;
create trigger set_order_items_updated_at
  before update on order_items
  for each row execute function public.set_updated_at();

create table order_item_modifiers (
  id uuid primary key default gen_random_uuid(),
  order_item_id uuid not null references order_items(id) on delete cascade,
  pos_modifier_id uuid references pos_modifiers(id) on delete set null,
  name text not null,
  price_adjustment numeric(12, 2) not null default 0,
  created_at timestamptz not null default now()
);

create index idx_order_item_modifiers_order_item_id on order_item_modifiers (order_item_id);
create index idx_order_item_modifiers_pos_modifier_id on order_item_modifiers (pos_modifier_id) where pos_modifier_id is not null;

-- Realtime for the (future) staff order dashboard — same tables/intent as
-- the original placeholder schema, carried over onto the new shape. Always
-- safe here since orders/order_items were just dropped and recreated above
-- (a fresh table is never already a publication member) — guarded anyway
-- for consistency with the block above and in case this section is ever
-- copy-pasted/run on its own.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'orders'
  ) then
    alter publication supabase_realtime add table orders;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'order_items'
  ) then
    alter publication supabase_realtime add table order_items;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Row Level Security — POS layer
--
-- Summary (see the accompanying report for the full breakdown):
--  * anon gets ZERO access to every table in this section — this is all
--    café back-office / order data, never public.
--  * authenticated (cafe_admin/super_admin) gets READ access scoped to
--    their own café via can_manage_cafe(), for everything except the two
--    OAuth secret-id columns on pos_connections, which are additionally
--    locked out at the column-privilege level below.
--  * authenticated gets WRITE access only on pos_product_mappings (a
--    legitimate admin action: choosing which POS product a menu item maps
--    to). Every other write — creating POS connections, importing
--    products/modifiers, creating/updating orders, sending to a POS — goes
--    through service-role Edge Function code only. Supabase's service_role
--    is not touched by the REVOKEs below; it already has full access by
--    the platform's own default configuration.
-- ---------------------------------------------------------------------------

alter table pos_connections enable row level security;
alter table pos_products enable row level security;
alter table pos_modifiers enable row level security;
alter table pos_product_mappings enable row level security;
alter table orders enable row level security;
alter table order_items enable row level security;
alter table order_item_modifiers enable row level security;

-- pos_connections: column-level lockdown (see table comment above) — note
-- for client code: a query must select an explicit column list here (never
-- `select('*')`), since access_token_secret_id/refresh_token_secret_id are
-- intentionally not in the authenticated grant below and `*` would error.
revoke all on pos_connections from anon;
revoke all on pos_connections from authenticated;
grant select (
  id, cafe_id, provider, location_id, status,
  token_expires_at, last_synced_at, last_error, created_at, updated_at
) on pos_connections to authenticated;

drop policy if exists "cafe admin reads own pos_connections" on pos_connections;
create policy "cafe admin reads own pos_connections" on pos_connections for select
  using (public.can_manage_cafe(cafe_id));

-- pos_products / pos_modifiers: read-only catalog mirror for cafe_admin;
-- all writes (import/sync) are service-role only.
revoke all on pos_products from anon;
revoke insert, update, delete on pos_products from authenticated;
drop policy if exists "cafe admin reads own pos_products" on pos_products;
create policy "cafe admin reads own pos_products" on pos_products for select
  using (public.can_manage_cafe(cafe_id));

revoke all on pos_modifiers from anon;
revoke insert, update, delete on pos_modifiers from authenticated;
drop policy if exists "cafe admin reads own pos_modifiers" on pos_modifiers;
create policy "cafe admin reads own pos_modifiers" on pos_modifiers for select
  using (public.can_manage_cafe(cafe_id));

-- pos_product_mappings: the one POS-layer table cafe_admin can write
-- directly — choosing/correcting which POS product a menu item maps to is
-- a genuine admin action, not something only a sync job should do.
revoke all on pos_product_mappings from anon;
drop policy if exists "cafe admin manages own pos_product_mappings" on pos_product_mappings;
create policy "cafe admin manages own pos_product_mappings" on pos_product_mappings for all
  using (public.can_manage_cafe((select cafe_id from pos_connections where id = pos_product_mappings.pos_connection_id)))
  with check (public.can_manage_cafe((select cafe_id from pos_connections where id = pos_product_mappings.pos_connection_id)));

-- orders / order_items / order_item_modifiers: cafe_admin can READ their
-- own café's orders (staff dashboard); nobody but service_role can WRITE.
-- Keeping every order mutation server-side (same pattern order-agent and
-- tts-speak already use for anything sensitive) avoids a whole class of
-- client-tampering bugs — a customer's client can never fabricate a "paid"
-- status or an arbitrary total by calling the table directly.
revoke all on orders from anon;
revoke insert, update, delete on orders from authenticated;
drop policy if exists "public read/write orders" on orders;
drop policy if exists "cafe admin reads own orders" on orders;
create policy "cafe admin reads own orders" on orders for select
  using (public.can_manage_cafe(cafe_id));

revoke all on order_items from anon;
revoke insert, update, delete on order_items from authenticated;
drop policy if exists "public read/write order_items" on order_items;
drop policy if exists "cafe admin reads own order_items" on order_items;
create policy "cafe admin reads own order_items" on order_items for select
  using (exists (
    select 1 from orders o where o.id = order_items.order_id and public.can_manage_cafe(o.cafe_id)
  ));

revoke all on order_item_modifiers from anon;
revoke insert, update, delete on order_item_modifiers from authenticated;
drop policy if exists "cafe admin reads own order_item_modifiers" on order_item_modifiers;
create policy "cafe admin reads own order_item_modifiers" on order_item_modifiers for select
  using (exists (
    select 1 from order_items oi
    join orders o on o.id = oi.order_id
    where oi.id = order_item_modifiers.order_item_id and public.can_manage_cafe(o.cafe_id)
  ));

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
