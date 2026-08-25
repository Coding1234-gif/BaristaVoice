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
  submitToPos,
  validateRequestShape,
  type CreateOrderRequestBody,
} from "./index.ts";

// ---------------------------------------------------------------------------
// validateRequestShape
// ---------------------------------------------------------------------------

Deno.test("validateRequestShape: accepts a well-formed request", () => {
  const body: CreateOrderRequestBody = {
    cafeId: "cafe-1",
    idempotencyKey: "idem-1",
    items: [{ menuItemId: "item-1", quantity: 2 }],
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
  const result = validateRequestShape({ cafeId: "c", idempotencyKey: "k", items: [{ quantity: 1 }] });
  assertEquals(result.ok, false);
  if (!result.ok) assertEquals(result.error, "Each order item must have a menuItemId.");
});

Deno.test("validateRequestShape: rejects a zero/negative quantity", () => {
  for (const quantity of [0, -1, -100]) {
    const result = validateRequestShape({
      cafeId: "c",
      idempotencyKey: "k",
      items: [{ menuItemId: "i", quantity }],
    });
    assertEquals(result.ok, false, `quantity ${quantity} should be rejected`);
  }
});

Deno.test("validateRequestShape: rejects a non-integer quantity", () => {
  const result = validateRequestShape({
    cafeId: "c",
    idempotencyKey: "k",
    items: [{ menuItemId: "i", quantity: 1.5 }],
  });
  assertEquals(result.ok, false);
});

Deno.test("validateRequestShape: rejects a missing quantity", () => {
  const result = validateRequestShape({ cafeId: "c", idempotencyKey: "k", items: [{ menuItemId: "i" }] });
  assertEquals(result.ok, false);
});

// ---------------------------------------------------------------------------
// buildRpcPayload — proves no price field can ever reach the database
// function's input, even if a manipulated client sends one.
// ---------------------------------------------------------------------------

Deno.test("buildRpcPayload: carries selections through but drops any client-supplied price fields", () => {
  const payload = buildRpcPayload({
    cafeId: "cafe-1",
    idempotencyKey: "idem-1",
    items: [
      {
        menuItemId: "item-1",
        quantity: 2,
        size: "Large",
        milk: "Oat",
        temperature: "hot",
        decaf: true,
        modifiers: ["Extra Shot"],
        specialRequest: "no whip",
        // A manipulated client trying to smuggle a price through — must be
        // dropped, not forwarded, since buildRpcPayload only reads the
        // known selection fields.
        unitPrice: 0.01,
        price: 0.01,
      } as unknown as Record<string, unknown>,
    ],
  });

  assertEquals(payload.cafe_id, "cafe-1");
  assertEquals(payload.idempotency_key, "idem-1");
  const items = payload.items as Record<string, unknown>[];
  assertEquals(items.length, 1);
  assertEquals(items[0].menuItemId, "item-1");
  assertEquals(items[0].quantity, 2);
  assertEquals(items[0].size, "Large");
  assertEquals(items[0].decaf, true);
  assertEquals(items[0].modifiers, ["Extra Shot"]);
  assertEquals("unitPrice" in items[0], false);
  assertEquals("price" in items[0], false);
});

Deno.test("buildRpcPayload: normalizes absent optional fields to null/empty, never undefined", () => {
  const payload = buildRpcPayload({
    cafeId: "cafe-1",
    idempotencyKey: "idem-1",
    items: [{ menuItemId: "item-1", quantity: 1 }],
  });
  const item = (payload.items as Record<string, unknown>[])[0];
  assertEquals(item.size, null);
  assertEquals(item.milk, null);
  assertEquals(item.temperature, null);
  assertEquals(item.decaf, false);
  assertEquals(item.modifiers, []);
  assertEquals(item.specialRequest, null);
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
