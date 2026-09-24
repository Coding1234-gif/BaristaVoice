// Tests for order-agent. Run with:
//   deno test --allow-env --node-modules-dir=auto supabase/functions/order-agent/index.test.ts
//
// Covers the compact-prompt/short-id mapping, the Groq call's throttling and
// optional-parameter handling (with an injected fetch), and the request
// handler end-to-end with Supabase and Groq both stubbed at the network
// boundary — no live project or API key needed.
import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";

// Env must be set BEFORE the module under test is imported: it reads
// LLM_PROVIDER / LLM_API_KEY / SUPABASE_URL at load time.
Deno.env.set("LLM_PROVIDER", "groq");
Deno.env.set("LLM_API_KEY", "test-key");
Deno.env.set("LLM_MODEL", "openai/gpt-oss-120b");
Deno.env.set("SUPABASE_URL", "https://stub.supabase.test");
Deno.env.set("SUPABASE_ANON_KEY", "stub-anon");

const mod = await import("./index.ts");
const {
  buildOpenAiTool,
  buildPromptMenu,
  buildSystemPrompt,
  callGroq,
  handler,
  restoreResultIds,
  retryAfterMs,
  shortenOrderIds,
  validateAndEnrich,
  validateMentionedItemIds,
  RequestTimer,
} = mod;

// A menu shaped like the real café's rows: full UUIDs, a long product-photo
// URL on every item, empty option lists.
function uuid(n: number): string {
  return `2e93cdf0-cdfb-4e16-8fe2-${String(n).padStart(12, "0")}`;
}

function makeMenu(count = 23) {
  return {
    cafeName: "Bean & Bloom Café",
    items: Array.from({ length: count }, (_, i) => ({
      id: uuid(i + 1),
      name: `Item ${i + 1}`,
      description: `Description of item ${i + 1}.`,
      category: i % 2 ? "Food" : "Coffee",
      basePrice: 3 + i / 10,
      popular: i === 0,
      imageUrl: `https://stub.supabase.test/storage/v1/object/public/product-images/2e93cdf0-cdfb-4e16-8fe2-${uuid(i + 1)}.jpg`,
      available: true,
      sizes: i % 2 ? [] : [{ name: "Regular", priceDelta: 0 }, { name: "Large", priceDelta: 0.4 }],
      milkOptions: i % 2 ? [] : [
        { name: "Dairy", priceDelta: 0 },
        { name: "Oat", priceDelta: 0.5 },
        { name: "Soy", priceDelta: 0.5 },
      ],
      temperatureOptions: i % 2 ? [] : ["hot"],
      decafAvailable: i % 2 === 0,
      modifiers: i % 2 ? [] : [{ name: "Extra shot", priceDelta: 0.6 }],
      allergens: i % 2 ? [] : ["milk"],
      dietaryTags: ["vegetarian"],
    })),
  };
}

// ---------------------------------------------------------------------------
// compact prompt + short ids
// ---------------------------------------------------------------------------

Deno.test("prompt menu drops photo URLs/availability and uses short ids", () => {
  const menu = makeMenu();
  const { promptMenu, shortIds } = buildPromptMenu(menu);
  const json = JSON.stringify(promptMenu);

  assertFalse(json.includes("imageUrl"));
  assertFalse(json.includes("storage/v1"));
  assertFalse(json.includes("available"));
  assertFalse(json.includes("2e93cdf0"), "no UUID should reach the model");
  assertEquals(shortIds.slice(0, 3), ["m1", "m2", "m3"]);
  assertEquals(shortIds.length, 23);
});

Deno.test("prompt menu keeps everything the model needs to answer and price", () => {
  const menu = makeMenu();
  const item = buildPromptMenu(menu).promptMenu.items[0] as Record<string, unknown>;

  assertEquals(item.name, "Item 1");
  assertEquals(item.basePrice, 3);
  assertEquals(item.popular, true);
  assert(item.description);
  // Option names only — the app prices, the model never needs the deltas.
  assertEquals(item.sizes, ["Regular", "Large"]);
  assertEquals(item.milkOptions, ["Dairy", "Oat", "Soy"]);
  assertEquals(item.temperatureOptions, ["hot"]);
  assertEquals(item.decafAvailable, true);
  assertEquals(item.modifiers, ["Extra shot"]);
  assertFalse(JSON.stringify(item).includes("priceDelta"));
  assertEquals(item.allergens, ["milk"]);

  // ...and omits empties/falsy flags instead of sending noise.
  const plain = buildPromptMenu(menu).promptMenu.items[1] as Record<string, unknown>;
  assertFalse("sizes" in plain);
  assertFalse("milkOptions" in plain);
  assertFalse("decafAvailable" in plain);
  assertFalse("popular" in plain);
});

