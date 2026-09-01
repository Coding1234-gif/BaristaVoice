// Tests for pos-square-order-pay. Run with:
//   deno test --allow-env supabase/functions/pos-square-order-pay/index.test.ts
//
// Same boundary as pos-square-order-submit's tests: these exercise the
// pure, dependency-injected core — caller classification, authorization,
// status eligibility, tender/payment-id extraction, capture verification,
// payload building, and the Square call with an injected fetch — not the
// Deno.serve handler end-to-end (needs a live Supabase project). The
// handler-level scenarios this file's pure functions are the building
// blocks for (payment pending, successful payment, already-paid retry,
// payment failure, captured payment with completed fulfillment) are each
// covered by the function(s) that decide that specific outcome.
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  authorizeOrderAccess,
  buildFulfillmentCompletionPayload,
  buildPayOrderPayload,
  classifyCaller,
  extractPaymentId,
  findAuthorizedTender,
  isPayEligibleStatus,
  isPaymentCaptured,
  isTrustedServiceRoleCaller,
  SquareApiError,
  squareRequest,
  type SquareTender,
} from "./index.ts";

// ---------------------------------------------------------------------------
// 1. Caller classification / authorization — same shape as
//    pos-square-terminal-checkout, a fresh copy in this file.
// ---------------------------------------------------------------------------

Deno.test("classifyCaller: no Authorization header -> anonymous (the kiosk's own convention)", () => {
  assertEquals(classifyCaller(null, "service-role-key"), "anonymous");
});

Deno.test("classifyCaller: the exact service-role bearer token -> service_role", () => {
  assertEquals(classifyCaller("Bearer service-role-key", "service-role-key"), "service_role");
});

Deno.test("classifyCaller: any other bearer token -> authenticated", () => {
  assertEquals(classifyCaller("Bearer some-user-jwt", "service-role-key"), "authenticated");
});

Deno.test("isTrustedServiceRoleCaller: exact match only", () => {
  assert(isTrustedServiceRoleCaller("Bearer key", "key"));
  assert(!isTrustedServiceRoleCaller("Bearer wrong", "key"));
});

Deno.test("authorizeOrderAccess: cafe_admin of the SAME cafe is allowed, a different cafe is denied", () => {
  assert(authorizeOrderAccess({ role: "cafe_admin", cafeId: "cafe-1" }, "cafe-1").allowed);
  assert(!authorizeOrderAccess({ role: "cafe_admin", cafeId: "cafe-1" }, "cafe-2").allowed);
});

Deno.test("authorizeOrderAccess: a non-admin role is denied — authorization failure scenario", () => {
  const result = authorizeOrderAccess({ role: "customer", cafeId: "cafe-1" }, "cafe-1");
  assertEquals(result.allowed, false);
  assertEquals(result.reason, "Only cafe admins can complete POS payments.");
});

// ---------------------------------------------------------------------------
// 2. Status eligibility gate — POS failure / not-yet-payable scenarios
// ---------------------------------------------------------------------------

Deno.test("isPayEligibleStatus: sent_to_pos, payment_pending, payment_failed are eligible", () => {
  assert(isPayEligibleStatus("sent_to_pos"));
  assert(isPayEligibleStatus("payment_pending"));
  assert(isPayEligibleStatus("payment_failed"));
});

Deno.test("isPayEligibleStatus: confirmed/sending_to_pos/pos_failed/cancelled are not eligible (e.g. POS submission never succeeded)", () => {
  for (const status of ["confirmed", "sending_to_pos", "pos_failed", "cancelled", "draft"]) {
    assert(!isPayEligibleStatus(status), `expected ${status} to be ineligible`);
  }
});

Deno.test("isPayEligibleStatus: paid is intentionally NOT in the eligible set — the handler short-circuits it earlier, before this check", () => {
  assert(!isPayEligibleStatus("paid"));
});

// ---------------------------------------------------------------------------
// 3. findAuthorizedTender — "payment pending" (no tender yet) vs. found
// ---------------------------------------------------------------------------

Deno.test("findAuthorizedTender: no tenders at all -> null (payment pending — customer hasn't tapped their card yet)", () => {
  assertEquals(findAuthorizedTender([]), null);
});

Deno.test("findAuthorizedTender: a tender without AUTHORIZED status is not matched", () => {
  const tenders: SquareTender[] = [{ payment_id: "pay-1", card_details: { status: "PENDING" } }];
  assertEquals(findAuthorizedTender(tenders), null);
});

Deno.test("findAuthorizedTender: an AUTHORIZED tender with no payment_id is not matched", () => {
  const tenders: SquareTender[] = [{ card_details: { status: "AUTHORIZED" } }];
  assertEquals(findAuthorizedTender(tenders), null);
});

Deno.test("findAuthorizedTender: finds the AUTHORIZED tender with a payment_id — successful-payment precondition", () => {
  const tenders: SquareTender[] = [
    { payment_id: "pay-1", card_details: { status: "AUTHORIZED" } },
  ];
  const found = findAuthorizedTender(tenders);
  assertEquals(found?.payment_id, "pay-1");
});

// ---------------------------------------------------------------------------
// 4. extractPaymentId — already-COMPLETED-order reconciliation path
// ---------------------------------------------------------------------------

