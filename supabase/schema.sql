-- ============================================================
-- BARISTAVOICE — MULTI-POS MVP DATABASE SCHEMA
-- Supabase / PostgreSQL
--
-- Fresh-project source of truth.
--
-- Architecture:
--
-- cafes
--   ├── menu_uploads
--   │      └── menu_items
--   │
--   ├── pos_connections
--   │      ├── pos_products
--   │      │      └── pos_modifiers
--   │      └── pos_product_mappings
--   │
--   └── orders
--          └── order_items
--                 └── order_item_modifiers
--
-- Canonical menu is POS-independent.
-- POS products are provider-specific.
-- Mappings connect the two.
-- ============================================================


-- ============================================================
-- EXTENSIONS
-- ============================================================

create extension if not exists pgcrypto;


-- ============================================================
-- ENUM-LIKE CHECK VALUES
-- ============================================================

-- We deliberately use TEXT rather than PostgreSQL enums so that
-- adding another POS provider later does not require an enum migration.


-- ============================================================
-- CAFES
-- ============================================================

create table if not exists public.cafes (
    id uuid primary key default gen_random_uuid(),

    name text not null,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

-- `create table if not exists` above is a no-op against an existing live
-- database, so these were never actually created there by this file (they
-- were added out-of-band) — confirmed via live introspection on
-- 2026-09-15. Documented here, and made idempotent, so this file stops
-- lying about what `cafes` actually looks like.
alter table public.cafes add column if not exists logo_url text;
alter table public.cafes add column if not exists description text;
alter table public.cafes add column if not exists address text;
alter table public.cafes add column if not exists slug text;


-- ============================================================
-- CAFE ADMINS
-- ============================================================
--
-- Connects Supabase auth.users to a cafe.
--
-- This supports the existing current_cafe_id() authorization model.
-- ============================================================

create table if not exists public.cafe_admins (
    id uuid primary key default gen_random_uuid(),

    cafe_id uuid not null
        references public.cafes(id)
        on delete cascade,

    user_id uuid not null
        references auth.users(id)
        on delete cascade,

    role text not null default 'admin'
        check (role in ('owner', 'admin', 'staff')),

    created_at timestamptz not null default now(),

    unique (cafe_id, user_id)
);


-- ============================================================
-- CURRENT CAFE HELPER
-- ============================================================
--
-- Returns the cafe associated with the currently authenticated
-- Supabase user.
--
-- SECURITY DEFINER is used so RLS does not recursively query
-- cafe_admins.
-- ============================================================

create or replace function public.current_cafe_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
    select ca.cafe_id
    from public.cafe_admins ca
    where ca.user_id = auth.uid()
    order by ca.created_at
    limit 1;
$$;

revoke all on function public.current_cafe_id() from public;
grant execute on function public.current_cafe_id() to authenticated;


-- ============================================================
-- MENU UPLOADS
-- ============================================================

create table if not exists public.menu_uploads (
    id uuid primary key default gen_random_uuid(),

    cafe_id uuid not null
        references public.cafes(id)
        on delete cascade,

    file_name text,

    source_type text not null default 'upload'
        check (
            source_type in (
                'upload',
                'manual',
                'url',
                'api'
            )
        ),

    status text not null default 'pending'
        check (
            status in (
                'pending',
                'processing',
                'completed',
                'failed'
            )
        ),

    metadata jsonb not null default '{}'::jsonb,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);


-- ============================================================
-- CANONICAL MENU ITEMS
-- ============================================================
--
-- IMPORTANT:
--
-- `data` intentionally remains JSONB because BaristaVoice's
-- canonical menu can contain:
--
-- {
--   "name": "Cafe Latte",
--   "category": "Coffee",
--   "price": 12,
--   "sizes": [...],
--   "modifiers": [...],
--   ...
-- }
--
-- The canonical menu does NOT contain provider-specific IDs.
-- ============================================================

create table if not exists public.menu_items (
    id uuid primary key default gen_random_uuid(),

    cafe_id uuid not null
        references public.cafes(id)
        on delete cascade,

    menu_upload_id uuid
        references public.menu_uploads(id)
        on delete set null,

    data jsonb not null default '{}'::jsonb,

    status text not null default 'active'
        check (
            status in (
                'draft',
                'active',
                'archived'
            )
        ),

    is_active boolean not null default true,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);


-- ============================================================
-- POS CONNECTIONS
-- ============================================================
--
-- One cafe can have multiple POS connections.
--
-- Examples:
--   Square
--   Toast
--   Lightspeed
--   EPOS Now
--
-- Provider credentials should NOT be stored as raw secrets here.
--
-- Store Vault secret references instead.
-- ============================================================

create table if not exists public.pos_connections (
    id uuid primary key default gen_random_uuid(),

    cafe_id uuid not null
        references public.cafes(id)
        on delete cascade,

    provider text not null,

    display_name text,

    status text not null default 'connected'
        check (
            status in (
                'pending',
                'connected',
                'disconnected',
                'error',
                'revoked'
            )
        ),

    merchant_id text,

    location_id text,

    -- References to Supabase Vault secrets.
    -- These are IDs, NOT credentials themselves.
    access_token_secret_id uuid,
    refresh_token_secret_id uuid,

    metadata jsonb not null default '{}'::jsonb,

    last_sync_at timestamptz,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    unique (cafe_id, provider, merchant_id, location_id)
);


-- ============================================================
-- POS PRODUCTS
-- ============================================================
--
-- These are provider-specific catalog products.
--
-- Example:
--
-- BaristaVoice:
--     Cafe Latte
--
-- Square:
--     id = local UUID
--     external_product_id = Square catalog ID
--
-- ============================================================

create table if not exists public.pos_products (
    id uuid primary key default gen_random_uuid(),

    cafe_id uuid not null
        references public.cafes(id)
        on delete cascade,

    pos_connection_id uuid not null
        references public.pos_connections(id)
        on delete cascade,

    external_product_id text not null,

    name text not null,

    category text,

    price numeric(12,2),

    active boolean not null default true,

    metadata jsonb not null default '{}'::jsonb,

    external_updated_at timestamptz,

    last_synced_at timestamptz,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    unique (pos_connection_id, external_product_id)
);


-- ============================================================
-- POS MODIFIERS
-- ============================================================

create table if not exists public.pos_modifiers (
    id uuid primary key default gen_random_uuid(),

    cafe_id uuid not null
        references public.cafes(id)
        on delete cascade,

    pos_connection_id uuid not null
        references public.pos_connections(id)
        on delete cascade,

    external_modifier_id text,

    name text not null,

    price_adjustment numeric(12,2) not null default 0,

    active boolean not null default true,

    metadata jsonb not null default '{}'::jsonb,

    external_updated_at timestamptz,

    last_synced_at timestamptz,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    unique (pos_connection_id, external_modifier_id)
);


-- ============================================================
-- POS PRODUCT MAPPINGS
-- ============================================================
--
-- THIS IS THE CRITICAL MULTI-POS BRIDGE.
--
-- canonical menu item
--        ↓
-- pos_product_mappings
--        ↓
-- provider-specific POS product
--
-- Example:
--
-- menu_items.id
--     feb97f8a...
--
-- maps to:
--
-- pos_products.id
--     38e92443...
--
-- which represents:
--
-- Square external_product_id
--     4TXML2YS6VBDMPWPS33KEY2I
--
-- ============================================================

create table if not exists public.pos_product_mappings (
    id uuid primary key default gen_random_uuid(),

    menu_item_id uuid not null
        references public.menu_items(id)
        on delete cascade,

    pos_connection_id uuid not null
        references public.pos_connections(id)
        on delete cascade,

    pos_product_id uuid not null
        references public.pos_products(id)
        on delete cascade,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    unique (menu_item_id, pos_connection_id),

    unique (pos_product_id)
);


-- ============================================================
-- ORDERS
-- ============================================================
--
-- POS-INDEPENDENT.
--
-- An order exists in BaristaVoice before it is sent to a POS.
--
-- status:
--
-- draft
-- pending
-- submitting
-- sent_to_pos
-- pos_failed
-- cancelled
--
-- ============================================================

create table if not exists public.orders (
    id uuid primary key default gen_random_uuid(),

    cafe_id uuid not null
        references public.cafes(id)
        on delete cascade,

    -- Plain bigint here for a fresh install, but the LIVE table has this as
    -- an identity column (added out-of-band, likely via Studio's table
    -- editor) — see the ALTER right after this CREATE TABLE block. The app
    -- always supplies this value itself (create_canonical_order calls
    -- next_order_number(), a per-cafe advisory-locked counter — NOT a
    -- global sequence), so it must be GENERATED BY DEFAULT, never ALWAYS:
    -- ALWAYS rejects create_canonical_order's explicit insert outright
    -- (confirmed live 2026-09-17: every order creation was failing with
    -- "cannot insert a non-DEFAULT value into column order_number").
    order_number bigint not null,

    status text not null default 'draft'
        check (
            status in (
                'draft',
                'pending',
                'submitting',
                'sent_to_pos',
                'pos_failed',
                'cancelled'
            )
        ),

    source text not null default 'voice'
        check (
            source in (
                'voice',
                'text',
                'kiosk',
                'staff',
                'api'
            )
        ),

    total numeric(12,2) not null default 0,

    currency text not null default 'GBP',

    pos_connection_id uuid
        references public.pos_connections(id)
        on delete set null,

    pos_provider text,

    external_order_id text,

    idempotency_key text,

    last_pos_error text,

    external_payment_id text,

    -- When a barista marks a paid order as handed over/fulfilled. Deliberately
    -- separate from `status` above: `status` tracks the payment/POS-submission
    -- pipeline (draft -> ... -> paid), while completed_at tracks the
    -- independent, staff-driven "this order has been made and given to the
    -- customer" step the live orders dashboard exposes as "Mark complete".
    completed_at timestamptz,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    unique (cafe_id, order_number),

    unique (cafe_id, idempotency_key)
);

-- `create table if not exists` above is a no-op against your existing live
-- database (the table already exists), so completed_at would never actually
-- get created there without this explicit, idempotent ALTER — same reason
-- the rest of this file can't just be re-run to pick up new columns.
alter table public.orders
    add column if not exists completed_at timestamptz;

-- BUG FIX (confirmed live 2026-09-17): order_number was found live as
-- `GENERATED ALWAYS AS IDENTITY`, which unconditionally rejects the
-- explicit value create_canonical_order always supplies (a per-cafe
-- sequential number from next_order_number(), not Postgres' own identity
-- sequence) — every single order creation was failing. `alter column ...
-- set generated by default` only changes the identity MODE (still
-- identity-backed, just no longer exclusive) — safe to re-run, and safe
-- even if a fresh install never had this as an identity column at all
-- (the ALTER is skipped when there's nothing to change).
do $$
begin
    if exists (
        select 1
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'orders'
          and column_name = 'order_number'
          and is_identity = 'YES'
          and identity_generation = 'ALWAYS'
    ) then
        alter table public.orders alter column order_number set generated by default;
    end if;
end $$;


-- ============================================================
-- ORDER ITEMS
-- ============================================================
--
-- Stores BOTH:
--
-- menu_item_id:
--     what BaristaVoice believes the customer ordered
--
-- pos_product_id:
--     which provider product should receive the order
--
-- IMPORTANT:
-- There is intentionally NO line_total column.
--
-- line total = quantity * unit_price
--
-- ============================================================

create table if not exists public.order_items (
    id uuid primary key default gen_random_uuid(),

    order_id uuid not null
        references public.orders(id)
        on delete cascade,

    menu_item_id uuid
        references public.menu_items(id)
        on delete set null,

    pos_product_id uuid
        references public.pos_products(id)
        on delete set null,

    name text not null,

    quantity integer not null default 1
        check (quantity > 0),

    unit_price numeric(12,2) not null
        check (unit_price >= 0),

    metadata jsonb not null default '{}'::jsonb,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);


-- ============================================================
-- ORDER ITEM MODIFIERS
-- ============================================================

create table if not exists public.order_item_modifiers (
    id uuid primary key default gen_random_uuid(),

    order_item_id uuid not null
        references public.order_items(id)
        on delete cascade,

    pos_modifier_id uuid
        references public.pos_modifiers(id)
        on delete set null,

    name text not null,

    price_adjustment numeric(12,2) not null default 0,

    created_at timestamptz not null default now()
);


-- ============================================================
-- ORDER NUMBER SEQUENCE
-- ============================================================

create sequence if not exists public.order_number_seq;


-- ============================================================
-- UPDATED_AT TRIGGER
-- ============================================================

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;


drop trigger if exists cafes_set_updated_at
on public.cafes;

create trigger cafes_set_updated_at
before update on public.cafes
for each row
execute function public.set_updated_at();


drop trigger if exists menu_uploads_set_updated_at
on public.menu_uploads;

create trigger menu_uploads_set_updated_at
before update on public.menu_uploads
for each row
execute function public.set_updated_at();


drop trigger if exists menu_items_set_updated_at
on public.menu_items;

create trigger menu_items_set_updated_at
before update on public.menu_items
for each row
execute function public.set_updated_at();


drop trigger if exists pos_connections_set_updated_at
on public.pos_connections;

create trigger pos_connections_set_updated_at
before update on public.pos_connections
for each row
execute function public.set_updated_at();


drop trigger if exists pos_products_set_updated_at
on public.pos_products;

create trigger pos_products_set_updated_at
before update on public.pos_products
for each row
execute function public.set_updated_at();


drop trigger if exists pos_modifiers_set_updated_at
on public.pos_modifiers;

create trigger pos_modifiers_set_updated_at
before update on public.pos_modifiers
for each row
execute function public.set_updated_at();


drop trigger if exists pos_product_mappings_set_updated_at
on public.pos_product_mappings;

create trigger pos_product_mappings_set_updated_at
before update on public.pos_product_mappings
for each row
execute function public.set_updated_at();


drop trigger if exists orders_set_updated_at
on public.orders;

create trigger orders_set_updated_at
before update on public.orders
for each row
execute function public.set_updated_at();


drop trigger if exists order_items_set_updated_at
on public.order_items;

create trigger order_items_set_updated_at
before update on public.order_items
for each row
execute function public.set_updated_at();


-- ============================================================
-- INDEXES
-- ============================================================

create index if not exists idx_cafe_admins_user_id
on public.cafe_admins(user_id);

create index if not exists idx_cafe_admins_cafe_id
on public.cafe_admins(cafe_id);


create index if not exists idx_menu_uploads_cafe_id
on public.menu_uploads(cafe_id);

create index if not exists idx_menu_items_cafe_id
on public.menu_items(cafe_id);

create index if not exists idx_menu_items_active
on public.menu_items(cafe_id, is_active);


create index if not exists idx_pos_connections_cafe_id
on public.pos_connections(cafe_id);

create index if not exists idx_pos_connections_provider
on public.pos_connections(cafe_id, provider);


create index if not exists idx_pos_products_cafe_id
on public.pos_products(cafe_id);

create index if not exists idx_pos_products_connection
on public.pos_products(pos_connection_id);

create index if not exists idx_pos_products_external_id
on public.pos_products(
    pos_connection_id,
    external_product_id
);


create index if not exists idx_pos_modifiers_connection
on public.pos_modifiers(pos_connection_id);


create index if not exists idx_pos_product_mappings_menu_item
on public.pos_product_mappings(menu_item_id);

create index if not exists idx_pos_product_mappings_connection
on public.pos_product_mappings(pos_connection_id);

create index if not exists idx_pos_product_mappings_product
on public.pos_product_mappings(pos_product_id);


create index if not exists idx_orders_cafe_id
on public.orders(cafe_id);

create index if not exists idx_orders_status
on public.orders(cafe_id, status);

create index if not exists idx_orders_created_at
on public.orders(cafe_id, created_at desc);

create index if not exists idx_orders_pos_connection
on public.orders(pos_connection_id);


create index if not exists idx_order_items_order_id
on public.order_items(order_id);

create index if not exists idx_order_items_menu_item
on public.order_items(menu_item_id);

create index if not exists idx_order_items_pos_product
on public.order_items(pos_product_id);


create index if not exists idx_order_item_modifiers_item
on public.order_item_modifiers(order_item_id);


-- ============================================================
-- ORDER NUMBER FUNCTION
-- ============================================================

create or replace function public.next_order_number(
    p_cafe_id uuid
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
    next_number bigint;
begin
    /*
     * Generate the next order number for this cafe.
     *
     * The advisory lock prevents two simultaneous requests
     * from receiving the same number.
     */

    perform pg_advisory_xact_lock(
        hashtextextended(p_cafe_id::text, 0)
    );

    select coalesce(max(order_number), 0) + 1
    into next_number
    from public.orders
    where cafe_id = p_cafe_id;

    return next_number;
end;
$$;

revoke all on function public.next_order_number(uuid) from public;
grant execute on function public.next_order_number(uuid) to service_role;


-- ============================================================
-- CANONICAL ORDER CREATION
-- ============================================================
--
-- The Edge Function should call this function.
--
-- Expected payload shape:
--
-- {
--   "cafe_id": "...",
--   "source": "voice",
--   "currency": "GBP",
--   "pos_connection_id": "...",
--   "items": [
--     {
--       "menu_item_id": "...",
--       "name": "Cafe Latte",
--       "quantity": 1,
--       "unit_price": 12,
--       "metadata": {},
--       "modifiers": [
--         {
--           "name": "Oat Milk",
--           "price_adjustment": 0.50,
--           "pos_modifier_id": "..."
--         }
--       ]
--     }
--   ]
-- }
--
-- IMPORTANT:
--
-- The function resolves the POS mapping itself.
-- The client does NOT get to choose an arbitrary pos_product_id.
--
-- CORRECTED 2026-09-18: despite what this function's body below implies,
-- it does NOT compute unit_price from menu_items itself — it just trusts
-- whatever `unit_price` arrives in payload->'items', defaulting to 0.
-- Confirmed live 2026-09-18 (every order was totaling £0.00 until fixed).
-- The actual pricing authority today is supabase/functions/create-order/
-- index.ts's resolveUnitPrices()/computeUnitPrice(), which resolves each
-- item's real price from menu_items BEFORE calling this function. Also
-- confirmed stale below: the POS-connection check compares
-- `pc.status = 'connected'`, but the live pos_connections_status_check
-- constraint only allows pending/active/error/disconnected — 'connected'
-- can never match. Neither of these was touched here since this is a
-- SECURITY DEFINER, payment-critical function and schema.sql's copy of it
-- is already known to differ from the live version in other ways too — see
-- pos_connections above. Flagged, not blindly rewritten.
--
-- ============================================================

-- `create or replace function` cannot change a function's return type, so a
-- database whose deployed version of this function predates a return-type
-- change would fail to re-run this file. Drop it first so schema.sql stays
-- idempotent regardless of what's currently deployed.
drop function if exists public.create_canonical_order(jsonb);

create or replace function public.create_canonical_order(
    payload jsonb
)
returns public.orders
language plpgsql
security definer
set search_path = public
as $$
declare
    v_order public.orders;

    v_cafe_id uuid;
    v_pos_connection_id uuid;
    v_source text;
    v_currency text;

    v_item jsonb;
    v_modifier jsonb;

    v_menu_item_id uuid;
    v_pos_product_id uuid;

    v_item_name text;
    v_quantity integer;
    v_unit_price numeric;

    v_item_id uuid;

    v_total numeric := 0;

    v_order_number bigint;
    v_idempotency_key text;
begin

    -- --------------------------------------------------------
    -- Basic payload validation
    -- --------------------------------------------------------

    if payload is null then
        raise exception 'Payload is required';
    end if;

    v_cafe_id :=
        nullif(payload->>'cafe_id', '')::uuid;

    if v_cafe_id is null then
        raise exception 'cafe_id is required';
    end if;

    if not exists (
        select 1
        from public.cafes c
        where c.id = v_cafe_id
    ) then
        raise exception 'Cafe not found';
    end if;


    v_source :=
        coalesce(payload->>'source', 'voice');

    v_currency :=
        coalesce(payload->>'currency', 'GBP');

    v_pos_connection_id :=
        nullif(payload->>'pos_connection_id', '')::uuid;

    v_idempotency_key :=
        nullif(payload->>'idempotency_key', '');


    -- --------------------------------------------------------
    -- Idempotency
    -- --------------------------------------------------------

    if v_idempotency_key is not null then

        select *
        into v_order
        from public.orders
        where cafe_id = v_cafe_id
          and idempotency_key = v_idempotency_key
        limit 1;

        if found then
            return v_order;
        end if;

    end if;


    -- --------------------------------------------------------
    -- POS connection validation
    -- --------------------------------------------------------

    if v_pos_connection_id is not null then

        if not exists (
            select 1
            from public.pos_connections pc
            where pc.id = v_pos_connection_id
              and pc.cafe_id = v_cafe_id
              and pc.status = 'connected'
        ) then
            raise exception 'Invalid POS connection for cafe';
        end if;

    end if;


    -- --------------------------------------------------------
    -- Create order number
    -- --------------------------------------------------------

    v_order_number :=
        public.next_order_number(v_cafe_id);


    -- --------------------------------------------------------
    -- Create order
    -- --------------------------------------------------------

    insert into public.orders (
        cafe_id,
        order_number,
        status,
        source,
        total,
        currency,
        pos_connection_id,
        pos_provider,
        idempotency_key
    )
    values (
        v_cafe_id,
        v_order_number,
        'pending',
        v_source,
        0,
        v_currency,
        v_pos_connection_id,

        case
            when v_pos_connection_id is not null
            then (
                select provider
                from public.pos_connections
                where id = v_pos_connection_id
            )
            else null
        end,

        v_idempotency_key
    )
    returning *
    into v_order;


    -- --------------------------------------------------------
    -- Validate items
    -- --------------------------------------------------------

    if not jsonb_typeof(payload->'items') = 'array' then
        raise exception 'items must be an array';
    end if;

    if jsonb_array_length(payload->'items') = 0 then
        raise exception 'Order must contain at least one item';
    end if;


    -- --------------------------------------------------------
    -- Create order items
    -- --------------------------------------------------------

    for v_item in
        select value
        from jsonb_array_elements(payload->'items')
    loop

        v_menu_item_id :=
            nullif(v_item->>'menu_item_id', '')::uuid;

        v_item_name :=
            coalesce(v_item->>'name', '');

        v_quantity :=
            coalesce(
                nullif(v_item->>'quantity', '')::integer,
                1
            );

        v_unit_price :=
            coalesce(
                nullif(v_item->>'unit_price', '')::numeric,
                0
            );


        if v_menu_item_id is null then
            raise exception 'menu_item_id is required';
        end if;

        if v_quantity <= 0 then
            raise exception 'quantity must be greater than zero';
        end if;

        if v_unit_price < 0 then
            raise exception 'unit_price cannot be negative';
        end if;


        -- ----------------------------------------------------
        -- Verify canonical menu item belongs to this cafe
        -- ----------------------------------------------------

        if not exists (
            select 1
            from public.menu_items mi
            where mi.id = v_menu_item_id
              and mi.cafe_id = v_cafe_id
              and mi.is_active = true
        ) then
            raise exception
                'Menu item % does not belong to cafe or is inactive',
                v_menu_item_id;
        end if;


        -- ----------------------------------------------------
        -- Resolve POS mapping
        -- ----------------------------------------------------
        --
        -- THIS is the piece that was missing for your
        -- Americano and Muffin.
        --
        -- Canonical:
        --
        -- menu_item_id
        --       ↓
        -- mapping
        --       ↓
        -- pos_product_id
        --
        -- ----------------------------------------------------

        v_pos_product_id := null;

        if v_pos_connection_id is not null then

            select ppm.pos_product_id
            into v_pos_product_id
            from public.pos_product_mappings ppm
            join public.pos_products pp
                on pp.id = ppm.pos_product_id
            where ppm.menu_item_id = v_menu_item_id
              and ppm.pos_connection_id = v_pos_connection_id
              and pp.pos_connection_id = v_pos_connection_id
              and pp.active = true
            limit 1;

            if v_pos_product_id is null then
                raise exception
                    'No POS mapping found for menu item %',
                    v_menu_item_id;
            end if;

        end if;


        -- ----------------------------------------------------
        -- Insert order item
        -- ----------------------------------------------------

        insert into public.order_items (
            order_id,
            menu_item_id,
            pos_product_id,
            name,
            quantity,
            unit_price,
            metadata
        )
        values (
            v_order.id,
            v_menu_item_id,
            v_pos_product_id,
            v_item_name,
            v_quantity,
            v_unit_price,
            coalesce(v_item->'metadata', '{}'::jsonb)
        )
        returning id
        into v_item_id;


        -- ----------------------------------------------------
        -- Insert modifiers
        -- ----------------------------------------------------

        if jsonb_typeof(v_item->'modifiers') = 'array' then

            for v_modifier in
                select value
                from jsonb_array_elements(v_item->'modifiers')
            loop

                insert into public.order_item_modifiers (
                    order_item_id,
                    pos_modifier_id,
                    name,
                    price_adjustment
                )
                values (
                    v_item_id,

                    nullif(
                        v_modifier->>'pos_modifier_id',
                        ''
                    )::uuid,

                    coalesce(
                        v_modifier->>'name',
                        'Modifier'
                    ),

                    coalesce(
                        nullif(
                            v_modifier->>'price_adjustment',
                            ''
                        )::numeric,
                        0
                    )
                );

            end loop;

        end if;


        -- ----------------------------------------------------
        -- Calculate total
        -- ----------------------------------------------------

        v_total :=
            v_total
            + (
                v_quantity
                * v_unit_price
            );

    end loop;


    -- --------------------------------------------------------
    -- Update final order total
    -- --------------------------------------------------------

    update public.orders
    set total = v_total
    where id = v_order.id
    returning *
    into v_order;


    return v_order;

end;
$$;


-- ============================================================
-- FUNCTION PERMISSIONS
-- ============================================================

revoke all
on function public.create_canonical_order(jsonb)
from public;

grant execute
on function public.create_canonical_order(jsonb)
to service_role;


-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================

alter table public.cafes enable row level security;
alter table public.cafe_admins enable row level security;
alter table public.menu_uploads enable row level security;
alter table public.menu_items enable row level security;
alter table public.pos_connections enable row level security;
alter table public.pos_products enable row level security;
alter table public.pos_modifiers enable row level security;
alter table public.pos_product_mappings enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.order_item_modifiers enable row level security;


-- ============================================================
-- CAFE POLICIES
-- ============================================================

drop policy if exists cafes_select_own
on public.cafes;

create policy cafes_select_own
on public.cafes
for select
to authenticated
using (
    id = public.current_cafe_id()
);

-- SECURITY FIX (2026-09-15): live introspection found a policy named
-- "public read/write cafes" — command ALL, role public, using(true),
-- with_check(true) — that OR'd together with every other policy on this
-- table, meaning any unauthenticated anon-key caller could read/insert/
-- update/delete ANY café's row. Legitimate anonymous access is already
-- covered by the (separately live, not yet mirrored into this file) public
-- read cafes / cafe admin updates own cafe / super admin inserts/deletes
-- cafes policies, so this was pure exposure, not a load-bearing shortcut.
-- This file never created that policy in the first place (create table if
-- not exists is a no-op against an existing table), so there's nothing
-- for this DROP to do on a fresh database — it only matters against the
-- live one, where it was actually run once.
drop policy if exists "public read/write cafes" on public.cafes;


-- ============================================================
-- CAFE ADMINS POLICIES
-- ============================================================

drop policy if exists cafe_admins_select_own
on public.cafe_admins;

create policy cafe_admins_select_own
on public.cafe_admins
for select
to authenticated
using (
    cafe_id = public.current_cafe_id()
);


-- ============================================================
-- MENU UPLOAD POLICIES
-- ============================================================

drop policy if exists menu_uploads_select_own
on public.menu_uploads;

create policy menu_uploads_select_own
on public.menu_uploads
for select
to authenticated
using (
    cafe_id = public.current_cafe_id()
);


-- ============================================================
-- MENU ITEM POLICIES
-- ============================================================

drop policy if exists menu_items_select_own
on public.menu_items;

create policy menu_items_select_own
on public.menu_items
for select
to authenticated
using (
    cafe_id = public.current_cafe_id()
);

-- SECURITY FIX (2026-09-15): same finding as cafes above — a live
-- "public read/write menu_items" policy (ALL, public, true/true) let any
-- unauthenticated caller write any café's menu. Legitimate access stays
-- covered by "public read published menu_items" and the cafe-admin CRUD
-- policies.
drop policy if exists "public read/write menu_items" on public.menu_items;


-- ============================================================
-- POS CONNECTION POLICIES
-- ============================================================
--
-- IMPORTANT:
--
-- Do NOT expose Vault secret IDs to normal authenticated users
-- unless your application genuinely needs them.
--
-- Prefer service-role Edge Functions for connection management.
-- ============================================================

drop policy if exists pos_connections_select_own
on public.pos_connections;

create policy pos_connections_select_own
on public.pos_connections
for select
to authenticated
using (
    cafe_id = public.current_cafe_id()
);


-- ============================================================
-- POS PRODUCT POLICIES
-- ============================================================

drop policy if exists pos_products_select_own
on public.pos_products;

create policy pos_products_select_own
on public.pos_products
for select
to authenticated
using (
    cafe_id = public.current_cafe_id()
);


-- ============================================================
-- POS MODIFIER POLICIES
-- ============================================================

drop policy if exists pos_modifiers_select_own
on public.pos_modifiers;

create policy pos_modifiers_select_own
on public.pos_modifiers
for select
to authenticated
using (
    cafe_id = public.current_cafe_id()
);


-- ============================================================
-- POS PRODUCT MAPPING POLICIES
-- ============================================================

drop policy if exists pos_product_mappings_select_own
on public.pos_product_mappings;

create policy pos_product_mappings_select_own
on public.pos_product_mappings
for select
to authenticated
using (
    exists (
        select 1
        from public.menu_items mi
        where mi.id = pos_product_mappings.menu_item_id
          and mi.cafe_id = public.current_cafe_id()
    )
);


-- ============================================================
-- ORDER POLICIES
-- ============================================================

drop policy if exists orders_select_own
on public.orders;

create policy orders_select_own
on public.orders
for select
to authenticated
using (
    cafe_id = public.current_cafe_id()
);

-- SECURITY FIX (2026-09-15): same finding again — a live "public
-- read/write orders" policy (ALL, public, true/true) let any
-- unauthenticated caller read/forge/alter/delete any café's orders,
-- directly undermining Live Orders, Analytics, and Stripe usage billing
-- (which all trust `orders.status`/`total`). Legitimate access stays
-- covered by "cafe admin reads own orders" and service-role Edge
-- Functions, which bypass RLS entirely and never needed this policy.
drop policy if exists "public read/write orders" on public.orders;


-- ============================================================
-- ORDER ITEM POLICIES
-- ============================================================

drop policy if exists order_items_select_own
on public.order_items;

create policy order_items_select_own
on public.order_items
for select
to authenticated
using (
    exists (
        select 1
        from public.orders o
        where o.id = order_items.order_id
          and o.cafe_id = public.current_cafe_id()
    )
);


-- ============================================================
-- ORDER ITEM MODIFIER POLICIES
-- ============================================================

drop policy if exists order_item_modifiers_select_own
on public.order_item_modifiers;

create policy order_item_modifiers_select_own
on public.order_item_modifiers
for select
to authenticated
using (
    exists (
        select 1
        from public.order_items oi
        join public.orders o
            on o.id = oi.order_id
        where oi.id = order_item_modifiers.order_item_id
          and o.cafe_id = public.current_cafe_id()
    )
);


-- ============================================================
-- WRITE SECURITY
-- ============================================================
--
-- Authenticated users can READ their cafe's data.
--
-- Writes involving POS connections, catalog sync, mappings and
-- canonical orders should go through trusted Edge Functions.
--
-- This prevents a client from:
--
--   - assigning arbitrary POS products
--   - changing POS credentials
--   - creating fake POS mappings
--   - manipulating order totals
-- ============================================================

revoke insert, update, delete
on public.pos_connections
from authenticated;

revoke insert, update, delete
on public.pos_products
from authenticated;

revoke insert, update, delete
on public.pos_modifiers
from authenticated;

revoke insert, update, delete
on public.pos_product_mappings
from authenticated;

revoke insert, update, delete
on public.orders
from authenticated;

revoke insert, update, delete
on public.order_items
from authenticated;

revoke insert, update, delete
on public.order_item_modifiers
from authenticated;


-- ============================================================
-- VAULT SECURITY
-- ============================================================
--
-- If using Supabase Vault:
--
-- pos_connections.access_token_secret_id
-- pos_connections.refresh_token_secret_id
--
-- contain ONLY Vault secret UUIDs.
--
-- The actual access/refresh tokens remain inside Vault and are
-- retrieved only by trusted server-side Edge Functions.
--
-- Do NOT put raw Square/Toast/etc. access tokens in:
--
--   pos_connections.access_token
--   pos_connections.refresh_token
--
-- ============================================================


-- ============================================================
-- USEFUL REPORTING VIEW
-- ============================================================
--
-- Gives analytics without adding redundant line_total storage.
-- ============================================================

create or replace view public.order_item_totals
with (security_invoker = true)
as
select
    oi.id,
    oi.order_id,
    oi.menu_item_id,
    oi.pos_product_id,
    oi.name,
    oi.quantity,
    oi.unit_price,

    (
        oi.quantity * oi.unit_price
    )::numeric(12,2) as line_total,

    oi.metadata,
    oi.created_at,
    oi.updated_at

from public.order_items oi;


-- ============================================================
-- USEFUL ORDER SUMMARY VIEW
-- ============================================================

create or replace view public.order_summary
with (security_invoker = true)
as
select
    o.id,
    o.cafe_id,
    o.order_number,
    o.status,
    o.source,
    o.total,
    o.currency,
    o.pos_provider,
    o.external_order_id,
    o.created_at,
    o.updated_at,

    count(oi.id) as item_count,

    coalesce(
        sum(oi.quantity),
        0
    ) as total_quantity,

    -- Appended at the end, not alongside the other o.* columns above:
    -- `create or replace view` only allows adding new output columns at the
    -- end of the list — it errors if an existing column's position shifts.
    o.completed_at

from public.orders o

left join public.order_items oi
    on oi.order_id = o.id

group by
    o.id;


-- ============================================================
-- USEFUL ITEM-SALES VIEW (analytics: top items, daily/weekly trends)
-- ============================================================
--
-- Same security_invoker pattern as order_summary/order_item_totals above —
-- there is no separate RLS policy on this view itself; row access is still
-- governed entirely by the underlying order_items/orders RLS policies
-- (order_items_select_own / orders_select_own), scoped to the caller's own
-- cafe_id via current_cafe_id(). Denormalizes cafe_id/status/created_at
-- from the parent order onto each line so the admin dashboard can filter
-- and bucket sales (by item, by day, by paid-vs-not) in one query instead
-- of joining client-side.
-- ============================================================

create or replace view public.order_item_sales
with (security_invoker = true)
as
select
    oi.id,
    oi.order_id,
    oi.menu_item_id,
    oi.name,
    oi.quantity,
    oi.unit_price,

    (
        oi.quantity * oi.unit_price
    )::numeric(12,2) as line_total,

    o.cafe_id,
    o.status as order_status,
    o.created_at as order_created_at

from public.order_items oi

join public.orders o
    on o.id = oi.order_id;


-- ============================================================
-- COMMENTS
-- ============================================================

comment on table public.menu_items is
'BaristaVoice canonical, POS-independent menu items.';

comment on table public.pos_products is
'Products synchronized from provider-specific POS systems.';

comment on table public.pos_product_mappings is
'Maps canonical BaristaVoice menu items to provider-specific POS products.';

comment on table public.orders is
'Canonical BaristaVoice orders independent of any specific POS provider.';

comment on table public.order_items is
'Individual canonical order lines with optional resolved POS product IDs.';

comment on view public.order_item_sales is
'order_items denormalized with their parent order''s cafe_id/status/created_at, for the admin analytics dashboard (top items, daily trends) without a client-side join.';

comment on function public.create_canonical_order(jsonb) is
'Creates a POS-independent canonical order and resolves canonical menu items to POS products through pos_product_mappings.';


-- ============================================================
-- STRIPE USAGE BILLING
-- ============================================================
--
-- RevenueCat remains the ONLY thing that ever charges the flat
-- £79/month subscription (see app/lib/data/billing/subscription_service.dart)
-- — nothing here creates a second subscription or duplicates that charge.
-- This section adds a second, independent billing lane: a 5p-per-item
-- usage charge, invoiced through Stripe once per monthly billing period.
--
-- Billing period = calendar month in Europe/London (this app has no
-- per-cafe timezone column; Europe/London was chosen as a single
-- consistent zone for all cafes — see cafe_billing_period_bounds()).
--
-- Source of truth for "how many items were actually ordered" is always
-- calculate_cafe_usage() below, re-derived from the same canonical
-- orders/order_items rows analytics already uses — never a client-
-- supplied number (see app/lib/data/admin/analytics_insights.dart's
-- `_paidStatus = 'paid'`, the same definition of "genuinely completed"
-- this reuses).
--
-- ============================================================


-- ------------------------------------------------------------
-- Pre-requisite fix: the orders status check constraint was written
-- before payment-capture statuses existed. pos-square-order-pay and
-- pos-square-terminal-checkout already write 'payment_pending',
-- 'payment_failed', and 'paid' (the actual "this order is genuinely
-- completed and was paid for" status — see analytics_insights.dart),
-- and pos-square-order-submit writes 'sending_to_pos'. None of those
-- were in the constraint below, so on a database where this constraint
-- was never manually patched, every real payment update would currently
-- fail. Usage billing depends on 'paid' being a real, reachable status,
-- so this widens the constraint (additive only — nothing removed, no
-- existing rows affected).
-- ------------------------------------------------------------

alter table public.orders
    drop constraint if exists orders_status_check;

alter table public.orders
    add constraint orders_status_check
    check (
        status in (
            'draft',
            'pending',
            'submitting',
            'sending_to_pos',
            'sent_to_pos',
            'pos_failed',
            'payment_pending',
            'payment_failed',
            'paid',
            'cancelled'
        )
    );


-- ============================================================
-- CAFE BILLING (Stripe customer + payment method state)
-- ============================================================
--
-- One row per cafe. Never holds card numbers/CVCs — only Stripe's own
-- identifiers, exactly like pos_connections holds a Vault secret ID
-- rather than a raw Square token. Written only by service-role Edge
-- Functions (stripe-setup-payment-method, stripe-webhook); cafe admins
-- get read-only access via RLS below.

create table if not exists public.cafe_billing (
    id uuid primary key default gen_random_uuid(),

    cafe_id uuid not null unique
        references public.cafes(id)
        on delete cascade,

    stripe_customer_id text unique,

    stripe_default_payment_method_id text,

    billing_status text not null default 'no_customer'
        check (
            billing_status in (
                'no_customer',
                'pending_payment_method',
                'active',
                'past_due'
            )
        ),

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

drop trigger if exists cafe_billing_set_updated_at
on public.cafe_billing;

create trigger cafe_billing_set_updated_at
before update on public.cafe_billing
for each row
execute function public.set_updated_at();

create index if not exists idx_cafe_billing_cafe_id
on public.cafe_billing(cafe_id);


-- ============================================================
-- CAFE USAGE (one row per cafe per billing period — the
-- duplicate-charge guard)
-- ============================================================
--
-- `unique (cafe_id, billing_period_start)` is the actual mechanism that
-- makes this idempotent: stripe-generate-usage-invoice always tries to
-- INSERT a row for the period first (ON CONFLICT DO NOTHING) before
-- talking to Stripe at all, so at most one row — and therefore at most
-- one Stripe invoice — can ever exist for a given cafe+period, no matter
-- how many times that function is invoked or retried.

create table if not exists public.cafe_usage (
    id uuid primary key default gen_random_uuid(),

    cafe_id uuid not null
        references public.cafes(id)
        on delete cascade,

    billing_period_start timestamptz not null,
    billing_period_end timestamptz not null,

    -- Reconciled from calculate_cafe_usage() — never trusted from the
    -- client. Integer pence throughout; no floating-point money math.
    item_count integer not null default 0
        check (item_count >= 0),

    usage_pence integer not null default 0
        check (usage_pence >= 0),

    status text not null default 'calculated'
        check (
            status in (
                'calculated',
                'invoiced',
                'paid',
                'payment_failed'
            )
        ),

    stripe_invoice_id text,
    stripe_invoice_item_id text,

    calculated_at timestamptz not null default now(),
    invoiced_at timestamptz,
    paid_at timestamptz,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    unique (cafe_id, billing_period_start)
);

drop trigger if exists cafe_usage_set_updated_at
on public.cafe_usage;

create trigger cafe_usage_set_updated_at
before update on public.cafe_usage
for each row
execute function public.set_updated_at();

create index if not exists idx_cafe_usage_cafe_id
on public.cafe_usage(cafe_id, billing_period_start desc);

create unique index if not exists idx_cafe_usage_stripe_invoice_id
on public.cafe_usage(stripe_invoice_id)
where stripe_invoice_id is not null;


-- ============================================================
-- STRIPE WEBHOOK EVENTS (delivery idempotency ledger)
-- ============================================================
--
-- Stripe does not guarantee exactly-once webhook delivery. The webhook
-- handler inserts the event id here BEFORE doing anything else
-- (`on conflict (id) do nothing`); if the insert reports no new row,
-- this exact event was already processed, so the handler returns 200
-- immediately without touching billing state again. No RLS policies are
-- defined for this table — it is never read by client roles, only by
-- the service-role stripe-webhook function.

create table if not exists public.stripe_webhook_events (
    id text primary key,

    type text not null,

    cafe_usage_id uuid
        references public.cafe_usage(id)
        on delete set null,

    processed_at timestamptz not null default now()
);

alter table public.stripe_webhook_events enable row level security;


-- ============================================================
-- USAGE RECONCILIATION (source of truth)
-- ============================================================
--
-- Deterministic and reproducible: same cafe_id + period always yields
-- the same numbers, derived fresh from canonical orders/order_items.
-- Only counts orders with status = 'paid' — the same "genuinely
-- completed" definition analytics already uses, so draft/pending/
-- submitting/sending_to_pos/sent_to_pos/pos_failed/payment_pending/
-- payment_failed/cancelled orders are all correctly excluded (an order
-- that failed payment or was never captured never reached 'paid').
-- Charges by ITEM QUANTITY, not by line/product count — a Latte x1 +
-- Americano x2 order contributes 3, not 2.
--
-- Not reachable by client roles (see revoke below) — only by
-- service-role Edge Functions. The Flutter app never calls this
-- directly; it goes through stripe-billing-status, which enforces the
-- same cafe-scoped authorization every other admin Edge Function uses.

create or replace function public.calculate_cafe_usage(
    p_cafe_id uuid,
    p_period_start timestamptz,
    p_period_end timestamptz
)
returns table (
    item_count bigint,
    usage_pence bigint,
    usage_gbp numeric
)
language sql
stable
security definer
set search_path = public
as $$
    select
        coalesce(sum(oi.quantity), 0) as item_count,
        coalesce(sum(oi.quantity), 0) * 5 as usage_pence,
        (coalesce(sum(oi.quantity), 0) * 5 / 100.0)::numeric(12,2) as usage_gbp
    from public.orders o
    join public.order_items oi
        on oi.order_id = o.id
    where o.cafe_id = p_cafe_id
      and o.status = 'paid'
      and o.created_at >= p_period_start
      and o.created_at < p_period_end;
$$;

revoke all on function public.calculate_cafe_usage(uuid, timestamptz, timestamptz)
from public;

grant execute
on function public.calculate_cafe_usage(uuid, timestamptz, timestamptz)
to service_role;


-- ============================================================
-- BILLING PERIOD BOUNDS (Europe/London calendar month)
-- ============================================================
--
-- Documents/derives the exact billing-period convention: a half-open
-- interval [start, end) in UTC, computed from a calendar month in
-- Europe/London so British Summer Time transitions don't shift which
-- side of midnight a boundary order lands on. Every order's
-- created_at (timestamptz, i.e. an absolute instant) falls into
-- exactly one period.

create or replace function public.cafe_billing_period_bounds(
    p_month_start_date date
)
returns table (
    period_start timestamptz,
    period_end timestamptz
)
language sql
immutable
as $$
    select
        (p_month_start_date::timestamp at time zone 'Europe/London') as period_start,
        ((p_month_start_date + interval '1 month')::timestamp at time zone 'Europe/London') as period_end;
$$;

revoke all on function public.cafe_billing_period_bounds(date)
from public;

grant execute
on function public.cafe_billing_period_bounds(date)
to service_role;


-- ============================================================
-- BILLING ROW LEVEL SECURITY
-- ============================================================

alter table public.cafe_billing enable row level security;
alter table public.cafe_usage enable row level security;

drop policy if exists cafe_billing_select_own
on public.cafe_billing;

create policy cafe_billing_select_own
on public.cafe_billing
for select
to authenticated
using (
    cafe_id = public.current_cafe_id()
);

drop policy if exists cafe_usage_select_own
on public.cafe_usage;

create policy cafe_usage_select_own
on public.cafe_usage
for select
to authenticated
using (
    cafe_id = public.current_cafe_id()
);


-- ============================================================
-- BILLING COMMENTS
-- ============================================================

comment on table public.cafe_billing is
'One row per cafe: Stripe Customer + default payment method identifiers for the 5p-per-item usage charge. Never holds raw card details.';


-- ============================================================
-- REALTIME (live orders dashboard)
-- ============================================================
--
-- Lets the admin "Live Orders" screen subscribe to Postgres Changes on
-- `orders` (new orders arriving, status/completed_at changing) instead of
-- polling. RLS still applies to realtime subscriptions the same as any other
-- read: `orders_select_own` above already scopes rows to the caller's own
-- cafe_id via current_cafe_id(), so a subscriber only ever receives their own
-- cafe's rows. Wrapped in a existence check so re-running this file is safe
-- even if the table was already added via the Dashboard.
-- ============================================================

do $$
begin
    if not exists (
        select 1
        from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename = 'orders'
    ) then
        alter publication supabase_realtime add table public.orders;
    end if;
end $$;

comment on table public.cafe_usage is
'One row per cafe per monthly billing period — unique(cafe_id, billing_period_start) is what guarantees a period is never invoiced twice.';

comment on table public.stripe_webhook_events is
'Idempotency ledger for Stripe webhook deliveries — Stripe may deliver the same event more than once.';

comment on function public.calculate_cafe_usage(uuid, timestamptz, timestamptz) is
'Source of truth for billable item usage: SUM(order_items.quantity) across paid orders in the period, at 5p/item. Deterministic and reproducible from canonical orders — never trusts a client-supplied count.';