import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noxo/assistant/ha_client.dart';
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

  test('the PC AI searches then commands the house', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serviceCalls = <String>[];
    var round = 0;
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      Object? answer;
      switch (request.uri.path) {
        case '/api/chat':
          final tools = (jsonDecode(body) as Map)['tools'];
          expect(tools, isNotNull);
          round++;
          answer = {
            'message': switch (round) {
              1 => {
                'role': 'assistant',
                'content': '',
                'tool_calls': [
                  {'function': {'name': 'chercher_appareils', 'arguments': {'texte': 'salon'}}},
                ],
              },
              2 => {
                'role': 'assistant',
                'content': '',
                'tool_calls': [
                  {
                    'function': {
                      'name': 'commander_appareil',
                      'arguments': {'identifiant': 'light.salon', 'action': 'allumer'},
                    },
                  },
                ],
              },
              _ => {'role': 'assistant', 'content': 'La lumière du salon est allumée.'},
            },
          };
        case '/api/states':
          answer = [
            {'entity_id': 'light.salon', 'state': 'off', 'attributes': {'friendly_name': 'Salon'}},
          ];
        default:
          serviceCalls.add('${request.uri.path} $body');
          answer = [];
      }
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(answer));
      await request.response.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    final text = await OllamaClient(base).chat(
      'qwen2.5:7b',
      ollamaMessages(const [ChatMessage(text: 'Allume le salon', fromUser: true)], DateTime(2026),
          home: true),
      home: HaClient(base, 'jeton'),
    );
    await server.close(force: true);
    expect(text, 'La lumière du salon est allumée.');
    expect(serviceCalls, ['/api/services/light/turn_on {"entity_id":"light.salon"}']);
  });
}
