// Supabase Edge Function: order-agent
//
// Holds the LLM API key server-side and turns one customer utterance into
// (a) a natural-language reply and (b) the FULL updated structured order.
//
// The client sends a cafeId, NOT a menu — this function fetches that café's
// PUBLISHED, available products itself (same query shape the RLS policy on
// menu_items enforces: `status = 'published'`) and is the only source of
// truth for valid items/options fed to the model. This means the AI can
// never be steered into recommending or pricing another café's products (or
// draft/unpublished ones) no matter what a client sends — the café is
// resolved and the product list is built entirely server-side.
import { createClient } from "jsr:@supabase/supabase-js@2";

// Inlined (rather than imported from ../_shared/cors.ts) so this file is
// self-contained and can be pasted directly into the Supabase Dashboard's
// Edge Function editor, which doesn't resolve cross-function relative
// imports the way `supabase functions deploy` does.
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

/** Per-request stage timing. Logged server-side (numbers only — never
 * transcript/order content) on every request so the Supabase function logs
 * show a latency breakdown for real traffic. Also echoed back in the
 * response body as `_timing`, but only when the caller sends
 * `x-debug-timing: 1` — normal client requests never see this field. */
class RequestTimer {
  private readonly id: string;
  private readonly t0: number;
  private marks: { label: string; atMs: number }[] = [];

  constructor(id: string) {
    this.id = id;
    this.t0 = performance.now();
  }

  mark(label: string) {
    this.marks.push({ label, atMs: Math.round(performance.now() - this.t0) });
  }

  summary(): Record<string, number> {
    const out: Record<string, number> = {};
    for (const m of this.marks) out[m.label] = m.atMs;
    return out;
  }

  log() {
    console.log(`[order-agent ${this.id}]`, JSON.stringify(this.summary()));
  }
}

type Provider = "gemini" | "groq";

const LLM_PROVIDER = (Deno.env.get("LLM_PROVIDER") ?? "gemini") as Provider;
const LLM_API_KEY = Deno.env.get("LLM_API_KEY");
const LLM_MODEL =
  Deno.env.get("LLM_MODEL") ??
  (LLM_PROVIDER === "groq" ? "openai/gpt-oss-120b" : "gemini-3.6-flash");

interface PricedOption {
  name: string;
  priceDelta: number;
}

interface MenuItem {
  id: string;
  name: string;
  description: string;
  category: string;
  basePrice: number;
  popular: boolean;
  imageUrl?: string | null;
  available?: boolean;
  sizes: PricedOption[];
  milkOptions: PricedOption[];
  temperatureOptions: string[];
  decafAvailable: boolean;
  modifiers: PricedOption[];
  allergens: string[];
  dietaryTags: string[];
}

interface Menu {
  cafeName: string;
  items: MenuItem[];
}

interface OrderItemIn {
  id?: string;
  menuItemId: string;
  name?: string;
  quantity: number;
  size?: string | null;
  milk?: string | null;
  temperature?: string | null;
  decaf?: boolean;
  modifiers?: string[];
  specialRequest?: string | null;
}

interface RequestBody {
  cafeId: string;
  transcript: string;
  currentOrder: { items: OrderItemIn[]; status?: string };
  history: { role: "customer" | "assistant"; text: string }[];
}

interface LlmToolResult {
  reply: string;
  needsClarification: boolean;
  order: { items: OrderItemIn[] };
}

const FALLBACK_REPLY =
  "Sorry, I didn't quite catch that. Could you say that again?";

const TOOL_NAME = "update_order";
const TOOL_DESCRIPTION = "Reply to the customer and set the full, updated order state.";

