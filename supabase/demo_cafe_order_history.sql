-- ============================================================
-- BEAN & BLOOM CAFÉ — demo order-history seed / clear / reseed
-- ============================================================
--
-- Makes the Demo Café (slug = 'demo') look like a café that has been
-- trading for ~30 days, by inserting realistic rows into the SAME tables the
-- live kiosk flow writes to: public.orders, public.order_items and
-- public.order_item_modifiers. Nothing here is a fake metric — the Overview,
-- Live Orders and Analytics screens (and Stripe usage reconciliation) compute
-- everything from these rows exactly as they do for genuine orders.
--
-- Paste the WHOLE file into the Supabase Dashboard SQL Editor and run it.
-- No CLI, no Edge Functions, no Square calls, no persistent objects: it is a
-- single DO block (temp tables only) plus one read-only report query.
--
-- HOW TO USE — change ONLY `v_mode` below, then run the whole file:
--
--   'seed'    (default) insert the history. If seeded history already exists
--             this does NOTHING (no duplicates) and says so in the report.
--   'clear'   delete ONLY the seeded rows. Genuine orders are untouched.
--   'reseed'  clear + seed again. Use this to re-anchor the history to
--             today's date (the 30 days are relative to when you run it, so
--             re-run 'reseed' shortly before a demo/recording).
--
-- HOW SEEDED ROWS ARE MARKED (and therefore the ONLY rows 'clear' can touch):
--
--   orders.idempotency_key = 'demo-seed:v1:0001', 'demo-seed:v1:0002', ...
--
--   * Real kiosk orders always carry a client-generated UUID key
--     (create-order), so they can never match the prefix.
--   * unique (cafe_id, idempotency_key) makes a second seed of the same
--     rows physically impossible, even on a concurrent double-run.
--   * order_items.metadata also carries "demoSeed": true, so a stray
--     order_items query can tell seeded lines apart without a join.
--   * Seeded orders NEVER carry pos_connection_id / pos_provider /
--     external_order_id / external_payment_id / last_pos_error: no Square
--     payment or POS submission is faked, and no live payment logic can pick
--     these rows up. They are historical rows only.
--
-- WHAT IT WRITES (mirrors what create-order + create_canonical_order write):
--
--   orders: status 'paid' (plus a few 'payment_failed'/'cancelled', see
--     config), source 'voice' (the only value create-order ever writes),
--     currency 'GBP', total = sum(quantity * unit_price), completed_at set
--     for paid orders (they were handed over), order_number continuing the
--     café's own sequence after any genuine orders.
--   order_items: name = the real menu item name, unit_price = the REAL menu
--     price (basePrice + size + milk + modifier deltas, i.e. computeUnitPrice
--     in create-order), menu_item_id = the real menu_items.id,
--     metadata = {size, milk, temperature, decaf, specialRequest}.
--   order_item_modifiers: Extra shot / syrups / food add-ons, with
--     price_adjustment = 0 — exactly as create-order does, because unit_price
--     already includes them.
--
--   The menu itself is READ from public.menu_items (published + active).
--   Nothing about the menu, prices, images, auth or POS credentials is
--   modified, and only items that exist in the menu can appear in an order.
--
-- SHAPE OF THE DATA (all tunable in the CONFIG block of the DO statement):
--
--   * ~210 orders over the 30 days ending today (today only up to ~25 min
--     ago — the last 25 minutes are left empty so nothing looks in-flight).
--   * Opening hours Mon-Fri 07:30-17:00, Sat 08:30-17:00, Sun 09:00-16:00,
--     Europe/London; nothing overnight. Breakfast and lunch peaks on
--     weekdays, a late-morning brunch peak at weekends; Sat/Sun busiest.
--   * 1-5 distinct menu items per order, quantity mostly 1. Popularity is
--     weighted (Latte / Flat White / Cappuccino / Croissant lead) and shifts
--     through the day (pastries early, hot food at lunch, iced drinks later).
--   * ~5% of orders are 'payment_failed' / 'cancelled' (never in the last 36h)
--     so the payment-failure stat is believable; the rest are 'paid' and
--     already completed.
--   * TREND GUARD: the app's Analytics screen headlines "Revenue is down X%
--     vs last week" when the last 7 days trail the previous 7 by 10%+. Left
--     to pure chance a random 30 days often does that, which would put a
--     spurious warning on the demo. A generated history is therefore only
--     accepted if its week-on-week revenue is within +3%..+25%; otherwise it
--     is regenerated (up to 40 times). This shapes the trend only — every row
--     is still an ordinary order at real menu prices.
--   * Order numbers continue from the café's current maximum (like
--     next_order_number()), so they never collide with genuine orders and
--     the next genuine order carries on after them. Any genuine orders that
--     already exist keep their (lower) numbers, and each 'reseed' moves the
--     seeded block up again — cosmetic only; Live Orders sorts by time.
--
-- The Supabase SQL Editor may show a "destructive query" confirmation
-- because of the DELETEs (they are scoped to seeded rows only) — that is
-- expected; confirm and run.
--
-- KNOWN SIDE EFFECT (by design of the existing app): usage billing
--   (calculate_cafe_usage) and the Analytics screen both count status='paid'
--   orders, so seeded paid orders are counted in the Demo Café's 5p-per-item
--   usage figure for the calendar month(s) they fall in. Do not press
--   "Generate invoice" for the demo café unless you intend that.
--
-- Written against schema.sql plus the live-schema notes in
-- demo_cafe_seed.sql (menu_items.status = 'published'; orders.order_number
-- may be a GENERATED identity column — handled with OVERRIDING SYSTEM VALUE).
-- All work happens in one transaction: if anything fails (missing column,
-- check-constraint violation, ...), NOTHING is written.
-- ============================================================


