import '../../models/menu.dart';
import '../../models/order.dart';
import 'conversation_turn.dart';

/// Result of one conversational turn. [order] is always the FULL, up to
/// date order state — never a diff — so the client can render it directly
/// as the new source of truth.
class AgentTurnResult {
  final String reply;
  final Order order;
  final bool needsClarification;

  const AgentTurnResult({
    required this.reply,
    required this.order,
    this.needsClarification = false,
  });
}

/// Translates natural language into structured order state. Implementations
/// must never invent menu items, options or prices that aren't present in
/// the [CafeMenu] passed in — grounding against the menu is the whole point.
/// [cafeId] identifies which café's products the AI is even allowed to
/// consider; the app never decides recommendations for a café other than
/// the one currently selected.
abstract class OrderAgentService {
  Future<AgentTurnResult> interpret({
    required String cafeId,
    required String transcript,
    required Order currentOrder,
    required CafeMenu menu,
    required List<ConversationTurn> history,
  });
}
