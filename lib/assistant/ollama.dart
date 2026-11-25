import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'chat.dart';

/// Model Noxo installs for the offline AI, unless another one is chosen.
const kDefaultOllamaModel = 'qwen2.5:7b';

const _installerUrl = 'https://ollama.com/download/OllamaSetup.exe';

/// What Noxo tells the offline AI about himself.
String ollamaSystemPrompt(DateTime now) {
  const days = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];
  final hh = now.hour.toString().padLeft(2, '0');
  final mm = now.minute.toString().padLeft(2, '0');
  final date = '${days[now.weekday - 1]} ${now.day}/${now.month}/${now.year}';
  return 'Tu es Noxo, un petit hibou qui vit sur le bureau de ton humain et '
      "l'aide au quotidien. Réponds en français, en tutoyant, brièvement et "
      'simplement. Nous sommes le $date, il est $hh:$mm. Home Assistant est '
      "injoignable : tu ne peux pas commander la maison ; si on te le demande, "
      'dis-le sans inventer.';
}

/// The conversation as Ollama expects it: the system prompt, then the
/// exchanged lines (Noxo's error notes left out).
List<Map<String, String>> ollamaMessages(List<ChatMessage> history, DateTime now) => [
  {'role': 'system', 'content': ollamaSystemPrompt(now)},
  for (final m in history)
    if (!m.error) {'role': m.fromUser ? 'user' : 'assistant', 'content': m.text},
];

/// Reads the answer of `/api/chat` (not streamed).
String? parseOllamaChat(Object? json) {
  if (json is! Map) return null;
  final message = json['message'];
  final content = message is Map ? message['content'] : null;
  if (content is! String) return null;
  final text = content.trim();
  return text.isEmpty ? null : text;
}

/// Whether [model] is among the installed [names] (`qwen2.5` is `qwen2.5:latest`).
bool hasOllamaModel(List<String> names, String model) =>
    names.contains(model) || (!model.contains(':') && names.contains('$model:latest'));

/// The installed model names in `/api/tags`.
List<String> parseOllamaTags(Object? json) {
  if (json is! Map || json['models'] is! List) return const [];
  return [
    for (final m in json['models'] as List)
      if (m is Map && m['name'] is String) m['name'] as String,
  ];
}

/// One line of `/api/pull`'s progress: the fraction downloaded, or null
/// while it is not known. Throws on an error line.
double? parsePullProgress(Object? json) {
  if (json is! Map) return null;
  if (json['error'] is String) throw OllamaException(json['error'] as String);
  final total = json['total'];
  final completed = json['completed'];
  if (total is! num || completed is! num || total <= 0) return null;
  return (completed / total).clamp(0.0, 1.0).toDouble();
}

class OllamaException implements Exception {
  const OllamaException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Talks to Ollama running on this PC.
class OllamaClient {
  const OllamaClient([this.base = 'http://127.0.0.1:11434']);

  final String base;

  Future<HttpClientResponse> _send(
    HttpClient client,
    String method,
    String path, {
    Object? body,
  }) async {
    final request = await client.openUrl(method, Uri.parse('$base$path'));
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body)));
    }
    final response = await request.close();
    if (response.statusCode != 200) {
      final text = await response.transform(utf8.decoder).join();
      String message = 'Ollama a répondu ${response.statusCode}.';
      try {
        final json = jsonDecode(text);
        if (json is Map && json['error'] is String) message = json['error'] as String;
      } on FormatException {
        // Keeps the status code.
      }
      throw OllamaException(message);
    }
    return response;
  }

  Future<Object?> _json(String method, String path, {Object? body, required Duration timeout}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final response = await _send(client, method, path, body: body).timeout(timeout);
      return jsonDecode(await response.transform(utf8.decoder).join().timeout(timeout));
    } finally {
      client.close(force: true);
    }
  }

  /// Whether Ollama answers.
  Future<bool> running() async {
    try {
      await _json('GET', '/api/version', timeout: const Duration(seconds: 3));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<String>> models() async =>
      parseOllamaTags(await _json('GET', '/api/tags', timeout: const Duration(seconds: 10)));

  /// Downloads [model]; [onProgress] gets the fraction done when known.
  Future<void> pull(String model, void Function(double? progress) onProgress) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final response = await _send(client, 'POST', '/api/pull', body: {'model': model, 'stream': true});
      await for (final line
          in response.transform(utf8.decoder).transform(const LineSplitter())) {
        if (line.trim().isEmpty) continue;
        onProgress(parsePullProgress(jsonDecode(line)));
      }
    } finally {
      client.close(force: true);
    }
  }

  /// Noxo's answer to the conversation so far.
  Future<String> chat(String model, List<Map<String, String>> messages) async {
    final json = await _json(
      'POST',
      '/api/chat',
      body: {'model': model, 'messages': messages, 'stream': false},
      // A first answer on a laptop without GPU loads the model: slow.
      timeout: const Duration(minutes: 3),
    );
    final text = parseOllamaChat(json);
    if (text == null) throw const OllamaException("Réponse vide de l'IA du PC.");
    return text;
  }
}

