// Tests for pos-square-sync. Run with:
//   deno test --allow-env supabase/functions/pos-square-sync/index.test.ts
//
// These exercise the function's pure, dependency-injected core (catalog
// normalization, pagination/fetch, row shaping, and the authorization
// decision) rather than the Deno.serve handler end-to-end — that handler's
// remaining code is a thin, already-established pass-through to Supabase
// (identical in shape to menu-extractor's, which has no tests of its own
// either) and would need a live Supabase project to exercise meaningfully.
// Everything that is actually specific to this function — Square catalog
// shape, idempotent row construction, provider-id preservation, and the
// cafe-isolation decision — is pure and is fully covered here.
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  authorizeConnectionAccess,
  buildModifierRows,
  buildProductRows,
  centsToDecimal,
  fetchAllCatalogObjects,
  normalizeCatalogObjects,
  SquareApiError,
} from "./index.ts";

// ---------------------------------------------------------------------------
// Fixtures — a small, realistic Square catalog: one item with two variations
// (sizes), one single-variation item, one modifier list with two modifiers,
// and one category.
// ---------------------------------------------------------------------------

const CATEGORY_OBJECT = {
  type: "CATEGORY",
  id: "cat_espresso",
  updated_at: "2026-01-01T00:00:00Z",
  category_data: { name: "Espresso Drinks" },
};

const LATTE_ITEM = {
  type: "ITEM",
  id: "item_latte",
  updated_at: "2026-01-02T00:00:00Z",
  item_data: {
    name: "Latte",
    category_id: "cat_espresso",
    variations: [
      {
        type: "ITEM_VARIATION",
        id: "var_latte_small",
        updated_at: "2026-01-02T00:00:00Z",
        item_variation_data: { name: "Small", price_money: { amount: 425, currency: "USD" } },
      },
      {
        type: "ITEM_VARIATION",
        id: "var_latte_large",
        updated_at: "2026-01-02T00:00:00Z",
        item_variation_data: { name: "Large", price_money: { amount: 525, currency: "USD" } },
      },
    ],
  },
};

const MUFFIN_ITEM = {
  type: "ITEM",
  id: "item_muffin",
  updated_at: "2026-01-03T00:00:00Z",
  item_data: {
    name: "Blueberry Muffin",
    variations: [
      {
        type: "ITEM_VARIATION",
        id: "var_muffin_regular",
        updated_at: "2026-01-03T00:00:00Z",
        item_variation_data: { name: "Regular", price_money: { amount: 350 } },
      },
    ],
  },
};

const MODIFIER_LIST_OBJECT = {
  type: "MODIFIER_LIST",
  id: "modlist_extras",
  updated_at: "2026-01-04T00:00:00Z",
  modifier_list_data: {
    name: "Extras",
    modifiers: [
      {
        type: "MODIFIER",
        id: "mod_extra_shot",
        updated_at: "2026-01-04T00:00:00Z",
        modifier_data: { name: "Extra Shot", price_money: { amount: 75 } },
      },
      {
        type: "MODIFIER",
        id: "mod_no_charge",
        updated_at: "2026-01-04T00:00:00Z",
        modifier_data: { name: "No Foam" }, // no price_money at all
      },
    ],
  },
};

const FULL_CATALOG = [CATEGORY_OBJECT, LATTE_ITEM, MUFFIN_ITEM, MODIFIER_LIST_OBJECT];

// ---------------------------------------------------------------------------
// 1. Successful catalog sync (normalization + row shaping end to end)
// ---------------------------------------------------------------------------

Deno.test("successful sync: normalizes items+variations+category into product rows", () => {
  const { products } = normalizeCatalogObjects(FULL_CATALOG);

  assertEquals(products.length, 3); // 2 latte sizes + 1 muffin

  const small = products.find((p) => p.externalProductId === "var_latte_small");
  assert(small);
  assertEquals(small.name, "Latte - Small");
  assertEquals(small.category, "Espresso Drinks");
  assertEquals(small.price, 4.25);
  assertEquals(small.active, true);

  const muffin = products.find((p) => p.externalProductId === "var_muffin_regular");
  assert(muffin);
  // Only variation on this item -> no "<item> - <variation>" suffix.
  assertEquals(muffin.name, "Blueberry Muffin");
  assertEquals(muffin.category, null); // item has no category_id
  assertEquals(muffin.price, 3.5);
});

