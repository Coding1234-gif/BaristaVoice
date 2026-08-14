// Supabase Edge Function: order-agent
//
// Holds the LLM API key server-side and turns one customer utterance into
// (a) a natural-language reply and (b) the FULL updated structured order.
// The menu is passed in on every request and is the only source of truth
// for valid items/options — this function grounds and validates the LLM's
// output against it so the conversation can never invent a menu item,
// option or price.
//
// Provider is a manual switch, not automatic failover: set LLM_PROVIDER to
// "gemini" or "groq" and LLM_API_KEY to that provider's key. Flip both in
// Supabase secrets (no redeploy needed) if one provider's free tier runs
// dry — the request/response contract to the Flutter app never changes.
import { corsHeaders } from "../_shared/cors.ts";

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
}

interface RequestBody {
  transcript: string;
  currentOrder: { items: OrderItemIn[]; status?: string };
  menu: Menu;
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
                    decaf: { type: "boolean" },
                    modifiers: { type: "array", items: { type: "string" } },
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
  history: RequestBody["history"]
): Promise<LlmToolResult | null> {
  const contents = [
    ...(history ?? []).map((h) => ({
      role: h.role === "customer" ? "user" : "model",
      parts: [{ text: h.text }],
    })),
    { role: "user", parts: [{ text: transcript }] },
  ];

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
      }),
    }
  );

  if (!res.ok) {
    console.error("Gemini API error:", res.status, await res.text());
    return null;
  }

  const data = await res.json();
  const parts = data.candidates?.[0]?.content?.parts ?? [];
  const functionCallPart = parts.find((p: { functionCall?: unknown }) => p.functionCall);
  if (!functionCallPart) return null;

  return functionCallPart.functionCall.args as LlmToolResult;
}

async function callGroq(
  menu: Menu,
  currentOrder: RequestBody["currentOrder"],
  transcript: string,
  history: RequestBody["history"]
): Promise<LlmToolResult | null> {
  const messages = [
    { role: "system", content: buildSystemPrompt(menu, currentOrder) },
    ...(history ?? []).map((h) => ({
      role: h.role === "customer" ? "user" : "assistant",
      content: h.text,
    })),
    { role: "user", content: transcript },
  ];

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

  if (!res.ok) {
    console.error("Groq API error:", res.status, await res.text());
    return null;
  }

  const data = await res.json();
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
    });
  }
  return result;
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

  try {
    const body = (await req.json()) as RequestBody;
    const { transcript, currentOrder, menu, history } = body;

    const result =
      LLM_PROVIDER === "groq"
        ? await callGroq(menu, currentOrder, transcript, history)
        : await callGemini(menu, currentOrder, transcript, history);

    if (!result) {
      return new Response(
        JSON.stringify({
          reply: FALLBACK_REPLY,
          order: currentOrder,
          needsClarification: true,
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const validatedItems = validateAndEnrich(result.order?.items ?? [], menu);

    return new Response(
      JSON.stringify({
        reply: result.reply ?? FALLBACK_REPLY,
        needsClarification: Boolean(result.needsClarification),
        order: { items: validatedItems, status: currentOrder.status ?? "draft" },
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err) {
    console.error("order-agent error:", err);
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
