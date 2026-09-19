// Tests for create-order. Run with:
//   deno test --allow-env supabase/functions/create-order/index.test.ts
//
// Same boundary as pos-square-sync/pos-square-order-submit's tests: these
// exercise the pure, dependency-injected core (request-shape validation,
// RPC payload shaping, error classification, and the relay to
// pos-square-order-submit with an injected fetch) — not the Deno.serve
// handler end-to-end (needs a live Supabase project with
// create_canonical_order() installed). Everything that decides whether an
// item/option/price is actually VALID lives in create_canonical_order()
// itself (see supabase/schema.sql) and is covered by
// supabase/tests/create_canonical_order_test.sql instead, for the same
// reason pos_product_mappings_test.sql exists: that logic depends on real
// menu_items/orders rows and can't be meaningfully exercised without a
// database.
import { assertEquals } from "jsr:@std/assert@1";
import {
  buildRpcPayload,
  classifyRpcError,
  computeUnitPrice,
  extractOrderRow,
  resolveUnitPrices,
  submitToPos,
  validateRequestShape,
  type CreateOrderRequestBody,
  type MenuItemPricingData,
  type RawOrderItem,
} from "./index.ts";

// ---------------------------------------------------------------------------
// validateRequestShape
// ---------------------------------------------------------------------------

Deno.test("validateRequestShape: accepts a well-formed request", () => {
  const body: CreateOrderRequestBody = {
    cafeId: "cafe-1",
    idempotencyKey: "idem-1",
    items: [{ menuItemId: "item-1", name: "Latte", quantity: 2 }],
  };
  const result = validateRequestShape(body);
  assertEquals(result.ok, true);
  if (result.ok) {
    assertEquals(result.value.cafeId, "cafe-1");
    assertEquals(result.value.items.length, 1);
  }
});

Deno.test("validateRequestShape: rejects a missing cafeId", () => {
  const result = validateRequestShape({ idempotencyKey: "idem-1", items: [{ menuItemId: "i", quantity: 1 }] });
  assertEquals(result.ok, false);
  if (!result.ok) assertEquals(result.error, "cafeId is required.");
});

Deno.test("validateRequestShape: rejects a missing idempotencyKey", () => {
  const result = validateRequestShape({ cafeId: "c", items: [{ menuItemId: "i", quantity: 1 }] });
  assertEquals(result.ok, false);
  if (!result.ok) assertEquals(result.error, "idempotencyKey is required.");
});

Deno.test("validateRequestShape: rejects empty items", () => {
  const result = validateRequestShape({ cafeId: "c", idempotencyKey: "k", items: [] });
  assertEquals(result.ok, false);
  if (!result.ok) assertEquals(result.error, "Order has no items.");
});

Deno.test("validateRequestShape: rejects items that are not an array", () => {
  const result = validateRequestShape({ cafeId: "c", idempotencyKey: "k", items: "not-an-array" });
  assertEquals(result.ok, false);
});

Deno.test("validateRequestShape: rejects an item with no menuItemId", () => {
  const result = validateRequestShape({ cafeId: "c", idempotencyKey: "k", items: [{ name: "Latte", quantity: 1 }] });
  assertEquals(result.ok, false);
  if (!result.ok) assertEquals(result.error, "Each order item must have a menuItemId.");
});

// Regression guard for a real bug (confirmed live 2026-09-18):
// RawOrderItem/buildRpcPayload never declared or forwarded `name` at all,
// even though the Dart client always sends it — every order_items.name
// silently ended up '', which then broke pos-square-order-submit's error
// messages AND the line-item name it sends to Square.
Deno.test("validateRequestShape: rejects an item with no name", () => {
  const result = validateRequestShape({
    cafeId: "c",
    idempotencyKey: "k",
    items: [{ menuItemId: "item-1", quantity: 1 }],
  });
  assertEquals(result.ok, false);
  if (!result.ok) assertEquals(result.error, "Each order item must have a name.");
});

