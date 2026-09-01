import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const SQUARE_ENVIRONMENT =
  (Deno.env.get("SQUARE_ENVIRONMENT") ?? "sandbox") as
    | "sandbox"
    | "production";

const SQUARE_VERSION =
  Deno.env.get("SQUARE_VERSION") ?? "2026-08-19";

const SQUARE_BASE_URL =
  SQUARE_ENVIRONMENT === "production"
    ? "https://connect.squareup.com"
    : "https://connect.squareupsandbox.com";

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
    },
  });
}

function isTrustedServiceRoleCaller(
  authHeader: string,
  serviceRoleKey: string | undefined,
): boolean {
  if (!serviceRoleKey) return false;
  return authHeader === `Bearer ${serviceRoleKey}`;
}

function authorizeOrderAccess(
  profile: { role: string; cafeId: string | null },
  orderCafeId: string,
): { allowed: boolean; reason?: string } {
  if (profile.role === "super_admin") {
    return { allowed: true };
  }

  if (profile.role === "cafe_admin") {
    if (profile.cafeId === orderCafeId) {
      return { allowed: true };
    }

    return {
      allowed: false,
      reason: "You do not have access to this order.",
    };
  }

  return {
    allowed: false,
    reason: "Only cafe admins can complete POS payments.",
  };
}

