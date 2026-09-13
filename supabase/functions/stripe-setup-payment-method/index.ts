// stripe-setup-payment-method — lets a café admin connect a payment
// method for the 5p-per-item usage charge, without this backend ever
// touching a card number.
//
// Flow: ensure a Stripe Customer exists for the café (create on first
// use) -> create a Stripe Checkout Session in `mode: "setup"` -> return
// its hosted URL for the Flutter app to open in an external browser.
// Stripe collects the card entirely on its own hosted page. The actual
// "payment method attached" confirmation happens asynchronously via the
// `checkout.session.completed` webhook (see stripe-webhook), not from
// this response — Stripe Checkout completion isn't guaranteed to be
// synchronous with the browser redirect.
//
// This never stores a card number/CVC — only stripe_customer_id and,
// once the webhook confirms it, stripe_default_payment_method_id.
import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY")!;

const STRIPE_API_BASE = "https://api.stripe.com/v1";

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

export class StripeApiError extends Error {
  readonly status: number;
  readonly detail: unknown;
  constructor(message: string, status: number, detail: unknown) {
    super(message);
    this.status = status;
    this.detail = detail;
  }
}

export async function stripeRequest(
  path: string,
  method: "GET" | "POST",
  params?: Record<string, string | number | boolean | undefined>,
  idempotencyKey?: string,
  fetchImpl: typeof fetch = fetch,
): Promise<any> {
  const headers: Record<string, string> = { Authorization: `Bearer ${STRIPE_SECRET_KEY}` };
  if (idempotencyKey) headers["Idempotency-Key"] = idempotencyKey;

  let url = `${STRIPE_API_BASE}${path}`;
  let body: string | undefined;

  const entries = Object.entries(params ?? {}).filter(([, v]) => v !== undefined) as [string, string | number | boolean][];

  if (method === "GET") {
    if (entries.length > 0) {
      const qs = new URLSearchParams();
      for (const [k, v] of entries) qs.set(k, String(v));
      url += `?${qs.toString()}`;
    }
  } else {
    headers["Content-Type"] = "application/x-www-form-urlencoded";
    const form = new URLSearchParams();
    for (const [k, v] of entries) form.set(k, String(v));
    body = form.toString();
  }

  const response = await fetchImpl(url, { method, headers, body });
  const json = await response.json();
  if (!response.ok) {
    throw new StripeApiError(json?.error?.message ?? `Stripe API error (${response.status})`, response.status, json);
  }
  return json;
}

export function authorizeCafeAccess(
  profile: { role: string; cafeId: string | null },
  requestedCafeId: string,
): { allowed: boolean; reason?: string } {
  if (profile.role === "super_admin") return { allowed: true };
  if (profile.role === "cafe_admin") {
    if (profile.cafeId === requestedCafeId) return { allowed: true };
    return { allowed: false, reason: "You do not have access to this café's billing." };
  }
  return { allowed: false, reason: "Only café admins can set up billing." };
}

async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed." }, 405);

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return jsonResponse({ error: "Missing Authorization header." }, 401);

    const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const callerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: userData, error: userError } = await callerClient.auth.getUser();
    if (userError || !userData.user) return jsonResponse({ error: "Invalid or expired session." }, 401);

    const { data: profile } = await adminClient
      .from("profiles")
      .select("role, cafe_id")
      .eq("id", userData.user.id)
      .maybeSingle();

    if (!profile || (profile.role !== "cafe_admin" && profile.role !== "super_admin")) {
      return jsonResponse({ error: "Only café admins can set up billing." }, 403);
    }

    const body = await req.json().catch(() => ({}));
    const cafeId = (body.cafeId as string | undefined) ?? profile.cafe_id;
    const successUrl = body.successUrl as string | undefined;
    const cancelUrl = body.cancelUrl as string | undefined;

    if (!cafeId) return jsonResponse({ error: "cafeId is required." }, 400);
    if (!successUrl || !cancelUrl) {
      return jsonResponse({ error: "successUrl and cancelUrl are required." }, 400);
    }

    const authz = authorizeCafeAccess(
      { role: profile.role as string, cafeId: profile.cafe_id as string | null },
      cafeId,
    );
    if (!authz.allowed) return jsonResponse({ error: authz.reason }, 403);

    const { data: cafe } = await adminClient.from("cafes").select("name").eq("id", cafeId).maybeSingle();

    const { data: existingBilling } = await adminClient
      .from("cafe_billing")
      .select("id, stripe_customer_id")
      .eq("cafe_id", cafeId)
      .maybeSingle();

    let stripeCustomerId = existingBilling?.stripe_customer_id ?? null;

    if (!stripeCustomerId) {
      const customer = await stripeRequest(
        "/customers",
        "POST",
        {
          name: cafe?.name ?? undefined,
          "metadata[cafe_id]": cafeId,
        },
        `cafe-customer-${cafeId}`,
      );
      stripeCustomerId = customer.id as string;

      const { error: upsertError } = await adminClient
        .from("cafe_billing")
        .upsert(
          { cafe_id: cafeId, stripe_customer_id: stripeCustomerId, billing_status: "pending_payment_method" },
          { onConflict: "cafe_id" },
        );
      if (upsertError) {
        console.error("Could not save new Stripe customer:", upsertError);
        return jsonResponse({ error: "Could not start billing setup. Please try again." }, 500);
      }
    }

    const session = await stripeRequest("/checkout/sessions", "POST", {
      mode: "setup",
      customer: stripeCustomerId,
      "payment_method_types[0]": "card",
      success_url: successUrl,
      cancel_url: cancelUrl,
      "metadata[cafe_id]": cafeId,
    });

    return jsonResponse({ url: session.url as string });
  } catch (err) {
    if (err instanceof StripeApiError) {
      console.error("Stripe error in stripe-setup-payment-method:", err.detail);
      return jsonResponse({ error: "Could not start billing setup with Stripe. Please try again." }, 502);
    }
    console.error("stripe-setup-payment-method failed:", err);
    return jsonResponse({ error: "Something went wrong. Please try again." }, 500);
  }
}

if (import.meta.main) {
  Deno.serve(handler);
}
