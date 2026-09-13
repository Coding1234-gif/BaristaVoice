// stripe-billing-status — read-only view for the café admin billing screen.
//
// Returns:
//   - cafeBilling: the cafe_billing row (Stripe customer / payment method
//     state), or a "no_customer" default if the cafe has never set one up.
//   - currentPeriod: a LIVE estimate for the still-open billing period,
//     computed on the fly from calculate_cafe_usage() — never written to
//     cafe_usage (that only happens once, when
//     stripe-generate-usage-invoice actually invoices a period).
//   - history: past cafe_usage rows (already-reconciled/invoiced periods),
//     newest first.
//
// Same authorization model as every other admin-facing Edge Function in
// this repo (see pos-square-order-pay's authorizeOrderAccess): a
// cafe_admin only ever sees their own café; a super_admin can pass any
// cafeId.
import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
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
  return { allowed: false, reason: "Only café admins can view billing." };
}

/** Calendar-month billing period, Europe/London, that `now` falls in.
 * Mirrors public.cafe_billing_period_bounds() — kept in sync manually
 * since this function has no SQL access until it calls the DB. */
export function currentPeriodBounds(now: Date): { start: Date; end: Date; label: string } {
  const londonParts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/London",
    year: "numeric",
    month: "2-digit",
  }).formatToParts(now);
  const year = Number(londonParts.find((p) => p.type === "year")!.value);
  const month = Number(londonParts.find((p) => p.type === "month")!.value);
  return {
    ...monthBounds(year, month),
    label: new Date(Date.UTC(year, month - 1, 1)).toLocaleString("en-GB", { month: "long", year: "numeric" }),
  };
}

function monthBounds(year: number, month1to12: number): { start: Date; end: Date } {
  // Europe/London midnight expressed as a UTC instant — approximated via
  // Intl round-trip rather than a timezone database, which is why the
  // authoritative version lives in Postgres (cafe_billing_period_bounds);
  // this one only needs to be good enough to draw a "so far this month"
  // estimate.
  const start = new Date(Date.UTC(year, month1to12 - 1, 1, 0, 0, 0));
  const end = new Date(Date.UTC(year, month1to12, 1, 0, 0, 0));
  const startOffset = londonOffsetMinutes(start);
  const endOffset = londonOffsetMinutes(end);
  return {
    start: new Date(start.getTime() - startOffset * 60_000),
    end: new Date(end.getTime() - endOffset * 60_000),
  };
}

function londonOffsetMinutes(utcDate: Date): number {
  const dtf = new Intl.DateTimeFormat("en-US", {
    timeZone: "Europe/London",
    hour12: false,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
  const parts = Object.fromEntries(dtf.formatToParts(utcDate).map((p) => [p.type, p.value]));
  const asUtc = Date.UTC(
    Number(parts.year),
    Number(parts.month) - 1,
    Number(parts.day),
    Number(parts.hour),
    Number(parts.minute),
    Number(parts.second),
  );
  return Math.round((asUtc - utcDate.getTime()) / 60_000);
}

const BASE_SUBSCRIPTION_PENCE = 7900;
const PENCE_PER_ITEM = 5;

async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });

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
      return jsonResponse({ error: "Only café admins can view billing." }, 403);
    }

    const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
    const cafeId = (body.cafeId as string | undefined) ?? profile.cafe_id;
    if (!cafeId) return jsonResponse({ error: "cafeId is required." }, 400);

    const authz = authorizeCafeAccess(
      { role: profile.role as string, cafeId: profile.cafe_id as string | null },
      cafeId,
    );
    if (!authz.allowed) return jsonResponse({ error: authz.reason }, 403);

    const { data: cafeBilling } = await adminClient
      .from("cafe_billing")
      .select("stripe_customer_id, stripe_default_payment_method_id, billing_status, updated_at")
      .eq("cafe_id", cafeId)
      .maybeSingle();

    const { start, end, label } = currentPeriodBounds(new Date());

    const { data: usageRows, error: usageError } = await adminClient.rpc("calculate_cafe_usage", {
      p_cafe_id: cafeId,
      p_period_start: start.toISOString(),
      p_period_end: end.toISOString(),
    });

    if (usageError) {
      console.error("calculate_cafe_usage failed:", usageError);
      return jsonResponse({ error: "Could not calculate current usage." }, 500);
    }

    const current = usageRows?.[0] ?? { item_count: 0, usage_pence: 0 };
    const itemCount = Number(current.item_count ?? 0);
    const usagePence = Number(current.usage_pence ?? 0);

    const { data: history, error: historyError } = await adminClient
      .from("cafe_usage")
      .select(
        "id, billing_period_start, billing_period_end, item_count, usage_pence, status, stripe_invoice_id, invoiced_at, paid_at",
      )
      .eq("cafe_id", cafeId)
      .order("billing_period_start", { ascending: false })
      .limit(12);

    if (historyError) {
      console.error("cafe_usage history query failed:", historyError);
      return jsonResponse({ error: "Could not load billing history." }, 500);
    }

    return jsonResponse({
      cafeBilling: cafeBilling ?? { billing_status: "no_customer", stripe_customer_id: null },
      currentPeriod: {
        label,
        start: start.toISOString(),
        end: end.toISOString(),
        itemCount,
        usagePence,
        baseSubscriptionPence: BASE_SUBSCRIPTION_PENCE,
        estimatedTotalPence: BASE_SUBSCRIPTION_PENCE + usagePence,
        pencePerItem: PENCE_PER_ITEM,
      },
      history: history ?? [],
    });
  } catch (err) {
    console.error("stripe-billing-status failed:", err);
    return jsonResponse({ error: "Something went wrong loading billing." }, 500);
  }
}

if (import.meta.main) {
  Deno.serve(handler);
}
