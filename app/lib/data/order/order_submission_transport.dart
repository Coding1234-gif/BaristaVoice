import 'package:supabase_flutter/supabase_flutter.dart';

/// Raw result of calling the `create-order` edge function, before
/// [OrderSubmissionService] turns it into a typed result or an
/// [OrderSubmissionException]. Kept as its own seam (same pattern as
/// `TtsTransport`/`TtsTransportResult`) so the service can be unit tested
/// with a hand-rolled fake instead of a real [SupabaseClient].
class OrderSubmissionTransportResult {
  final int status;
  final Object? data;

  const OrderSubmissionTransportResult({required this.status, required this.data});
}

abstract class OrderSubmissionTransport {
  Future<OrderSubmissionTransportResult> invoke(Map<String, dynamic> body);
}

/// Calls the `create-order` Supabase Edge Function the same way
/// [SupabaseTtsTransport] calls `tts-speak` — no Authorization/JWT is
/// required (this is a customer-facing endpoint, not an admin one; there is
/// no customer login in this app), and every privileged operation (writing
/// `orders`, computing prices, submitting to Square) happens entirely
/// server-side. The client only ever sends the customer's selections —
/// never a price, never a POS id.
class SupabaseOrderSubmissionTransport implements OrderSubmissionTransport {
  final SupabaseClient _client;

  SupabaseOrderSubmissionTransport(this._client);

  @override
  Future<OrderSubmissionTransportResult> invoke(Map<String, dynamic> body) async {
    try {
      final response = await _client.functions.invoke('create-order', body: body);
      return OrderSubmissionTransportResult(status: response.status, data: response.data);
    } on FunctionException catch (e) {
      return OrderSubmissionTransportResult(status: e.status, data: e.details);
    }
  }
}
