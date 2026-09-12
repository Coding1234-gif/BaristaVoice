// Tests for pos-square-terminal-checkout. Run with:
//   deno test --allow-env supabase/functions/pos-square-terminal-checkout/index.test.ts
//
// Same boundary as pos-square-order-submit's tests: these exercise the
// pure, dependency-injected core (caller classification, authorization,
// status eligibility, device-id resolution, payload building, and the
// Square call with an injected fetch) — not the Deno.serve handler
// end-to-end (needs a live Supabase project).
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  authorizeOrderAccess,
  buildTerminalCheckoutPayload,
  classifyCaller,
  createSquareTerminalCheckout,
  isCheckoutEligibleStatus,
  isTrustedServiceRoleCaller,
  resolveDeviceId,
  SquareApiError,
} from "./index.ts";

// ---------------------------------------------------------------------------
// 1. Caller classification — the new three-way split (service_role /
//    anonymous / authenticated) that opens this function to the kiosk.
// ---------------------------------------------------------------------------

Deno.test("classifyCaller: no Authorization header at all is the kiosk's own convention -> anonymous", () => {
  assertEquals(classifyCaller(null, "anon-key", "service-role-key"), "anonymous");
});

Deno.test("classifyCaller: the exact service-role bearer token -> service_role", () => {
  assertEquals(classifyCaller("Bearer service-role-key", "anon-key", "service-role-key"), "service_role");
});

// The real Flutter/Supabase client always attaches `Authorization: Bearer
// <anon key>` for an unauthenticated caller (it never actually omits the
// header) — so this is the kiosk's real-world calling convention, not the
// theoretical "no header" case above.
Deno.test("classifyCaller: the anon-key bearer token is also the kiosk's convention -> anonymous", () => {
  assertEquals(classifyCaller("Bearer anon-key", "anon-key", "service-role-key"), "anonymous");
});

Deno.test("classifyCaller: any other bearer token -> authenticated (goes through the profile check)", () => {
  assertEquals(classifyCaller("Bearer some-user-jwt", "anon-key", "service-role-key"), "authenticated");
});

Deno.test("isTrustedServiceRoleCaller: exact match only", () => {
  assert(isTrustedServiceRoleCaller("Bearer key", "key"));
  assert(!isTrustedServiceRoleCaller("Bearer wrong", "key"));
  assert(!isTrustedServiceRoleCaller("Bearer key", undefined));
});

// ---------------------------------------------------------------------------
// 2. authorizeOrderAccess — unchanged shape from pos-square-order-submit,
//    still exercised here since it's a fresh copy in this file.
// ---------------------------------------------------------------------------

Deno.test("authorizeOrderAccess: cafe_admin of the SAME cafe is allowed", () => {
  const result = authorizeOrderAccess({ role: "cafe_admin", cafeId: "cafe-1" }, "cafe-1");
  assertEquals(result.allowed, true);
});

Deno.test("authorizeOrderAccess: cafe_admin of a DIFFERENT cafe is denied", () => {
  const result = authorizeOrderAccess({ role: "cafe_admin", cafeId: "cafe-1" }, "cafe-2");
  assertEquals(result.allowed, false);
});

Deno.test("authorizeOrderAccess: super_admin is allowed regardless of cafe", () => {
  const result = authorizeOrderAccess({ role: "super_admin", cafeId: null }, "cafe-2");
  assertEquals(result.allowed, true);
});

Deno.test("authorizeOrderAccess: a non-admin role is denied", () => {
  const result = authorizeOrderAccess({ role: "customer", cafeId: "cafe-1" }, "cafe-1");
  assertEquals(result.allowed, false);
});

// ---------------------------------------------------------------------------
// 3. Status eligibility gate
// ---------------------------------------------------------------------------

Deno.test("isCheckoutEligibleStatus: sent_to_pos, payment_pending, payment_failed are eligible", () => {
  assert(isCheckoutEligibleStatus("sent_to_pos"));
  assert(isCheckoutEligibleStatus("payment_pending"));
  assert(isCheckoutEligibleStatus("payment_failed"));
});

Deno.test("isCheckoutEligibleStatus: confirmed/sending_to_pos/pos_failed/paid/cancelled are not eligible", () => {
  for (const status of ["confirmed", "sending_to_pos", "pos_failed", "paid", "cancelled", "draft"]) {
    assert(!isCheckoutEligibleStatus(status), `expected ${status} to be ineligible`);
  }
});

// ---------------------------------------------------------------------------
// 4. Device id resolution — sandbox always uses the fixed simulated
//    device; production requires a real device id from a staff/service
//    caller, never from an anonymous kiosk caller.
// ---------------------------------------------------------------------------

