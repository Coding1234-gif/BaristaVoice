// Supabase Edge Function: pos-square-terminal-checkout
//
//   canonical order (status: sent_to_pos / payment_pending / payment_failed)
//           v
//   pos-square-terminal-checkout (this file)
//           v
//   Square Terminal Checkout API
//           v
//   canonical order (status: payment_pending)
//
// Starts (or safely re-starts) a Square Terminal checkout for an EXISTING
// canonical order that has already reached Square (pos-square-order-submit
// has already run). Customer pays on the physical/simulated Terminal
// device; a separate function (pos-square-order-pay) later confirms and
// captures that payment.
//
// Security model — same shape as pos-square-order-submit/pos-square-sync,
// plus one addition:
// - Callable three ways: (a) an authenticated cafe_admin/super_admin (JWT,
//   scoped to their own café via authorizeOrderAccess()); (b) a trusted
//   server-to-server caller presenting SUPABASE_SERVICE_ROLE_KEY; or (c) an
//   UNAUTHENTICATED caller with no Authorization header at all — the kiosk
//   app itself, which has no customer login (same posture as
//   create-order/order-agent). The only thing an anonymous caller supplies
//   is `orderId`; every value that matters (cafe_id, Square location,
//   amount, access token) is still resolved entirely server-side from the
//   `orders` row and its joins, exactly as for the other two caller kinds.
//   `orders.id` is a gen_random_uuid() — the same unguessable-id security
//   boundary create-order already relies on. `deviceId` (production only)
//   remains restricted below to authenticated/service-role callers.
// - The order's cafe_id is read server-side from the `orders` row itself,
//   never trusted from the request body.
// - The Square access token is resolved server-side from Vault and used
//   only as an outbound Authorization header — never returned or logged.
//
// Inlined imports (not a shared module) — matches every other function in
// this project.
import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const SQUARE_ENVIRONMENT = (Deno.env.get("SQUARE_ENVIRONMENT") ?? "sandbox") as "sandbox" | "production";
const SQUARE_VERSION = Deno.env.get("SQUARE_VERSION") ?? "2026-08-19";
const SQUARE_BASE_URL = SQUARE_ENVIRONMENT === "production"
  ? "https://connect.squareup.com"
  : "https://connect.squareupsandbox.com";

// Square Sandbox simulated Terminal. This device ID produces a successful
// test checkout — see Square's own sandbox documentation.
const SANDBOX_DEVICE_ID = "9fa747a2-25ff-48ee-b078-04381f7c828f";

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

/** Thrown for a non-2xx response from Square's own API, or a 2xx response
 * missing the field this function actually needed from it. */
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
// Pure decision/building logic — no network/DB calls, fully unit testable.
// ---------------------------------------------------------------------------

export function isTrustedServiceRoleCaller(authHeader: string, serviceRoleKey: string | undefined): boolean {
  if (!serviceRoleKey) return false;
  return authHeader === `Bearer ${serviceRoleKey}`;
}

export function authorizeOrderAccess(
  profile: { role: string; cafeId: string | null },
  orderCafeId: string,
): { allowed: boolean; reason?: string } {
  if (profile.role === "super_admin") return { allowed: true };
  if (profile.role === "cafe_admin") {
    if (profile.cafeId === orderCafeId) return { allowed: true };
    return { allowed: false, reason: "You do not have access to this order." };
  }
  return { allowed: false, reason: "Only cafe admins can start Terminal checkouts." };
}

/** Requirement (new): who is calling, in one of three shapes. An absent
 * Authorization header is the kiosk's own, unauthenticated calling
 * convention (see file header) — NOT an error — and is handled distinctly
 * from a present-but-invalid one, which still fails as before. */
export type CallerKind = "service_role" | "anonymous" | "authenticated";

export function classifyCaller(
  authHeader: string | null,
  serviceRoleKey: string | undefined,
): CallerKind {
  if (!authHeader) return "anonymous";
  if (isTrustedServiceRoleCaller(authHeader, serviceRoleKey)) return "service_role";
  return "authenticated";
}

