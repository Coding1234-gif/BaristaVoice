// Supabase Edge Function: pos-square-order-submit
//
//   BaristaVoice canonical order
//           v
//   order_items / order_item_modifiers
//           v
//   pos_product_mappings
//           v
//   Square adapter (this file)
//           v
//   Square order
//
// Takes an EXISTING canonical order (an `orders` row plus its `order_items`
// / `order_item_modifiers`) and submits it to Square as a real order.
// Scope is deliberately narrow: this does not create canonical orders (that
// remains a separate, not-yet-built step — see the architecture notes this
// implements), does not take a payment, and does not handle any provider
// other than Square.
//
// Security model (same shape as pos-square-sync/menu-extractor):
// - Callable two ways: (a) an authenticated cafe_admin/super_admin, JWT
//   verified via supabase.auth.getUser() and scoped to their own café by
//   authorizeOrderAccess(); or (b) a trusted server-to-server caller that
//   presents this project's own SUPABASE_SERVICE_ROLE_KEY as its bearer
//   token (isTrustedServiceRoleCaller()) — the realistic production
//   trigger, e.g. a future create-order step calling straight through, or
//   a Database Webhook configured with that key. A service-role caller
//   skips the cafe_admin check entirely (it already has full DB access by
//   definition), but every other rule below still applies to it.
// - The order's cafe_id is read server-side from the `orders` row itself,
//   never trusted from the request body — there is no cafe_id in the
//   request at all, only an orderId.
// - Every POS-side id used in the Square request (product ids, modifier
//   ids, location id) is resolved server-side from pos_product_mappings /
//   pos_products / pos_modifiers / pos_connections — the request body is
//   just `{ orderId }`, so there is no POS id for a client to supply in
//   the first place.
// - The Square access token is resolved server-side from Vault (exactly
//   like pos-square-sync) and used only as an outbound Authorization
//   header — never returned in a response or written to a log line. See
//   the "secret-access boundaries" tests for a direct check of this.
//
// Inlined imports (not a shared module) so this file stays a single,
// self-contained, dashboard-pasteable function, matching every other
// function in this project.
import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

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

/** Thrown for a non-2xx response from Square's own API. */
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

/** Thrown when an order_item has no resolvable POS product at all —
 * either menu_item_id is null, or no pos_product_mappings row exists for
 * it on the resolved connection. */
export class UnmappedProductError extends Error {
  readonly itemName: string;
  constructor(itemName: string) {
    super(`No POS mapping found for "${itemName}".`);
    this.name = "UnmappedProductError";
    this.itemName = itemName;
  }
}

/** Thrown when a mapping (product- or modifier-level) exists but points at
 * something no longer usable — e.g. the mapped pos_product/pos_modifier has
 * since been deactivated. Distinct from [UnmappedProductError]: here a
 * mapping decision was made, it's just stale. */
export class InvalidMappingError extends Error {
  readonly itemName: string;
  constructor(itemName: string, reason: string) {
    super(`Mapping for "${itemName}" is invalid: ${reason}`);
    this.name = "InvalidMappingError";
    this.itemName = itemName;
  }
}

// ---------------------------------------------------------------------------
// Pure resolution + payload-building logic — no network/DB calls, fully
// unit testable. This is the part of the file that's actually specific to
// "submit a canonical BaristaVoice order to Square."
// ---------------------------------------------------------------------------

export interface OrderModifierInput {
  name: string;
  priceAdjustment: number; // decimal dollars, matches order_item_modifiers.price_adjustment
  posModifierId: string | null;
}

export interface OrderLineInput {
  menuItemId: string | null;
  name: string;
  quantity: number;
  unitPrice: number; // decimal dollars, matches order_items.unit_price
  modifiers: OrderModifierInput[];
}

export interface ProductMappingLookup {
  externalProductId: string;
  active: boolean;
}

export interface ModifierCatalogLookup {
  externalModifierId: string;
  active: boolean;
}

export interface ResolvedLineItem {
  name: string;
  quantity: number;
  externalProductId: string;
  basePriceCents: number;
  modifiers: { name: string; priceAdjustmentCents: number; externalModifierId: string | null }[];
}

export function dollarsToCents(amount: number): number {
  return Math.round(amount * 100);
}

