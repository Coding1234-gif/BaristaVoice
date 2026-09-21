// Run with:
//   deno test --allow-env supabase/functions/stripe-setup-payment-method/index.test.ts
import { assertEquals } from "jsr:@std/assert@1";
import { buildSetupSessionParams } from "./index.ts";

const params = buildSetupSessionParams({
  stripeCustomerId: "cus_123",
  successUrl: "baristavoice://open/admin/billing?stripe_setup=success",
  cancelUrl: "baristavoice://open/admin/billing?stripe_setup=cancel",
  cafeId: "cafe-1",
});

Deno.test("setup session: is a card-only Checkout in setup mode for the café's customer", () => {
  assertEquals(params.mode, "setup");
  assertEquals(params.customer, "cus_123");
  assertEquals(params["payment_method_types[0]"], "card");
  assertEquals(params["metadata[cafe_id]"], "cafe-1");
});

// Regression guard (confirmed 2026-09-19): an account with Managed Payments
// on by default makes Stripe reject `mode: setup` unless the request opts out.
Deno.test("setup session: explicitly opts out of Managed Payments", () => {
  assertEquals(params["managed_payments[enabled]"], false);
});

Deno.test("setup session: the opt-out is form-encoded the way Stripe expects", () => {
  const form = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) form.set(k, String(v));
  assertEquals(form.get("managed_payments[enabled]"), "false");
});