/** A checkout may only be started (or safely re-started — see below) from
 * one of these statuses. `payment_pending` is included deliberately: a
 * retry/duplicate tap while a checkout is already in flight re-issues the
 * SAME Square Terminal checkout (via the deterministic idempotency key
 * built below) rather than erroring, so this never needs to distinguish
 * "genuinely a duplicate call" from "the first call's response was lost." */
const CHECKOUT_ELIGIBLE_STATUSES = ["sent_to_pos", "payment_pending", "payment_failed"];

export function isCheckoutEligibleStatus(status: string): boolean {
  return CHECKOUT_ELIGIBLE_STATUSES.includes(status);
}

/** Production requires a real, staff-configured device id — never a
 * client-controlled one accepted from an anonymous caller (this app's
 * kiosk never has a reason to know a device id at all; only an
 * authenticated/service-role caller may supply one, and only in
 * production). Sandbox always uses the fixed simulated-Terminal id. */
export function resolveDeviceId(params: {
  environment: "sandbox" | "production";
  sandboxDeviceId: string;
  callerKind: CallerKind;
  requestedDeviceId?: unknown;
}): { ok: true; deviceId: string } | { ok: false; error: string; status: number } {
  if (params.environment === "sandbox") {
    return { ok: true, deviceId: params.sandboxDeviceId };
  }

  if (params.callerKind === "anonymous") {
    return {
      ok: false,
      status: 403,
      error: "Terminal checkout in production requires staff to specify the device.",
    };
  }

  if (typeof params.requestedDeviceId !== "string" || params.requestedDeviceId.trim().length === 0) {
    return { ok: false, status: 400, error: "deviceId is required in production." };
  }

  return { ok: true, deviceId: params.requestedDeviceId };
}

export function buildTerminalCheckoutPayload(params: {
  idempotencyKey: string;
  amountCents: number;
  currency: string;
  squareOrderId: string;
  orderId: string;
  deviceId: string;
}) {
  return {
    idempotency_key: params.idempotencyKey,
    checkout: {
      amount_money: { amount: params.amountCents, currency: params.currency },
      order_id: params.squareOrderId,
      reference_id: params.orderId,
      device_options: { device_id: params.deviceId, show_itemized_cart: true },
    },
  };
}

/** Calls Square's Create Terminal Checkout API. accessToken is used only as
 * the outbound Authorization header — never returned or logged. */