/** Requirements 2-4: resolves every order line's menu_item_id through the
 * café's pos_product_mappings, and every modifier that has a pos_modifier_id
 * through the connection's pos_modifiers — throwing (never silently
 * dropping or partially resolving) the moment anything can't be resolved,
 * so a caller never submits a partial order to Square. A modifier with no
 * pos_modifier_id at all (never resolved to a specific POS catalog entry)
 * is not an error — it's forwarded to Square as an ad-hoc, uncataloged
 * modifier (name + price only), which Square's Orders API supports
 * natively; only a modifier that WAS mapped but is no longer valid fails. */
export function resolveOrderLineItems(
  items: OrderLineInput[],
  productMappingsByMenuItem: Map<string, ProductMappingLookup>,
  modifierCatalogById: Map<string, ModifierCatalogLookup>,
): ResolvedLineItem[] {
  return items.map((item) => {
    if (!item.menuItemId) {
      throw new UnmappedProductError(item.name);
    }
    const mapping = productMappingsByMenuItem.get(item.menuItemId);
    if (!mapping) {
      throw new UnmappedProductError(item.name);
    }
    if (!mapping.active) {
      throw new InvalidMappingError(item.name, "the mapped POS product is no longer active");
    }

    const modifiers = item.modifiers.map((mod) => {
      if (!mod.posModifierId) {
        return {
          name: mod.name,
          priceAdjustmentCents: dollarsToCents(mod.priceAdjustment),
          externalModifierId: null,
        };
      }
      const catalogModifier = modifierCatalogById.get(mod.posModifierId);
      if (!catalogModifier || !catalogModifier.active) {
        throw new InvalidMappingError(
          item.name,
          `modifier "${mod.name}" is mapped to a POS modifier that no longer exists or is inactive`,
        );
      }
      return {
        name: mod.name,
        priceAdjustmentCents: dollarsToCents(mod.priceAdjustment),
        externalModifierId: catalogModifier.externalModifierId,
      };
    });

    return {
      name: item.name,
      quantity: item.quantity,
      externalProductId: mapping.externalProductId,
      basePriceCents: dollarsToCents(item.unitPrice),
      modifiers,
    };
  });
}

/** Requirement 9: the idempotency_key is threaded straight through from the
 * canonical order's own orders.idempotency_key — never generated here —
 * so every retry of this function for the same order sends Square the
 * exact same key, and Square's own idempotency guarantee (not just ours)
 * is what makes retrying always safe, including for an ambiguous prior
 * failure (timeout, dropped response) where we genuinely don't know
 * whether Square already created the order. */
export function buildSquareCreateOrderPayload(params: {
  locationId: string;
  idempotencyKey: string;
  currency: string;
  lineItems: ResolvedLineItem[];
}) {
  return {
    idempotency_key: params.idempotencyKey,
    order: {
      location_id: params.locationId,
      line_items: params.lineItems.map((li) => ({
        name: li.name,
        quantity: String(li.quantity),
        base_price_money: { amount: li.basePriceCents, currency: params.currency },
        catalog_object_id: li.externalProductId,
        modifiers: li.modifiers.map((m) => ({
          ...(m.externalModifierId
            ? { catalog_object_id: m.externalModifierId }
            : { name: m.name }),
          base_price_money: { amount: m.priceAdjustmentCents, currency: params.currency },
        })),
      })),
    },
  };
}

/** Calls Square's Create Order API. accessToken is used only as the
 * outbound Authorization header — it never appears in the request body
 * built above, and this function never returns it. */
