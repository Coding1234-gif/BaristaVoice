// Supabase Edge Function: create-order
//
//   Kiosk confirm tap
//           v
//   create-order (this file) — resolves each item's authoritative unit
//   price from menu_items (resolveUnitPrices/computeUnitPrice below), then
//   calls create_canonical_order() to validate the selections and write the
//   order inside one transaction
//           v
//   orders / order_items / order_item_modifiers
//           v
//   pos-square-order-submit (EXISTING, unmodified) — invoked automatically
//   as soon as the canonical order exists
//           v
//   explicit { orderId, orderStatus, total, pos: {...} } response
//
// CORRECTED 2026-09-18: this file's original header (and
// create_canonical_order()'s own doc comment in schema.sql, still stale)
// claimed the Postgres function was "the sole pricing authority... every
// price is computed in the same transaction." In reality
// create_canonical_order() only ever trusts whatever `unit_price` arrives
// in its payload (defaulting to 0) — it never looks up menu_items itself.
// Confirmed live 2026-09-18: every order was totaling £0.00 as a result.
// So pricing is computed HERE instead, from real menu_items data, before
// the RPC is ever called — never from anything the client sent (RawOrderItem
// has no price field at all). create_canonical_order() remains the
// authority for everything else: item/menu-item validity, POS mapping,
// idempotency, and the actual writes.
//
// This file still does request-shape checking, price resolution, calls the
// database function that validates/writes, and relays to the existing
// Square submission function.
//
// ALSO FIXED 2026-09-18 (see extractOrderRow below): the RPC result was
// being read as `orderRow.order_id`, a column that has never existed —
// create_canonical_order() is declared `RETURNS orders`, so the row's PK
// column is `id`. Every successful order creation was being reported back
// to the kiosk as "Could not create the order. Please try again."
//
// Callable two ways, matching order-agent (this is a customer-facing
// endpoint, not an admin one): no Authorization/JWT is required — any caller
// with the project's anon key can invoke it, same as order-agent. There is
// no customer login in this app. Every privileged step below (the RPC call,
// the call to pos-square-order-submit) uses the service-role key
// server-side; the client never sees it.
//
// Inlined imports (not a shared module), matching every other function in
// this project — see order-agent's header for why.
import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// Request shape — the ONLY thing this file itself validates. Everything
// about whether an item/option is actually valid for this café's menu is
// decided by create_canonical_order(); this is just "is the request even
// well-formed enough to be worth a database round trip."
// ---------------------------------------------------------------------------

export interface RawOrderItem {
  menuItemId?: unknown;
  // BUG FIX (confirmed live 2026-09-18): this field didn't exist here at
  // all, even though the Dart client always sends it (OrderItem.toJson()'s
  // 'name'). buildRpcPayload had nothing to forward, so create_canonical_order()
  // always fell back to '' — every order_items.name was empty, which
  // pos-square-order-submit then used both for its own error messages
  // ("No POS mapping found for \"\"") and as the actual line-item name it
  // would send to Square's Orders API.
  name?: unknown;
  quantity?: unknown;
  size?: unknown;
  milk?: unknown;
  temperature?: unknown;
  decaf?: unknown;
  modifiers?: unknown;
  specialRequest?: unknown;
}

export interface CreateOrderRequestBody {
  cafeId?: unknown;
  idempotencyKey?: unknown;
  items?: unknown;
}

export interface ValidatedOrderRequest {
  cafeId: string;
  idempotencyKey: string;
  items: RawOrderItem[];
}

export type ShapeValidationResult =
  | { ok: true; value: ValidatedOrderRequest }
  | { ok: false; error: string };

function isNonEmptyString(v: unknown): v is string {
  return typeof v === "string" && v.trim().length > 0;
}

/** Cheap, non-authoritative shape check so a malformed request fails fast
 * with a clear 400 instead of a confusing database error. Deliberately does
 * NOT check menu-item identity/availability/pricing — that's
 * create_canonical_order()'s job, against real menu data, inside the same
 * transaction that writes the order. */
