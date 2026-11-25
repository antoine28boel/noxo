/// One line of the conversation with Noxo.
class ChatMessage {
  const ChatMessage({
    required this.text,
    required this.fromUser,
    this.error = false,
    this.source,
  });

  final String text;

  /// Typed by the user (otherwise Noxo's answer).
  final bool fromUser;

  /// Noxo could not get an answer (Home Assistant unreachable…).
  final bool error;

  /// Who answered, when it is worth saying (the PC's AI, offline).
  final String? source;
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

/// A conversation agent of Home Assistant (an AI or its built-in Assist).
class ConversationAgent {
  const ConversationAgent({required this.id, required this.name});

  /// Entity id, e.g. `conversation.ollama`.
  final String id;
  final String name;
}

/// The conversation agents found in `/api/states`, by name. Home
/// Assistant's built-in agent is left out: it is the default choice.
List<ConversationAgent> parseConversationAgents(Object? json) {
  if (json is! List) return const [];
  final agents = <ConversationAgent>[];
  for (final state in json) {
    if (state is! Map) continue;
    final id = state['entity_id'];
    if (id is! String || !id.startsWith('conversation.')) continue;
    if (id == 'conversation.home_assistant') continue;
    final attributes = state['attributes'];
    final name = attributes is Map ? attributes['friendly_name'] : null;
    agents.add(ConversationAgent(id: id, name: name is String && name.isNotEmpty ? name : id));
  }
  agents.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return agents;
}

/// The conversation agent of Home Assistant's preferred voice assistant
/// (Paramètres → Assistants vocaux), from `assist_pipeline/pipeline/list`.
/// Null when it is the built-in Assist or unknown.
String? preferredPipelineAgent(Object? json) {
  if (json is! Map || json['pipelines'] is! List) return null;
  final preferred = json['preferred_pipeline'];
  for (final pipeline in json['pipelines'] as List) {
    if (pipeline is! Map || pipeline['id'] != preferred) continue;
    final engine = pipeline['conversation_engine'];
    if (engine is! String || engine.isEmpty) return null;
    if (engine == 'homeassistant' || engine == 'conversation.home_assistant') return null;
    return engine;
  }
  return null;
}
