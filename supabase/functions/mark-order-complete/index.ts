// Supabase Edge Function: mark-order-complete
//
// Sets orders.completed_at for the "Mark complete" action on the admin Live
// Orders dashboard. Writes to `orders` are revoked from `authenticated`
// clients (see supabase/schema.sql's WRITE SECURITY section) — every order
// mutation goes through a trusted Edge Function instead, same pattern as
// menu-extractor.
//
// Security: the caller's identity comes from verifying their JWT via
// supabase.auth.getUser(), never from a client-supplied user/cafe id. Once
// identified, the target order (and therefore its cafe_id) is looked up
// server-side with the service-role key, and the caller's own profile is
// checked against it — a cafe_admin can never complete another cafe's order,
// no matter what id they pass in.
import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

interface RequestBody {
  orderId: string;
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return jsonResponse({ error: "Missing Authorization header." }, 401);
  }

  try {
    const { orderId } = (await req.json()) as RequestBody;
    if (!orderId) return jsonResponse({ error: "orderId is required." }, 400);

    // Verify the caller's identity from their JWT (never trust a client-supplied user id).
    const callerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userError } = await callerClient.auth.getUser();
    if (userError || !userData.user) {
      return jsonResponse({ error: "Invalid or expired session." }, 401);
    }

    // Service-role client for the privileged lookup/write below. Every
    // authorization decision past this point is made in code from data we
    // just fetched ourselves — never from anything the client sent.
    const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    const { data: profile } = await adminClient
      .from("profiles")
      .select("role, cafe_id")
      .eq("id", userData.user.id)
      .maybeSingle();

    if (!profile || (profile.role !== "cafe_admin" && profile.role !== "super_admin")) {
      return jsonResponse({ error: "Only cafe admins can complete orders." }, 403);
    }

    const { data: order, error: orderError } = await adminClient
      .from("orders")
      .select("id, cafe_id, status, completed_at")
      .eq("id", orderId)
      .maybeSingle();

    if (orderError || !order) {
      return jsonResponse({ error: "Order not found." }, 404);
    }

    if (profile.role === "cafe_admin" && order.cafe_id !== profile.cafe_id) {
      return jsonResponse({ error: "You do not have access to this order." }, 403);
    }

    if (order.completed_at) {
      // Already complete — idempotent no-op rather than an error, so a
      // double-tap on a slow connection doesn't surface a scary message.
      return jsonResponse({ completedAt: order.completed_at });
    }

    if (order.status !== "paid") {
      return jsonResponse({ error: "Only paid orders can be marked complete." }, 409);
    }

    const completedAt = new Date().toISOString();
    const { error: updateError } = await adminClient
      .from("orders")
      .update({ completed_at: completedAt })
      .eq("id", orderId);

    if (updateError) throw new Error(`Could not mark order complete: ${updateError.message}`);

    return jsonResponse({ completedAt });
  } catch (err) {
    console.error("mark-order-complete error:", err);
    return jsonResponse({ error: err instanceof Error ? err.message : "Failed to mark order complete." }, 500);
  }
});