do $demo_seed$
declare
    -- --------------------------------------------------------
    -- CONFIG — the only thing you normally edit is v_mode.
    -- --------------------------------------------------------
    v_mode           text    := 'seed';          -- 'seed' | 'clear' | 'reseed'

    v_cafe_slug      text    := 'demo';
    v_target_orders  int     := 210;             -- 150-250 recommended
    v_days           int     := 30;              -- history length, ending today
    v_include_today  boolean := true;            -- include today's orders up to ~25 min ago
    v_tz             text    := 'Europe/London'; -- the café's local time (matches billing periods)
    v_failed_share   numeric := 0.03;            -- share of orders that are 'payment_failed'
    v_cancel_share   numeric := 0.02;            -- share of orders that are 'cancelled'
    v_wow_min        numeric := 0.03;            -- accept the generated history only if last-7-days revenue is
    v_wow_max        numeric := 0.25;            --   within this band of the prior 7 days (see "guard" below)
    v_max_attempts   int     := 40;
    v_key_prefix     constant text := 'demo-seed:v1:';

    -- --------------------------------------------------------
    -- working state
    -- --------------------------------------------------------
    v_cafe_id        uuid;
    v_missing        text;
    v_menu_count     int;
    v_deleted_orders bigint := 0;
    v_deleted_items  bigint := 0;
    v_deleted_mods   bigint := 0;

    v_today          date;
    v_last_day       date;
    v_first_day      date;
    v_tries          int := 0;
    v_attempt        int := 0;
    v_now_local      timestamp;
    v_cutoff         timestamptz;
    v_frac           numeric;
    dc               record;
    v_cur            numeric;
    v_prior          numeric;
    v_wow            numeric;

    v_day            date;
    v_isodow         int;
    v_hour           int;
    v_min_lo         int;
    v_min_hi         int;
    v_created_at     timestamptz;

    r                record;
    v_daypart        int;
    v_order_id       uuid;
    v_status         text;
    v_completed_at   timestamptz;
    v_updated_at     timestamptz;
    v_roll           numeric;

    v_lines          int;
    v_used           uuid[];
    m                record;
    v_qty            int;
    v_price          numeric;
    v_sizes          jsonb;
    v_size_idx       int;
    v_size           text;
    v_milks          jsonb;
    v_milk           text;
    v_temp           text;
    v_decaf          boolean;
    v_request        text;
    v_mods           text[];
    v_has_syrup      boolean;
    v_mod            jsonb;
    v_mod_name       text;
    v_mod_prob       numeric;
    v_line_id        uuid;

    v_base_number    bigint;
    v_ins_orders     bigint;
    v_ins_items      bigint;
    v_ins_mods       bigint;
    v_result         text;