function buildSystemPrompt(menu: Menu, currentOrder: RequestBody["currentOrder"]): string {
  return `You are a friendly, knowledgeable barista working the order counter at ${menu.cafeName}.
Customers speak to you naturally. Your job each turn is to:
1. Understand what they want (a question, an item to add, a change, a removal, or a confirmation).
2. Reply the way a real barista would: warm, brief, natural — not robotic.
3. Call the ${TOOL_NAME} tool with the FULL, correct order state after applying any change.

Hard rules — never break these:
- Only ever reference items, sizes, milk options, temperatures, modifiers and decaf availability that literally appear in the MENU json below, matched by id. Never invent a product, option or price.
- If the customer asks for something not on the menu, or an option a specific item doesn't support (e.g. oat milk on an item with no milkOptions, or decaf on an item where decafAvailable is false), do NOT add or change it. Explain what's actually available instead, and leave the order for that item unchanged.
- If it's ambiguous which order item the customer means (e.g. "make it large" and there are two drinks in the order), ask a short clarifying question, set needsClarification true, and leave the order unchanged.
- If you can't understand the request at all, say so briefly and ask them to repeat it; leave the order unchanged.
- Never invent or state a price yourself — prices are computed by the app from menu data, not by you.
- "Another one" / "same again" means add another of the most recently discussed matching item (increase quantity if identical, otherwise add a new line).
- Pure questions ("what's popular", "what's in that", "how much is my order") must NOT change the order — answer in reply and return the order exactly as it was.
- Always call ${TOOL_NAME} with the complete current list of items (not a diff) — including ones you didn't just change.
- If the customer adds a special request that isn't one of the menu's structured options (e.g. "extra hot", "light ice", "no whip", "cup with a lid"), capture it verbatim in that item's specialRequest field instead of dropping it or inventing a matching modifier. Don't put anything in specialRequest that's actually one of the menu's real sizes/milk/temperature/modifiers — use the proper field for those.

MENU (json):
${JSON.stringify(menu)}

CURRENT ORDER (json):
${JSON.stringify(currentOrder)}`;
}

/** Gemini's function-declaration schema: uppercase types, `nullable: true`. */
function buildGeminiFunctionDeclaration(menu: Menu) {
  const itemIds = menu.items.map((i) => i.id);
  return {
    name: TOOL_NAME,
    description: TOOL_DESCRIPTION,
    parameters: {
      type: "OBJECT",
      properties: {
        reply: { type: "STRING", description: "What you say back to the customer." },
        needsClarification: { type: "BOOLEAN" },
        order: {
          type: "OBJECT",
          properties: {
            items: {
              type: "ARRAY",
              items: {
                type: "OBJECT",
                properties: {
                  menuItemId: { type: "STRING", enum: itemIds },
                  quantity: { type: "INTEGER" },
                  size: { type: "STRING", nullable: true },
                  milk: { type: "STRING", nullable: true },
                  temperature: { type: "STRING", nullable: true },
                  decaf: { type: "BOOLEAN" },
                  modifiers: { type: "ARRAY", items: { type: "STRING" } },
                  specialRequest: { type: "STRING", nullable: true },
                },
                required: ["menuItemId", "quantity"],
              },
            },
          },
          required: ["items"],
        },
      },
      required: ["reply", "needsClarification", "order"],
    },
  };
}

/** OpenAI-compatible (Groq) tool schema: lowercase types, `["string","null"]` unions. */
function buildOpenAiTool(menu: Menu) {
  const itemIds = menu.items.map((i) => i.id);
  return {
    type: "function",
    function: {
      name: TOOL_NAME,
      description: TOOL_DESCRIPTION,
      parameters: {
        type: "object",
        properties: {
          reply: { type: "string", description: "What you say back to the customer." },
          needsClarification: { type: "boolean" },
          order: {
            type: "object",
            properties: {
              items: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    menuItemId: { type: "string", enum: itemIds },
                    quantity: { type: "integer", minimum: 1 },
                    size: { type: ["string", "null"] },
                    milk: { type: ["string", "null"] },
                    temperature: { type: ["string", "null"] },
                    // Groq enforces this schema strictly server-side (unlike
                    // Gemini) and the model sometimes emits `null` here
                    // instead of `false` — must accept both since
                    // validateAndEnrich already treats null as falsy.
                    decaf: { type: ["boolean", "null"] },
                    modifiers: { type: "array", items: { type: "string" } },
                    specialRequest: { type: ["string", "null"] },
                  },
                  required: ["menuItemId", "quantity"],
                },
              },
            },
            required: ["items"],
          },
        },
        required: ["reply", "needsClarification", "order"],
      },
    },
  };
}

