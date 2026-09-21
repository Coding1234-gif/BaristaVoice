-- ============================================================
-- BEAN & BLOOM CAFÉ — demo admin account + Square sandbox setup
-- ============================================================
--
-- Run each step IN ORDER, filling in the placeholders as you go. This is a
-- guided script, not a blind paste-and-run — steps 2/3/5/6 need a value
-- copied from the previous step's result.
-- ============================================================


-- ============================================================
-- PART A — link a dedicated admin account to Bean & Bloom
-- ============================================================
--
-- create_cafe_admin_account() always provisions a BRAND NEW café — it can't
-- attach to an existing one. So: sign up normally through the app's real
-- "New café? Create an account" flow first (any throwaway café name, e.g.
-- "temp"), using the email/password you want judges to log in with. Then
-- come back here.
-- ============================================================

-- STEP A1 — find your new admin's user id and their auto-created throwaway
-- café id (note BOTH values down before continuing):
select
    p.id as user_id,
    p.cafe_id as throwaway_cafe_id,
    c.name as throwaway_cafe_name
from public.profiles p
join public.cafes c on c.id = p.cafe_id
where p.id = (select id from auth.users where email = 'baristavoice.demo@gmail.com');


-- STEP A2 — point that admin at Bean & Bloom instead of their throwaway café
-- (replace <user_id> with the value from STEP A1):

-- CORRECTED 2026-09-19: this used to be `update public.cafe_admins ...`, which
-- silently matched ZERO rows — create_cafe_admin_account() (the signup RPC)
-- inserts into cafes + profiles only, never cafe_admins, so there was no row
-- to update. current_cafe_id(), which most RLS policies rely on, reads
-- cafe_admins, so the demo admin had no café as far as those policies were
-- concerned. Insert the link if it's missing instead.
insert into public.cafe_admins (cafe_id, user_id, role)
select c.id, 'af43626d-42a9-4e0e-b82c-06b22522d4a1'::uuid, 'owner'
from public.cafes c
where c.slug = 'demo'
  and not exists (
      select 1 from public.cafe_admins ca
      where ca.cafe_id = c.id and ca.user_id = 'af43626d-42a9-4e0e-b82c-06b22522d4a1'::uuid
  );

update public.profiles
set cafe_id = (select id from public.cafes where slug = 'demo')
where id = 'af43626d-42a9-4e0e-b82c-06b22522d4a1';


-- STEP A3 — delete the now-orphaned throwaway café (replace
-- <throwaway_cafe_id> with the value from STEP A1 — NOT the demo café's id):

delete from public.cafes where id = '0e601b13-cb01-47eb-8fb7-cfe09dc27e80';


-- ============================================================
-- PART B — connect Square Sandbox so kiosk orders can reach 'paid'
-- ============================================================
--
-- Prerequisite: an Edge Function secret SQUARE_ENVIRONMENT should be either
-- unset (defaults to "sandbox") or explicitly "sandbox" — check under
-- Edge Functions -> Secrets in the dashboard. If it's set to "production",
-- change it to "sandbox" for the demo.
--
-- From your Square Developer Dashboard (developer.squareup.com/apps) ->
-- your app -> Sandbox tab, grab:
--   - Sandbox Access Token
--   - Sandbox Location ID (a default sandbox location already exists)
-- No device id is needed — pos-square-terminal-checkout already hardcodes
-- Square's known sandbox simulated-Terminal device id and uses it
-- automatically.
-- ============================================================

-- STEP B1 — store the raw access token in Vault (never store it in a plain
-- column). Note the returned uuid:

select vault.create_secret(
    '<your Square sandbox access token>',
    'square-sandbox-bean-and-bloom',
    'Square sandbox access token for the Bean & Bloom demo cafe'
) as access_token_secret_id;


-- STEP B2 — create the pos_connections row (replace <location_id> and
-- <access_token_secret_id> with your values from above). status must be
-- 'active' — confirmed via introspection; schema.sql's 'connected' default
-- is stale and was never actually a valid live value:

insert into public.pos_connections (cafe_id, provider, location_id, status, access_token_secret_id)
values (
    (select id from public.cafes where slug = 'demo'),
    'square',
    'LHJX9729JDV2V',
    'active',
    'ee1aa1c3-1e78-4df1-aedd-890e87885f53'
);


-- STEP B3 — sanity check:

select id, provider, location_id, status
from public.pos_connections
where cafe_id = (select id from public.cafes where slug = 'demo');
-- expect one row, status = 'active'
