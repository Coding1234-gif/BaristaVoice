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

  /// IDs of menu items this reply is actually about (recommended, described,
  /// answered a question about, or just added/changed) — never more than 4,
  /// already filtered server-side to ids that exist on this café's menu.
  /// Empty for a reply that isn't about any specific item(s). Drives the
  /// item cards shown below the conversation panel — see MentionedItemsStrip.
  final List<String> mentionedItemIds;

  /// True when the server produced no real answer for this turn (the AI
  /// provider was throttling or failed) and [reply] is just an apology. The
  /// exchange is then not a conversation turn: it must not enter the history
  /// sent with the next request, and [order] must not be adopted.
  final bool retryable;

  const AgentTurnResult({
    required this.reply,
    required this.order,
    this.needsClarification = false,
    this.mentionedItemIds = const [],
    this.retryable = false,
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
