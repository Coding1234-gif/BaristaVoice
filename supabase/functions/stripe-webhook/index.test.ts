// Tests for stripe-webhook's pure signature-verification logic. Run with:
//   deno test --allow-env supabase/functions/stripe-webhook/index.test.ts
//
// Does NOT exercise the Deno.serve handler itself (needs a live Supabase
// project + real Stripe-signed payloads) — covers the one thing that must
// never be wrong: a request without a valid, fresh Stripe signature is
// rejected, since this is the ONLY thing standing between a public
// endpoint and forged "invoice paid" events.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { timingSafeEqual, verifyStripeSignature } from "./index.ts";

const SECRET = "whsec_test_secret";

async function sign(payload: string, secret: string, timestamp: number): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sigBytes = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${timestamp}.${payload}`));
  return Array.from(new Uint8Array(sigBytes)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.test("verifyStripeSignature: accepts a correctly-signed, fresh payload", async () => {
  const payload = JSON.stringify({ id: "evt_1", type: "invoice.paid" });
  const now = Math.floor(Date.now() / 1000);
  const sig = await sign(payload, SECRET, now);
  const header = `t=${now},v1=${sig}`;

  assert(await verifyStripeSignature(payload, header, SECRET, now));
});

Deno.test("verifyStripeSignature: rejects a payload signed with the wrong secret — forged event", async () => {
  const payload = JSON.stringify({ id: "evt_1", type: "invoice.paid" });
  const now = Math.floor(Date.now() / 1000);
  const sig = await sign(payload, "whsec_wrong_secret", now);
  const header = `t=${now},v1=${sig}`;

  assertEquals(await verifyStripeSignature(payload, header, SECRET, now), false);
});

Deno.test("verifyStripeSignature: rejects a tampered payload (signature no longer matches)", async () => {
  const originalPayload = JSON.stringify({ id: "evt_1", type: "invoice.paid" });
  const now = Math.floor(Date.now() / 1000);
  const sig = await sign(originalPayload, SECRET, now);
  const header = `t=${now},v1=${sig}`;

  const tamperedPayload = JSON.stringify({ id: "evt_1", type: "invoice.paid", amount: 999999 });

  assertEquals(await verifyStripeSignature(tamperedPayload, header, SECRET, now), false);
});

Deno.test("verifyStripeSignature: rejects a replayed old signature outside the tolerance window", async () => {
  const payload = JSON.stringify({ id: "evt_1", type: "invoice.paid" });
  const now = Math.floor(Date.now() / 1000);
  const oldTimestamp = now - 60 * 60; // 1 hour old
  const sig = await sign(payload, SECRET, oldTimestamp);
  const header = `t=${oldTimestamp},v1=${sig}`;

  assertEquals(await verifyStripeSignature(payload, header, SECRET, now), false);
});

Deno.test("verifyStripeSignature: rejects a missing signature header", async () => {
  assertEquals(await verifyStripeSignature("{}", null, SECRET), false);
});

Deno.test("verifyStripeSignature: rejects a malformed header with no v1", async () => {
  const now = Math.floor(Date.now() / 1000);
  assertEquals(await verifyStripeSignature("{}", `t=${now}`, SECRET, now), false);
});

Deno.test("timingSafeEqual: equal strings match", () => {
  assert(timingSafeEqual("abc123", "abc123"));
});

Deno.test("timingSafeEqual: different-length strings never match", () => {
  assertEquals(timingSafeEqual("abc", "abcd"), false);
});

Deno.test("timingSafeEqual: same-length but different strings don't match", () => {
  assertEquals(timingSafeEqual("abc123", "abc124"), false);
});
