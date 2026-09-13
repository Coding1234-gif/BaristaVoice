// Tests for stripe-generate-usage-invoice's pure logic. Run with:
//   deno test --allow-env supabase/functions/stripe-generate-usage-invoice/index.test.ts
//
// Same boundary as the Square functions' tests: exercises authorization,
// date math, and the fetch-injected Stripe request builder — not the
// Deno.serve handler end-to-end (needs a live Supabase project + Stripe
// test-mode keys). The idempotency/duplicate-invoice guarantees this
// function relies on live in the database (unique(cafe_id,
// billing_period_start) — see schema.sql) and in the manual test plan.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { authorizeCafeAccess, isTrustedServiceRoleCaller, previousMonthStartDate, stripeRequest } from "./index.ts";

// ---------------------------------------------------------------------
// authorizeCafeAccess — the same guarantee test #19 needs: a cafe_admin
// for one café must never see or act on another café's billing.
// ---------------------------------------------------------------------

Deno.test("authorizeCafeAccess: cafe_admin of the SAME cafe is allowed", () => {
  const result = authorizeCafeAccess({ role: "cafe_admin", cafeId: "cafe-1" }, "cafe-1");
  assertEquals(result.allowed, true);
});

Deno.test("authorizeCafeAccess: cafe_admin of a DIFFERENT cafe is denied — cross-café billing isolation", () => {
  const result = authorizeCafeAccess({ role: "cafe_admin", cafeId: "cafe-1" }, "cafe-2");
  assertEquals(result.allowed, false);
});

Deno.test("authorizeCafeAccess: super_admin is allowed regardless of cafe", () => {
  const result = authorizeCafeAccess({ role: "super_admin", cafeId: null }, "cafe-2");
  assertEquals(result.allowed, true);
});

Deno.test("authorizeCafeAccess: a non-admin role is denied", () => {
  const result = authorizeCafeAccess({ role: "customer", cafeId: null }, "cafe-1");
  assertEquals(result.allowed, false);
});

Deno.test("authorizeCafeAccess: cafe_admin with no cafe_id is denied, never falls back to allow", () => {
  const result = authorizeCafeAccess({ role: "cafe_admin", cafeId: null }, "cafe-1");
  assertEquals(result.allowed, false);
});

// ---------------------------------------------------------------------
// isTrustedServiceRoleCaller — gates the future-cron entry point.
// ---------------------------------------------------------------------

Deno.test("isTrustedServiceRoleCaller: exact service-role bearer matches", () => {
  assert(isTrustedServiceRoleCaller("Bearer service-role-key", "service-role-key"));
});

Deno.test("isTrustedServiceRoleCaller: a cafe admin's own token is never mistaken for service role", () => {
  assertEquals(isTrustedServiceRoleCaller("Bearer some-users-jwt", "service-role-key"), false);
});

// ---------------------------------------------------------------------
// previousMonthStartDate — billing period assignment (Europe/London).
// ---------------------------------------------------------------------

Deno.test("previousMonthStartDate: mid-month resolves to the 1st of the prior month", () => {
  // 2026-09-15 in UTC is still September in Europe/London.
  assertEquals(previousMonthStartDate(new Date("2026-09-15T12:00:00Z")), "2026-08-01");
});

Deno.test("previousMonthStartDate: January rolls back to December of the previous year", () => {
  assertEquals(previousMonthStartDate(new Date("2026-01-10T12:00:00Z")), "2025-12-01");
});

// ---------------------------------------------------------------------
// stripeRequest — form-encodes params and attaches the idempotency key,
// the mechanism every duplicate-invoice/duplicate-charge guarantee in
// this function depends on.
// ---------------------------------------------------------------------

Deno.test("stripeRequest: form-encodes params and sets the Idempotency-Key header", async () => {
  let capturedUrl = "";
  let capturedInit: RequestInit | undefined;

  const fetchImpl = ((url: string, init?: RequestInit) => {
    capturedUrl = url;
    capturedInit = init;
    return Promise.resolve(new Response(JSON.stringify({ id: "in_123" }), { status: 200 }));
  }) as unknown as typeof fetch;

  await stripeRequest(
    "/invoices",
    "POST",
    { customer: "cus_1", amount: 6200, currency: "gbp" },
    "usageinvoice-abc",
    fetchImpl,
  );

  assertEquals(capturedUrl, "https://api.stripe.com/v1/invoices");
  const headers = capturedInit!.headers as Record<string, string>;
  assertEquals(headers["Idempotency-Key"], "usageinvoice-abc");
  assert((capturedInit!.body as string).includes("customer=cus_1"));
  assert((capturedInit!.body as string).includes("amount=6200"));
});

Deno.test("stripeRequest: a non-2xx response throws with the Stripe error message, not a generic one", async () => {
  const fetchImpl = (() =>
    Promise.resolve(
      new Response(JSON.stringify({ error: { message: "Your card was declined." } }), { status: 402 }),
    )) as unknown as typeof fetch;

  try {
    await stripeRequest("/invoices/in_1/pay", "POST", {}, "pay-abc", fetchImpl);
    throw new Error("expected stripeRequest to throw");
  } catch (err) {
    assert((err as Error).message.includes("card was declined"));
  }
});