Deno.test("successful sync: buildProductRows/buildModifierRows attach connection+cafe scoping", () => {
  const { products, modifiers } = normalizeCatalogObjects(FULL_CATALOG);
  const syncedAt = "2026-02-01T00:00:00Z";
  const productRows = buildProductRows("conn-1", "cafe-1", products, syncedAt);
  const modifierRows = buildModifierRows("conn-1", "cafe-1", modifiers, syncedAt);

  assertEquals(productRows.length, 3);
  assertEquals(modifierRows.length, 2);
  for (const row of productRows) {
    assertEquals(row.pos_connection_id, "conn-1");
    assertEquals(row.cafe_id, "cafe-1");
    assertEquals(row.last_synced_at, syncedAt);
  }
  for (const row of modifierRows) {
    assertEquals(row.pos_connection_id, "conn-1");
    assertEquals(row.cafe_id, "cafe-1");
  }
});

Deno.test("successful sync: fetchAllCatalogObjects follows pagination cursors", async () => {
  const calls: string[] = [];
  const fetchImpl = (input: string | URL) => {
    const url = new URL(input.toString());
    calls.push(url.searchParams.get("cursor") ?? "first");
    if (!url.searchParams.get("cursor")) {
      return Promise.resolve(
        new Response(JSON.stringify({ objects: [CATEGORY_OBJECT, LATTE_ITEM], cursor: "page2" }), {
          status: 200,
        }),
      );
    }
    return Promise.resolve(
      new Response(JSON.stringify({ objects: [MUFFIN_ITEM, MODIFIER_LIST_OBJECT] }), { status: 200 }),
    );
  };

  const objects = await fetchAllCatalogObjects({
    accessToken: "token",
    baseUrl: "https://example.test",
    squareVersion: "2024-10-17",
    fetchImpl: fetchImpl as unknown as typeof fetch,
  });

  assertEquals(calls, ["first", "page2"]);
  assertEquals(objects.length, 4);
});

// ---------------------------------------------------------------------------
// 2. Repeated sync / idempotency
// ---------------------------------------------------------------------------

Deno.test("idempotency: normalizing + row-building the same catalog twice is byte-identical", () => {
  const first = normalizeCatalogObjects(FULL_CATALOG);
  const second = normalizeCatalogObjects(FULL_CATALOG);
  assertEquals(first, second);

  const rows1 = buildProductRows("conn-1", "cafe-1", first.products, "2026-01-01T00:00:00Z");
  const rows2 = buildProductRows("conn-1", "cafe-1", second.products, "2026-01-01T00:00:00Z");
  assertEquals(rows1, rows2);
});

Deno.test("idempotency: repeat sync targets the same conflict key, not a new row", () => {
  // No `id` field is ever produced by buildProductRows/buildModifierRows —
  // that's what makes an upsert on (pos_connection_id, external_product_id)
  // land on the SAME existing row every time instead of inserting a
  // duplicate. Asserting the shape has no `id` key is a direct regression
  // guard for that property.
  const { products, modifiers } = normalizeCatalogObjects(FULL_CATALOG);
  const productRows = buildProductRows("conn-1", "cafe-1", products, "2026-01-01T00:00:00Z");
  const modifierRows = buildModifierRows("conn-1", "cafe-1", modifiers, "2026-01-01T00:00:00Z");

  for (const row of [...productRows, ...modifierRows]) {
    assertEquals(Object.prototype.hasOwnProperty.call(row, "id"), false);
  }

  // The natural key used by the DB's unique index/upsert target.
  const keys = productRows.map((r) => `${r.pos_connection_id}:${r.external_product_id}`);
  assertEquals(new Set(keys).size, keys.length); // no duplicate keys within one sync
});

