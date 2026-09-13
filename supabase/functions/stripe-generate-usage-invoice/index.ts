// stripe-generate-usage-invoice — the core billing job: turns one café's
// reconciled item usage for one billing period into a single Stripe
// invoice for the 5p-per-item component (never the £79 subscription —
// that stays RevenueCat's job).
//
// Callable two ways:
//   - By a signed-in cafe_admin (their own café) or super_admin, for a
//     manual "generate this period's invoice" action in the admin UI —
//     the MVP's stand-in for scheduling, since this repo intentionally
//     has no cron wired up yet (see this function's own header comment
//     on how to add one later).
//   - By the service role (Authorization: Bearer <service role key>),
//     for that future scheduled trigger — same logic path either way.
//
// IDEMPOTENCY (the most important property of this function):
//   `cafe_usage` has `unique (cafe_id, billing_period_start)`. This
//   function always tries to INSERT that row FIRST, before ever calling
//   Stripe. If the insert hits the unique constraint, a row for this
//   period already exists:
//     - if it's already invoiced/paid/payment_failed, this call is a
//       total no-op — returns the existing row, touches Stripe for
//       nothing. A billing period can never get a second invoice.
//     - if it's still 'calculated' (a previous attempt crashed/errored
//       before reaching Stripe, or usage has changed since it was first
//       calculated — e.g. a late-arriving payment webhook), it's safe
//       to refresh the numbers from calculate_cafe_usage() and continue
//       — nothing has been charged yet.
//   Every Stripe write below also carries an idempotency key derived
//   from the cafe_usage row's own id, so even a network-level retry of
//   this same request can't create a second Stripe invoice item/invoice.
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
const PENCE_PER_ITEM = 5;

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
  return { allowed: false, reason: "Only café admins can generate invoices." };
}

export function isTrustedServiceRoleCaller(authHeader: string, serviceRoleKey: string | undefined): boolean {
  if (!serviceRoleKey) return false;
  return authHeader === `Bearer ${serviceRoleKey}`;
}

/** Previous calendar month's first-of-month date, Europe/London "today". */
export function previousMonthStartDate(now: Date): string {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/London",
    year: "numeric",
    month: "2-digit",
  }).formatToParts(now);
  const year = Number(parts.find((p) => p.type === "year")!.value);
  const month = Number(parts.find((p) => p.type === "month")!.value);
  const prevMonth = month === 1 ? 12 : month - 1;
  const prevYear = month === 1 ? year - 1 : year;
  return `${prevYear}-${String(prevMonth).padStart(2, "0")}-01`;
}

