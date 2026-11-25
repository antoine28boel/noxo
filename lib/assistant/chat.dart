/// One line of the conversation with Noxo.
class ChatMessage {
  const ChatMessage({required this.text, required this.fromUser, this.error = false});

  final String text;

  /// Typed by the user (otherwise Noxo's answer).
  final bool fromUser;

  /// Noxo could not get an answer (Home Assistant unreachable…).
  final bool error;
}

/// Home Assistant's answer to a sentence.
class ConversationReply {
  const ConversationReply({required this.text, this.conversationId, this.failed = false});

  final String text;

  /// Lets the next sentence continue the same conversation.
  final String? conversationId;

  /// The agent did not understand or could not do it.
  final bool failed;
}

/// Reads the answer of `/api/conversation/process`.
ConversationReply? parseConversationReply(Object? json) {
  if (json is! Map) return null;
  final response = json['response'];
  if (response is! Map) return null;
  final speech = response['speech'];
  final plain = speech is Map ? speech['plain'] : null;
  final said = plain is Map ? plain['speech'] : null;
  final text = said is String ? said.trim() : '';
  final id = json['conversation_id'];
  final failed = response['response_type'] == 'error';
  return ConversationReply(
    text: text.isEmpty ? (failed ? "Je n'ai pas compris." : 'C\'est fait.') : text,
    conversationId: id is String && id.isNotEmpty ? id : null,
    failed: failed,
  );
}