// ---------------------------------------------------------------------------
// 3. Provider ID preservation
// ---------------------------------------------------------------------------

Deno.test("provider IDs: external_product_id is Square's variation id, not the parent item id", () => {
  const { products } = normalizeCatalogObjects(FULL_CATALOG);
  const small = products.find((p) => p.name === "Latte - Small")!;
  const large = products.find((p) => p.name === "Latte - Large")!;

  assertEquals(small.externalProductId, "var_latte_small");
  assertEquals(large.externalProductId, "var_latte_large");
  assert(small.externalProductId !== LATTE_ITEM.id);
  assertEquals(small.metadata.squareItemId, "item_latte");
  assertEquals(small.metadata.squareVariationId, "var_latte_small");
});

Deno.test("provider IDs: external_modifier_id is the modifier's own id, not the modifier list id", () => {
  const { modifiers } = normalizeCatalogObjects(FULL_CATALOG);
  const extraShot = modifiers.find((m) => m.name === "Extra Shot")!;

  assertEquals(extraShot.externalModifierId, "mod_extra_shot");
  assert(extraShot.externalModifierId !== MODIFIER_LIST_OBJECT.id);
  assertEquals(extraShot.metadata.squareModifierListId, "modlist_extras");
});

Deno.test("provider IDs: survive unchanged into the upsert row", () => {
  const { products, modifiers } = normalizeCatalogObjects(FULL_CATALOG);
  const productRows = buildProductRows("conn-1", "cafe-1", products, "2026-01-01T00:00:00Z");
  const modifierRows = buildModifierRows("conn-1", "cafe-1", modifiers, "2026-01-01T00:00:00Z");

  assert(productRows.some((r) => r.external_product_id === "var_latte_small"));
  assert(modifierRows.some((r) => r.external_modifier_id === "mod_extra_shot"));
});

// ---------------------------------------------------------------------------
// 4. Modifier handling
// ---------------------------------------------------------------------------

Deno.test("modifiers: price_adjustment is computed from cents, defaults to 0 when unpriced", () => {
  const { modifiers } = normalizeCatalogObjects(FULL_CATALOG);
  const extraShot = modifiers.find((m) => m.externalModifierId === "mod_extra_shot")!;
  const noFoam = modifiers.find((m) => m.externalModifierId === "mod_no_charge")!;

  assertEquals(extraShot.priceAdjustment, 0.75);
  assertEquals(noFoam.priceAdjustment, 0); // no price_money -> 0, not null (modifiers always have a numeric adjustment)
});

Deno.test("modifiers: a modifier list with no modifiers contributes nothing, doesn't throw", () => {
  const emptyList = {
    type: "MODIFIER_LIST",
    id: "modlist_empty",
    modifier_list_data: { name: "Empty", modifiers: [] },
  };
  const { modifiers } = normalizeCatalogObjects([emptyList]);
  assertEquals(modifiers, []);
});

Deno.test("modifiers: deleted modifiers and modifier lists are excluded", () => {
  const deletedModifier = {
    ...MODIFIER_LIST_OBJECT,
    id: "modlist_with_deleted",
    modifier_list_data: {
      name: "Extras",
      modifiers: [
        { ...MODIFIER_LIST_OBJECT.modifier_list_data.modifiers[0], is_deleted: true },
        MODIFIER_LIST_OBJECT.modifier_list_data.modifiers[1],
      ],
    },
  };
  const { modifiers } = normalizeCatalogObjects([deletedModifier]);
  assertEquals(modifiers.length, 1);
  assertEquals(modifiers[0].externalModifierId, "mod_no_charge");
});

// ---------------------------------------------------------------------------
// 5. Authorization boundaries
// ---------------------------------------------------------------------------