async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed." }, 405);

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return jsonResponse({ error: "Missing Authorization header." }, 401);

    const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    const body = await req.json().catch(() => ({}));
    let cafeId = body.cafeId as string | undefined;

    if (!isTrustedServiceRoleCaller(authHeader, SUPABASE_SERVICE_ROLE_KEY)) {
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
        return jsonResponse({ error: "Only café admins can generate invoices." }, 403);
      }

      cafeId = cafeId ?? (profile.cafe_id as string | undefined);
      const authz = authorizeCafeAccess(
        { role: profile.role as string, cafeId: profile.cafe_id as string | null },
        cafeId ?? "",
      );
      if (!authz.allowed) return jsonResponse({ error: authz.reason }, 403);
    }

    if (!cafeId) return jsonResponse({ error: "cafeId is required." }, 400);

    const periodStartDate = (body.periodStartDate as string | undefined) ?? previousMonthStartDate(new Date());

    const { data: bounds, error: boundsError } = await adminClient
      .rpc("cafe_billing_period_bounds", { p_month_start_date: periodStartDate })
      .single();

    if (boundsError || !bounds) {
      console.error("cafe_billing_period_bounds failed:", boundsError);
      return jsonResponse({ error: "Could not resolve billing period." }, 500);
    }

    const periodStart = (bounds as any).period_start as string;
    const periodEnd = (bounds as any).period_end as string;

    // -----------------------------------------------------------
    // Find or create the cafe_usage row for this period — the
    // idempotency gate described in the file header.
    // -----------------------------------------------------------

    let usageRow = await selectUsageRow(adminClient, cafeId, periodStart);

    if (usageRow && usageRow.status !== "calculated") {
      // Already invoiced (or further along) — total no-op, Stripe is
      // never touched again for this period.
      return jsonResponse({ usage: usageRow, alreadyProcessed: true });
    }

    const { data: calc, error: calcError } = await adminClient.rpc("calculate_cafe_usage", {
      p_cafe_id: cafeId,
      p_period_start: periodStart,
      p_period_end: periodEnd,
    });

    if (calcError) {
      console.error("calculate_cafe_usage failed:", calcError);
      return jsonResponse({ error: "Could not calculate usage for this period." }, 500);
    }

    const itemCount = Number(calc?.[0]?.item_count ?? 0);
    const usagePence = Number(calc?.[0]?.usage_pence ?? 0);

    if (!usageRow) {
      const { data: inserted, error: insertError } = await adminClient
        .from("cafe_usage")
        .insert({
          cafe_id: cafeId,
          billing_period_start: periodStart,
          billing_period_end: periodEnd,
          item_count: itemCount,
          usage_pence: usagePence,
          status: "calculated",
        })
        .select()
        .maybeSingle();

      if (insertError) {
        if (insertError.code === "23505") {
          // Lost a race with a concurrent call for the same period —
          // fetch what the winner inserted and proceed from there.
          usageRow = await selectUsageRow(adminClient, cafeId, periodStart);
          if (usageRow && usageRow.status !== "calculated") {
            return jsonResponse({ usage: usageRow, alreadyProcessed: true });
          }
        } else {
          console.error("Could not insert cafe_usage row:", insertError);
          return jsonResponse({ error: "Could not record usage for this period." }, 500);
        }
      } else {
        usageRow = inserted;
      }
    } else {
      // Existing 'calculated' row — refresh with the latest numbers
      // (handles a late-arriving paid order changing the count) before
      // we lock it in by invoicing.
      const { data: updated, error: updateError } = await adminClient
        .from("cafe_usage")
        .update({ item_count: itemCount, usage_pence: usagePence, calculated_at: new Date().toISOString() })
        .eq("id", usageRow.id)
        .select()
        .maybeSingle();
      if (updateError) {
        console.error("Could not refresh cafe_usage row:", updateError);
        return jsonResponse({ error: "Could not refresh usage for this period." }, 500);
      }
      usageRow = updated;
    }

    if (!usageRow) return jsonResponse({ error: "Could not resolve usage for this period." }, 500);

    // -----------------------------------------------------------
    // Zero usage — nothing to invoice. Settle the row without ever
    // calling Stripe.
    // -----------------------------------------------------------

    if (usageRow.usage_pence === 0) {
      const { data: settled } = await adminClient
        .from("cafe_usage")
        .update({ status: "paid", paid_at: new Date().toISOString() })
        .eq("id", usageRow.id)
        .select()
        .maybeSingle();
      return jsonResponse({ usage: settled ?? usageRow, zeroUsage: true });
    }

    // -----------------------------------------------------------
    // Need an active Stripe customer + default payment method before
    // we can invoice. If not ready, leave the row as 'calculated' —
    // safe to retry once billing is set up (see this function's
    // "resume" branch above).
    // -----------------------------------------------------------

    const { data: billing } = await adminClient
      .from("cafe_billing")
      .select("stripe_customer_id, stripe_default_payment_method_id, billing_status")
      .eq("cafe_id", cafeId)
      .maybeSingle();

    if (!billing?.stripe_customer_id) {
      return jsonResponse(
        { error: "This café has no Stripe customer set up yet.", usage: usageRow },
        409,
      );
    }
    if (!billing.stripe_default_payment_method_id || billing.billing_status !== "active") {
      return jsonResponse(
        { error: "This café has not connected a payment method yet.", usage: usageRow },
        409,
      );
    }

    // -----------------------------------------------------------
    // Stripe: one invoice item (the usage line), one invoice that
    // sweeps it in, finalized and charged immediately. Each write is
    // keyed to usageRow.id, so retrying this whole function after a
    // partial failure can never create a second item/invoice.
    // -----------------------------------------------------------

    const description = `BaristaVoice usage — ${usageRow.item_count} items × £0.05`;

    await stripeRequest(
      "/invoiceitems",
      "POST",
      {
        customer: billing.stripe_customer_id,
        amount: usageRow.usage_pence,
        currency: "gbp",
        description,
        "metadata[cafe_usage_id]": usageRow.id,
      },
      `usageitem-${usageRow.id}`,
    );

    const invoice = await stripeRequest(
      "/invoices",
      "POST",
      {
        customer: billing.stripe_customer_id,
        collection_method: "charge_automatically",
        auto_advance: false,
        description,
        "metadata[cafe_usage_id]": usageRow.id,
      },
      `usageinvoice-${usageRow.id}`,
    );

    const finalized = await stripeRequest("/invoices/" + invoice.id + "/finalize", "POST", {}, `finalize-${usageRow.id}`);

    let paymentIssue = false;
    let paidInvoice = finalized;
    try {
      paidInvoice = await stripeRequest("/invoices/" + invoice.id + "/pay", "POST", {}, `pay-${usageRow.id}`);
    } catch (payErr) {
      // A synchronous decline is a normal business outcome, not a
      // system error — the invoice still exists in Stripe, and
      // invoice.payment_failed will arrive via webhook shortly.
      paymentIssue = true;
      console.warn("Immediate invoice payment attempt failed:", payErr);
    }

    const { data: finalRow, error: finalUpdateError } = await adminClient
      .from("cafe_usage")
      .update({
        status: "invoiced",
        stripe_invoice_id: invoice.id,
        invoiced_at: new Date().toISOString(),
      })
      .eq("id", usageRow.id)
      .select()
      .maybeSingle();

    if (finalUpdateError) {
      console.error("Could not record Stripe invoice id after creating it:", finalUpdateError, {
        cafeUsageId: usageRow.id,
        stripeInvoiceId: invoice.id,
      });
    }

    return jsonResponse({
      usage: finalRow ?? { ...usageRow, status: "invoiced", stripe_invoice_id: invoice.id },
      stripeInvoiceStatus: paidInvoice?.status ?? finalized?.status ?? null,
      paymentIssue,
    });
  } catch (err) {
    if (err instanceof StripeApiError) {
      console.error("Stripe error in stripe-generate-usage-invoice:", err.detail);
      return jsonResponse({ error: "Stripe could not process this invoice. Please try again." }, 502);
    }
    console.error("stripe-generate-usage-invoice failed:", err);
    return jsonResponse({ error: "Something went wrong generating the invoice." }, 500);
  }
}

if (import.meta.main) {
  Deno.serve(handler);
}

async function selectUsageRow(adminClient: any, cafeId: string, periodStart: string) {
  const { data } = await adminClient
    .from("cafe_usage")
    .select("*")
    .eq("cafe_id", cafeId)
    .eq("billing_period_start", periodStart)
    .maybeSingle();
  return data;
}