Deno.test("resolveDeviceId: sandbox always resolves to the fixed simulated device, regardless of caller", () => {
  const result = resolveDeviceId({
    environment: "sandbox",
    sandboxDeviceId: "sandbox-device",
    callerKind: "anonymous",
    requestedDeviceId: undefined,
  });
  assert(result.ok);
  assertEquals(result.ok && result.deviceId, "sandbox-device");
});

Deno.test("resolveDeviceId: production + anonymous caller is rejected even if a deviceId was supplied", () => {
  const result = resolveDeviceId({
    environment: "production",
    sandboxDeviceId: "sandbox-device",
    callerKind: "anonymous",
    requestedDeviceId: "some-device",
  });
  assert(!result.ok);
  assertEquals(!result.ok && result.status, 403);
});

Deno.test("resolveDeviceId: production + authenticated caller with no deviceId is rejected", () => {
  const result = resolveDeviceId({
    environment: "production",
    sandboxDeviceId: "sandbox-device",
    callerKind: "authenticated",
    requestedDeviceId: undefined,
  });
  assert(!result.ok);
  assertEquals(!result.ok && result.status, 400);
});

Deno.test("resolveDeviceId: production + service_role caller with a real deviceId is allowed", () => {
  const result = resolveDeviceId({
    environment: "production",
    sandboxDeviceId: "sandbox-device",
    callerKind: "service_role",
    requestedDeviceId: "device-abc",
  });
  assert(result.ok);
  assertEquals(result.ok && result.deviceId, "device-abc");
});

Deno.test("resolveDeviceId: a non-string deviceId in production is rejected, not coerced", () => {
  const result = resolveDeviceId({
    environment: "production",
    sandboxDeviceId: "sandbox-device",
    callerKind: "authenticated",
    requestedDeviceId: 12345,
  });
  assert(!result.ok);
});

// ---------------------------------------------------------------------------
// 5. Payload building
// ---------------------------------------------------------------------------

Deno.test("buildTerminalCheckoutPayload: shapes the Square Terminal checkout request", () => {
  const payload = buildTerminalCheckoutPayload({
    idempotencyKey: "order-idem-1-terminal",
    amountCents: 825,
    currency: "USD",
    squareOrderId: "sq-order-1",
    orderId: "order-1",
    deviceId: "device-1",
  });
  assertEquals(payload, {
    idempotency_key: "order-idem-1-terminal",
    checkout: {
      amount_money: { amount: 825, currency: "USD" },
      order_id: "sq-order-1",
      reference_id: "order-1",
      device_options: { device_id: "device-1", show_itemized_cart: true },
    },
  });
});

Deno.test("idempotency: building the checkout payload twice from the same inputs is byte-identical", () => {
  const params = {
    idempotencyKey: "idem-1-terminal",
    amountCents: 500,
    currency: "USD",
    squareOrderId: "sq-1",
    orderId: "order-1",
    deviceId: "device-1",
  };
  assertEquals(buildTerminalCheckoutPayload(params), buildTerminalCheckoutPayload(params));
});

// ---------------------------------------------------------------------------
// 6. Square API call (fetch-injected)
// ---------------------------------------------------------------------------

Deno.test("createSquareTerminalCheckout: returns the checkout id + status on success", async () => {
  const fetchImpl = () =>
    Promise.resolve(
      new Response(JSON.stringify({ checkout: { id: "checkout-1", status: "PENDING" } }), { status: 200 }),
    );

  const result = await createSquareTerminalCheckout({
    accessToken: "token",
    baseUrl: "https://example.test",
    squareVersion: "2024-10-17",
    payload: {},
    fetchImpl: fetchImpl as unknown as typeof fetch,
  });

  assertEquals(result.checkoutId, "checkout-1");
  assertEquals(result.status, "PENDING");
});

Deno.test("createSquareTerminalCheckout: a non-2xx response throws SquareApiError with status + bounded detail", async () => {
  const fetchImpl = () => Promise.resolve(new Response(JSON.stringify({ errors: ["boom"] }), { status: 500 }));

  const err = await assertRejects(
    () =>
      createSquareTerminalCheckout({
        accessToken: "token",
        baseUrl: "https://example.test",
        squareVersion: "2024-10-17",
        payload: {},
        fetchImpl: fetchImpl as unknown as typeof fetch,
      }),
    SquareApiError,
  );
  assertEquals((err as SquareApiError).status, 500);
});

Deno.test("createSquareTerminalCheckout: a 200 with no checkout id still fails loudly", async () => {
  const fetchImpl = () => Promise.resolve(new Response(JSON.stringify({}), { status: 200 }));

  await assertRejects(
    () =>
      createSquareTerminalCheckout({
        accessToken: "token",
        baseUrl: "https://example.test",
        squareVersion: "2024-10-17",
        payload: {},
        fetchImpl: fetchImpl as unknown as typeof fetch,
      }),
    SquareApiError,
  );
});
