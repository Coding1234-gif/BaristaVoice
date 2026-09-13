// Supabase Edge Function: create-order
//
//   Kiosk confirm tap
//           v
//   create-order (this file)
//           v
//   create_canonical_order() — the sole pricing/validation authority,
//   implemented as a Postgres function (see schema.sql) so every price is
//   computed in the same transaction as the writes that use it
//           v
//   orders / order_items / order_item_modifiers
//           v
//   pos-square-order-submit (EXISTING, unmodified) — invoked automatically
//   as soon as the canonical order exists
//           v
//   explicit { orderId, orderStatus, total, pos: {...} } response
//
// This file is deliberately thin: it does request-shape checking, calls the
// database function that does the real validation/pricing/writing, and then
// relays to the existing Square submission function. It does NOT itself
// decide whether an item/option/price is valid — that decision, and the
// database writes that follow from it, live entirely in
// create_canonical_order() so there is exactly one place that can get it
// wrong, and it's the one place that already has the menu data in front of
// it inside a transaction.
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
 * parameter). No price of any kind is included — the contract this function
 * reads has no price field to smuggle one into. */
export function buildRpcPayload(request: ValidatedOrderRequest): Record<string, unknown> {
  return {
    cafe_id: request.cafeId,
    idempotency_key: request.idempotencyKey,
    source: "voice",
    currency: "GBP",
    items: request.items.map((item) => ({
      menuItemId: item.menuItemId,
      quantity: item.quantity,
      size: typeof item.size === "string" ? item.size : null,
      milk: typeof item.milk === "string" ? item.milk : null,
      temperature: typeof item.temperature === "string" ? item.temperature : null,
      decaf: item.decaf === true,
      modifiers: Array.isArray(item.modifiers)
        ? item.modifiers.filter((m): m is string => typeof m === "string")
        : [],
      specialRequest: typeof item.specialRequest === "string" ? item.specialRequest : null,
    })),
  };
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
    // 'confirmed') — this only means POS submission didn't happen this
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

  const { data: rpcRows, error: rpcError } = await adminClient
    .rpc("create_canonical_order", { payload: buildRpcPayload(shape.value) });

  if (rpcError) {
    const { status, message } = classifyRpcError(rpcError);
    console.error("create-order: create_canonical_order failed", rpcError);
    return jsonResponse({ error: message }, status);
  }

  const orderRow = Array.isArray(rpcRows) ? rpcRows[0] : rpcRows;
  if (!orderRow?.order_id) {
    console.error("create-order: create_canonical_order returned no order", rpcRows);
    return jsonResponse({ error: "Could not create the order. Please try again." }, 500);
  }

  const orderId = orderRow.order_id as string;
  const orderStatus = orderRow.status as string;
  const total = Number(orderRow.total);

  // Automatic POS submission — every newly-created order is 'confirmed',
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