Deno.test("extractPaymentId: prefers a CAPTURED tender over any other", () => {
  const tenders: SquareTender[] = [
    { payment_id: "pay-old", card_details: { status: "AUTHORIZED" } },
    { payment_id: "pay-captured", card_details: { status: "CAPTURED" } },
  ];
  assertEquals(extractPaymentId(tenders), "pay-captured");
});

Deno.test("extractPaymentId: falls back to any tender with a payment_id when none is CAPTURED", () => {
  const tenders: SquareTender[] = [{ payment_id: "pay-1", card_details: { status: "AUTHORIZED" } }];
  assertEquals(extractPaymentId(tenders), "pay-1");
});

Deno.test("extractPaymentId: no tenders with a payment_id at all -> null (reconciliation still shouldn't throw)", () => {
  assertEquals(extractPaymentId([]), null);
  assertEquals(extractPaymentId([{ card_details: { status: "CAPTURED" } }]), null);
});

// ---------------------------------------------------------------------------
// 5. isPaymentCaptured — capture verification, never assumed from a 2xx
// ---------------------------------------------------------------------------

Deno.test("isPaymentCaptured: true only when the matching payment_id's tender is CAPTURED", () => {
  const tenders: SquareTender[] = [{ payment_id: "pay-1", card_details: { status: "CAPTURED" } }];
  assert(isPaymentCaptured(tenders, "pay-1"));
});

Deno.test("isPaymentCaptured: false when the tender exists but isn't CAPTURED — payment failure scenario", () => {
  const tenders: SquareTender[] = [{ payment_id: "pay-1", card_details: { status: "AUTHORIZED" } }];
  assert(!isPaymentCaptured(tenders, "pay-1"));
});

Deno.test("isPaymentCaptured: false when no tender matches the payment id at all", () => {
  const tenders: SquareTender[] = [{ payment_id: "pay-other", card_details: { status: "CAPTURED" } }];
  assert(!isPaymentCaptured(tenders, "pay-1"));
});

// ---------------------------------------------------------------------------
// 6. Payload building — idempotency keys derived from the canonical order
// ---------------------------------------------------------------------------

Deno.test("buildPayOrderPayload: forwards the deterministic idempotency key, order version, and payment id", () => {
  const payload = buildPayOrderPayload({
    idempotencyKey: "order-idem-1-pay",
    orderVersion: 3,
    paymentId: "pay-1",
  });
  assertEquals(payload, {
    idempotency_key: "order-idem-1-pay",
    order_version: 3,
    payment_ids: ["pay-1"],
  });
});

Deno.test("buildFulfillmentCompletionPayload: marks every given fulfillment uid COMPLETED", () => {
  const payload = buildFulfillmentCompletionPayload({
    orderVersion: 4,
    fulfillmentUids: ["ff-1", "ff-2"],
    idempotencyKey: "order-idem-1-fulfillment",
  });
  assertEquals(payload, {
    order: {
      version: 4,
      fulfillments: [
        { uid: "ff-1", state: "COMPLETED" },
        { uid: "ff-2", state: "COMPLETED" },
      ],
    },
    idempotency_key: "order-idem-1-fulfillment",
  });
});

// ---------------------------------------------------------------------------
// 7. squareRequest (fetch-injected) — the shared Square API caller used for
//    GET order / PayOrder / UpdateOrder.
// ---------------------------------------------------------------------------

Deno.test("squareRequest: returns the parsed JSON body on a 2xx response", async () => {
  const fetchImpl = () =>
    Promise.resolve(new Response(JSON.stringify({ order: { id: "sq-1", state: "COMPLETED" } }), { status: 200 }));

  const result = await squareRequest({
    accessToken: "token",
    baseUrl: "https://example.test",
    squareVersion: "2024-10-17",
    path: "/v2/orders/sq-1",
    method: "GET",
    fetchImpl: fetchImpl as unknown as typeof fetch,
  });

  assertEquals(result.order.state, "COMPLETED");
});

Deno.test("squareRequest: a non-2xx response throws SquareApiError with status + bounded detail — POS/payment failure scenario", async () => {
  const fetchImpl = () =>
    Promise.resolve(new Response(JSON.stringify({ errors: [{ code: "CARD_DECLINED" }] }), { status: 402 }));

  const err = await assertRejects(
    () =>
      squareRequest({
        accessToken: "token",
        baseUrl: "https://example.test",
        squareVersion: "2024-10-17",
        path: "/v2/orders/sq-1/pay",
        method: "POST",
        body: {},
        fetchImpl: fetchImpl as unknown as typeof fetch,
      }),
    SquareApiError,
  );
  assertEquals((err as SquareApiError).status, 402);
});

Deno.test("squareRequest: never leaks the access token into the thrown error", async () => {
  const fetchImpl = () => Promise.resolve(new Response(JSON.stringify({ errors: ["boom"] }), { status: 500 }));

  try {
    await squareRequest({
      accessToken: "super-secret-token",
      baseUrl: "https://example.test",
      squareVersion: "2024-10-17",
      path: "/v2/orders/sq-1",
      method: "GET",
      fetchImpl: fetchImpl as unknown as typeof fetch,
    });
    throw new Error("expected squareRequest to throw");
  } catch (err) {
    assert(!(err as Error).message.includes("super-secret-token"));
    assert(!(err instanceof SquareApiError && err.detail.includes("super-secret-token")));
  }
});
