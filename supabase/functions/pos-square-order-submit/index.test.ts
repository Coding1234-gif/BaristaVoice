// Tests for pos-square-order-submit. Run with:
//   deno test --allow-env supabase/functions/pos-square-order-submit/index.test.ts
//
// Same boundary as pos-square-sync's tests: these exercise the pure,
// dependency-injected core (resolution, payload building, the Square call
// with an injected fetch, and the two authorization decision functions),
// not the Deno.serve handler end-to-end (needs a live Supabase project —
// the handler itself is a thin, already-established orchestration layer
// around these functions). Everything specific to "submit a canonical
// order to Square" — mapping resolution, modifier handling, idempotency-key
// forwarding, and the secret/body boundary — is pure and covered here.
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  authorizeOrderAccess,
  buildSquareCreateOrderPayload,
  dollarsToCents,
  ELIGIBLE_STATUSES,
  InvalidMappingError,
  isTrustedServiceRoleCaller,
  type ModifierCatalogLookup,
  type OrderLineInput,
  type ProductMappingLookup,
  resolveOrderLineItems,
  SquareApiError,
  submitOrderToSquare,
  UnmappedProductError,
} from "./index.ts";

// ---------------------------------------------------------------------------
// ELIGIBLE_STATUSES — regression guard for a real bug (confirmed live
// 2026-09-18): this used to be ["confirmed", "pos_failed"], but 'confirmed'
// has never been a legal orders.status value (see the live
// orders_status_check constraint in schema.sql), while create_canonical_order()
// always inserts a fresh order as 'pending'. So every newly-created order
// was rejected outright — "Order is not eligible for POS submission
// (status: pending)" — and never actually reached Square.
// ---------------------------------------------------------------------------

Deno.test("ELIGIBLE_STATUSES: includes 'pending' (what a freshly created order actually is)", () => {
  assert(ELIGIBLE_STATUSES.includes("pending"));
});

Deno.test("ELIGIBLE_STATUSES: does NOT include 'confirmed' (never a legal orders.status value)", () => {
  assert(!ELIGIBLE_STATUSES.includes("confirmed"));
});

// ---------------------------------------------------------------------------
// Fixtures: a two-item order (Latte with a resolved modifier + an ad-hoc
// one, and a Muffin with no modifiers), mirroring what a real canonical
// order's order_items/order_item_modifiers would look like.
// ---------------------------------------------------------------------------

const LATTE_LINE: OrderLineInput = {
  menuItemId: "menu-latte",
  name: "Latte",
  quantity: 2,
  unitPrice: 4.25,
  modifiers: [
    { name: "Extra Shot", priceAdjustment: 0.75, posModifierId: "posmod-extra-shot" },
    { name: "light ice", priceAdjustment: 0, posModifierId: null }, // ad-hoc, unmapped
  ],
};

const MUFFIN_LINE: OrderLineInput = {
  menuItemId: "menu-muffin",
  name: "Blueberry Muffin",
  quantity: 1,
  unitPrice: 3.5,
  modifiers: [],
};

function baseMappings(): Map<string, ProductMappingLookup> {
  return new Map([
    ["menu-latte", { externalProductId: "sq-latte-var", active: true }],
    ["menu-muffin", { externalProductId: "sq-muffin-var", active: true }],
  ]);
}

function baseModifierCatalog(): Map<string, ModifierCatalogLookup> {
  return new Map([
    ["posmod-extra-shot", { externalModifierId: "sq-mod-extra-shot", active: true }],
  ]);
}

// ---------------------------------------------------------------------------
// 1. Successful order (single item) + 2. multiple items
// ---------------------------------------------------------------------------

Deno.test("successful order: a single mapped item resolves cleanly", () => {
  const [resolved] = resolveOrderLineItems([MUFFIN_LINE], baseMappings(), baseModifierCatalog());
  assertEquals(resolved.externalProductId, "sq-muffin-var");
  assertEquals(resolved.basePriceCents, 350);
  assertEquals(resolved.modifiers, []);
});

Deno.test("multiple items: every line in the order resolves independently", () => {
  const resolved = resolveOrderLineItems([LATTE_LINE, MUFFIN_LINE], baseMappings(), baseModifierCatalog());
  assertEquals(resolved.length, 2);
  assertEquals(resolved[0].name, "Latte");
  assertEquals(resolved[0].quantity, 2);
  assertEquals(resolved[1].name, "Blueberry Muffin");
  assertEquals(resolved[1].externalProductId, "sq-muffin-var");
});