export async function submitOrderToSquare(params: {
  accessToken: string;
  baseUrl: string;
  squareVersion: string;
  payload: unknown;
  fetchImpl?: typeof fetch;
}): Promise<{ externalOrderId: string; raw: unknown }> {
  const doFetch = params.fetchImpl ?? fetch;
  const res = await doFetch(`${params.baseUrl}/v2/orders`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${params.accessToken}`,
      "Square-Version": params.squareVersion,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(params.payload),
  });

  const body = await res.json().catch(() => ({}));

  if (!res.ok) {
    throw new SquareApiError(
      `Square create-order failed: ${res.status}`,
      res.status,
      JSON.stringify(body).slice(0, 500),
    );
  }

  const externalOrderId = body?.order?.id;
  if (!externalOrderId) {
    throw new SquareApiError("Square create-order returned no order id.", res.status, JSON.stringify(body).slice(0, 500));
  }

  return { externalOrderId, raw: body };
}

// ---------------------------------------------------------------------------
// Authorization — requirement 12. Pure decision functions, unit-testable
// without a DB. Mirrors pos-square-sync's authorizeConnectionAccess exactly
// (small, deliberate duplication — see that file's header on why this
// project keeps every Edge Function single-file/import-free).
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
  return { allowed: false, reason: "Only cafe admins can submit orders to the POS." };
}

// ---------------------------------------------------------------------------
// Request handler
// ---------------------------------------------------------------------------

interface RequestBody {
  orderId: string;
}

const ELIGIBLE_STATUSES = ["confirmed", "pos_failed"];

export async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return jsonResponse({ error: "Missing Authorization header." }, 401);
  }

  try {
    const { orderId } = (await req.json()) as RequestBody;
    if (!orderId) return jsonResponse({ error: "orderId is required." }, 400);

    const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const trustedCaller = isTrustedServiceRoleCaller(authHeader, SUPABASE_SERVICE_ROLE_KEY);

    // Requirement 12: cafe_admin/super_admin path, or a trusted service-role
    // caller. Nothing else is accepted.
    let callerProfile: { role: string; cafeId: string | null } | null = null;
    if (!trustedCaller) {
      const callerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
        global: { headers: { Authorization: authHeader } },
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
        return jsonResponse({ error: "Only cafe admins can submit orders to the POS." }, 403);
      }
      callerProfile = { role: profile.role as string, cafeId: profile.cafe_id as string | null };
    }

    // Read the order server-side — cafe_id, status, and everything else
    // needed below comes from this row, never from the request body.
    const { data: order, error: orderError } = await adminClient
      .from("orders")
      .select("id, cafe_id, status, currency, pos_connection_id, external_order_id, idempotency_key")
      .eq("id", orderId)
      .maybeSingle();

    if (orderError || !order) {
      return jsonResponse({ error: "Order not found." }, 404);
    }

    // Authorize BEFORE any mutation — an unauthorized caller never even
    // transiently changes another café's order status.
    if (callerProfile) {
      const authz = authorizeOrderAccess(callerProfile, order.cafe_id as string);
      if (!authz.allowed) {
        return jsonResponse({ error: authz.reason }, 403);
      }
    }

    // Requirement 9 (idempotency), part 1: already sent — return the
    // existing result rather than resubmitting. Safe no-op for any retry
    // that arrives after a prior call already succeeded.
    if (order.status === "sent_to_pos") {
      return jsonResponse({
        orderId,
        externalOrderId: order.external_order_id,
        status: order.status,
        alreadySubmitted: true,
      });
    }

    if (!ELIGIBLE_STATUSES.includes(order.status as string)) {
      return jsonResponse(
        { error: `Order is not eligible for POS submission (status: ${order.status}).` },
        409,
      );
    }

    if (!order.idempotency_key) {
      return jsonResponse({ error: "Order has no idempotency_key set — cannot submit safely." }, 500);
    }

    // Requirement 9, part 2 / requirement 11: atomically claim the order.
    // The WHERE clause re-checks status at the moment of the UPDATE (not
    // the earlier SELECT above), so two concurrent submit calls can't both
    // proceed — exactly one UPDATE affects a row; the other gets zero rows
    // back and is treated as a conflict below, never as "go ahead."
    const { data: claimedRows, error: claimError } = await adminClient
      .from("orders")
      .update({ status: "sending_to_pos" })
      .eq("id", orderId)
      .in("status", ELIGIBLE_STATUSES)
      .select();

    if (claimError) throw new Error(`Could not claim order for submission: ${claimError.message}`);

    if (!claimedRows || claimedRows.length === 0) {
      // Lost the race (or the DB state changed between the SELECT above and
      // now) — re-check rather than guess.
      const { data: current } = await adminClient
        .from("orders")
        .select("status, external_order_id")
        .eq("id", orderId)
        .maybeSingle();
      if (current?.status === "sent_to_pos") {
        return jsonResponse({
          orderId,
          externalOrderId: current.external_order_id,
          status: current.status,
          alreadySubmitted: true,
        });
      }
      return jsonResponse(
        { error: `Order is currently being submitted or is no longer eligible (status: ${current?.status ?? "unknown"}).` },
        409,
      );
    }

    // From here on, the order is claimed (status = sending_to_pos). Any
    // exit below MUST leave it in a terminal state (sent_to_pos or
    // pos_failed) — never leave it stuck in sending_to_pos.
    const failOrder = async (message: string) => {
      await adminClient.from("orders").update({
        status: "pos_failed",
        last_pos_error: message.slice(0, 500),
      }).eq("id", orderId);
    };

    try {
      // Resolve the Square connection: trust the order's own
      // pos_connection_id if already set (it was written server-side, by
      // definition — never by a client), otherwise resolve the café's
      // sole active Square connection. Never accept a connection id from
      // the request (there isn't one to accept — see file header).
      let connectionId = order.pos_connection_id as string | null;
      if (!connectionId) {
        const { data: connections } = await adminClient
          .from("pos_connections")
          .select("id")
          .eq("cafe_id", order.cafe_id)
          .eq("provider", "square")
          .eq("status", "active");

        if (!connections || connections.length === 0) {
          const message = "No active Square connection for this cafe.";
          await failOrder(message);
          return jsonResponse({ error: message }, 400);
        }
        if (connections.length > 1) {
          const message =
            "This cafe has multiple active Square connections — the order must specify pos_connection_id.";
          await failOrder(message);
          return jsonResponse({ error: message }, 400);
        }
        connectionId = connections[0].id as string;
      }

      const { data: connection } = await adminClient
        .from("pos_connections")
        .select("id, location_id, status, access_token_secret_id, token_expires_at")
        .eq("id", connectionId)
        .maybeSingle();

      if (!connection || connection.status !== "active") {
        const message = "The linked Square connection is not active.";
        await failOrder(message);
        return jsonResponse({ error: message }, 400);
      }
      if (!connection.location_id) {
        const message = "The linked Square connection has no location configured.";
        await failOrder(message);
        return jsonResponse({ error: message }, 400);
      }
      if (!connection.access_token_secret_id) {
        const message = "The linked Square connection has no stored access token.";
        await failOrder(message);
        return jsonResponse({ error: message }, 400);
      }
      if (connection.token_expires_at && new Date(connection.token_expires_at as string) <= new Date()) {
        const message = "Square access token expired — reconnect required.";
        await adminClient.from("pos_connections").update({ status: "error", last_error: message }).eq("id", connectionId);
        await failOrder(message);
        return jsonResponse({ error: message }, 401);
      }

      // Load order_items + order_item_modifiers.
      const { data: itemRows, error: itemsError } = await adminClient
        .from("order_items")
        .select("id, menu_item_id, name, quantity, unit_price")
        .eq("order_id", orderId);
      if (itemsError) throw new Error(`Could not load order items: ${itemsError.message}`);
      if (!itemRows || itemRows.length === 0) {
        const message = "Order has no items to submit.";
        await failOrder(message);
        return jsonResponse({ error: message }, 400);
      }

      const { data: modifierRows, error: modifiersError } = await adminClient
        .from("order_item_modifiers")
        .select("order_item_id, name, price_adjustment, pos_modifier_id")
        .in("order_item_id", itemRows.map((r) => r.id));
      if (modifiersError) throw new Error(`Could not load order item modifiers: ${modifiersError.message}`);

      const modifiersByOrderItem = new Map<string, OrderModifierInput[]>();
      for (const row of modifierRows ?? []) {
        const list = modifiersByOrderItem.get(row.order_item_id as string) ?? [];
        list.push({
          name: row.name as string,
          priceAdjustment: Number(row.price_adjustment),
          posModifierId: row.pos_modifier_id as string | null,
        });
        modifiersByOrderItem.set(row.order_item_id as string, list);
      }

      const lineInputs: OrderLineInput[] = itemRows.map((row) => ({
        menuItemId: row.menu_item_id as string | null,
        name: row.name as string,
        quantity: row.quantity as number,
        unitPrice: Number(row.unit_price),
        modifiers: modifiersByOrderItem.get(row.id as string) ?? [],
      }));

      // Requirement 2: resolve every menu_item through pos_product_mappings
      // for this connection (never trust order_items.pos_product_id, which
      // is only a display snapshot — see file header rationale).
      const menuItemIds = [...new Set(lineInputs.map((l) => l.menuItemId).filter((v): v is string => !!v))];
      const productMappingsByMenuItem = new Map<string, ProductMappingLookup>();
      if (menuItemIds.length > 0) {
        const { data: mappingRows, error: mappingError } = await adminClient
          .from("pos_product_mappings")
          .select("menu_item_id, pos_products(external_product_id, active)")
          .eq("pos_connection_id", connectionId)
          .in("menu_item_id", menuItemIds);
        if (mappingError) throw new Error(`Could not load POS product mappings: ${mappingError.message}`);
        for (const row of mappingRows ?? []) {
          const product = row.pos_products as unknown as { external_product_id: string; active: boolean } | null;
          if (!product) continue;
          productMappingsByMenuItem.set(row.menu_item_id as string, {
            externalProductId: product.external_product_id,
            active: product.active,
          });
        }
      }

      // Requirement 3: resolve every modifier that has a pos_modifier_id.
      const modifierIds = [
        ...new Set((modifierRows ?? []).map((r) => r.pos_modifier_id).filter((v): v is string => !!v)),
      ];
      const modifierCatalogById = new Map<string, ModifierCatalogLookup>();
      if (modifierIds.length > 0) {
        const { data: modRows, error: modError } = await adminClient
          .from("pos_modifiers")
          .select("id, external_modifier_id, active")
          .in("id", modifierIds);
        if (modError) throw new Error(`Could not load POS modifiers: ${modError.message}`);
        for (const row of modRows ?? []) {
          modifierCatalogById.set(row.id as string, {
            externalModifierId: row.external_modifier_id as string,
            active: row.active as boolean,
          });
        }
      }

      let lineItems: ResolvedLineItem[];
      try {
        lineItems = resolveOrderLineItems(lineInputs, productMappingsByMenuItem, modifierCatalogById);
      } catch (err) {
        // Requirement 4: fail safely — abort the whole submission, no
        // partial order is ever sent to Square.
        const message = err instanceof Error ? err.message : "Could not resolve order items to POS products.";
        await failOrder(message);
        return jsonResponse({ error: message }, 400);
      }

      // Requirement 7: resolve the access token from Vault, server-role
      // only — never from the client, never returned below. Vault secrets
      // live in the `vault` schema, which PostgREST does not expose by
      // default (not even to a service-role client scoped to it) —
      // get_vault_secret() is a SECURITY DEFINER function in `public` that
      // reads vault.decrypted_secrets internally, reached here via RPC.
      // Mirrors the same fix already applied to pos-square-sync.
      const { data: accessToken, error: secretError } = await adminClient
        .rpc("get_vault_secret", {
          secret_id: connection.access_token_secret_id,
        });

      if (secretError || !accessToken) {
        console.error("Vault secret resolution failed:", {
          message: secretError?.message,
          code: secretError?.code,
          details: secretError?.details,
          hint: secretError?.hint,
        });
        throw new Error("Could not resolve the stored Square access token.");
      }

      const payload = buildSquareCreateOrderPayload({
        locationId: connection.location_id as string,
        idempotencyKey: order.idempotency_key as string,
        currency: order.currency as string,
        lineItems,
      });

      let squareResult: { externalOrderId: string; raw: unknown };
      try {
        squareResult = await submitOrderToSquare({
          accessToken,
          baseUrl: SQUARE_BASE_URL,
          squareVersion: SQUARE_VERSION,
          payload,
        });
      } catch (err) {
        // Requirement 11: whatever went wrong (a clean rejection, a
        // timeout, a dropped connection — we can't always tell which),
        // this order ends in pos_failed, never stuck in sending_to_pos.
        // Retrying is always safe regardless of which case it was: Square
        // dedupes on idempotency_key, so a retry either returns the order
        // Square already created, or genuinely creates it — never twice.
        const message = err instanceof SquareApiError
          ? `Square order submission failed (${err.status}).`
          : err instanceof Error
          ? err.message
          : "Square order submission failed.";
        console.error(
          "pos-square-order-submit: submission failed",
          orderId,
          err instanceof SquareApiError ? err.detail : err instanceof Error ? err.message : err,
        );
        await failOrder(message);
        return jsonResponse({ error: message }, err instanceof SquareApiError ? 502 : 500);
      }

      // Requirement 10: persist the POS order/provider identifier on the
      // canonical order.
      await adminClient.from("orders").update({
        status: "sent_to_pos",
        external_order_id: squareResult.externalOrderId,
        pos_provider: "square",
        pos_connection_id: connectionId,
        last_pos_error: null,
      }).eq("id", orderId);

      return jsonResponse({
        orderId,
        externalOrderId: squareResult.externalOrderId,
        status: "sent_to_pos",
      });
    } catch (err) {
      // Anything unexpected past the claim step still has to resolve to a
      // terminal state — never leave the order stuck in sending_to_pos.
      const message = err instanceof Error ? err.message : "Order submission failed.";
      await failOrder(message);
      console.error("pos-square-order-submit error (post-claim):", err);
      return jsonResponse({ error: message }, 500);
    }
  } catch (err) {
    console.error("pos-square-order-submit error:", err);
    return jsonResponse({ error: err instanceof Error ? err.message : "Order submission failed." }, 500);
  }
}

if (import.meta.main) {
  Deno.serve(handler);
}