begin
    if v_mode not in ('seed', 'clear', 'reseed') then
        raise exception 'v_mode must be ''seed'', ''clear'' or ''reseed'' (got %)', v_mode;
    end if;
    if v_target_orders < 1 or v_days < 1 then
        raise exception 'v_target_orders and v_days must be positive';
    end if;

    -- --------------------------------------------------------
    -- Identify the Demo Café, and serialise concurrent runs.
    -- --------------------------------------------------------
    select id into v_cafe_id from public.cafes where slug = v_cafe_slug;
    if v_cafe_id is null then
        raise exception 'No café with slug % — refusing to seed anything.', v_cafe_slug;
    end if;

    perform pg_advisory_xact_lock(hashtextextended('demo-seed:' || v_cafe_id::text, 0));

    -- --------------------------------------------------------
    -- Preflight: fail loudly (before writing) if the live schema drifted.
    -- --------------------------------------------------------
    select string_agg(req.tbl || '.' || req.col, ', ')
    into v_missing
    from (values
        ('orders', 'id'), ('orders', 'cafe_id'), ('orders', 'order_number'),
        ('orders', 'status'), ('orders', 'source'), ('orders', 'total'),
        ('orders', 'currency'), ('orders', 'idempotency_key'),
        ('orders', 'completed_at'), ('orders', 'created_at'), ('orders', 'updated_at'),
        ('order_items', 'id'), ('order_items', 'order_id'), ('order_items', 'menu_item_id'),
        ('order_items', 'name'), ('order_items', 'quantity'), ('order_items', 'unit_price'),
        ('order_items', 'metadata'), ('order_items', 'created_at'), ('order_items', 'updated_at'),
        ('order_item_modifiers', 'id'), ('order_item_modifiers', 'order_item_id'),
        ('order_item_modifiers', 'name'), ('order_item_modifiers', 'price_adjustment'),
        ('order_item_modifiers', 'created_at')
    ) as req(tbl, col)
    where not exists (
        select 1
        from information_schema.columns c
        where c.table_schema = 'public'
          and c.table_name = req.tbl
          and c.column_name = req.col
    );
    if v_missing is not null then
        raise exception 'Live schema is missing expected columns: %. Nothing was written.', v_missing;
    end if;

    -- --------------------------------------------------------
    -- CLEAR — only rows whose idempotency_key carries the seed prefix.
    -- Children are deleted explicitly (not just via ON DELETE CASCADE) so
    -- this stays correct even if a live FK was created without cascade.
    -- --------------------------------------------------------
    if v_mode in ('clear', 'reseed') then
        delete from public.order_item_modifiers oim
        using public.order_items oi, public.orders o
        where oim.order_item_id = oi.id
          and oi.order_id = o.id
          and o.cafe_id = v_cafe_id
          and starts_with(o.idempotency_key, v_key_prefix);
        get diagnostics v_deleted_mods = row_count;

        delete from public.order_items oi
        using public.orders o
        where oi.order_id = o.id
          and o.cafe_id = v_cafe_id
          and starts_with(o.idempotency_key, v_key_prefix);
        get diagnostics v_deleted_items = row_count;

        delete from public.orders o
        where o.cafe_id = v_cafe_id
          and starts_with(o.idempotency_key, v_key_prefix);
        get diagnostics v_deleted_orders = row_count;
    end if;

    if v_mode = 'clear' then
        v_result := format(
            'CLEARED %s seeded orders (%s items, %s modifiers). Genuine orders untouched.',
            v_deleted_orders, v_deleted_items, v_deleted_mods
        );
        perform set_config('demo_seed.result', v_result, false);
        perform set_config('demo_seed.cafe_slug', v_cafe_slug, false);
        raise notice '%', v_result;
        return;
    end if;

    -- --------------------------------------------------------
    -- SEED — duplicate protection.
    -- --------------------------------------------------------
    if exists (
        select 1 from public.orders o
        where o.cafe_id = v_cafe_id
          and starts_with(o.idempotency_key, v_key_prefix)
    ) then
        v_result := 'SKIPPED: seeded history already exists — nothing inserted. '
                    'Set v_mode to ''reseed'' to rebuild it, or ''clear'' to remove it.';
        perform set_config('demo_seed.result', v_result, false);
        perform set_config('demo_seed.cafe_slug', v_cafe_slug, false);
        raise notice '%', v_result;
        return;
    end if;

    -- --------------------------------------------------------
    -- The menu: read from the café's real, live menu — never hard-coded.
    -- weight = relative popularity, profile = when in the day it sells.
    -- An item not listed here still sells (weight 1); an item listed here
    -- that is not on the menu is simply ignored.
    -- --------------------------------------------------------
    drop table if exists pg_temp._demo_seed_menu;
    create temp table _demo_seed_menu as
    select
        mi.id,
        mi.data->>'name'                          as name,
        mi.data                                   as data,
        (mi.data->>'basePrice')::numeric          as base_price,
        coalesce(w.weight, 1.0)                   as weight,
        coalesce(
            w.profile,
            case mi.data->>'category'
                when 'Food' then 'meal'
                when 'Cold Drinks' then 'cold'
                else 'hot'
            end
        )                                         as profile
    from public.menu_items mi
    left join (values
        ('Latte',                    14.0, 'hot'),
        ('Flat White',              12.0, 'hot'),
        ('Cappuccino',              10.0, 'hot'),
        ('Caramel Latte',            8.0, 'hot'),
        ('Americano',                6.0, 'hot'),
        ('Vanilla Latte',            5.0, 'hot'),
        ('Mocha',                    4.0, 'hot'),
        ('Espresso',                 3.0, 'hot'),
        ('Chai Latte',               3.0, 'hot'),
        ('Matcha Latte',             3.0, 'hot'),
        ('English Breakfast Tea',    3.0, 'hot'),
        ('Earl Grey Tea',            2.0, 'hot'),
        ('Iced Matcha Latte',        6.0, 'cold'),
        ('Iced Latte',               5.0, 'cold'),
        ('Iced Americano',           3.0, 'cold'),
        ('Strawberry Lemonade',      2.5, 'cold'),
        ('Sparkling Peach Iced Tea', 2.0, 'cold'),
        ('Butter Croissant',         9.0, 'pastry'),
        ('Pain au Chocolat',         5.0, 'pastry'),
        ('Blueberry Muffin',         4.0, 'pastry'),
        ('Avocado & Feta Toast',     5.0, 'meal'),
        ('Bacon & Egg Brioche',      3.5, 'breakfast'),
        ('Grilled Cheese Sandwich',  3.0, 'meal')
    ) as w(name, weight, profile)
        on lower(w.name) = lower(mi.data->>'name')
    where mi.cafe_id = v_cafe_id
      and mi.status = 'published'
      and mi.is_active
      and coalesce((mi.data->>'available')::boolean, true)
      and nullif(mi.data->>'name', '') is not null
      and nullif(mi.data->>'basePrice', '') is not null;

    select count(*) into v_menu_count from _demo_seed_menu;
    if v_menu_count = 0 then
        raise exception 'The demo café has no published, active menu items — nothing to seed.';
    end if;

    -- --------------------------------------------------------
    -- Which days, and how busy each one is.
    -- Weekday shape (Sat busiest, Mon quietest) x a gentle upward ramp so
    -- the café reads as "growing" rather than flat.
    -- --------------------------------------------------------
    v_today     := (now() at time zone v_tz)::date;
    v_last_day  := case when v_include_today then v_today else v_today - 1 end;
    v_first_day := v_last_day - (v_days - 1);
    v_cutoff    := now() - interval '25 minutes';   -- never invent an in-flight order

    -- Opening hours: Mon-Fri 07:30-17:00, Sat 08:30-17:00, Sun 09:00-16:00
    -- (last orders 15 min before close). Nothing overnight. Weights are
    -- relative order volume per hour: breakfast (8-9) and lunch (12-13)
    -- peaks on weekdays, a late-morning brunch peak at the weekend.
    drop table if exists pg_temp._demo_seed_hours;
    create temp table _demo_seed_hours as
    select * from (values
        (7,  6, 0, 0), (8, 15,  5, 0), (9, 12, 11,  8), (10,  9, 15, 14),
        (11, 9, 14, 14), (12, 15, 13, 12), (13, 13, 10, 9), (14,  7,  8,  7),
        (15, 5,  6, 3), (16,  3,  3, 0)
    ) as t(hh, wd, sat, sun);

    drop table if exists pg_temp._demo_seed_days;
    create temp table _demo_seed_days as
    select
        d.day,
        extract(isodow from d.day)::int as isodow,
        (
            case extract(isodow from d.day)::int
                when 1 then 0.85 when 2 then 0.90 when 3 then 0.95
                when 4 then 1.00 when 5 then 1.15 when 6 then 1.45
                else 1.20
            end
        ) * (0.92 + 0.16 * (d.n::numeric / greatest(v_days - 1, 1))) as w
    from (
        select n, (v_first_day + n) as day
        from generate_series(0, v_days - 1) as n
    ) d;

    -- Today is only part-way through its trading day: scale its weight by
    -- the share of today's order volume that has already happened, so the
    -- current day looks like a day in progress rather than a full one.
    v_now_local := v_cutoff at time zone v_tz;
    if v_last_day = v_today then
        if v_now_local::date < v_today then
            v_frac := 0;
        else
            select coalesce(
                sum(x.wt * greatest(0, least(1, extract(epoch from (v_now_local::time - make_time(x.hh, 0, 0))) / 3600.0)))
                / nullif(sum(x.wt), 0),
                0)
            into v_frac
            from (
                select h.hh,
                       case when extract(isodow from v_today) = 6 then h.sat
                            when extract(isodow from v_today) = 7 then h.sun
                            else h.wd end as wt
                from _demo_seed_hours h
            ) x;
        end if;
        update _demo_seed_days set w = w * v_frac where day = v_today;
    end if;

    -- Deterministic shape between runs (the dates themselves are relative
    -- to "today", so a later reseed is re-anchored, not identical).
    perform setseed(0.4242);

    -- Staging tables, refilled on every attempt below.
    drop table if exists pg_temp._demo_seed_slots;
    create temp table _demo_seed_slots (created_at timestamptz not null);

    drop table if exists pg_temp._demo_seed_orders;
    create temp table _demo_seed_orders (
        id           uuid primary key,
        n            int  not null,
        created_at   timestamptz not null,
        status       text not null,
        completed_at timestamptz,
        updated_at   timestamptz not null
    );

    drop table if exists pg_temp._demo_seed_lines;
    create temp table _demo_seed_lines (
        id           uuid primary key,
        order_id     uuid not null,
        menu_item_id uuid not null,
        name         text not null,
        quantity     int  not null,
        unit_price   numeric(12,2) not null,
        metadata     jsonb not null,
        mods         text[] not null
    );

    -- ========================================================
    -- GENERATE (with a sanity guard).
    --
    -- Left completely to chance, a random 30 days can by pure noise put the
    -- last week 20%+ below the one before it, and the app's own analytics
    -- would then headline "Revenue is down X% vs last week" on the demo
    -- café. So a generated history is only accepted if its last-7-days
    -- revenue is within [v_wow_min, v_wow_max] of the prior 7 days;
    -- otherwise it is regenerated from the continuing random stream (still
    -- fully deterministic for a given day). This shapes the trend only —
    -- every row is still an ordinary order with real menu prices.
    -- ========================================================
    loop
        v_attempt := v_attempt + 1;
        truncate _demo_seed_slots, _demo_seed_orders, _demo_seed_lines;

        -- ----------------------------------------------------
        -- Phase 1 — how many orders each day gets, then when.
        -- Day counts are stratified (expected share +/- 12% noise, remainder
        -- allocated by largest fraction) instead of drawn independently,
        -- which keeps the total exactly v_target_orders and day-to-day
        -- variation believable rather than wild.
        -- ----------------------------------------------------
        for dc in
            with noisy as materialized (
                select d.day, d.isodow, d.w * (0.88 + 0.24 * random()) as nw
                from _demo_seed_days d
            ),
            expected as materialized (
                select n.day, n.isodow,
                       v_target_orders * n.nw / nullif(sum(n.nw) over (), 0) as e
                from noisy n
            ),
            base as materialized (
                select e.day, e.isodow, floor(e.e)::int as b, e.e - floor(e.e) as f
                from expected e
            )
            select b.day, b.isodow,
                   b.b + case
                       when row_number() over (order by b.f desc, b.day)
                            <= v_target_orders - sum(b.b) over ()
                       then 1 else 0
                   end as cnt
            from base b
            order by b.day
        loop
            for i in 1..dc.cnt loop
                v_tries := 0;
                loop
                    v_tries := v_tries + 1;
                    exit when v_tries > 500;   -- can only happen for a barely-started "today"

                    select t.hh into v_hour
                    from _demo_seed_hours t
                    where (case when dc.isodow = 6 then t.sat when dc.isodow = 7 then t.sun else t.wd end) > 0
                    order by -ln(1 - random()) /
                             (case when dc.isodow = 6 then t.sat when dc.isodow = 7 then t.sun else t.wd end)
                    limit 1;

                    v_min_lo := case when (dc.isodow <= 5 and v_hour = 7) or (dc.isodow = 6 and v_hour = 8) then 30 else 0 end;
                    v_min_hi := case when (dc.isodow <= 6 and v_hour = 16) or (dc.isodow = 7 and v_hour = 15) then 45 else 60 end;

                    v_created_at := (
                        (dc.day + make_time(
                            v_hour,
                            v_min_lo + floor(random() * (v_min_hi - v_min_lo))::int,
                            floor(random() * 60)::double precision
                        ))::timestamp
                    ) at time zone v_tz;

                    if v_created_at <= v_cutoff then
                        insert into _demo_seed_slots (created_at) values (v_created_at);
                        exit;
                    end if;
                end loop;
            end loop;
        end loop;

        -- ----------------------------------------------------
        -- Phase 2 — build each order's lines (staged in temp tables).
        -- ----------------------------------------------------
        for r in
            select s.created_at, row_number() over (order by s.created_at) as n
            from _demo_seed_slots s
            order by s.created_at
        loop
            v_order_id := gen_random_uuid();

            -- local hour -> daypart: 1 morning (<11), 2 midday (11-14), 3 afternoon
            v_hour := extract(hour from r.created_at at time zone v_tz)::int;
            v_daypart := case when v_hour < 11 then 1 when v_hour < 14 then 2 else 3 end;

            -- Status: overwhelmingly paid. A few failed/cancelled orders make the
            -- payment-failure stat believable — but the last 36 hours are always
            -- clean so the "recent orders" a demo opens on look healthy.
            v_roll := random();
            if r.created_at > now() - interval '36 hours' then
                v_status := 'paid';
            elsif v_roll < v_failed_share then
                v_status := 'payment_failed';
            elsif v_roll < v_failed_share + v_cancel_share then
                v_status := 'cancelled';
            else
                v_status := 'paid';
            end if;

            if v_status = 'paid' then
                -- made and handed over 3-10 minutes later
                v_completed_at := r.created_at + make_interval(secs => (180 + floor(random() * 420))::int);
                v_updated_at   := v_completed_at;
            else
                v_completed_at := null;
                v_updated_at   := r.created_at + make_interval(secs => (45 + floor(random() * 90))::int);
            end if;

            insert into _demo_seed_orders (id, n, created_at, status, completed_at, updated_at)
            values (v_order_id, r.n::int, r.created_at, v_status, v_completed_at, v_updated_at);

            -- 1-5 distinct menu items per order (mostly 1-2).
            v_roll := random();
            v_lines := case
                when v_roll < 0.40 then 1
                when v_roll < 0.75 then 2
                when v_roll < 0.90 then 3
                when v_roll < 0.97 then 4
                else 5
            end;
            v_used := '{}'::uuid[];

            for i in 1..v_lines loop
                -- Popularity x time-of-day weighting (pastries in the morning,
                -- hot meals at lunch, cold drinks in the afternoon, ...).
                select * into m
                from _demo_seed_menu x
                where not (x.id = any (v_used))
                order by -ln(1 - random()) / (
                    x.weight * case x.profile
                        when 'hot'       then case v_daypart when 1 then 1.3 when 2 then 1.0 else 0.8 end
                        when 'cold'      then case v_daypart when 1 then 0.6 when 2 then 1.3 else 1.5 end
                        when 'pastry'    then case v_daypart when 1 then 1.6 when 2 then 0.6 else 0.8 end
                        when 'breakfast' then case v_daypart when 1 then 2.2 when 2 then 0.6 else 0.2 end
                        else                  case v_daypart when 1 then 0.5 when 2 then 2.2 else 1.0 end
                    end
                )
                limit 1;
                exit when not found;
                v_used := v_used || m.id;

                v_price := m.base_price;

                -- size (Regular 70% / Large 30%) — only if the item has sizes
                v_size := null;
                v_sizes := m.data->'sizes';
                if jsonb_typeof(v_sizes) = 'array' and jsonb_array_length(v_sizes) > 0 then
                    v_size_idx := case when random() < 0.70 then 0 else jsonb_array_length(v_sizes) - 1 end;
                    v_size  := v_sizes->v_size_idx->>'name';
                    v_price := v_price + coalesce((v_sizes->v_size_idx->>'priceDelta')::numeric, 0);
                end if;

                -- milk (dairy 55 / oat 27 / almond 10 / soy 8) — only if the item has milk options
                v_milk := null;
                v_milks := m.data->'milkOptions';
                if jsonb_typeof(v_milks) = 'array' and jsonb_array_length(v_milks) > 0 then
                    select o->>'name', v_price + coalesce((o->>'priceDelta')::numeric, 0)
                    into v_milk, v_price
                    from jsonb_array_elements(v_milks) o
                    order by -ln(1 - random()) / (
                        case lower(o->>'name')
                            when 'dairy' then 55 when 'oat' then 27
                            when 'almond' then 10 when 'soy' then 8 else 5
                        end
                    )
                    limit 1;
                end if;

                -- temperature: the item's own (single) option, as the kiosk sends it
                v_temp := case
                    when jsonb_typeof(m.data->'temperatureOptions') = 'array'
                         and jsonb_array_length(m.data->'temperatureOptions') > 0
                    then m.data->'temperatureOptions'->>0
                    else null
                end;

                -- decaf: 7% of orders on items that offer it
                v_decaf := coalesce((m.data->>'decafAvailable')::boolean, false) and random() < 0.07;

                -- modifiers (extra shot / one syrup / food add-ons), max 2 per line
                v_mods := '{}'::text[];
                v_has_syrup := false;
                if jsonb_typeof(m.data->'modifiers') = 'array' then
                    for v_mod in select value from jsonb_array_elements(m.data->'modifiers') loop
                        exit when cardinality(v_mods) >= 2;
                        v_mod_name := v_mod->>'name';
                        if v_mod_name is null then continue; end if;
                        if lower(v_mod_name) like '%syrup%' and v_has_syrup then continue; end if;

                        v_mod_prob := case
                            when lower(v_mod_name) = 'extra shot'      then 0.10
                            when lower(v_mod_name) like '%syrup%'      then 0.06
                            when lower(v_mod_name) = 'add egg'         then 0.25
                            when lower(v_mod_name) = 'add bacon'       then 0.15
                            when lower(v_mod_name) = 'add cheese'      then 0.15
                            else 0.08
                        end;

                        if random() < v_mod_prob then
                            v_mods  := v_mods || v_mod_name;
                            v_price := v_price + coalesce((v_mod->>'priceDelta')::numeric, 0);
                            if lower(v_mod_name) like '%syrup%' then v_has_syrup := true; end if;
                        end if;
                    end loop;
                end if;

                -- the occasional free-text request
                v_request := null;
                if random() < 0.04 then
                    v_request := case m.profile
                        when 'hot'  then 'Extra hot'
                        when 'cold' then 'Light ice'
                        else 'Warmed through please'
                    end;
                end if;

                -- quantity: mostly 1, sometimes 2, rarely 3 (bigger orders skew to 1)
                v_roll := random();
                v_qty := case
                    when v_roll < (case when v_lines >= 3 then 0.93 else 0.82 end) then 1
                    when v_roll < (case when v_lines >= 3 then 0.98 else 0.96 end) then 2
                    else 3
                end;

                v_line_id := gen_random_uuid();
                insert into _demo_seed_lines (id, order_id, menu_item_id, name, quantity, unit_price, metadata, mods)
                values (
                    v_line_id, v_order_id, m.id, m.name, v_qty, round(v_price, 2),
                    jsonb_build_object(
                        'size', v_size,
                        'milk', v_milk,
                        'temperature', v_temp,
                        'decaf', v_decaf,
                        'specialRequest', v_request,
                        'demoSeed', true
                    ),
                    v_mods
                );
            end loop;
        end loop;

        -- ----------------------------------------------------
        -- Guard: is this history's weekly trend acceptable?
        -- Same windows as AnalyticsInsights (yesterday back 7 days vs the 7
        -- before that), paid orders only.
        -- ----------------------------------------------------
        select
            coalesce(sum(t.total) filter (where t.d >= v_today - 7  and t.d < v_today), 0),
            coalesce(sum(t.total) filter (where t.d >= v_today - 14 and t.d < v_today - 7), 0)
        into v_cur, v_prior
        from (
            select (o.created_at at time zone v_tz)::date as d,
                   sum(l.quantity * l.unit_price) as total
            from _demo_seed_orders o
            join _demo_seed_lines l on l.order_id = o.id
            where o.status = 'paid'
            group by o.id, o.created_at
        ) t;

        v_wow := case when v_prior > 0 then (v_cur - v_prior) / v_prior else null end;
        exit when v_wow is null                       -- history too short to compare: nothing to guard
               or v_wow between v_wow_min and v_wow_max
               or v_attempt >= v_max_attempts;
    end loop;

    if v_wow is not null and v_wow not between v_wow_min and v_wow_max then
        raise notice 'Weekly trend guard gave up after % attempts (last week vs prior: %%%); keeping the last attempt.',
            v_attempt, round(v_wow * 100, 1);
    end if;

    -- --------------------------------------------------------
    -- Phase 3 — write to the real tables (set-based, one pass each).
    -- Order numbers continue the café's own per-cafe sequence
    -- (max + 1, like next_order_number()), so they never collide with
    -- genuine orders, and the next genuine order simply carries on after.
    -- --------------------------------------------------------
    select coalesce(max(o.order_number), 0) into v_base_number
    from public.orders o
    where o.cafe_id = v_cafe_id;

    insert into public.orders (
        id, cafe_id, order_number, status, source, total, currency,
        idempotency_key, completed_at, created_at, updated_at
    ) overriding system value
    select
        o.id,
        v_cafe_id,
        v_base_number + o.n,
        o.status,
        'voice',
        coalesce(t.total, 0),
        'GBP',
        v_key_prefix || lpad(o.n::text, 4, '0'),
        o.completed_at,
        o.created_at,
        o.updated_at
    from _demo_seed_orders o
    left join (
        select l.order_id, sum(l.quantity * l.unit_price) as total
        from _demo_seed_lines l
        group by l.order_id
    ) t on t.order_id = o.id
    order by o.n;
    get diagnostics v_ins_orders = row_count;

    insert into public.order_items (
        id, order_id, menu_item_id, name, quantity, unit_price, metadata,
        created_at, updated_at
    )
    select l.id, l.order_id, l.menu_item_id, l.name, l.quantity, l.unit_price, l.metadata,
           o.created_at, o.created_at
    from _demo_seed_lines l
    join _demo_seed_orders o on o.id = l.order_id;
    get diagnostics v_ins_items = row_count;

    insert into public.order_item_modifiers (order_item_id, name, price_adjustment, created_at)
    select l.id, mod_name, 0, o.created_at
    from _demo_seed_lines l
    join _demo_seed_orders o on o.id = l.order_id
    cross join lateral unnest(l.mods) as mod_name;
    get diagnostics v_ins_mods = row_count;

    drop table if exists pg_temp._demo_seed_lines;
    drop table if exists pg_temp._demo_seed_orders;
    drop table if exists pg_temp._demo_seed_slots;
    drop table if exists pg_temp._demo_seed_days;
    drop table if exists pg_temp._demo_seed_menu;

    v_result := format(
        '%s: inserted %s orders, %s order lines, %s modifiers (%s..%s). Seeded week-on-week revenue: %s. %sGenuine orders untouched.',
        case when v_mode = 'reseed' then 'RESEEDED' else 'SEEDED' end,
        v_ins_orders, v_ins_items, v_ins_mods, v_first_day, v_last_day,
        case when v_wow is null then 'n/a' else to_char(v_wow * 100, 'FM990.0') || '%' end,
        case when v_mode = 'reseed'
             then format('Removed %s previously seeded orders first. ', v_deleted_orders)
             else '' end
    );
    perform set_config('demo_seed.result', v_result, false);
    perform set_config('demo_seed.cafe_slug', v_cafe_slug, false);
    raise notice '%', v_result;