Deno.test("successful order: end-to-end payload -> Square call -> externalOrderId", async () => {
  const resolved = resolveOrderLineItems([MUFFIN_LINE], baseMappings(), baseModifierCatalog());
  const payload = buildSquareCreateOrderPayload({
    locationId: "loc-1",
    idempotencyKey: "idem-abc",
    currency: "USD",
    lineItems: resolved,
  });

  const fetchImpl = () =>
    Promise.resolve(new Response(JSON.stringify({ order: { id: "square-order-1" } }), { status: 200 }));

  const result = await submitOrderToSquare({
    accessToken: "token",
    baseUrl: "https://example.test",
    squareVersion: "2024-10-17",
    payload,
    fetchImpl: fetchImpl as unknown as typeof fetch,
  });

  assertEquals(result.externalOrderId, "square-order-1");
});

// ---------------------------------------------------------------------------
// 3. Modifiers
// ---------------------------------------------------------------------------

Deno.test("modifiers: a resolved (pos_modifier_id set) modifier maps to its catalog_object_id", () => {
  const [resolved] = resolveOrderLineItems([LATTE_LINE], baseMappings(), baseModifierCatalog());
  const extraShot = resolved.modifiers.find((m) => m.name === "Extra Shot")!;
  assertEquals(extraShot.externalModifierId, "sq-mod-extra-shot");
  assertEquals(extraShot.priceAdjustmentCents, 75);
});

Deno.test("modifiers: an unresolved (pos_modifier_id null) modifier is forwarded ad-hoc, not rejected", () => {
  const [resolved] = resolveOrderLineItems([LATTE_LINE], baseMappings(), baseModifierCatalog());
  const lightIce = resolved.modifiers.find((m) => m.name === "light ice")!;
  assertEquals(lightIce.externalModifierId, null);
  assertEquals(lightIce.priceAdjustmentCents, 0);
});

Deno.test("modifiers: payload sends catalog_object_id for resolved, name for ad-hoc", () => {
  const resolved = resolveOrderLineItems([LATTE_LINE], baseMappings(), baseModifierCatalog());
  const payload = buildSquareCreateOrderPayload({
    locationId: "loc-1",
    idempotencyKey: "idem-abc",
    currency: "USD",
    lineItems: resolved,
  });
  const mods = payload.order.line_items[0].modifiers as Record<string, unknown>[];
  assertEquals(mods[0].catalog_object_id, "sq-mod-extra-shot");
  assertEquals(mods[0].name, undefined);
  assertEquals(mods[1].catalog_object_id, undefined);
  assertEquals(mods[1].name, "light ice");
});

// ---------------------------------------------------------------------------
// 4. Unmapped product
// ---------------------------------------------------------------------------

Deno.test("unmapped product: no menu_item_id at all -> UnmappedProductError", () => {
  const line: OrderLineInput = { ...MUFFIN_LINE, menuItemId: null };
  try {
    resolveOrderLineItems([line], baseMappings(), baseModifierCatalog());
    throw new Error("expected UnmappedProductError");
  } catch (err) {
    assert(err instanceof UnmappedProductError);
    assertEquals(err.itemName, "Blueberry Muffin");
  }
});

Deno.test("unmapped product: menu_item_id has no pos_product_mappings row -> UnmappedProductError", () => {
  const mappings = new Map<string, ProductMappingLookup>(); // empty — nothing mapped
  try {
    resolveOrderLineItems([MUFFIN_LINE], mappings, baseModifierCatalog());
    throw new Error("expected UnmappedProductError");
  } catch (err) {
    assert(err instanceof UnmappedProductError);
  }
});

Deno.test("unmapped product: one bad item aborts the whole order, not just that line", () => {
  const mappings = baseMappings();
  mappings.delete("menu-muffin");
  assertThrowsSync(() => resolveOrderLineItems([LATTE_LINE, MUFFIN_LINE], mappings, baseModifierCatalog()));
});

function assertThrowsSync(fn: () => unknown) {
  try {
    fn();
  } catch {
    return;
  }
  throw new Error("expected function to throw");
}

// ---------------------------------------------------------------------------
// 5. Invalid mapping
// ---------------------------------------------------------------------------

Deno.test("invalid mapping: mapped product exists but is inactive -> InvalidMappingError", () => {
  const mappings = baseMappings();
  mappings.set("menu-muffin", { externalProductId: "sq-muffin-var", active: false });
  try {
    resolveOrderLineItems([MUFFIN_LINE], mappings, baseModifierCatalog());
    throw new Error("expected InvalidMappingError");
  } catch (err) {
    assert(err instanceof InvalidMappingError);
    assertEquals(err.itemName, "Blueberry Muffin");
  }
});

