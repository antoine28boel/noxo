import 'package:flutter_test/flutter_test.dart';
import 'package:noxo/assistant/chat.dart';
import 'package:noxo/assistant/ollama.dart';

void main() {
  test('the conversation sent to Ollama leaves error notes out', () {
    final messages = ollamaMessages(const [
      ChatMessage(text: 'Bonjour', fromUser: true),
      ChatMessage(text: 'Injoignable', fromUser: false, error: true),
      ChatMessage(text: 'Salut !', fromUser: false),
    ], DateTime(2026, 11, 25, 9, 5));
    expect(messages.first['role'], 'system');
    expect(messages.first['content'], contains('mercredi 25/11/2026'));
    expect(messages.first['content'], contains('09:05'));
    expect(messages.skip(1).toList(), [
      {'role': 'user', 'content': 'Bonjour'},
      {'role': 'assistant', 'content': 'Salut !'},
    ]);
  });

  test('reads the chat answer', () {
    expect(parseOllamaChat({'message': {'role': 'assistant', 'content': ' Oui. '}}), 'Oui.');
    expect(parseOllamaChat({'message': {'content': ''}}), isNull);
    expect(parseOllamaChat('x'), isNull);
  });

  test('finds installed models', () {
    final names = parseOllamaTags({
      'models': [
        {'name': 'qwen2.5:7b'},
        {'name': 'llama3.1:latest'},
      ],
    });
    expect(hasOllamaModel(names, 'qwen2.5:7b'), isTrue);
    expect(hasOllamaModel(names, 'llama3.1'), isTrue);
    expect(hasOllamaModel(names, 'qwen2.5:3b'), isFalse);
    expect(parseOllamaTags({'oops': 1}), isEmpty);
  });

  test('reads the pull progress', () {
    expect(parsePullProgress({'status': 'pulling manifest'}), isNull);
    expect(parsePullProgress({'status': 'pulling', 'total': 200, 'completed': 50}), 0.25);
    expect(() => parsePullProgress({'error': 'file does not exist'}), throwsA(isA<OllamaException>()));
  });
}
