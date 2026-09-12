import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/menu.dart';
import '../../models/order.dart';
import 'conversation_turn.dart';
import 'order_agent_service.dart';

/// Calls the `order-agent` Supabase Edge Function, which holds the LLM API
/// key server-side and does the actual model call. The client never talks
/// to the LLM provider directly, and doesn't need to know which provider
/// (Gemini, Groq, ...) is currently active — that's a manual switch on the
/// server side via the LLM_PROVIDER/LLM_API_KEY secrets.
class LlmOrderAgentService implements OrderAgentService {
  final SupabaseClient _client;

  LlmOrderAgentService(this._client);

  @override
  Future<AgentTurnResult> interpret({
    required String cafeId,
    required String transcript,
    required Order currentOrder,
    required CafeMenu menu,
    required List<ConversationTurn> history,
  }) async {
    // No `menu` in the request: the function fetches this café's own
    // published+available products itself and never trusts a client-supplied
    // product list for what the AI can recommend or price.
    final response = await _client.functions.invoke(
      'order-agent',
      body: {
        'cafeId': cafeId,
        'transcript': transcript,
        'currentOrder': currentOrder.toJson(),
        'history': history.map((h) => h.toJson()).toList(),
      },
    );

    final data = response.data as Map<String, dynamic>;

    return AgentTurnResult(
      reply: data['reply'] as String,
      order: Order.fromJson(data['order'] as Map<String, dynamic>),
      needsClarification: data['needsClarification'] as bool? ?? false,
      mentionedItemIds: (data['mentionedItemIds'] as List<dynamic>? ?? [])
          .map((e) => e as String)
          .toList(),
    );
  }
}