Deno.test("token-budget guard: the menu+schema the model receives stays well under the untrimmed size", () => {
  const menu = makeMenu();
  const bundle = buildPromptMenu(menu);
  const order = { items: [], status: "draft" };
  const rules = buildSystemPrompt({ cafeName: "", items: [] }, order).length; // constant rules text

  const before = JSON.stringify(menu).length +
    JSON.stringify(buildOpenAiTool(menu.items.map((i) => i.id))).length;
  const after = buildSystemPrompt(bundle.promptMenu, order).length - rules +
    JSON.stringify(buildOpenAiTool(bundle.shortIds)).length;

  console.log(`  menu+schema chars: ${before} -> ${after}`);
  // Provider rate limits count tokens; a regression that re-adds photo URLs,
  // UUIDs or price deltas to the prompt would push this back up.
  assert(after < before * 0.6, `menu+schema is ${after} chars vs ${before} untrimmed`);
});

Deno.test("the tool schema only allows the short ids", () => {
  const { shortIds } = buildPromptMenu(makeMenu(3));
  const tool = buildOpenAiTool(shortIds) as {
    function: { parameters: { properties: Record<string, any> } };
  };
  const props = tool.function.parameters.properties;

  assertEquals(props.order.properties.items.items.properties.menuItemId.enum, ["m1", "m2", "m3"]);
  assertEquals(props.mentionedItemIds.items.enum, ["m1", "m2", "m3"]);
});

Deno.test("current-order ids are shortened for the model and unknown ids pass through", () => {
  const menu = makeMenu(3);
  const { shortById } = buildPromptMenu(menu);
  const out = shortenOrderIds(
    { status: "draft", items: [{ menuItemId: uuid(2), quantity: 1 }, { menuItemId: "stale-id", quantity: 1 }] },
    shortById,
  );

  assertEquals(out.items.map((i) => i.menuItemId), ["m2", "stale-id"]);
  assertEquals(out.status, "draft");
});

Deno.test("model ids are mapped back to real menu ids before validation", () => {
  const menu = makeMenu(3);
  const { idByShort } = buildPromptMenu(menu);

  const restored = restoreResultIds(
    {
      reply: "ok",
      needsClarification: false,
      order: { items: [{ menuItemId: "m3", quantity: 2 }] },
      mentionedItemIds: ["m1", "m3"],
    },
    idByShort,
  );

  assertEquals(restored.order.items[0].menuItemId, uuid(3));
  assertEquals(restored.mentionedItemIds, [uuid(1), uuid(3)]);
  assertEquals(validateMentionedItemIds(restored.mentionedItemIds, menu), [uuid(1), uuid(3)]);
  assertEquals(validateAndEnrich(restored.order.items, menu)[0].menuItemId, uuid(3));
});

Deno.test("a hallucinated short id is dropped by the existing validation, never trusted", () => {
  const menu = makeMenu(3);
  const { idByShort } = buildPromptMenu(menu);

  const restored = restoreResultIds(
    {
      reply: "ok",
      needsClarification: false,
      order: { items: [{ menuItemId: "m99", quantity: 1 }, { menuItemId: "m1", quantity: 1 }] },
      mentionedItemIds: ["m99", "m2"],
    },
    idByShort,
  );

  assertEquals(validateAndEnrich(restored.order.items, menu).map((i) => i.menuItemId), [uuid(1)]);
  assertEquals(validateMentionedItemIds(restored.mentionedItemIds, menu), [uuid(2)]);
});

Deno.test("a reply with no mentionedItemIds stays undefined (missing field == no cards)", () => {
  const restored = restoreResultIds(
    { reply: "ok", needsClarification: false, order: { items: [] } },
    new Map(),
  );
  assertEquals(restored.mentionedItemIds, undefined);
  assertEquals(validateMentionedItemIds(restored.mentionedItemIds, makeMenu(2)), []);
});

