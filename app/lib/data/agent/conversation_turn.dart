enum SpeakerRole { customer, assistant }

class ConversationTurn {
  final SpeakerRole role;
  final String text;

  const ConversationTurn({required this.role, required this.text});

  Map<String, dynamic> toJson() => {'role': role.name, 'text': text};
}