export async function createSquareTerminalCheckout(params: {
  accessToken: string;
  baseUrl: string;
  squareVersion: string;
  payload: unknown;
  fetchImpl?: typeof fetch;
}): Promise<{ checkoutId: string; status: string | null; raw: unknown }> {
  const doFetch = params.fetchImpl ?? fetch;
  const response = await doFetch(`${params.baseUrl}/v2/terminals/checkouts`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${params.accessToken}`,
      "Square-Version": params.squareVersion,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(params.payload),
  });

  const result = await response.json().catch(() => ({}));

  if (!response.ok) {
    throw new SquareApiError(
      `Square Terminal checkout failed (${response.status}).`,
      response.status,
      JSON.stringify(result?.errors ?? result).slice(0, 500),
    );
  }

  const checkoutId = result?.checkout?.id;
  if (!checkoutId) {
    throw new SquareApiError(
      "Square Terminal checkout returned no checkout id.",
      response.status,
      JSON.stringify(result).slice(0, 500),
    );
  }

  return { checkoutId, status: result?.checkout?.status ?? null, raw: result };
}

// ---------------------------------------------------------------------------
// Request handler
// ---------------------------------------------------------------------------

interface RequestBody {
  orderId?: unknown;
  deviceId?: unknown;
}

export async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return jsonResponse({ error: "Only POST requests are supported." }, 405);
  }

  try {
    const body = (await req.json()) as RequestBody;
    const orderId = body?.orderId;
    if (!orderId || typeof orderId !== "string") {
      return jsonResponse({ error: "orderId is required." }, 400);
    }

    const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const authHeader = req.headers.get("Authorization");
    const callerKind = classifyCaller(authHeader, SUPABASE_SERVICE_ROLE_KEY);

    // ---------------------------------------------------------------
    // Authorization — only the "authenticated" caller kind needs a
    // profile lookup; "service_role" is inherently trusted and
    // "anonymous" is the kiosk's own convention (see file header).
    // ---------------------------------------------------------------

    let callerProfile: { role: string; cafeId: string | null } | null = null;

    if (callerKind === "authenticated") {
      const callerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
        global: { headers: { Authorization: authHeader! } },
      });
      const { data: userData, error: userError } = await callerClient.auth.getUser();
      if (userError || !userData.user) {
        return jsonResponse({ error: "Invalid or expired session." }, 401);
      }

      const { data: profile } = await adminClient
        .from("profiles")
        .select("role, cafe_id")
        .eq("id", userData.user.id)
        .maybeSingle();

      if (!profile || (profile.role !== "cafe_admin" && profile.role !== "super_admin")) {
        return jsonResponse({ error: "Only cafe admins can start Terminal checkouts." }, 403);
      }
      callerProfile = { role: profile.role as string, cafeId: profile.cafe_id as string | null };
    }

    // ---------------------------------------------------------------
    // Load canonical order
    // ---------------------------------------------------------------

    const { data: order, error: orderError } = await adminClient
      .from("orders")
      .select(
        "id, cafe_id, status, currency, total, external_order_id, pos_provider, pos_connection_id, idempotency_key",
      )
      .eq("id", orderId)
      .maybeSingle();

    if (orderError || !order) {
      return jsonResponse({ error: "Order not found." }, 404);
    }

    if (callerProfile) {
      const authz = authorizeOrderAccess(callerProfile, order.cafe_id as string);
      if (!authz.allowed) {
        return jsonResponse({ error: authz.reason }, 403);
      }
    }

    if (order.pos_provider !== "square") {
      return jsonResponse({ error: "This order has not been submitted to Square." }, 409);
    }
    if (!order.external_order_id) {
      return jsonResponse({ error: "This order has no Square external_order_id." }, 409);
    }
    if (!isCheckoutEligibleStatus(order.status as string)) {
      return jsonResponse(
        { error: `Order is not eligible for Terminal checkout (status: ${order.status}).` },
        409,
      );
    }
    if (!order.idempotency_key) {
      return jsonResponse({ error: "Order has no idempotency_key set — cannot start checkout safely." }, 500);
    }

    // ---------------------------------------------------------------
    // Resolve device id BEFORE touching order status, so an invalid
    // production request never transiently marks the order payment_pending.
    // ---------------------------------------------------------------

    const deviceResolution = resolveDeviceId({
      environment: SQUARE_ENVIRONMENT,
      sandboxDeviceId: SANDBOX_DEVICE_ID,
      callerKind,
      requestedDeviceId: body?.deviceId,
    });
    if (!deviceResolution.ok) {
      return jsonResponse({ error: deviceResolution.error }, deviceResolution.status);
    }

    const amountCents = Math.round(Number(order.total) * 100);
    if (!Number.isFinite(amountCents) || amountCents <= 0) {
      return jsonResponse({ error: "Order total is invalid or zero." }, 400);
    }

    // ---------------------------------------------------------------
    // Atomically claim the order into payment_pending — mirrors
    // pos-square-order-submit's claim pattern so two concurrent starts
    // (double tap) can't race each other into starting two checkouts.
    // ---------------------------------------------------------------

    const { data: claimedRows, error: claimError } = await adminClient
      .from("orders")
      .update({ status: "payment_pending", last_pos_error: null })
      .eq("id", orderId)
      .in("status", CHECKOUT_ELIGIBLE_STATUSES)
      .select();

    if (claimError) {
      throw new Error(`Could not claim order for Terminal checkout: ${claimError.message}`);
    }
    if (!claimedRows || claimedRows.length === 0) {
      const { data: current } = await adminClient
        .from("orders")
        .select("status")
        .eq("id", orderId)
        .maybeSingle();
      return jsonResponse(
        { error: `Order is no longer eligible for Terminal checkout (status: ${current?.status ?? "unknown"}).` },
        409,
      );
    }

    // ---------------------------------------------------------------
    // Resolve Square connection + access token
    // ---------------------------------------------------------------

    let connectionId = (order.pos_connection_id as string | null) ?? null;
    if (!connectionId) {
      const { data: connections } = await adminClient
        .from("pos_connections")
        .select("id")
        .eq("cafe_id", order.cafe_id)
        .eq("provider", "square")
        .eq("status", "active");

      if (!connections || connections.length === 0) {
        return jsonResponse({ error: "No active Square connection for this cafe." }, 400);
      }
      if (connections.length > 1) {
        return jsonResponse(
          { error: "Multiple active Square connections exist. The order must specify pos_connection_id." },
          400,
        );
      }
      connectionId = connections[0].id as string;
    }

    const { data: connection } = await adminClient
      .from("pos_connections")
      .select("id, location_id, status, access_token_secret_id, token_expires_at")
      .eq("id", connectionId)
      .maybeSingle();

    if (!connection || connection.status !== "active") {
      return jsonResponse({ error: "The linked Square connection is not active." }, 400);
    }
    if (!connection.location_id) {
      return jsonResponse({ error: "The linked Square connection has no location configured." }, 400);
    }
    if (!connection.access_token_secret_id) {
      return jsonResponse({ error: "The linked Square connection has no stored access token." }, 400);
    }
    if (connection.token_expires_at && new Date(connection.token_expires_at as string) <= new Date()) {
      return jsonResponse({ error: "Square access token expired — reconnect required." }, 401);
    }

    const { data: accessToken, error: secretError } = await adminClient.rpc("get_vault_secret", {
      secret_id: connection.access_token_secret_id,
    });

    if (secretError || !accessToken) {
      console.error("Vault secret resolution failed:", {
        message: secretError?.message,
        code: secretError?.code,
      });
      return jsonResponse({ error: "Could not resolve the stored Square access token." }, 500);
    }

    // ---------------------------------------------------------------
    // Create the Terminal checkout
    // ---------------------------------------------------------------

    const squareOrderId = order.external_order_id as string;
    const payload = buildTerminalCheckoutPayload({
      idempotencyKey: `${order.idempotency_key}-terminal`,
      amountCents,
      currency: order.currency as string,
      squareOrderId,
      orderId,
      deviceId: deviceResolution.deviceId,
    });

    let checkout;
    try {
      checkout = await createSquareTerminalCheckout({
        accessToken,
        baseUrl: SQUARE_BASE_URL,
        squareVersion: SQUARE_VERSION,
        payload,
      });
    } catch (err) {
      const message = err instanceof SquareApiError ? err.message : "Square Terminal checkout failed.";
      await adminClient
        .from("orders")
        .update({ status: "payment_failed", last_pos_error: message.slice(0, 500) })
        .eq("id", orderId);
      console.error("Square Terminal checkout failed:", err);
      return jsonResponse({ error: message }, err instanceof SquareApiError ? 502 : 500);
    }

    return jsonResponse({
      orderId,
      squareOrderId,
      checkoutId: checkout.checkoutId,
      status: checkout.status,
      orderStatus: "payment_pending",
      amount: amountCents,
      currency: order.currency,
    });
  } catch (err) {
    console.error("pos-square-terminal-checkout error:", err);
    return jsonResponse(
      { error: err instanceof Error ? err.message : "Terminal checkout failed." },
      500,
    );
  }
}

if (import.meta.main) {
  Deno.serve(handler);
}
