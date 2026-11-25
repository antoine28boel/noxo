import 'package:flutter_test/flutter_test.dart';
import 'package:nox/assistant/chat.dart';

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
}
