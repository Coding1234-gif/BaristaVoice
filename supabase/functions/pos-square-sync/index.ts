// Supabase Edge Function: pos-square-sync
//
// Square → BaristaVoice catalog sync. Pulls one café's Square catalog
// (items/variations + modifier lists/modifiers), normalizes it into this
// project's provider-independent pos_products/pos_modifiers shape, and
// upserts it. Scope is deliberately narrow: this function ONLY reads from
// Square and writes pos_products/pos_modifiers + pos_connections' status
// fields. It never touches menu_items, never creates/submits an order, and
// never handles Lightspeed/Epos Now/any other provider.
//
// Security model (same shape as menu-extractor):
// - The caller's identity comes from verifying their JWT via
//   supabase.auth.getUser(), never from a client-supplied user/cafe id.
// - The target pos_connections row (and therefore its cafe_id) is looked up
//   server-side with the service-role key, and the caller's own
//   profile.cafe_id is checked against it (see authorizeConnectionAccess) —
//   a cafe_admin can never sync another café's POS connection, no matter
//   what connectionId they pass in. super_admin may sync any café's.
// - The Square access token is never read by, or returned to, the client.
//   It's resolved server-side from Supabase Vault (via a service-role
//   client scoped to the `vault` schema) and used only as an outbound
//   Authorization header to Square — it never appears in a response body or
//   a log line.
//
// Inlined (rather than imported from a shared module) so this file is
// self-contained and can be pasted directly into the Supabase Dashboard's
// Edge Function editor, matching order-agent/tts-speak/menu-extractor.
import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// This function's deployment talks to exactly one Square environment for
// every café it syncs (matches how LLM_PROVIDER is already a single
// project-wide manual switch, not a per-row setting) — pos_connections has
// no "environment" column, and adding one isn't needed: a sandbox access
// token simply fails against the production host and vice versa, so the
// wrong setting fails loudly rather than silently.
const SQUARE_ENVIRONMENT = (Deno.env.get("SQUARE_ENVIRONMENT") ?? "sandbox") as "sandbox" | "production";
const SQUARE_VERSION = Deno.env.get("SQUARE_VERSION") ?? "2024-10-17";
const SQUARE_BASE_URL = SQUARE_ENVIRONMENT === "production"
  ? "https://connect.squareup.com"
  : "https://connect.squareupsandbox.com";

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// Square catalog types (only the fields this function reads).
// ---------------------------------------------------------------------------

interface SquareMoney {
  amount?: number; // integer minor units (cents)
  currency?: string;
}

interface SquareCatalogObject {
  type: string;
  id: string;
  updated_at?: string;
  is_deleted?: boolean;
  item_data?: {
    name?: string;
    category_id?: string;
    variations?: SquareCatalogObject[];
  };
  item_variation_data?: {
    name?: string;
    price_money?: SquareMoney;
  };
  category_data?: {
    name?: string;
  };
  modifier_list_data?: {
    name?: string;
    modifiers?: SquareCatalogObject[];
  };
  modifier_data?: {
    name?: string;
    price_money?: SquareMoney;
  };
}

interface SquareCatalogListResponse {
  objects?: SquareCatalogObject[];
  cursor?: string;
}

/** Thrown for a non-2xx response from Square's own API, as opposed to a
 * local/DB error — lets the handler report a distinct status and message. */
export class SquareApiError extends Error {
  readonly status: number;
  readonly detail: string;
  constructor(message: string, status: number, detail: string) {
    super(message);
    this.name = "SquareApiError";
    this.status = status;
    this.detail = detail;
  }
}

// ---------------------------------------------------------------------------
// Provider-independent normalized shape (mirrors pos_products/pos_modifiers
// columns) — see the POS adapter architecture this implements.
// ---------------------------------------------------------------------------

export interface NormalizedProduct {
  externalProductId: string;
  name: string;
  category: string | null;
  price: number | null; // decimal dollars, matches numeric(12,2)
  active: boolean;
  metadata: Record<string, unknown>;
  externalUpdatedAt: string | null;
}

export interface NormalizedModifier {
  externalModifierId: string;
  name: string;
  priceAdjustment: number;
  active: boolean;
  metadata: Record<string, unknown>;
  externalUpdatedAt: string | null;
}

