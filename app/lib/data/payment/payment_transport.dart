import 'package:supabase_flutter/supabase_flutter.dart';

/// Raw result of calling a payment-related edge function, before
/// [PaymentService] turns it into a typed result or a
/// [PaymentServiceException] — same seam as
/// `OrderSubmissionTransportResult`/`OrderSubmissionTransport`.
class PaymentTransportResult {
  final int status;
  final Object? data;

  const PaymentTransportResult({required this.status, required this.data});
}

/// Unlike [OrderSubmissionTransport] (always `create-order`), this seam
/// calls two different edge functions (`pos-square-terminal-checkout` and
/// `pos-square-order-pay`) depending on where the payment flow currently
/// is, so the function name is a parameter rather than baked in.
abstract class PaymentTransport {
  Future<PaymentTransportResult> invoke(String functionName, Map<String, dynamic> body);
}

/// Calls a payment edge function the same way [SupabaseOrderSubmissionTransport]
/// calls `create-order`: no Authorization/JWT is sent (there is no customer
/// login in this app — security is enforced server-side via the order id
/// plus everything sensitive being resolved from the `orders` row, never
/// from the client; see both edge functions' own header comments).
class SupabasePaymentTransport implements PaymentTransport {
  final SupabaseClient _client;

  SupabasePaymentTransport(this._client);

  @override
  Future<PaymentTransportResult> invoke(String functionName, Map<String, dynamic> body) async {
    try {
      final response = await _client.functions.invoke(functionName, body: body);
      return PaymentTransportResult(status: response.status, data: response.data);
    } on FunctionException catch (e) {
      return PaymentTransportResult(status: e.status, data: e.details);
    }
  }
}