Deno.test("invalid mapping: modifier's pos_modifier_id points at a missing/inactive POS modifier", () => {
  const emptyModifierCatalog = new Map<string, ModifierCatalogLookup>(); // extra-shot mapping vanished
  try {
    resolveOrderLineItems([LATTE_LINE], baseMappings(), emptyModifierCatalog);
    throw new Error("expected InvalidMappingError");
  } catch (err) {
    assert(err instanceof InvalidMappingError);
    assert(err.message.includes("Extra Shot"));
  }
});

Deno.test("invalid mapping: modifier's POS modifier exists but is inactive", () => {
  const catalog = new Map<string, ModifierCatalogLookup>([
    ["posmod-extra-shot", { externalModifierId: "sq-mod-extra-shot", active: false }],
  ]);
  try {
    resolveOrderLineItems([LATTE_LINE], baseMappings(), catalog);
    throw new Error("expected InvalidMappingError");
  } catch (err) {
    assert(err instanceof InvalidMappingError);
  }
});

// ---------------------------------------------------------------------------
// 6. Square API failure
// ---------------------------------------------------------------------------

Deno.test("Square API failure: a non-2xx response throws SquareApiError with status + bounded detail", async () => {
  const fetchImpl = () => Promise.resolve(new Response(JSON.stringify({ errors: ["boom"] }), { status: 500 }));

  const err = await assertRejects(
    () =>
      submitOrderToSquare({
        accessToken: "token",
        baseUrl: "https://example.test",
        squareVersion: "2024-10-17",
        payload: {},
        fetchImpl: fetchImpl as unknown as typeof fetch,
      }),
    SquareApiError,
  );
  assertEquals((err as SquareApiError).status, 500);
});

Deno.test("Square API failure: a 200 with no order id still fails loudly rather than returning undefined", async () => {
  const fetchImpl = () => Promise.resolve(new Response(JSON.stringify({}), { status: 200 }));

  await assertRejects(
    () =>
      submitOrderToSquare({
        accessToken: "token",
        baseUrl: "https://example.test",
        squareVersion: "2024-10-17",
        payload: {},
        fetchImpl: fetchImpl as unknown as typeof fetch,
      }),
    SquareApiError,
  );
});

// ---------------------------------------------------------------------------
// 7. Retry / idempotency
// ---------------------------------------------------------------------------

Deno.test("idempotency: the same order's idempotency_key is forwarded unchanged into the Square payload", () => {
  const resolved = resolveOrderLineItems([MUFFIN_LINE], baseMappings(), baseModifierCatalog());
  const payload = buildSquareCreateOrderPayload({
    locationId: "loc-1",
    idempotencyKey: "order-idem-key-123",
    currency: "USD",
    lineItems: resolved,
  });
  assertEquals(payload.idempotency_key, "order-idem-key-123");
});

Deno.test("idempotency: building the payload twice from the same order data is byte-identical", () => {
  const resolved1 = resolveOrderLineItems([LATTE_LINE, MUFFIN_LINE], baseMappings(), baseModifierCatalog());
  const resolved2 = resolveOrderLineItems([LATTE_LINE, MUFFIN_LINE], baseMappings(), baseModifierCatalog());
  const payload1 = buildSquareCreateOrderPayload({
    locationId: "loc-1",
    idempotencyKey: "idem-1",
    currency: "USD",
    lineItems: resolved1,
  });
  const payload2 = buildSquareCreateOrderPayload({
    locationId: "loc-1",
    idempotencyKey: "idem-1",
    currency: "USD",
    lineItems: resolved2,
  });
  assertEquals(payload1, payload2);
});

Deno.test("idempotency: a retried Square call with the same idempotency_key surfaces Square's own dedup result", async () => {
  // Simulates Square recognizing the idempotency key from a prior attempt
  // and returning the SAME order id rather than creating a new one — the
  // adapter has no special-case code path for this; it's just what Square
  // returns, and submitOrderToSquare treats it like any other success.
  let calls = 0;
  const fetchImpl = () => {
    calls++;
    return Promise.resolve(new Response(JSON.stringify({ order: { id: "square-order-dedup" } }), { status: 200 }));
  };

  const first = await submitOrderToSquare({
    accessToken: "token",
    baseUrl: "https://example.test",
    squareVersion: "2024-10-17",
    payload: { idempotency_key: "same-key" },
    fetchImpl: fetchImpl as unknown as typeof fetch,
  });
  const second = await submitOrderToSquare({
    accessToken: "token",
    baseUrl: "https://example.test",
    squareVersion: "2024-10-17",
    payload: { idempotency_key: "same-key" },
    fetchImpl: fetchImpl as unknown as typeof fetch,
  });

  assertEquals(first.externalOrderId, second.externalOrderId);
  assertEquals(calls, 2); // both calls were made (retry), both landed on the same Square order
});