/** Square prices are integer cents; pos_products/pos_modifiers store decimal
 * dollars (numeric(12,2)). `null`/`undefined` means "no price set" and is
 * preserved as null rather than coerced to 0 — those are different facts. */
export function centsToDecimal(amount: number | null | undefined): number | null {
  if (amount === null || amount === undefined || !Number.isFinite(amount)) return null;
  return Math.round(amount) / 100;
}

/** Flattens Square's nested catalog (ITEM -> variations, MODIFIER_LIST ->
 * modifiers) into the flat product/modifier rows this project stores. This
 * is the ONLY place that understands Square's catalog shape — everything
 * downstream of this function deals exclusively in the normalized shape.
 *
 * One pos_products row per purchasable ITEM_VARIATION (Square has no
 * standalone price at the ITEM level), named "<item> - <variation>" when an
 * item has more than one variation (e.g. sizes) and just "<item>" when it
 * has exactly one (Square still models a single-size item as one variation
 * named e.g. "Regular"). One pos_modifiers row per MODIFIER (not per
 * MODIFIER_LIST, which has no price of its own).
 *
 * Deleted objects are skipped defensively even though Square's list API
 * shouldn't return them by default — cheap insurance against a future
 * `include_deleted_objects=true` caller.
 */
export function normalizeCatalogObjects(
  objects: SquareCatalogObject[],
): { products: NormalizedProduct[]; modifiers: NormalizedModifier[] } {
  const categoryNames = new Map<string, string>();
  for (const obj of objects) {
    if (obj.type === "CATEGORY" && !obj.is_deleted && obj.category_data?.name) {
      categoryNames.set(obj.id, obj.category_data.name);
    }
  }

  const products: NormalizedProduct[] = [];
  for (const obj of objects) {
    if (obj.type !== "ITEM" || obj.is_deleted || !obj.item_data) continue;

    const itemData = obj.item_data;
    const itemName = itemData.name?.trim() || "Untitled item";
    const category = itemData.category_id
      ? categoryNames.get(itemData.category_id) ?? null
      : null;
    const variations = (itemData.variations ?? []).filter(
      (v) => v.type === "ITEM_VARIATION" && !v.is_deleted && v.item_variation_data,
    );

    for (const variation of variations) {
      const variationData = variation.item_variation_data!;
      const variationName = variationData.name?.trim() || null;
      const name = variationName && variations.length > 1
        ? `${itemName} - ${variationName}`
        : itemName;

      products.push({
        externalProductId: variation.id,
        name,
        category,
        price: centsToDecimal(variationData.price_money?.amount),
        active: true,
        metadata: {
          squareItemId: obj.id,
          squareVariationId: variation.id,
          itemName,
          variationName,
        },
        externalUpdatedAt: variation.updated_at ?? obj.updated_at ?? null,
      });
    }
  }

  const modifiers: NormalizedModifier[] = [];
  for (const obj of objects) {
    if (obj.type !== "MODIFIER_LIST" || obj.is_deleted || !obj.modifier_list_data) continue;

    const listData = obj.modifier_list_data;
    for (const modifier of listData.modifiers ?? []) {
      if (modifier.type !== "MODIFIER" || modifier.is_deleted || !modifier.modifier_data) continue;

      const modifierData = modifier.modifier_data;
      modifiers.push({
        externalModifierId: modifier.id,
        name: modifierData.name?.trim() || "Untitled modifier",
        priceAdjustment: centsToDecimal(modifierData.price_money?.amount) ?? 0,
        active: true,
        metadata: {
          squareModifierListId: obj.id,
          modifierListName: listData.name ?? null,
        },
        externalUpdatedAt: modifier.updated_at ?? obj.updated_at ?? null,
      });
    }
  }

  return { products, modifiers };
}

/** Fetches every page of Square's catalog before returning anything. If any
 * page fails, this throws instead of returning a partial list — the caller
 * (below) never sees, and therefore never writes, a half-synced catalog. */
