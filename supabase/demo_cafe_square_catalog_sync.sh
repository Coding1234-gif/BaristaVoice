#!/usr/bin/env bash
# ============================================================
# BEAN & BLOOM CAFÉ — push menu to Square Sandbox, then pull it back
# ============================================================
#
# menu-square-sync and pos-square-sync both require a real cafe_admin (or
# super_admin) session — neither has a trusted-service-role-key bypass like
# create-order/pos-square-order-submit do. So this signs in as the demo
# admin first to get a real access token, then calls both functions with it.
#
# Export the four variables below, then run:
#   SUPABASE_URL=... ANON_KEY=... EMAIL=... PASSWORD=... bash supabase/demo_cafe_square_catalog_sync.sh
# ============================================================
set -euo pipefail

# Credentials come from the environment — nothing secret lives in this file.
: "${SUPABASE_URL:?Set SUPABASE_URL, e.g. https://<project-ref>.supabase.co}"
: "${ANON_KEY:?Set ANON_KEY to your projects publishable or anon key}"
: "${EMAIL:?Set EMAIL to the demo admin email}"
: "${PASSWORD:?Set PASSWORD to the demo admin password}"

# Bean & Bloom's Square sandbox pos_connections.id (from earlier setup).
CONNECTION_ID="59bc9095-2cb0-4380-bec8-afe14cba9da1"

echo "Signing in as $EMAIL..."
ACCESS_TOKEN=$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

if [ -z "$ACCESS_TOKEN" ]; then
  echo "Could not sign in — check EMAIL/PASSWORD/ANON_KEY above." >&2
  exit 1
fi
echo "Signed in."

echo ""
echo "== menu-square-sync (BaristaVoice menu -> Square catalog) =="
curl -s -X POST "$SUPABASE_URL/functions/v1/menu-square-sync" \
  -H "Authorization: Bearer $ACCESS_TOKEN" -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"connectionId\":\"$CONNECTION_ID\"}"
echo ""

echo ""
echo "== pos-square-sync (Square catalog -> pos_products/pos_modifiers) =="
curl -s -X POST "$SUPABASE_URL/functions/v1/pos-square-sync" \
  -H "Authorization: Bearer $ACCESS_TOKEN" -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"connectionId\":\"$CONNECTION_ID\"}"
echo ""

echo ""
echo "Both done. Next: run supabase/demo_cafe_pos_mapping.sql in the SQL Editor to create the menu_item <-> pos_product mappings (no UI does this today)."
