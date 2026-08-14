// Supabase Edge Function: menu-extractor
//
// Turns an uploaded PDF/image menu into structured, DRAFT menu_items rows
// for a cafe_admin to review before publishing. Runs Gemini's multimodal
// generateContent directly on the uploaded file (no separate PDF text
// extraction step needed) — always Gemini regardless of the order-agent's
// LLM_PROVIDER switch, since extraction needs a vision-capable model.
//
// Security: the caller's identity comes from verifying their JWT via
// supabase.auth.getUser(), never from a client-supplied user/cafe id. Once
// identified, the target menu_uploads row (and therefore its cafe_id) is
// looked up server-side with the service-role key, and the caller's own
// profile.cafe_id is checked against it — a cafe_admin can never trigger
// extraction for another cafe's upload, no matter what id they pass in.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GEMINI_API_KEY = Deno.env.get("LLM_API_KEY");
const GEMINI_MODEL = Deno.env.get("EXTRACTOR_MODEL") ?? "gemini-3.6-flash";

interface RequestBody {
  uploadId: string;
}

const EXTRACTION_PROMPT = `You are reading a coffee shop's menu (PDF or photo). Extract every
distinct product into a JSON array. For each product, output an object with
EXACTLY this shape (omit a field only if truly not applicable — use empty
arrays/false, never null):

{
  "name": string,
  "description": string,            // short, empty string if menu has none
  "category": string,                // e.g. "Coffee", "Tea", "Pastries"
  "basePrice": number,               // the item's base/smallest listed price
  "popular": boolean,                // true only if menu marks it (star, "popular" label) — else false
  "sizes": [{ "name": string, "priceDelta": number }],       // priceDelta relative to basePrice; [] if one size only
  "milkOptions": [{ "name": string, "priceDelta": number }], // [] if not a milk-based drink
  "temperatureOptions": string[],    // e.g. ["hot","iced"]; [] if not applicable
  "decafAvailable": boolean,
  "modifiers": [{ "name": string, "priceDelta": number }],   // extra shots, syrups, etc.
  "allergens": string[],
  "dietaryTags": string[]            // e.g. "vegan", "gluten-free" if the menu marks them
}

Rules:
- Only extract items actually printed on the menu. Never invent products or prices.
- basePrice must be a plain number (no currency symbol).
- Return ONLY a JSON array of these objects — no surrounding text, no markdown fences.`;

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function mimeTypeFor(path: string): string {
  const ext = path.split(".").pop()?.toLowerCase();
  switch (ext) {
    case "pdf":
      return "application/pdf";
    case "png":
      return "image/png";
    case "webp":
      return "image/webp";
    case "heic":
      return "image/heic";
    default:
      return "image/jpeg";
  }
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

async function extractWithGemini(base64Data: string, mimeType: string) {
  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent`,
    {
      method: "POST",
      headers: { "content-type": "application/json", "x-goog-api-key": GEMINI_API_KEY! },
      body: JSON.stringify({
        contents: [
          {
            role: "user",
            parts: [
              { text: EXTRACTION_PROMPT },
              { inline_data: { mime_type: mimeType, data: base64Data } },
            ],
          },
        ],
        generationConfig: { responseMimeType: "application/json" },
      }),
    },
  );

  if (!res.ok) {
    throw new Error(`Gemini extraction failed: ${res.status} ${await res.text()}`);
  }

  const data = await res.json();
  const text = data.candidates?.[0]?.content?.parts?.[0]?.text;
  if (!text) throw new Error("Gemini returned no extraction content");

  const parsed = JSON.parse(text);
  if (!Array.isArray(parsed)) throw new Error("Gemini extraction did not return an array");
  return parsed;
}

function normalizeItem(raw: Record<string, unknown>) {
  const name = typeof raw.name === "string" ? raw.name.trim() : "";
  const basePrice = Number(raw.basePrice);
  if (!name || !Number.isFinite(basePrice)) return null;

  return {
    id: crypto.randomUUID(),
    name,
    description: typeof raw.description === "string" ? raw.description : "",
    category: typeof raw.category === "string" && raw.category ? raw.category : "Other",
    basePrice,
    popular: Boolean(raw.popular),
    imageUrl: null,
    available: true,
    sizes: Array.isArray(raw.sizes) ? raw.sizes : [],
    milkOptions: Array.isArray(raw.milkOptions) ? raw.milkOptions : [],
    temperatureOptions: Array.isArray(raw.temperatureOptions) ? raw.temperatureOptions : [],
    decafAvailable: Boolean(raw.decafAvailable),
    modifiers: Array.isArray(raw.modifiers) ? raw.modifiers : [],
    allergens: Array.isArray(raw.allergens) ? raw.allergens : [],
    dietaryTags: Array.isArray(raw.dietaryTags) ? raw.dietaryTags : [],
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (!GEMINI_API_KEY) {
    return jsonResponse({ error: "LLM_API_KEY is not configured on the server." }, 500);
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return jsonResponse({ error: "Missing Authorization header." }, 401);
  }

  try {
    const { uploadId } = (await req.json()) as RequestBody;
    if (!uploadId) return jsonResponse({ error: "uploadId is required." }, 400);

    // Verify the caller's identity from their JWT (never trust a client-supplied user id).
    const callerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userError } = await callerClient.auth.getUser();
    if (userError || !userData.user) {
      return jsonResponse({ error: "Invalid or expired session." }, 401);
    }

    // Service-role client for the privileged lookups/writes below. Every
    // authorization decision past this point is made in code from data we
    // just fetched ourselves — never from anything the client sent.
    const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    const { data: profile } = await adminClient
      .from("profiles")
      .select("role, cafe_id")
      .eq("id", userData.user.id)
      .maybeSingle();

    if (!profile || (profile.role !== "cafe_admin" && profile.role !== "super_admin")) {
      return jsonResponse({ error: "Only cafe admins can trigger menu extraction." }, 403);
    }

    const { data: upload, error: uploadError } = await adminClient
      .from("menu_uploads")
      .select("id, cafe_id, source_ref, source_type")
      .eq("id", uploadId)
      .maybeSingle();

    if (uploadError || !upload) {
      return jsonResponse({ error: "Upload not found." }, 404);
    }

    if (profile.role === "cafe_admin" && upload.cafe_id !== profile.cafe_id) {
      return jsonResponse({ error: "You do not have access to this upload." }, 403);
    }

    if (!upload.source_ref) {
      return jsonResponse({ error: "Upload has no file attached." }, 400);
    }

    const { data: fileBlob, error: downloadError } = await adminClient.storage
      .from("menu-uploads")
      .download(upload.source_ref);

    if (downloadError || !fileBlob) {
      throw new Error(`Could not download uploaded file: ${downloadError?.message}`);
    }

    const bytes = new Uint8Array(await fileBlob.arrayBuffer());
    const base64Data = bytesToBase64(bytes);
    const mimeType = mimeTypeFor(upload.source_ref);

    const rawItems = await extractWithGemini(base64Data, mimeType);
    const items = rawItems.map(normalizeItem).filter((i) => i !== null);

    if (items.length === 0) {
      await adminClient.from("menu_uploads").update({ status: "failed" }).eq("id", uploadId);
      return jsonResponse({ error: "No products could be detected in this file." }, 422);
    }

    const rows = items.map((item) => ({
      id: item.id, // keep the row's primary key in sync with data.id
      cafe_id: upload.cafe_id,
      menu_upload_id: uploadId,
      status: "draft" as const,
      data: item,
    }));

    const { error: insertError } = await adminClient.from("menu_items").insert(rows);
    if (insertError) throw new Error(`Could not save extracted items: ${insertError.message}`);

    await adminClient.from("menu_uploads").update({ status: "structured" }).eq("id", uploadId);

    return jsonResponse({ count: items.length, items });
  } catch (err) {
    console.error("menu-extractor error:", err);
    return jsonResponse({ error: err instanceof Error ? err.message : "Extraction failed." }, 500);
  }
});