Deno.test("retryAfterMs", () => {
  assertEquals(retryAfterMs("2"), 2000);
  assertEquals(retryAfterMs("0"), 0);
  assertEquals(retryAfterMs("37.5"), 37500);
  assertEquals(retryAfterMs(null), null);
  assertEquals(retryAfterMs("soon"), null);
  assertEquals(retryAfterMs("-3"), null);
});

// ---------------------------------------------------------------------------
// callGroq: optional params, 400 fallback, short 429 retry
// ---------------------------------------------------------------------------

const toolArgs = { reply: "Sure.", needsClarification: false, order: { items: [] } };
const okResponse = () =>
  new Response(
    JSON.stringify({ choices: [{ message: { tool_calls: [{ function: { arguments: JSON.stringify(toolArgs) } }] } }] }),
    { status: 200 },
  );

function promptInputs() {
  const bundle = buildPromptMenu(makeMenu(3));
  return { menu: bundle.promptMenu, shortIds: bundle.shortIds, order: { items: [] } };
}

function scripted(responses: Response[]) {
  const bodies: Record<string, unknown>[] = [];
  const fetchImpl = ((_url: string | URL | Request, init?: RequestInit) => {
    bodies.push(JSON.parse(init!.body as string));
    return Promise.resolve(responses.shift()!);
  }) as typeof fetch;
  return { bodies, fetchImpl };
}

Deno.test("callGroq asks for low reasoning and a capped output", async () => {
  const { bodies, fetchImpl } = scripted([okResponse()]);
  const result = await callGroq(promptInputs(), "hi", [], new RequestTimer("t"), {}, fetchImpl);

  assertEquals(result?.reply, "Sure.");
  assertEquals(bodies.length, 1);
  assertEquals(bodies[0].reasoning_effort, "low");
  assertEquals(bodies[0].max_completion_tokens, 1024);
});

Deno.test("callGroq retries WITHOUT the optional params if the provider rejects them", async () => {
  const { bodies, fetchImpl } = scripted([
    new Response('{"error":{"message":"unknown parameter"}}', { status: 400 }),
    okResponse(),
  ]);
  const result = await callGroq(promptInputs(), "hi", [], new RequestTimer("t"), {}, fetchImpl);

  assertEquals(result?.reply, "Sure.");
  assertEquals(bodies.length, 2);
  assertFalse("reasoning_effort" in bodies[1]);
  assertFalse("max_completion_tokens" in bodies[1]);
  assertEquals(bodies[1].model, bodies[0].model);
});

Deno.test("callGroq waits out a short 429 and retries once", async () => {
  const { bodies, fetchImpl } = scripted([
    new Response("{}", { status: 429, headers: { "retry-after": "0" } }),
    okResponse(),
  ]);
  const result = await callGroq(promptInputs(), "hi", [], new RequestTimer("t"), {}, fetchImpl);

  assertEquals(result?.reply, "Sure.");
  assertEquals(bodies.length, 2);
});

Deno.test("callGroq does NOT block a customer on a long 429: flags it and returns null", async () => {
  const { bodies, fetchImpl } = scripted([
    new Response('{"error":{"message":"Rate limit reached"}}', { status: 429, headers: { "retry-after": "38" } }),
  ]);
  const debug: { rateLimited?: boolean; info?: unknown } = {};
  const result = await callGroq(promptInputs(), "hi", [], new RequestTimer("t"), debug, fetchImpl);

  assertEquals(result, null);
  assertEquals(bodies.length, 1);
  assertEquals(debug.rateLimited, true);
});

// ---------------------------------------------------------------------------
// handler end-to-end, with Supabase + Groq stubbed at the network boundary
// ---------------------------------------------------------------------------