/// Puts Ollama and its model on this PC, the first time Noxo starts and
/// again later if it was cut short (offline…). Its [status] is shown in
/// the settings.
class OllamaSetup extends ChangeNotifier {
  OllamaSetup({this.client = const OllamaClient()});

  final OllamaClient client;

  String status = '';
  bool busy = false;

  /// Ollama runs and the model is there: the chat can fall back on it.
  bool ready = false;

  void _say(String text) {
    status = text;
    notifyListeners();
  }

  static String? get _localAppData => Platform.environment['LOCALAPPDATA'];

  static String? get _ollamaDir {
    final base = _localAppData;
    return base == null ? null : '$base\\Programs\\Ollama';
  }

  /// Starts Ollama if it is installed but not running. True once it answers.
  Future<bool> start() async {
    if (await client.running()) return true;
    final dir = _ollamaDir;
    if (!Platform.isWindows || dir == null) return false;
    final app = File('$dir\\ollama app.exe');
    final cli = File('$dir\\ollama.exe');
    if (app.existsSync()) {
      await Process.start(app.path, const [], mode: ProcessStartMode.detached);
    } else if (cli.existsSync()) {
      await Process.start(cli.path, const ['serve'], mode: ProcessStartMode.detached);
    } else {
      return false;
    }
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (await client.running()) return true;
    }
    return false;
  }

  /// Installs what is missing. Never throws: the error ends up in [status].
  Future<void> ensure(String model) async {
    if (busy) return;
    busy = true;
    ready = false;
    try {
      if (!await start()) {
        if (!Platform.isWindows) {
          _say('Installation automatique prévue pour Windows seulement.');
          return;
        }
        await _install();
        if (!await start()) {
          _say("Ollama est installé mais ne démarre pas.");
          return;
        }
      }
      if (!hasOllamaModel(await client.models(), model)) {
        _say('Téléchargement du modèle $model…');
        var shown = -1;
        await client.pull(model, (progress) {
          if (progress == null) return;
          final percent = (progress * 100).floor();
          if (percent == shown) return;
          shown = percent;
          _say('Téléchargement du modèle $model : $percent %');
        });
      }
      ready = true;
      _say('Prête : $model, sur ce PC.');
    } catch (e) {
      _say('Installation interrompue ($e). Nouvel essai plus tard.');
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _install() async {
    final base = _localAppData;
    if (base == null) throw const OllamaException('dossier LOCALAPPDATA introuvable');
    final dir = Directory('$base\\Noxo\\ollama')..createSync(recursive: true);
    final setup = File('${dir.path}\\OllamaSetup.exe');
    _say("Téléchargement d'Ollama…");
    final http = HttpClient()..userAgent = 'noxo';
    try {
      final request = await http.getUrl(Uri.parse(_installerUrl));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw OllamaException('téléchargement refusé (${response.statusCode})');
      }
      final total = response.contentLength;
      var received = 0;
      var shown = -1;
      final sink = setup.openWrite();
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) {
            final percent = received * 100 ~/ total;
            if (percent != shown) {
              shown = percent;
              _say("Téléchargement d'Ollama : $percent %");
            }
          }
        }
      } finally {
        await sink.close();
      }
    } finally {
      http.close(force: true);
    }
    _say("Installation d'Ollama…");
    // Per-user install, no admin rights needed, nothing to click.
    final result = await Process.run(
      setup.path,
      const ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-'],
    );
    try {
      setup.deleteSync();
    } on FileSystemException {
      // Left for the next cleanup.
    }
    if (result.exitCode != 0) {
      throw OllamaException("l'installateur d'Ollama a échoué (${result.exitCode})");
    }
  }
}