export function validateRequestShape(body: CreateOrderRequestBody): ShapeValidationResult {
  if (!isNonEmptyString(body.cafeId)) {
    return { ok: false, error: "cafeId is required." };
  }
  if (!isNonEmptyString(body.idempotencyKey)) {
    return { ok: false, error: "idempotencyKey is required." };
  }
  if (!Array.isArray(body.items) || body.items.length === 0) {
    return { ok: false, error: "Order has no items." };
  }

  const items: RawOrderItem[] = [];
  for (const raw of body.items) {
    if (typeof raw !== "object" || raw === null) {
      return { ok: false, error: "Each order item must be an object." };
    }
    const item = raw as RawOrderItem;
    if (!isNonEmptyString(item.menuItemId)) {
      return { ok: false, error: "Each order item must have a menuItemId." };
    }
    if (!isNonEmptyString(item.name)) {
      return { ok: false, error: "Each order item must have a name." };
    }
    if (
      typeof item.quantity !== "number" ||
      !Number.isFinite(item.quantity) ||
      !Number.isInteger(item.quantity) ||
      item.quantity < 1
    ) {
      return { ok: false, error: "Each order item must have a positive integer quantity." };
    }
    items.push(item);
  }

  return {
    ok: true,
    value: { cafeId: body.cafeId as string, idempotencyKey: body.idempotencyKey as string, items },
  };
}

/** Shapes one validated item into the payload create_canonical_order()
 * expects (snake_case keys, matching the Postgres function's `payload`
 * parameter). `unitPrices` must be aligned by index with `request.items` —
 * see resolveUnitPrices, the only thing allowed to produce these numbers.
 * A price is never read from the client request itself: RawOrderItem has no
 * price field at all, so there is nothing to smuggle one through even from
 * a manipulated request body. */
export function buildRpcPayload(
  request: ValidatedOrderRequest,
  unitPrices: number[],
): Record<string, unknown> {
  return {
    cafe_id: request.cafeId,
    idempotency_key: request.idempotencyKey,
    source: "voice",
    currency: "GBP",
    items: request.items.map((item, i) => ({
      menu_item_id: item.menuItemId,
      name: typeof item.name === "string" ? item.name : "",
      quantity: item.quantity,
      unit_price: unitPrices[i] ?? 0,
      // create_canonical_order() reads each modifier as an OBJECT
      // (`v_modifier->>'name'`); sending bare strings made every modifier
      // name fall back to 'Modifier' (confirmed live 2026-09-19).
      // price_adjustment is deliberately 0: unit_price above already
      // includes every modifier's delta, and pos-square-order-submit sends
      // each modifier's price to Square ON TOP of the line's base price —
      // a non-zero value here would double-charge in Square.
      modifiers: (Array.isArray(item.modifiers)
        ? item.modifiers.filter((m): m is string => typeof m === "string")
        : []
      ).map((name) => ({ name, price_adjustment: 0 })),
      // size/milk/temperature/decaf/specialRequest used to sit at the top
      // level of this object, where the RPC never reads them — so a "large
      // oat latte, decaf" was stored as just "Latte". The RPC does persist
      // an item's `metadata` jsonb into order_items.metadata, so they live
      // there (no effect on pricing or on what's sent to Square).
      metadata: {
        size: typeof item.size === "string" ? item.size : null,
        milk: typeof item.milk === "string" ? item.milk : null,
        temperature: typeof item.temperature === "string" ? item.temperature : null,
        decaf: item.decaf === true,
        specialRequest: typeof item.specialRequest === "string" ? item.specialRequest : null,
      },
    })),
  };
}

// ---------------------------------------------------------------------------
// Server-side pricing — create_canonical_order() itself just trusts
// whatever `unit_price` arrives in the payload (defaulting to 0 if absent),
// it does NOT look up menu_items itself. So THIS file is the actual
// pricing authority in practice, not the database function — this is where
// a price must be computed from real menu data, never from anything the
// client sent. Mirrors OrderItem.unitPrice() in app/lib/models/order.dart
// exactly: base price + the matched size/milk delta + every matched
// modifier's delta. temperature/decaf/specialRequest never affect price.
// ---------------------------------------------------------------------------

export interface MenuItemPricingData {
  basePrice: number;
  sizes?: { name: string; priceDelta: number }[];
  milkOptions?: { name: string; priceDelta: number }[];
  modifiers?: { name: string; priceDelta: number }[];
}