async function callGemini(
  menu: Menu,
  currentOrder: RequestBody["currentOrder"],
  transcript: string,
  history: RequestBody["history"],
  timer: RequestTimer,
  debugRef?: { info?: unknown }
): Promise<LlmToolResult | null> {
  const contents = [
    ...(history ?? []).map((h) => ({
      role: h.role === "customer" ? "user" : "model",
      parts: [{ text: h.text }],
    })),
    { role: "user", parts: [{ text: transcript }] },
  ];

  timer.mark("llm_request_start");
  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${LLM_MODEL}:generateContent`,
    {
      method: "POST",
      headers: { "content-type": "application/json", "x-goog-api-key": LLM_API_KEY! },
      body: JSON.stringify({
        system_instruction: { parts: [{ text: buildSystemPrompt(menu, currentOrder) }] },
        contents,
        tools: [{ functionDeclarations: [buildGeminiFunctionDeclaration(menu)] }],
        tool_config: {
          function_calling_config: { mode: "ANY", allowed_function_names: [TOOL_NAME] },
        },
        // This is a deterministic structured-extraction task (pick a tool
        // call, fill known fields from a short menu) — it doesn't benefit
        // from extended reasoning, and measurement showed the default
        // (unbounded) thinking budget was the dominant source of latency
        // (single-digit seconds normally, 19-21s on some turns).
        generationConfig: {
          thinkingConfig: { thinkingBudget: 0 },
        },
      }),
    }
  );
  timer.mark("llm_response_headers_received");

  if (!res.ok) {
    const text = await res.text();
    console.error("Gemini API error:", res.status, text);
    if (debugRef) debugRef.info = { status: res.status, body: text.slice(0, 2000) };
    return null;
  }

  const data = await res.json();
  timer.mark("llm_response_body_parsed");
  const parts = data.candidates?.[0]?.content?.parts ?? [];
  const functionCallPart = parts.find((p: { functionCall?: unknown }) => p.functionCall);
  if (!functionCallPart) {
    if (debugRef) debugRef.info = { status: res.status, candidates: data.candidates, promptFeedback: data.promptFeedback };
    return null;
  }

  return functionCallPart.functionCall.args as LlmToolResult;
}

async function callGroq(
  menu: Menu,
  currentOrder: RequestBody["currentOrder"],
  transcript: string,
  history: RequestBody["history"],
  timer: RequestTimer,
  debugRef?: { info?: unknown }
): Promise<LlmToolResult | null> {
  const messages = [
    { role: "system", content: buildSystemPrompt(menu, currentOrder) },
    ...(history ?? []).map((h) => ({
      role: h.role === "customer" ? "user" : "assistant",
      content: h.text,
    })),
    { role: "user", content: transcript },
  ];

  timer.mark("llm_request_start");
  const res = await fetch("https://api.groq.com/openai/v1/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${LLM_API_KEY}`,
    },
    body: JSON.stringify({
      model: LLM_MODEL,
      messages,
      tools: [buildOpenAiTool(menu)],
      tool_choice: { type: "function", function: { name: TOOL_NAME } },
    }),
  });
  timer.mark("llm_response_headers_received");

  if (!res.ok) {
    const text = await res.text();
    console.error("Groq API error:", res.status, text);
    if (debugRef) debugRef.info = { status: res.status, body: text.slice(0, 2000) };
    return null;
  }

  const data = await res.json();
  timer.mark("llm_response_body_parsed");
  const toolCall = data.choices?.[0]?.message?.tool_calls?.[0];
  if (!toolCall) return null;

  return JSON.parse(toolCall.function.arguments) as LlmToolResult;
}

/** Strips any option the LLM might have hallucinated so the order can never
 * contain something outside what the menu actually allows. */
function validateAndEnrich(items: OrderItemIn[], menu: Menu): OrderItemIn[] {
  const result: OrderItemIn[] = [];
  for (const raw of items) {
    const menuItem = menu.items.find((m) => m.id === raw.menuItemId);
    if (!menuItem) continue; // drop hallucinated item entirely

    const size =
      raw.size && menuItem.sizes.some((s) => s.name === raw.size) ? raw.size : null;
    const milk =
      raw.milk && menuItem.milkOptions.some((m) => m.name === raw.milk)
        ? raw.milk
        : null;
    const temperature =
      raw.temperature && menuItem.temperatureOptions.includes(raw.temperature)
        ? raw.temperature
        : null;
    const decaf = Boolean(raw.decaf) && menuItem.decafAvailable;
    const modifiers = (raw.modifiers ?? []).filter((m) =>
      menuItem.modifiers.some((mod) => mod.name === m)
    );
    // Free text (e.g. "extra hot", "no whip") — not menu-validated like the
    // structured fields above, just length-capped so one turn can't smuggle
    // in an unbounded blob of text.
    const specialRequest = raw.specialRequest?.trim()
      ? raw.specialRequest.trim().slice(0, 140)
      : null;

    result.push({
      id: raw.id,
      menuItemId: raw.menuItemId,
      name: menuItem.name,
      quantity: Math.max(1, Math.floor(raw.quantity ?? 1)),
      size,
      milk,
      temperature,
      decaf,
      modifiers,
      specialRequest,
    });
  }
  return result;
}