Deno.test("validateRequestShape: rejects a zero/negative quantity", () => {
  for (const quantity of [0, -1, -100]) {
    const result = validateRequestShape({
      cafeId: "c",
      idempotencyKey: "k",
      items: [{ menuItemId: "i", name: "Latte", quantity }],
    });
    assertEquals(result.ok, false, `quantity ${quantity} should be rejected`);
  }
});

Deno.test("validateRequestShape: rejects a non-integer quantity", () => {
  const result = validateRequestShape({
    cafeId: "c",
    idempotencyKey: "k",
    items: [{ menuItemId: "i", name: "Latte", quantity: 1.5 }],
  });
  assertEquals(result.ok, false);
});

Deno.test("validateRequestShape: rejects a missing quantity", () => {
  const result = validateRequestShape({
    cafeId: "c",
    idempotencyKey: "k",
    items: [{ menuItemId: "i", name: "Latte" }],
  });
  assertEquals(result.ok, false);
});

// ---------------------------------------------------------------------------
// buildRpcPayload — proves no price field can ever reach the database
// function's input, even if a manipulated client sends one.
// ---------------------------------------------------------------------------

Deno.test("buildRpcPayload: carries selections through, ignores any client-supplied price field, and uses the given unitPrices", () => {
  const payload = buildRpcPayload(
    {
      cafeId: "cafe-1",
      idempotencyKey: "idem-1",
      items: [
        {
          menuItemId: "item-1",
          name: "Latte",
          quantity: 2,
          size: "Large",
          milk: "Oat",
          temperature: "hot",
          decaf: true,
          modifiers: ["Extra Shot"],
          specialRequest: "no whip",
          // A manipulated client trying to smuggle a price through — must
          // be ignored, not forwarded: buildRpcPayload only ever reads the
          // unit price from its own `unitPrices` parameter, never from the
          // request item itself.
          unitPrice: 0.01,
          price: 0.01,
        } as unknown as Record<string, unknown>,
      ],
    },
    [3.7],
  );

  assertEquals(payload.cafe_id, "cafe-1");
  assertEquals(payload.idempotency_key, "idem-1");
  const items = payload.items as Record<string, unknown>[];
  assertEquals(items.length, 1);
  assertEquals(items[0].menu_item_id, "item-1");
  assertEquals(items[0].name, "Latte");
  assertEquals(items[0].quantity, 2);
  assertEquals(items[0].unit_price, 3.7);
  // Modifiers must be OBJECTS (the RPC reads `->>'name'`), with a 0
  // price_adjustment — unit_price already includes the delta, and Square
  // adds modifier prices on top of the base price.
  assertEquals(items[0].modifiers, [{ name: "Extra Shot", price_adjustment: 0 }]);
  // Selections the RPC would otherwise ignore are persisted via `metadata`.
  assertEquals(items[0].metadata, {
    size: "Large",
    milk: "Oat",
    temperature: "hot",
    decaf: true,
    specialRequest: "no whip",
  });
});

Deno.test("buildRpcPayload: normalizes absent optional fields to null/empty, never undefined", () => {
  const payload = buildRpcPayload(
    { cafeId: "cafe-1", idempotencyKey: "idem-1", items: [{ menuItemId: "item-1", quantity: 1 }] },
    [3.3],
  );
  const item = (payload.items as Record<string, unknown>[])[0];
  assertEquals(item.unit_price, 3.3);
  assertEquals(item.name, "");
  assertEquals(item.modifiers, []);
  assertEquals(item.metadata, {
    size: null,
    milk: null,
    temperature: null,
    decaf: false,
    specialRequest: null,
  });
});

Deno.test("buildRpcPayload: an item with no matching price (index out of range) defaults to 0, never undefined", () => {
  const payload = buildRpcPayload(
    { cafeId: "cafe-1", idempotencyKey: "idem-1", items: [{ menuItemId: "item-1", quantity: 1 }] },
    [],
  );
  const item = (payload.items as Record<string, unknown>[])[0];
  assertEquals(item.unit_price, 0);
});

// ---------------------------------------------------------------------------
// computeUnitPrice — mirrors OrderItem.unitPrice() in
// app/lib/models/order.dart; keep these two in sync if either changes.
// ---------------------------------------------------------------------------