// ---------------------------------------------------------------------------
// 8. Cross-cafe authorization
// ---------------------------------------------------------------------------

Deno.test("authorization: cafe_admin of the SAME cafe as the order is allowed", () => {
  const result = authorizeOrderAccess({ role: "cafe_admin", cafeId: "cafe-1" }, "cafe-1");
  assertEquals(result.allowed, true);
});

Deno.test("authorization: cafe_admin of a DIFFERENT cafe cannot submit another cafe's order", () => {
  const result = authorizeOrderAccess({ role: "cafe_admin", cafeId: "cafe-1" }, "cafe-2");
  assertEquals(result.allowed, false);
  assertEquals(result.reason, "You do not have access to this order.");
});

Deno.test("authorization: super_admin can submit any cafe's order", () => {
  const result = authorizeOrderAccess({ role: "super_admin", cafeId: null }, "cafe-anything");
  assertEquals(result.allowed, true);
});

Deno.test("authorization: a non-admin role is denied", () => {
  const result = authorizeOrderAccess({ role: "customer", cafeId: null }, "cafe-1");
  assertEquals(result.allowed, false);
});

Deno.test("authorization: isTrustedServiceRoleCaller only matches the exact configured service-role key", () => {
  assertEquals(isTrustedServiceRoleCaller("Bearer real-key", "real-key"), true);
  assertEquals(isTrustedServiceRoleCaller("Bearer wrong-key", "real-key"), false);
  assertEquals(isTrustedServiceRoleCaller("Bearer real-key", undefined), false);
  assertEquals(isTrustedServiceRoleCaller("real-key", "real-key"), false); // missing "Bearer " prefix
});

// ---------------------------------------------------------------------------
// 9. Secret-access boundaries
// ---------------------------------------------------------------------------

Deno.test("secret boundary: the access token appears only in the Authorization header, never in the request body", async () => {
  const SECRET = "sq-access-token-do-not-leak";
  let capturedHeaders: Headers | undefined;
  let capturedBody: string | undefined;

  const fetchImpl = (_url: string, init?: RequestInit) => {
    capturedHeaders = new Headers(init?.headers);
    capturedBody = init?.body as string;
    return Promise.resolve(new Response(JSON.stringify({ order: { id: "square-order-1" } }), { status: 200 }));
  };

  const resolved = resolveOrderLineItems([MUFFIN_LINE], baseMappings(), baseModifierCatalog());
  const payload = buildSquareCreateOrderPayload({
    locationId: "loc-1",
    idempotencyKey: "idem-abc",
    currency: "USD",
    lineItems: resolved,
  });

  await submitOrderToSquare({
    accessToken: SECRET,
    baseUrl: "https://example.test",
    squareVersion: "2024-10-17",
    payload,
    fetchImpl: fetchImpl as unknown as typeof fetch,
  });

  assertEquals(capturedHeaders?.get("Authorization"), `Bearer ${SECRET}`);
  assert(!capturedBody?.includes(SECRET), "the Square request body must never contain the access token");
});

Deno.test("secret boundary: a resolved line item's shape carries no token/secret field at all", () => {
  const [resolved] = resolveOrderLineItems([MUFFIN_LINE], baseMappings(), baseModifierCatalog());
  assertEquals(Object.keys(resolved).sort(), ["basePriceCents", "externalProductId", "modifiers", "name", "quantity"]);
});

Deno.test("secret boundary: a successful submission's own return value carries no token/secret field", async () => {
  const fetchImpl = () =>
    Promise.resolve(new Response(JSON.stringify({ order: { id: "square-order-1" } }), { status: 200 }));

  const result = await submitOrderToSquare({
    accessToken: "sq-access-token-do-not-leak",
    baseUrl: "https://example.test",
    squareVersion: "2024-10-17",
    payload: {},
    fetchImpl: fetchImpl as unknown as typeof fetch,
  });

  assertEquals(Object.keys(result).sort(), ["externalOrderId", "raw"]);
  assert(!JSON.stringify(result).includes("do-not-leak"));
});

// ---------------------------------------------------------------------------
// dollarsToCents edge cases (feeds every price field above)
// ---------------------------------------------------------------------------

Deno.test("dollarsToCents: rounds to the nearest cent", () => {
  assertEquals(dollarsToCents(4.25), 425);
  assertEquals(dollarsToCents(0), 0);
  assertEquals(dollarsToCents(3.999), 400);
});
