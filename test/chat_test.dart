import 'package:flutter_test/flutter_test.dart';
import 'package:noxo/assistant/chat.dart';

void main() {
  group('parseConversationReply', () {
    test('reads the speech and the conversation id', () {
      final reply = parseConversationReply({
        'response': {
          'response_type': 'action_done',
          'speech': {
            'plain': {'speech': 'Lumière du salon allumée'}
          },
        },
        'conversation_id': 'abc',
      });
      expect(reply!.text, 'Lumière du salon allumée');
      expect(reply.conversationId, 'abc');
      expect(reply.failed, isFalse);
    });

    test('flags an error answer', () {
      final reply = parseConversationReply({
        'response': {
          'response_type': 'error',
          'speech': {
            'plain': {'speech': "Désolé, je n'ai pas compris"}
          },
        },
      });
      expect(reply!.failed, isTrue);
      expect(reply.conversationId, isNull);
    });

    test('gives a text when the agent says nothing', () {
      expect(parseConversationReply({'response': {'response_type': 'action_done'}})!.text,
          "C'est fait.");
    });

    test('rejects something else', () {
      expect(parseConversationReply('oops'), isNull);
      expect(parseConversationReply({'message': 'x'}), isNull);
    });
  });

  test('parseConversationAgents lists the AIs, without Assist', () {
    final agents = parseConversationAgents([
      {'entity_id': 'light.salon', 'attributes': {'friendly_name': 'Salon'}},
      {'entity_id': 'conversation.home_assistant', 'attributes': {'friendly_name': 'Home Assistant'}},
      {'entity_id': 'conversation.ollama', 'attributes': {'friendly_name': 'Ollama'}},
      {'entity_id': 'conversation.claude', 'attributes': {'friendly_name': 'Claude'}},
      {'entity_id': 'conversation.sans_nom', 'attributes': {}},
    ]);
    expect([for (final a in agents) a.id],
        ['conversation.claude', 'conversation.sans_nom', 'conversation.ollama']);
    expect(agents.first.name, 'Claude');
    expect(parseConversationAgents({'oops': 1}), isEmpty);
  });

  test('preferredPipelineAgent gives the voice assistant\'s AI', () {
    Map<String, Object?> list(String engine) => {
      'preferred_pipeline': 'b',
      'pipelines': [
        {'id': 'a', 'conversation_engine': 'conversation.other'},
        {'id': 'b', 'conversation_engine': engine},
      ],
    };
    expect(preferredPipelineAgent(list('conversation.google_ai')), 'conversation.google_ai');
    expect(preferredPipelineAgent(list('conversation.home_assistant')), isNull);
    expect(preferredPipelineAgent(list('homeassistant')), isNull);
    expect(preferredPipelineAgent(null), isNull);
  });
}
