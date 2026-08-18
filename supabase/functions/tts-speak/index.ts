// Supabase Edge Function: tts-speak
//
// Holds the ElevenLabs API key server-side and turns barista reply text into
// spoken audio. The client never talks to ElevenLabs directly and never sees
// the API key — it only ever calls this function.
//
// Streams the ElevenLabs response straight through to the caller (no
// buffering the whole clip in memory) so playback can start as soon as the
// first bytes arrive.
//
// Self-contained on purpose (no imports from ../_shared/*) so this file can
// be pasted directly into the Supabase Dashboard's Edge Function editor,
// which doesn't resolve cross-function relative imports the way
// `supabase functions deploy` does.

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const ELEVENLABS_API_KEY = Deno.env.get("ELEVENLABS_API_KEY");
const ELEVENLABS_VOICE_ID = Deno.env.get("ELEVENLABS_VOICE_ID");
const ELEVENLABS_MODEL_ID = Deno.env.get("ELEVENLABS_MODEL_ID") ?? "eleven_flash_v2_5";

/** Reports stage timing back as a standard `Server-Timing` header (visible
 * in browser devtools network panel and readable by curl) instead of a JSON
 * field, since a successful response body here is raw audio, not JSON. */
class RequestTimer {
  private readonly t0 = performance.now();
  private marks: { label: string; atMs: number }[] = [];

  mark(label: string) {
    this.marks.push({ label, atMs: Math.round(performance.now() - this.t0) });
  }

  serverTimingHeader(): string {
    return this.marks.map((m) => `${m.label};dur=${m.atMs}`).join(", ");
  }
}

// A single call covers one chunk of a reply (the client splits long replies
// at sentence boundaries before calling this function). This cap just
// guards against an oversized single request reaching ElevenLabs.
const MAX_TEXT_LENGTH = 2000;

interface RequestBody {
  text?: string;
}

function errorResponse(status: number, message: string): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return errorResponse(405, "Method not allowed.");
  }

  if (!ELEVENLABS_API_KEY) {
    return errorResponse(500, "ELEVENLABS_API_KEY is not configured on the server.");
  }

  const requestId = req.headers.get("x-request-id") ?? crypto.randomUUID().slice(0, 8);
  const timer = new RequestTimer();
  timer.mark("request_received");

  let body: RequestBody;
  try {
    body = (await req.json()) as RequestBody;
  } catch {
    return errorResponse(400, "Request body must be valid JSON.");
  }

  const text = (body.text ?? "").trim();
  if (!text) {
    return errorResponse(400, "text is required.");
  }
  if (text.length > MAX_TEXT_LENGTH) {
    return errorResponse(
      400,
      `text is too long for a single request (max ${MAX_TEXT_LENGTH} characters) — split it into smaller chunks.`
    );
  }

  // Always the configured café voice — a client-supplied voice id is never
  // trusted, so nobody can make this function speak in an arbitrary voice.
  const voiceId = ELEVENLABS_VOICE_ID;
  if (!voiceId) {
    return errorResponse(500, "ELEVENLABS_VOICE_ID is not configured on the server.");
  }

  timer.mark("body_parsed");

  let upstream: Response;
  try {
    timer.mark("elevenlabs_request_start");
    upstream = await fetch(
      `https://api.elevenlabs.io/v1/text-to-speech/${encodeURIComponent(voiceId)}/stream?output_format=mp3_44100_128`,
      {
        method: "POST",
        headers: {
          "xi-api-key": ELEVENLABS_API_KEY,
          "content-type": "application/json",
          accept: "audio/mpeg",
        },
        body: JSON.stringify({
          text,
          model_id: ELEVENLABS_MODEL_ID,
        }),
      }
    );
    timer.mark("elevenlabs_response_headers_received");
  } catch (err) {
    console.error("tts-speak: network error calling ElevenLabs:", err);
    return errorResponse(502, "Could not reach the speech provider. Check your connection and try again.");
  }

  if (!upstream.ok || !upstream.body) {
    const detail = await upstream.text().catch(() => "");
    console.error("tts-speak: ElevenLabs API error:", upstream.status, detail);

    if (upstream.status === 401 || upstream.status === 403) {
      return errorResponse(500, "The speech provider rejected the request. Check server configuration.");
    }
    if (upstream.status === 429) {
      return errorResponse(429, "Rate limited by the speech provider. Try again shortly.");
    }
    return errorResponse(502, `The speech provider returned an error (status ${upstream.status}).`);
  }

  console.log(`[tts-speak ${requestId}]`, timer.serverTimingHeader());

  return new Response(upstream.body, {
    status: 200,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/octet-stream",
      "Server-Timing": timer.serverTimingHeader(),
      "X-Request-Id": requestId,
    },
  });
});