Deno.test("authorization: cafe_admin of the SAME cafe is allowed", () => {
  const result = authorizeConnectionAccess({ role: "cafe_admin", cafeId: "cafe-1" }, "cafe-1");
  assertEquals(result.allowed, true);
});

Deno.test("authorization: cafe_admin of a DIFFERENT cafe is denied — cannot sync another cafe's connection", () => {
  const result = authorizeConnectionAccess({ role: "cafe_admin", cafeId: "cafe-1" }, "cafe-2");
  assertEquals(result.allowed, false);
  assertEquals(result.reason, "You do not have access to this POS connection.");
});

Deno.test("authorization: super_admin is allowed regardless of cafe", () => {
  const result = authorizeConnectionAccess({ role: "super_admin", cafeId: null }, "cafe-anything");
  assertEquals(result.allowed, true);
});

Deno.test("authorization: a non-admin role (e.g. customer) is denied", () => {
  const result = authorizeConnectionAccess({ role: "customer", cafeId: null }, "cafe-1");
  assertEquals(result.allowed, false);
});

Deno.test("authorization: cafe_admin with no cafe_id is denied (never falls back to allow)", () => {
  const result = authorizeConnectionAccess({ role: "cafe_admin", cafeId: null }, "cafe-1");
  assertEquals(result.allowed, false);
});

// ---------------------------------------------------------------------------
// 6. Failure / partial-sync behavior
// ---------------------------------------------------------------------------

Deno.test("failure: a failing page aborts the whole fetch — no partial catalog is ever returned", async () => {
  let callCount = 0;
  const fetchImpl = (input: string | URL) => {
    callCount++;
    const url = new URL(input.toString());
    if (!url.searchParams.get("cursor")) {
      return Promise.resolve(
        new Response(JSON.stringify({ objects: [LATTE_ITEM], cursor: "page2" }), { status: 200 }),
      );
    }
    return Promise.resolve(new Response("Square is down", { status: 500 }));
  };

  await assertRejects(
    () =>
      fetchAllCatalogObjects({
        accessToken: "token",
        baseUrl: "https://example.test",
        squareVersion: "2024-10-17",
        fetchImpl: fetchImpl as unknown as typeof fetch,
      }),
    SquareApiError,
  );
  assertEquals(callCount, 2); // page 1 succeeded, page 2 failed — both attempted, nothing returned
});

Deno.test("failure: SquareApiError carries the HTTP status and a bounded error detail", async () => {
  const fetchImpl = () => Promise.resolve(new Response("x".repeat(10_000), { status: 503 }));

  const err = await assertRejects(
    () =>
      fetchAllCatalogObjects({
        accessToken: "token",
        baseUrl: "https://example.test",
        squareVersion: "2024-10-17",
        fetchImpl: fetchImpl as unknown as typeof fetch,
      }),
    SquareApiError,
  );
  assertEquals((err as SquareApiError).status, 503);
  assert((err as SquareApiError).detail.length <= 500);
});

Deno.test("failure: an item with no valid variations contributes no products, doesn't throw", () => {
  const brokenItem = {
    type: "ITEM",
    id: "item_broken",
    item_data: { name: "Broken", variations: [] },
  };
  const { products } = normalizeCatalogObjects([brokenItem]);
  assertEquals(products, []);
});

Deno.test("failure: unrelated/unknown object types are ignored rather than throwing", () => {
  const unknown = { type: "DISCOUNT", id: "disc_1" };
  const result = normalizeCatalogObjects([unknown, LATTE_ITEM]);
  assertEquals(result.products.length, 2);
});

// ---------------------------------------------------------------------------
// centsToDecimal edge cases (small pure helper feeding all price fields)
// ---------------------------------------------------------------------------

Deno.test("centsToDecimal: converts cents to dollars, treats missing as null (not 0)", () => {
  assertEquals(centsToDecimal(425), 4.25);
  assertEquals(centsToDecimal(0), 0);
  assertEquals(centsToDecimal(undefined), null);
  assertEquals(centsToDecimal(null), null);
});