export function computeUnitPrice(
  menuItem: MenuItemPricingData,
  selection: { size?: string | null; milk?: string | null; modifiers?: string[] },
): number {
  let price = menuItem.basePrice;

  if (selection.size) {
    const match = menuItem.sizes?.find((s) => s.name === selection.size);
    if (match) price += match.priceDelta;
  }
  if (selection.milk) {
    const match = menuItem.milkOptions?.find((m) => m.name === selection.milk);
    if (match) price += match.priceDelta;
  }
  for (const modName of selection.modifiers ?? []) {
    const match = menuItem.modifiers?.find((m) => m.name === modName);
    if (match) price += match.priceDelta;
  }

  // Avoid float artifacts like 3.7000000000000006 reaching a numeric(12,2)
  // column — cosmetic here since Postgres would round it anyway, but keeps
  // the value this function returns sane on its own terms.
  return Math.round(price * 100) / 100;
}

/** Resolves the authoritative unit price for every item in `items`, aligned
 * by index. `fetchMenuItems` is injected (rather than this function taking
 * a Supabase client directly) so the pricing math above is exercised by a
 * real unit test without a live database — same DI pattern as submitToPos's
 * `fetchImpl`. An item whose menu_item_id isn't returned by the fetch (not
 * found, wrong café, inactive) prices at 0; that's safe because
 * create_canonical_order() itself rejects that item with a clear error
 * before the price would ever be used. */
export async function resolveUnitPrices(
  items: RawOrderItem[],
  fetchMenuItems: (ids: string[]) => Promise<{ id: string; data: MenuItemPricingData }[]>,
): Promise<number[]> {
  const ids = [...new Set(items.map((i) => i.menuItemId as string))];
  const rows = await fetchMenuItems(ids);
  const byId = new Map(rows.map((r) => [r.id, r.data]));

  return items.map((item) => {
    const menuItem = byId.get(item.menuItemId as string);
    if (!menuItem) return 0;
    return computeUnitPrice(menuItem, {
      size: typeof item.size === "string" ? item.size : null,
      milk: typeof item.milk === "string" ? item.milk : null,
      modifiers: Array.isArray(item.modifiers)
        ? item.modifiers.filter((m): m is string => typeof m === "string")
        : [],
    });
  });
}

export interface CanonicalOrderRow {
  id: string;
  status: string;
  total: number;
}

/** Normalizes the RPC's return value into a typed row, or null if it's
 * missing/malformed. Postgrest wraps a single composite-row RPC result in a
 * one-element array, so both shapes are accepted here. IMPORTANT: the row's
 * primary key column is `id` — create_canonical_order() is declared
 * `RETURNS orders` (the whole table row), not a custom `order_id` column.
 * Confirmed live 2026-09-18: an earlier version of this file checked
 * `orderRow.order_id`, which never existed, so a SUCCESSFUL order creation
 * was being reported back to the kiosk as "Could not create the order." */
export function extractOrderRow(rpcRows: unknown): CanonicalOrderRow | null {
  const row = Array.isArray(rpcRows) ? rpcRows[0] : rpcRows;
  if (!row || typeof row !== "object") return null;
  const r = row as Record<string, unknown>;
  if (typeof r.id !== "string" || typeof r.status !== "string") return null;
  return { id: r.id, status: r.status, total: Number(r.total) };
}

/** Postgres errors raised by create_canonical_order() (validation failures,
 * the required-field checks, a unique/foreign-key violation) always carry a
 * `code` — that's what distinguishes "the request was bad" (400, safe to
 * show the message) from an infrastructure failure with no code (500, show
 * a generic message). */
export function classifyRpcError(error: { code?: string | null; message?: string } | null): {
  status: number;
  message: string;
} {
  if (error?.code) {
    return { status: 400, message: error.message || "Could not create the order." };
  }
  return { status: 500, message: "Could not create the order. Please try again." };
}

// ---------------------------------------------------------------------------
// Relay to the EXISTING pos-square-order-submit function — not rewritten,
// not duplicated. Called as a trusted service-role caller (see that file's
// isTrustedServiceRoleCaller), which is exactly the "future create-order
// step calling straight through" scenario its own header comment already
// anticipated.
// ---------------------------------------------------------------------------