end
$demo_seed$;


-- ============================================================
-- REPORT — read-only. Shows what the run did and what the database
-- now holds, split into seeded history vs genuine orders.
-- ============================================================

select
    current_setting('demo_seed.result', true)                                         as result,
    count(*) filter (where s.is_seed)                                                 as seeded_orders,
    count(*) filter (where s.is_seed and o.status = 'paid')                           as seeded_paid_orders,
    count(*) filter (where s.is_seed and o.status <> 'paid')                          as seeded_unpaid_orders,
    (select count(*) from public.order_items oi
       join public.orders so on so.id = oi.order_id
      where so.cafe_id = c.id and starts_with(so.idempotency_key, 'demo-seed:'))      as seeded_order_lines,
    (select coalesce(sum(oi.quantity), 0) from public.order_items oi
       join public.orders so on so.id = oi.order_id
      where so.cafe_id = c.id and starts_with(so.idempotency_key, 'demo-seed:'))      as seeded_units,
    (select count(*) from public.order_item_modifiers m
       join public.order_items oi on oi.id = m.order_item_id
       join public.orders so on so.id = oi.order_id
      where so.cafe_id = c.id and starts_with(so.idempotency_key, 'demo-seed:'))      as seeded_modifiers,
    coalesce(sum(o.total) filter (where s.is_seed and o.status = 'paid'), 0)          as seeded_paid_revenue_gbp,
    min(o.created_at) filter (where s.is_seed)                                        as seeded_first_order_at,
    max(o.created_at) filter (where s.is_seed)                                        as seeded_last_order_at,
    count(*) filter (where not s.is_seed)                                             as genuine_orders,
    max(o.created_at) filter (where not s.is_seed)                                    as genuine_latest_order_at
from public.cafes c
left join public.orders o on o.cafe_id = c.id
left join lateral (
    select starts_with(coalesce(o.idempotency_key, ''), 'demo-seed:') as is_seed
) s on true
where c.slug = coalesce(current_setting('demo_seed.cafe_slug', true), 'demo')
group by c.id;