const latte: MenuItemPricingData = {
  basePrice: 3.30,
  sizes: [{ name: "Regular", priceDelta: 0 }, { name: "Large", priceDelta: 0.40 }],
  milkOptions: [
    { name: "Dairy", priceDelta: 0 },
    { name: "Oat", priceDelta: 0.50 },
  ],
  modifiers: [{ name: "Extra shot", priceDelta: 0.60 }, { name: "Vanilla syrup", priceDelta: 0.50 }],
};

Deno.test("computeUnitPrice: base price alone when nothing is selected", () => {
  assertEquals(computeUnitPrice(latte, {}), 3.30);
});

Deno.test("computeUnitPrice: adds the matched size, milk, and every matched modifier delta", () => {
  const price = computeUnitPrice(latte, { size: "Large", milk: "Oat", modifiers: ["Extra shot"] });
  // 3.30 + 0.40 + 0.50 + 0.60
  assertEquals(price, 4.80);
});

Deno.test("computeUnitPrice: an unmatched size/milk/modifier name contributes nothing, never throws", () => {
  const price = computeUnitPrice(latte, { size: "Huge", milk: "Coconut", modifiers: ["Sprinkles"] });
  assertEquals(price, 3.30);
});

Deno.test("computeUnitPrice: multiple modifiers all stack", () => {
  const price = computeUnitPrice(latte, { modifiers: ["Extra shot", "Vanilla syrup"] });
  // 3.30 + 0.60 + 0.50
  assertEquals(price, 4.40);
});

// ---------------------------------------------------------------------------
// resolveUnitPrices — aligns computed prices by index with the input items,
// via an injected fetch (same DI pattern as submitToPos's fetchImpl) so this
// is exercised without a live database.
// ---------------------------------------------------------------------------

Deno.test("resolveUnitPrices: prices two items referencing the SAME menu item but different selections independently", async () => {
  const items: RawOrderItem[] = [
    { menuItemId: "latte-id", quantity: 1, size: "Large", milk: "Oat" },
    { menuItemId: "latte-id", quantity: 1 },
  ];

  const prices = await resolveUnitPrices(items, (ids) => {
    assertEquals(ids, ["latte-id"]);
    return Promise.resolve([{ id: "latte-id", data: latte }]);
  });

  assertEquals(prices, [4.20, 3.30]); // 3.30 + 0.40 + 0.50, and plain 3.30
});

Deno.test("resolveUnitPrices: a menu item id the fetch doesn't return prices at 0, not an error", async () => {
  const items: RawOrderItem[] = [{ menuItemId: "does-not-exist", quantity: 1 }];
  const prices = await resolveUnitPrices(items, () => Promise.resolve([]));
  assertEquals(prices, [0]);
});

// ---------------------------------------------------------------------------
// extractOrderRow — the row's PK column is `id`, not `order_id`
// (create_canonical_order() is `RETURNS orders`, the whole table row).
// This fixture is the exact row shape logged from a real, successful RPC
// call on 2026-09-18 — a prior version of this parsing reported that
// success back to the kiosk as a failure.
// ---------------------------------------------------------------------------

const realOrderRow = {
  id: "b0f1facf-750b-4487-8b7f-d91ca6cfa781",
  cafe_id: "2e93cdf0-cdfb-4e16-8fe2-f01ff9877605",
  order_number: 1,
  status: "pending",
  source: "voice",
  total: 7,
  currency: "GBP",
  pos_connection_id: null,
  pos_provider: null,
  external_order_id: null,
  idempotency_key: "3f079726-1a11-4e3a-94e9-3c6d96694b5f",
  last_pos_error: null,
  created_at: "2026-09-18T18:02:52.989302+00:00",
  updated_at: "2026-09-18T18:02:52.989302+00:00",
  external_payment_id: null,
  completed_at: null,
};