function withStubbedNetwork(groq: () => Response, menu = makeMenu(3)) {
  const original = globalThis.fetch;
  const groqBodies: Record<string, any>[] = [];

  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    if (url.includes("/rest/v1/cafes")) {
      return Promise.resolve(new Response(JSON.stringify({ name: menu.cafeName }), {
        status: 200,
        headers: { "content-type": "application/json" },
      }));
    }
    if (url.includes("/rest/v1/menu_items")) {
      return Promise.resolve(new Response(JSON.stringify(menu.items.map((data) => ({ data }))), {
        status: 200,
        headers: { "content-type": "application/json" },
      }));
    }
    if (url.includes("api.groq.com")) {
      groqBodies.push(JSON.parse(init!.body as string));
      return Promise.resolve(groq());
    }
    throw new Error(`unexpected fetch in test: ${url}`);
  }) as typeof fetch;

  return { groqBodies, restore: () => (globalThis.fetch = original) };
}

function request(body: unknown) {
  return new Request("https://stub.supabase.test/functions/v1/order-agent", {
    method: "POST",
    headers: { "content-type": "application/json", "x-debug-timing": "1" },
    body: JSON.stringify(body),
  });
}

const cart = {
  status: "draft",
  items: [{ id: "line-1", menuItemId: uuid(1), name: "Item 1", quantity: 1, size: null, milk: null, temperature: null, decaf: false, modifiers: [] }],
};

Deno.test("handler: model sees short ids only, real ids come back, cards get real ids", async () => {
  const reply = { reply: "Item 2 is lovely.", needsClarification: false, order: { items: [{ menuItemId: "m1", quantity: 1 }] }, mentionedItemIds: ["m2", "m99"] };
  const net = withStubbedNetwork(() =>
    new Response(JSON.stringify({ choices: [{ message: { tool_calls: [{ function: { arguments: JSON.stringify(reply) } }] } }] }), { status: 200 })
  );
  try {
    const res = await handler(request({ cafeId: "cafe-1", transcript: "tell me about item 2", currentOrder: cart, history: [] }));
    const json = await res.json();

    // What the model was shown:
    const sent = JSON.stringify(net.groqBodies[0]);
    assertFalse(sent.includes("2e93cdf0"), "no UUID may reach the LLM (menu, schema or current order)");
    assertFalse(sent.includes("imageUrl"));
    assert(sent.includes('"m1"'));

    // What the app gets back:
    assertEquals(json.reply, "Item 2 is lovely.");
    assertEquals(json.order.items[0].menuItemId, uuid(1));
    assertEquals(json.mentionedItemIds, [uuid(2)], "hallucinated m99 dropped, m2 mapped to the real id");
    assertEquals(json.retryable, undefined);
  } finally {
    net.restore();
  }
});

Deno.test("handler: a 429 gives the 'busy' reply, keeps the customer's cart, and is retryable", async () => {
  const net = withStubbedNetwork(() =>
    new Response('{"error":{"message":"Rate limit reached ... TPM"}}', { status: 429, headers: { "retry-after": "38" } })
  );
  try {
    const res = await handler(request({ cafeId: "cafe-1", transcript: "a latte", currentOrder: cart, history: [] }));
    const json = await res.json();

    assertEquals(json.reply, "I'm a little busy right now — give me a few seconds and try that again.");
    assertEquals(json.order, cart, "a failed turn must hand back the customer's own cart");
    assertEquals(json.retryable, true);
    assertEquals(json.needsClarification, true);
    assertEquals(json._debug.status, 429);
  } finally {
    net.restore();
  }
});

Deno.test("handler: other LLM failures keep the old wording, keep the cart, and are retryable", async () => {
  const net = withStubbedNetwork(() => new Response("upstream exploded", { status: 500 }));
  try {
    const res = await handler(request({ cafeId: "cafe-1", transcript: "a latte", currentOrder: cart, history: [] }));
    const json = await res.json();

    assertEquals(json.reply, "Sorry, I didn't quite catch that. Could you say that again?");
    assertEquals(json.order, cart);
    assertEquals(json.retryable, true);
  } finally {
    net.restore();
  }
});

Deno.test("handler: an unparseable model answer no longer blanks the cart", async () => {
  const net = withStubbedNetwork(() =>
    new Response(JSON.stringify({ choices: [{ message: { tool_calls: [{ function: { arguments: "{not json" } }] } }] }), { status: 200 })
  );
  try {
    const res = await handler(request({ cafeId: "cafe-1", transcript: "a latte", currentOrder: cart, history: [] }));
    const json = await res.json();

    assertEquals(json.order, cart);
    assertEquals(json.retryable, true);
  } finally {
    net.restore();
  }
});
