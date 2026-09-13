// stripe-webhook — the only source of truth for "did the café's usage
// invoice actually get paid". Everything else in the usage-billing flow
// (stripe-generate-usage-invoice) only ever gets as far as "invoiced";
// this function is what moves a cafe_usage row to 'paid' or
// 'payment_failed', and what confirms a payment method was actually
// attached after stripe-setup-payment-method's Checkout Session.
//
// Public endpoint — Stripe calls this directly, with no Supabase auth
// header, so authenticity comes entirely from verifying the
// Stripe-Signature header against STRIPE_WEBHOOK_SECRET (see
// verifyStripeSignature). Never trust an unsigned/unverified request
// here.
//
// IDEMPOTENCY: Stripe explicitly does not guarantee exactly-once
// delivery. Every event id is inserted into stripe_webhook_events
// BEFORE any billing state changes; if that insert hits the primary
// key (i.e. this event id was already processed), the handler returns
// 200 immediately and does nothing else — so a retried/duplicated
// delivery can never double-apply a payment.
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY")!;
const STRIPE_WEBHOOK_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET")!;

const STRIPE_API_BASE = "https://api.stripe.com/v1";
const TOLERANCE_SECONDS = 5 * 60;

function textResponse(body: string, status = 200) {
  return new Response(body, { status });
}

export async function verifyStripeSignature(
  payload: string,
  sigHeader: string | null,
  secret: string,
  nowSeconds: number = Math.floor(Date.now() / 1000),
): Promise<boolean> {
  if (!sigHeader) return false;

  const parts = Object.fromEntries(
    sigHeader.split(",").map((kv) => {
      const idx = kv.indexOf("=");
      return [kv.slice(0, idx), kv.slice(idx + 1)];
    }),
  );

  const timestamp = parts["t"];
  const signature = parts["v1"];
  if (!timestamp || !signature) return false;

  const timestampNum = Number(timestamp);
  if (!Number.isFinite(timestampNum) || Math.abs(nowSeconds - timestampNum) > TOLERANCE_SECONDS) {
    return false;
  }

  const signedPayload = `${timestamp}.${payload}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sigBytes = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(signedPayload));
  const expectedHex = Array.from(new Uint8Array(sigBytes))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

  return timingSafeEqual(expectedHex, signature);
}

export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function stripeGet(path: string): Promise<any> {
  const response = await fetch(`${STRIPE_API_BASE}${path}`, {
    headers: { Authorization: `Bearer ${STRIPE_SECRET_KEY}` },
  });
  return response.json();
}

async function stripePost(path: string, params: Record<string, string | undefined>): Promise<any> {
  const form = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) {
    if (v !== undefined) form.set(k, v);
  }
  const response = await fetch(`${STRIPE_API_BASE}${path}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${STRIPE_SECRET_KEY}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: form.toString(),
  });
  return response.json();
}

async function handler(req: Request): Promise<Response> {
  if (req.method !== "POST") return textResponse("Method not allowed.", 405);

  const payload = await req.text();
  const signatureHeader = req.headers.get("Stripe-Signature");

  const verified = await verifyStripeSignature(payload, signatureHeader, STRIPE_WEBHOOK_SECRET);
  if (!verified) {
    console.error("stripe-webhook: signature verification failed.");
    return textResponse("Invalid signature.", 400);
  }

  let event: any;
  try {
    event = JSON.parse(payload);
  } catch {
    return textResponse("Invalid payload.", 400);
  }

  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  const { error: insertEventError } = await adminClient
    .from("stripe_webhook_events")
    .insert({ id: event.id, type: event.type });

  if (insertEventError) {
    if (insertEventError.code === "23505") {
      // Already processed this exact event id — duplicate delivery.
      return textResponse("Already processed.", 200);
    }
    console.error("stripe-webhook: could not record event id:", insertEventError);
    return textResponse("Could not record event.", 500);
  }

  try {
    switch (event.type) {
      case "checkout.session.completed":
        await handleCheckoutSessionCompleted(adminClient, event.data.object);
        break;
      case "invoice.paid":
        await handleInvoicePaid(adminClient, event.data.object);
        break;
      case "invoice.payment_failed":
        await handleInvoicePaymentFailed(adminClient, event.data.object);
        break;
      default:
        // Unhandled event types are expected and fine — Stripe sends
        // far more event types than this MVP needs to react to.
        break;
    }
  } catch (err) {
    // The event id is already recorded, so a crash here does NOT risk
    // reprocessing — Stripe will retry on a non-2xx, but our own
    // idempotency ledger means a retry is always safe regardless.
    console.error(`stripe-webhook: handler for ${event.type} failed:`, err);
    return textResponse("Handler error.", 500);
  }

  return textResponse("ok", 200);
}

if (import.meta.main) {
  Deno.serve(handler);
}

async function handleCheckoutSessionCompleted(adminClient: any, session: any) {
  if (session.mode !== "setup") return;

  const cafeId = session.metadata?.cafe_id as string | undefined;
  const customerId = session.customer as string | undefined;
  const setupIntentId = session.setup_intent as string | undefined;
  if (!customerId || !setupIntentId) return;

  const setupIntent = await stripeGet(`/setup_intents/${setupIntentId}`);
  const paymentMethodId = setupIntent?.payment_method as string | undefined;
  if (!paymentMethodId) {
    console.error("stripe-webhook: setup_intent has no payment_method:", setupIntentId);
    return;
  }

  await stripePost(`/payment_methods/${paymentMethodId}/attach`, { customer: customerId });
  await stripePost(`/customers/${customerId}`, {
    "invoice_settings[default_payment_method]": paymentMethodId,
  });

  const update = {
    stripe_default_payment_method_id: paymentMethodId,
    billing_status: "active",
  };

  if (cafeId) {
    await adminClient.from("cafe_billing").update(update).eq("cafe_id", cafeId);
  } else {
    await adminClient.from("cafe_billing").update(update).eq("stripe_customer_id", customerId);
  }
}

async function handleInvoicePaid(adminClient: any, invoice: any) {
  const invoiceId = invoice.id as string;

  const { data: usageRow } = await adminClient
    .from("cafe_usage")
    .select("id, cafe_id")
    .eq("stripe_invoice_id", invoiceId)
    .maybeSingle();

  if (!usageRow) {
    console.warn("stripe-webhook: invoice.paid for unknown invoice:", invoiceId);
    return;
  }

  await adminClient
    .from("cafe_usage")
    .update({ status: "paid", paid_at: new Date().toISOString() })
    .eq("id", usageRow.id);

  await adminClient
    .from("cafe_billing")
    .update({ billing_status: "active" })
    .eq("cafe_id", usageRow.cafe_id);
}

async function handleInvoicePaymentFailed(adminClient: any, invoice: any) {
  const invoiceId = invoice.id as string;

  const { data: usageRow } = await adminClient
    .from("cafe_usage")
    .select("id, cafe_id")
    .eq("stripe_invoice_id", invoiceId)
    .maybeSingle();

  if (!usageRow) {
    console.warn("stripe-webhook: invoice.payment_failed for unknown invoice:", invoiceId);
    return;
  }

  await adminClient.from("cafe_usage").update({ status: "payment_failed" }).eq("id", usageRow.id);

  await adminClient
    .from("cafe_billing")
    .update({ billing_status: "past_due" })
    .eq("cafe_id", usageRow.cafe_id);
}