/** Fetches ONE café's published, available products straight from the
 * database (anon key, same RLS a customer's own client is bound by) — the
 * only place this function decides what the AI is even allowed to see.
 * Never trusts anything about product identity/pricing from the client. */
async function fetchCafeMenu(cafeId: string, timer: RequestTimer): Promise<Menu | null> {
  const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

  // The café-name lookup and the menu-items lookup don't depend on each
  // other (both only need cafeId) — run them concurrently instead of
  // serially so this stage costs one round trip instead of two.
  timer.mark("db_fetch_start");
  const [{ data: cafe }, { data: rows, error }] = await Promise.all([
    supabase.from("cafes").select("name").eq("id", cafeId).maybeSingle(),
    supabase.from("menu_items").select("data").eq("cafe_id", cafeId).eq("status", "published"),
  ]);
  timer.mark("db_fetch_end");

  if (!cafe) return null;
  if (error) throw new Error(`Could not load menu: ${error.message}`);

  const items = ((rows ?? []) as { data: MenuItem }[])
    .map((row) => row.data)
    .filter((item) => item.available !== false);

  return { cafeName: cafe.name as string, items };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (!LLM_API_KEY) {
    return new Response(
      JSON.stringify({ error: "LLM_API_KEY is not configured on the server." }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Correlates this request's timing marks with the client-side pipeline
  // stages (STT/TTS) logged in the app — the client generates and sends one
  // id per customer turn. Falls back to a server-generated id for calls
  // that don't send one (e.g. the debug curl probes used to measure this).
  const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID().slice(0, 8);
  const debugTiming = req.headers.get("x-debug-timing") === "1";
  const timer = new RequestTimer(requestId);
  timer.mark("request_received");

  try {
    const body = (await req.json()) as RequestBody;
    const { cafeId, transcript, currentOrder, history } = body;
    timer.mark("body_parsed");

    if (!cafeId) {
      return new Response(JSON.stringify({ error: "cafeId is required." }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const menu = await fetchCafeMenu(cafeId, timer);

    if (!menu) {
      return new Response(
        JSON.stringify({
          reply: "Sorry, we couldn't find this café.",
          order: currentOrder,
          needsClarification: true,
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (menu.items.length === 0) {
      return new Response(
        JSON.stringify({
          reply: `${menu.cafeName} hasn't published its menu yet — nothing to order right now.`,
          order: currentOrder,
          needsClarification: true,
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const debugRef: { info?: unknown } = {};
    const result =
      LLM_PROVIDER === "groq"
        ? await callGroq(menu, currentOrder, transcript, history, timer, debugRef)
        : await callGemini(menu, currentOrder, transcript, history, timer, debugRef);

    if (!result) {
      timer.log();
      return new Response(
        JSON.stringify({
          reply: FALLBACK_REPLY,
          order: currentOrder,
          needsClarification: true,
          ...(debugTiming ? { _timing: { requestId, ...timer.summary() }, _debug: debugRef.info } : {}),
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const validatedItems = validateAndEnrich(result.order?.items ?? [], menu);
    timer.mark("validated");
    timer.log();

    return new Response(
      JSON.stringify({
        reply: result.reply ?? FALLBACK_REPLY,
        needsClarification: Boolean(result.needsClarification),
        order: { items: validatedItems, status: currentOrder.status ?? "draft" },
        ...(debugTiming ? { _timing: { requestId, ...timer.summary() } } : {}),
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err) {
    console.error("order-agent error:", err);
    timer.log();
    return new Response(
      JSON.stringify({
        reply: FALLBACK_REPLY,
        order: { items: [] },
        needsClarification: true,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