async function squareRequest(
  accessToken: string,
  path: string,
  method: string,
  body?: unknown,
) {
  const response = await fetch(`${SQUARE_BASE_URL}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Square-Version": SQUARE_VERSION,
      "Content-Type": "application/json",
    },
    ...(body !== undefined
      ? { body: JSON.stringify(body) }
      : {}),
  });

  const result = await response.json().catch(() => ({}));

  if (!response.ok) {
    throw new Error(
      `Square API failed (${response.status}): ${JSON.stringify(
        result?.errors ?? result,
      ).slice(0, 1000)}`,
    );
  }

  return result;
}

export async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse(
      { error: "Only POST requests are supported." },
      405,
    );
  }

  const authHeader = req.headers.get("Authorization");

  if (!authHeader) {
    return jsonResponse(
      { error: "Missing Authorization header." },
      401,
    );
  }

  try {
    const body = await req.json();
    const orderId = body?.orderId;

    if (!orderId || typeof orderId !== "string") {
      return jsonResponse(
        { error: "orderId is required." },
        400,
      );
    }

    const adminClient = createClient(
      SUPABASE_URL,
      SUPABASE_SERVICE_ROLE_KEY,
    );

    const trustedCaller = isTrustedServiceRoleCaller(
      authHeader,
      SUPABASE_SERVICE_ROLE_KEY,
    );

    // ---------------------------------------------------------------
    // Authorization
    // ---------------------------------------------------------------

    let callerProfile:
      | { role: string; cafeId: string | null }
      | null = null;

    if (!trustedCaller) {
      const callerClient = createClient(
        SUPABASE_URL,
        SUPABASE_ANON_KEY,
        {
          global: {
            headers: {
              Authorization: authHeader,
            },
          },
        },
      );

      const { data: userData, error: userError } =
        await callerClient.auth.getUser();

      if (userError || !userData.user) {
        return jsonResponse(
          { error: "Invalid or expired session." },
          401,
        );
      }

      const { data: profile } = await adminClient
        .from("profiles")
        .select("role, cafe_id")
        .eq("id", userData.user.id)
        .maybeSingle();

      if (
        !profile ||
        (profile.role !== "cafe_admin" &&
          profile.role !== "super_admin")
      ) {
        return jsonResponse(
          {
            error:
              "Only cafe admins can complete POS payments.",
          },
          403,
        );
      }

      callerProfile = {
        role: profile.role as string,
        cafeId: profile.cafe_id as string | null,
      };
    }

    // ---------------------------------------------------------------
    // Load canonical BaristaVoice order
    // ---------------------------------------------------------------

    const { data: order, error: orderError } =
      await adminClient
        .from("orders")
        .select(
          "id, cafe_id, status, currency, external_order_id, external_payment_id, pos_provider, pos_connection_id, idempotency_key",
        )
        .eq("id", orderId)
        .maybeSingle();

    if (orderError || !order) {
      return jsonResponse(
        { error: "Order not found." },
        404,
      );
    }

    // ---------------------------------------------------------------
    // Authorization against actual cafe
    // ---------------------------------------------------------------

    if (callerProfile) {
      const authz = authorizeOrderAccess(
        callerProfile,
        order.cafe_id as string,
      );

      if (!authz.allowed) {
        return jsonResponse(
          { error: authz.reason },
          403,
        );
      }
    }

    // ---------------------------------------------------------------
    // Local idempotency
    //
    // If BaristaVoice already knows the payment is complete, do not
    // touch Square again.
    // ---------------------------------------------------------------

    if (order.status === "paid") {
      return jsonResponse({
        orderId,
        squareOrderId: order.external_order_id,
        paymentId: order.external_payment_id,
        paymentStatus: "COMPLETED",
        orderStatus: "COMPLETED",
        alreadyPaid: true,
      });
    }

    // ---------------------------------------------------------------
    // Verify Square order association
    // ---------------------------------------------------------------

    if (order.pos_provider !== "square") {
      return jsonResponse(
        {
          error:
            "This order is not associated with Square.",
        },
        409,
      );
    }

    if (!order.external_order_id) {
      return jsonResponse(
        {
          error:
            "This order has no Square external_order_id.",
        },
        409,
      );
    }

    if (!order.pos_connection_id) {
      return jsonResponse(
        {
          error:
            "This order has no Square connection.",
        },
        409,
      );
    }

    // ---------------------------------------------------------------
    // Resolve Square connection
    // ---------------------------------------------------------------

    const { data: connection } = await adminClient
      .from("pos_connections")
      .select(
        "id, location_id, status, access_token_secret_id, token_expires_at",
      )
      .eq("id", order.pos_connection_id)
      .maybeSingle();

    if (!connection || connection.status !== "active") {
      return jsonResponse(
        {
          error:
            "The linked Square connection is not active.",
        },
        400,
      );
    }

    if (!connection.access_token_secret_id) {
      return jsonResponse(
        {
          error:
            "The linked Square connection has no stored access token.",
        },
        400,
      );
    }

    if (
      connection.token_expires_at &&
      new Date(connection.token_expires_at as string) <=
        new Date()
    ) {
      return jsonResponse(
        {
          error:
            "Square access token expired — reconnect required.",
        },
        401,
      );
    }

    // ---------------------------------------------------------------
    // Resolve Square access token from Vault
    // ---------------------------------------------------------------

    const { data: accessToken, error: secretError } =
      await adminClient.rpc("get_vault_secret", {
        secret_id: connection.access_token_secret_id,
      });

    if (secretError || !accessToken) {
      console.error(
        "Vault secret resolution failed:",
        {
          message: secretError?.message,
          code: secretError?.code,
        },
      );

      return jsonResponse(
        {
          error:
            "Could not resolve the stored Square access token.",
        },
        500,
      );
    }

    const squareOrderId =
      order.external_order_id as string;

    // ---------------------------------------------------------------
    // Retrieve current Square order
    // ---------------------------------------------------------------

    const squareOrderResult = await squareRequest(
      accessToken,
      `/v2/orders/${squareOrderId}`,
      "GET",
    );

    let currentOrder = squareOrderResult?.order;

    if (!currentOrder) {
      return jsonResponse(
        {
          error:
            "Square returned no order.",
        },
        502,
      );
    }

    // ---------------------------------------------------------------
    // Check whether Square already considers the order completed
    //
    // This handles retries where the previous PayOrder succeeded but
    // our response was lost before we updated Supabase.
    // ---------------------------------------------------------------

    if (currentOrder.state === "COMPLETED") {
      const completedTender = (currentOrder.tenders ?? []).find(
        (tender: any) =>
          tender?.payment_id &&
          (
            tender?.card_details?.status === "CAPTURED" ||
            tender?.payment_id === order.external_payment_id
          ),
      );

      const completedPaymentId =
        completedTender?.payment_id ??
        order.external_payment_id ??
        null;

      await adminClient
        .from("orders")
        .update({
          status: "paid",
          external_order_id: squareOrderId,
          external_payment_id: completedPaymentId,
          pos_provider: "square",
          last_pos_error: null,
        })
        .eq("id", orderId);

      return jsonResponse({
        orderId,
        squareOrderId,
        paymentId: completedPaymentId,
        paymentStatus: "COMPLETED",
        orderStatus: currentOrder.state,
        fulfillmentStatus:
          currentOrder.fulfillments?.[0]?.state ?? null,
        alreadyPaid: true,
      });
    }

    if (currentOrder.state !== "OPEN") {
      return jsonResponse(
        {
          error:
            `Square order is not payable (state: ${currentOrder.state}).`,
        },
        409,
      );
    }

    // ---------------------------------------------------------------
    // Find authorized Terminal payment
    // ---------------------------------------------------------------

    const tenders = currentOrder.tenders ?? [];

    const authorizedTender = tenders.find(
      (tender: any) =>
        tender?.card_details?.status === "AUTHORIZED" &&
        tender?.payment_id,
    );

    if (!authorizedTender) {
      return jsonResponse(
        {
          error:
            "No authorized Terminal payment was found for this Square order.",
        },
        409,
      );
    }

    const paymentId =
      authorizedTender.payment_id as string;

    // ---------------------------------------------------------------
    // Mark canonical order as payment_pending
    //
    // This happens immediately before asking Square to capture the
    // authorized payment.
    // ---------------------------------------------------------------

    await adminClient
      .from("orders")
      .update({
        status: "payment_pending",
        last_pos_error: null,
      })
      .eq("id", orderId)
      .in("status", ["sent_to_pos", "payment_pending"]);

    // ---------------------------------------------------------------
    // Capture / pay Square order
    // ---------------------------------------------------------------

    const payIdempotencyKey =
      `${order.idempotency_key}-pay`;

    let payResult: any;

    try {
      payResult = await squareRequest(
        accessToken,
        `/v2/orders/${squareOrderId}/pay`,
        "POST",
        {
          idempotency_key: payIdempotencyKey,
          order_version: currentOrder.version,
          payment_ids: [paymentId],
        },
      );
    } catch (err) {
      const message =
        err instanceof Error
          ? err.message
          : "Square payment failed.";

      await adminClient
        .from("orders")
        .update({
          status: "payment_failed",
          last_pos_error: message.slice(0, 500),
        })
        .eq("id", orderId);

      console.error(
        "Square PayOrder failed:",
        {
          orderId,
          squareOrderId,
          paymentId,
          error: message,
        },
      );

      return jsonResponse(
        {
          error: "Square payment failed.",
          detail: message,
        },
        502,
      );
    }

    const paidOrder = payResult?.order;

    if (!paidOrder) {
      const message =
        "Square PayOrder returned no order.";

      await adminClient
        .from("orders")
        .update({
          status: "payment_failed",
          last_pos_error: message,
        })
        .eq("id", orderId);

      return jsonResponse(
        { error: message },
        502,
      );
    }

    // ---------------------------------------------------------------
    // Verify the payment is actually captured
    // ---------------------------------------------------------------

    const paidTender = (paidOrder.tenders ?? []).find(
      (tender: any) =>
        tender?.payment_id === paymentId,
    );

    const paymentCaptured =
      paidTender?.card_details?.status === "CAPTURED" ||
      paidOrder?.net_amount_due_money?.amount === 0;

    if (!paymentCaptured) {
      const message =
        "Square accepted the payment request but the payment is not confirmed as captured.";

      await adminClient
        .from("orders")
        .update({
          status: "payment_failed",
          last_pos_error: message,
        })
        .eq("id", orderId);

      return jsonResponse(
        {
          error: message,
          paymentId,
          orderStatus: paidOrder.state,
        },
        502,
      );
    }

    // ---------------------------------------------------------------
    // Complete fulfillment if necessary
    //
    // If Square has already completed it, no update is necessary.
    // Otherwise update each existing fulfillment to COMPLETED.
    // ---------------------------------------------------------------

    let finalOrder = paidOrder;

    const fulfillments = paidOrder.fulfillments ?? [];

    const incompleteFulfillments = fulfillments.filter(
      (fulfillment: any) =>
        fulfillment?.state !== "COMPLETED" &&
        fulfillment?.state !== "CANCELED",
    );

    if (incompleteFulfillments.length > 0) {
      const updatedFulfillments = fulfillments.map(
        (fulfillment: any) => ({
          uid: fulfillment.uid,
          state:
            fulfillment.state === "CANCELED"
              ? "CANCELED"
              : "COMPLETED",
        }),
      );

      const updateIdempotencyKey =
        `${order.idempotency_key}-fulfillment`;

      try {
        const updatedOrderResult =
          await squareRequest(
            accessToken,
            `/v2/orders/${squareOrderId}`,
            "PUT",
            {
              order: {
                version: paidOrder.version,
                fulfillments: updatedFulfillments,
              },
              idempotency_key:
                updateIdempotencyKey,
            },
          );

        if (updatedOrderResult?.order) {
          finalOrder =
            updatedOrderResult.order;
        }
      } catch (err) {
        // Payment has already succeeded. We do NOT change the order
        // back to payment_failed because that would be incorrect.
        //
        // The payment is real; fulfillment can be retried separately.
        const message =
          err instanceof Error
            ? err.message
            : "Square fulfillment update failed.";

        console.error(
          "Square fulfillment update failed after successful payment:",
          {
            orderId,
            squareOrderId,
            paymentId,
            error: message,
          },
        );
      }
    }

    // ---------------------------------------------------------------
    // Final canonical order update
    // ---------------------------------------------------------------

    const finalFulfillmentStatus =
      finalOrder?.fulfillments?.[0]?.state ?? null;

    const { error: finalUpdateError } =
      await adminClient
        .from("orders")
        .update({
          status: "paid",
          external_order_id: squareOrderId,
          external_payment_id: paymentId,
          pos_provider: "square",
          last_pos_error: null,
        })
        .eq("id", orderId);

    if (finalUpdateError) {
      console.error(
        "Could not update canonical order after successful Square payment:",
        finalUpdateError,
      );

      // IMPORTANT:
      // Square has already captured the payment, so we deliberately
      // return success information rather than claiming the payment
      // failed.
      return jsonResponse(
        {
          orderId,
          squareOrderId,
          paymentId,
          paymentStatus: "COMPLETED",
          orderStatus:
            finalOrder?.state ?? null,
          fulfillmentStatus:
            finalFulfillmentStatus,
          warning:
            "Square payment completed, but the BaristaVoice order record could not be updated.",
        },
        200,
      );
    }

    return jsonResponse({
      orderId,
      squareOrderId,
      paymentId,
      paymentStatus: "COMPLETED",
      orderStatus:
        finalOrder?.state ?? null,
      fulfillmentStatus:
        finalFulfillmentStatus,
      alreadyPaid: false,
    });
  } catch (err) {
    console.error(
      "pos-square-order-pay error:",
      err,
    );

    return jsonResponse(
      {
        error:
          err instanceof Error
            ? err.message
            : "Could not complete Square order payment.",
      },
      500,
    );
  }
}

if (import.meta.main) {
  Deno.serve(handler);
}