export async function fetchAllCatalogObjects(params: {
  accessToken: string;
  baseUrl: string;
  squareVersion: string;
  fetchImpl?: typeof fetch;
}): Promise<SquareCatalogObject[]> {
  const doFetch = params.fetchImpl ?? fetch;
  const all: SquareCatalogObject[] = [];
  let cursor: string | undefined;

  do {
    const url = new URL(`${params.baseUrl}/v2/catalog/list`);
    url.searchParams.set("types", "ITEM,CATEGORY,MODIFIER_LIST");
    if (cursor) url.searchParams.set("cursor", cursor);

    const res = await doFetch(url.toString(), {
      method: "GET",
      headers: {
        "Authorization": `Bearer ${params.accessToken}`,
        "Square-Version": params.squareVersion,
      },
    });

    if (!res.ok) {
      const text = await res.text().catch(() => "");
      throw new SquareApiError(
        `Square catalog list failed: ${res.status}`,
        res.status,
        text.slice(0, 500),
      );
    }

    const body = await res.json() as SquareCatalogListResponse;
    all.push(...(body.objects ?? []));
    cursor = body.cursor || undefined;
  } while (cursor);

  return all;
}

// ---------------------------------------------------------------------------
// Authorization — respects the existing cafe_admin/current_cafe_id model.
// Pure decision function so the boundary can be unit tested without a DB.
// ---------------------------------------------------------------------------

export function authorizeConnectionAccess(
  profile: { role: string; cafeId: string | null },
  connectionCafeId: string,
): { allowed: boolean; reason?: string } {
  if (profile.role === "super_admin") return { allowed: true };
  if (profile.role === "cafe_admin") {
    if (profile.cafeId === connectionCafeId) return { allowed: true };
    return { allowed: false, reason: "You do not have access to this POS connection." };
  }
  return { allowed: false, reason: "Only cafe admins can trigger POS catalog sync." };
}

// ---------------------------------------------------------------------------
// DB row shaping. Deliberately omits `id` — pos_products/pos_modifiers are
// upserted on their (pos_connection_id, external_*_id) unique index, so the
// same Square object always resolves to the same row (its DB-generated id
// never changes across re-syncs) rather than inserting a duplicate.
// ---------------------------------------------------------------------------

export function buildProductRows(
  connectionId: string,
  cafeId: string,
  products: NormalizedProduct[],
  syncedAt: string,
) {
  return products.map((p) => ({
    cafe_id: cafeId,
    pos_connection_id: connectionId,
    external_product_id: p.externalProductId,
    name: p.name,
    category: p.category,
    price: p.price,
    active: p.active,
    metadata: p.metadata,
    external_updated_at: p.externalUpdatedAt,
    last_synced_at: syncedAt,
  }));
}

export function buildModifierRows(
  connectionId: string,
  cafeId: string,
  modifiers: NormalizedModifier[],
  syncedAt: string,
) {
  return modifiers.map((m) => ({
    cafe_id: cafeId,
    pos_connection_id: connectionId,
    external_modifier_id: m.externalModifierId,
    name: m.name,
    price_adjustment: m.priceAdjustment,
    active: m.active,
    metadata: m.metadata,
    external_updated_at: m.externalUpdatedAt,
    last_synced_at: syncedAt,
  }));
}

// ---------------------------------------------------------------------------
// Request handler
// ---------------------------------------------------------------------------

interface RequestBody {
  connectionId: string;
}