Deno.test("extractOrderRow: reads a real create_canonical_order() row (single object, not wrapped in an array)", () => {
  const row = extractOrderRow(realOrderRow);
  assertEquals(row, { id: "b0f1facf-750b-4487-8b7f-d91ca6cfa781", status: "pending", total: 7 });
});

Deno.test("extractOrderRow: also accepts Postgrest's single-row-wrapped-in-an-array shape", () => {
  const row = extractOrderRow([realOrderRow]);
  assertEquals(row, { id: "b0f1facf-750b-4487-8b7f-d91ca6cfa781", status: "pending", total: 7 });
});

Deno.test("extractOrderRow: null/undefined/empty-array all resolve to null, not a throw", () => {
  assertEquals(extractOrderRow(null), null);
  assertEquals(extractOrderRow(undefined), null);
  assertEquals(extractOrderRow([]), null);
});

Deno.test("extractOrderRow: a row with order_id instead of id (the old, wrong shape) is rejected as malformed", () => {
  assertEquals(extractOrderRow({ order_id: "x", status: "pending", total: 7 }), null);
});

// ---------------------------------------------------------------------------
// classifyRpcError
// ---------------------------------------------------------------------------

Deno.test("classifyRpcError: a Postgres error with a code is a 400 with its message", () => {
  const { status, message } = classifyRpcError({ code: "P0001", message: 'Invalid size "Huge" for "Latte".' });
  assertEquals(status, 400);
  assertEquals(message, 'Invalid size "Huge" for "Latte".');
});

Deno.test("classifyRpcError: an error with no code is a generic 500", () => {
  const { status, message } = classifyRpcError({ message: "connection reset" });
  assertEquals(status, 500);
  assertEquals(message, "Could not create the order. Please try again.");
});

Deno.test("classifyRpcError: null error still resolves to a safe 500", () => {
  const { status } = classifyRpcError(null);
  assertEquals(status, 500);
});

// ---------------------------------------------------------------------------
// submitToPos — the relay to the EXISTING pos-square-order-submit function.
// ---------------------------------------------------------------------------

Deno.test("submitToPos: relays a successful Square submission", async () => {
  const outcome = await submitToPos({
    orderId: "order-1",
    supabaseUrl: "https://example.supabase.co",
    serviceRoleKey: "service-role-key",
    fetchImpl: (async (url: string, init?: RequestInit) => {
      assertEquals(url, "https://example.supabase.co/functions/v1/pos-square-order-submit");
      assertEquals((init?.headers as Record<string, string>)?.Authorization, "Bearer service-role-key");
      assertEquals(JSON.parse(init!.body as string), { orderId: "order-1" });
      return new Response(
        JSON.stringify({ orderId: "order-1", externalOrderId: "sq-123", status: "sent_to_pos" }),
        { status: 200 },
      );
    }) as unknown as typeof fetch,
  });

  assertEquals(outcome.attempted, true);
  assertEquals(outcome.status, "sent_to_pos");
  assertEquals(outcome.externalOrderId, "sq-123");
  assertEquals(outcome.error, null);
});

Deno.test("submitToPos: relays a POS failure without claiming success", async () => {
  const outcome = await submitToPos({
    orderId: "order-1",
    supabaseUrl: "https://example.supabase.co",
    serviceRoleKey: "service-role-key",
    fetchImpl: (async () =>
      new Response(JSON.stringify({ error: "No active Square connection for this cafe." }), { status: 400 })
    ) as unknown as typeof fetch,
  });

  assertEquals(outcome.attempted, true);
  assertEquals(outcome.status, null);
  assertEquals(outcome.error, "No active Square connection for this cafe.");
});

Deno.test("submitToPos: a network failure reaching the function is reported, not swallowed as success", async () => {
  const outcome = await submitToPos({
    orderId: "order-1",
    supabaseUrl: "https://example.supabase.co",
    serviceRoleKey: "service-role-key",
    fetchImpl: (async () => {
      throw new Error("network unreachable");
    }) as unknown as typeof fetch,
  });

  assertEquals(outcome.attempted, false);
  assertEquals(outcome.status, null);
  assertEquals(outcome.error, "network unreachable");
});