export interface PosSubmitOutcome {
  attempted: boolean;
  status: string | null;
  externalOrderId: string | null;
  error: string | null;
}

/** fetchImpl injected so this is testable without a live Edge Function
 * runtime, matching submitOrderToSquare/fetchAllCatalogObjects's pattern in
 * the POS functions this relays to. */
export async function submitToPos(params: {
  orderId: string;
  supabaseUrl: string;
  serviceRoleKey: string;
  fetchImpl?: typeof fetch;
}): Promise<PosSubmitOutcome> {
  const doFetch = params.fetchImpl ?? fetch;
  try {
    const res = await doFetch(`${params.supabaseUrl}/functions/v1/pos-square-order-submit`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${params.serviceRoleKey}`,
        "apikey": params.serviceRoleKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ orderId: params.orderId }),
    });
    const body = await res.json().catch(() => ({}));

    if (!res.ok) {
      return {
        attempted: true,
        status: null,
        externalOrderId: null,
        error: typeof body?.error === "string" ? body.error : `POS submission failed (${res.status}).`,
      };
    }

    return {
      attempted: true,
      status: typeof body?.status === "string" ? body.status : null,
      externalOrderId: typeof body?.externalOrderId === "string" ? body.externalOrderId : null,
      error: null,
    };
  } catch (err) {
    // Network failure reaching pos-square-order-submit itself. The
    // canonical order is already safely persisted (status stays
    // 'pending') — this only means POS submission didn't happen this
    // time, which is an explicit, honest outcome, not a fabricated one.
    return {
      attempted: false,
      status: null,
      externalOrderId: null,
      error: err instanceof Error ? err.message : "Could not reach POS submission.",
    };
  }
}

// ---------------------------------------------------------------------------
// Request handler
// ---------------------------------------------------------------------------

export async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  let body: CreateOrderRequestBody;
  try {
    body = (await req.json()) as CreateOrderRequestBody;
  } catch {
    return jsonResponse({ error: "Invalid request body." }, 400);
  }

  const shape = validateRequestShape(body);
  if (!shape.ok) {
    return jsonResponse({ error: shape.error }, 400);
  }

  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  const unitPrices = await resolveUnitPrices(shape.value.items, async (ids) => {
    const { data, error } = await adminClient
      .from("menu_items")
      .select("id, data")
      .eq("cafe_id", shape.value.cafeId)
      .in("id", ids);
    if (error) {
      console.error("create-order: could not fetch menu items for pricing", error);
      return [];
    }
    return (data ?? []) as { id: string; data: MenuItemPricingData }[];
  });

  const { data: rpcRows, error: rpcError } = await adminClient
    .rpc("create_canonical_order", { payload: buildRpcPayload(shape.value, unitPrices) });

  if (rpcError) {
    const { status, message } = classifyRpcError(rpcError);
    console.error("create-order: create_canonical_order failed", rpcError);
    return jsonResponse({ error: message }, status);
  }

  const orderRow = extractOrderRow(rpcRows);
  if (!orderRow) {
    console.error("create-order: create_canonical_order returned no order", rpcRows);
    return jsonResponse({ error: "Could not create the order. Please try again." }, 500);
  }

  const orderId = orderRow.id;
  const orderStatus = orderRow.status;
  const total = orderRow.total;

  // Automatic POS submission — every newly-created order is 'pending',
  // which is one of pos-square-order-submit's own ELIGIBLE_STATUSES, so
  // this always attempts submission. If the café has no active Square
  // connection, that function's own existing logic decides the outcome
  // (currently: pos_failed with an explicit last_pos_error) — this file
  // does not special-case that, per the existing status model.
  const pos = await submitToPos({
    orderId,
    supabaseUrl: SUPABASE_URL,
    serviceRoleKey: SUPABASE_SERVICE_ROLE_KEY,
  });

  return jsonResponse({
    orderId,
    orderStatus,
    total,
    pos: {
      status: pos.status,
      externalOrderId: pos.externalOrderId,
      error: pos.error,
    },
  });
}

if (import.meta.main) {
  Deno.serve(handler);
}