export async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return jsonResponse({ error: "Missing Authorization header." }, 401);
  }

  try {
    const { connectionId } = (await req.json()) as RequestBody;
    if (!connectionId) return jsonResponse({ error: "connectionId is required." }, 400);

    // Verify the caller's identity from their JWT (never trust a
    // client-supplied user/cafe id).
    const callerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userError } = await callerClient.auth.getUser();
    if (userError || !userData.user) {
      return jsonResponse({ error: "Invalid or expired session." }, 401);
    }

    // Service-role client for the privileged lookups/writes below. Every
    // authorization decision past this point is made from data fetched
    // ourselves — never from anything the client sent.
    const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    const { data: profile } = await adminClient
      .from("profiles")
      .select("role, cafe_id")
      .eq("id", userData.user.id)
      .maybeSingle();

    if (!profile || (profile.role !== "cafe_admin" && profile.role !== "super_admin")) {
      return jsonResponse({ error: "Only cafe admins can trigger POS catalog sync." }, 403);
    }

    const { data: connection, error: connectionError } = await adminClient
      .from("pos_connections")
      .select("id, cafe_id, provider, status, access_token_secret_id, token_expires_at")
      .eq("id", connectionId)
      .maybeSingle();

    if (connectionError || !connection) {
      return jsonResponse({ error: "POS connection not found." }, 404);
    }

    const authz = authorizeConnectionAccess(
      { role: profile.role as string, cafeId: profile.cafe_id as string | null },
      connection.cafe_id as string,
    );
    if (!authz.allowed) {
      return jsonResponse({ error: authz.reason }, 403);
    }

    if (connection.provider !== "square") {
      return jsonResponse(
        { error: `This function only syncs Square connections (got "${connection.provider}").` },
        400,
      );
    }

    if (connection.status === "disconnected") {
      return jsonResponse(
        { error: "This POS connection is disconnected — reconnect it before syncing." },
        400,
      );
    }

    if (!connection.access_token_secret_id) {
      return jsonResponse({ error: "This connection has no stored access token yet." }, 400);
    }

    if (connection.token_expires_at && new Date(connection.token_expires_at as string) <= new Date()) {
      await adminClient.from("pos_connections").update({
        status: "error",
        last_error: "Square access token expired — reconnect required.",
      }).eq("id", connectionId);
      return jsonResponse({ error: "Square access token expired — reconnect required." }, 401);
    }

    // Vault secrets live in the `vault` schema, not `public` — a second
    // service-role client scoped to it (rather than adminClient.schema())
    // keeps adminClient's default schema unambiguous everywhere above. The
    // decrypted value is held only in this local variable, used solely as
    // an outbound Authorization header to Square below, and is never
    // returned in a response or written to a log line.
    const vaultClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
      db: { schema: "vault" },
    });
    const { data: secretRow, error: secretError } = await vaultClient
      .from("decrypted_secrets")
      .select("decrypted_secret")
      .eq("id", connection.access_token_secret_id)
      .maybeSingle();

    if (secretError || !secretRow?.decrypted_secret) {
      throw new Error("Could not resolve the stored Square access token.");
    }
    const accessToken = secretRow.decrypted_secret as string;

    let result: { productsSynced: number; modifiersSynced: number };
    try {
      const catalogObjects = await fetchAllCatalogObjects({
        accessToken,
        baseUrl: SQUARE_BASE_URL,
        squareVersion: SQUARE_VERSION,
      });

      const { products, modifiers } = normalizeCatalogObjects(catalogObjects);
      const syncedAt = new Date().toISOString();
      const productRows = buildProductRows(connectionId, connection.cafe_id as string, products, syncedAt);
      const modifierRows = buildModifierRows(connectionId, connection.cafe_id as string, modifiers, syncedAt);

      if (productRows.length > 0) {
        const { error } = await adminClient
          .from("pos_products")
          .upsert(productRows, { onConflict: "pos_connection_id,external_product_id" });
        if (error) throw new Error(`Could not save synced products: ${error.message}`);
      }

      if (modifierRows.length > 0) {
        const { error } = await adminClient
          .from("pos_modifiers")
          .upsert(modifierRows, { onConflict: "pos_connection_id,external_modifier_id" });
        if (error) throw new Error(`Could not save synced modifiers: ${error.message}`);
      }

      await adminClient.from("pos_connections").update({
        status: "active",
        last_synced_at: syncedAt,
        last_error: null,
      }).eq("id", connectionId);

      result = { productsSynced: productRows.length, modifiersSynced: modifierRows.length };
    } catch (err) {
      const message = err instanceof SquareApiError
        ? `Square catalog fetch failed (${err.status}).`
        : err instanceof Error
        ? err.message
        : "Catalog sync failed.";

      await adminClient.from("pos_connections").update({
        status: "error",
        last_error: message.slice(0, 500),
      }).eq("id", connectionId);

      console.error(
        "pos-square-sync: sync failed",
        connectionId,
        err instanceof SquareApiError ? err.detail : err instanceof Error ? err.message : err,
      );

      return jsonResponse({ error: message }, err instanceof SquareApiError ? 502 : 500);
    }

    return jsonResponse({ connectionId, ...result });
  } catch (err) {
    console.error("pos-square-sync error:", err);
    return jsonResponse({ error: err instanceof Error ? err.message : "Catalog sync failed." }, 500);
  }
}

// Only starts the server when this file is run directly (deployed, or `deno
// run`) — not when a test file `import`s it to reach the exports above.
if (import.meta.main) {
  Deno.serve(handler);
}
