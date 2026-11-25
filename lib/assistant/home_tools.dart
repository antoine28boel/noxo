import 'dart:convert';

/// The house commands the PC's AI can use, described to Ollama. Noxo runs
/// them through Home Assistant's API.
const homeToolDefinitions = [
  {
    'type': 'function',
    'function': {
      'name': 'chercher_appareils',
      'description':
          "Cherche des appareils de la maison par nom ou par pièce (ex. 'salon', "
          "'lumière cuisine', 'volet'). Renvoie leur identifiant et leur état. "
          'Toujours chercher avant de commander un appareil.',
      'parameters': {
        'type': 'object',
        'properties': {
          'texte': {'type': 'string', 'description': 'Mots à chercher'},
        },
        'required': ['texte'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'etat_appareil',
      'description': "Donne l'état détaillé d'un appareil (température, luminosité…).",
      'parameters': {
        'type': 'object',
        'properties': {
          'identifiant': {'type': 'string', 'description': 'ex. light.salon'},
        },
        'required': ['identifiant'],
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'commander_appareil',
      'description': 'Commande un appareil de la maison.',
      'parameters': {
        'type': 'object',
        'properties': {
          'identifiant': {'type': 'string', 'description': 'ex. light.salon'},
          'action': {
            'type': 'string',
            'enum': [
              'allumer',
              'eteindre',
              'basculer',
              'ouvrir',
              'fermer',
              'activer',
              'luminosite',
              'temperature',
              'position',
            ],
          },
          'valeur': {
            'type': 'number',
            'description': 'Luminosité ou position en %, température en °C',
          },
        },
        'required': ['identifiant', 'action'],
      },
    },
  },
];

/// Domains the AI may command. Locks and alarms are left out on purpose:
/// they stay in Home Assistant's hands.
const _commandable = {
  'light',
  'switch',
  'fan',
  'cover',
  'climate',
  'media_player',
  'scene',
  'script',
  'input_boolean',
  'humidifier',
  'vacuum',
};

/// Domains worth finding (commandable ones plus what can be read).
const _searchable = {
  ..._commandable,
  'sensor',
  'binary_sensor',
  'lock',
  'alarm_control_panel',
  'weather',
  'person',
};

/// Lowercase, without accents, so "lumiere" finds "Lumière".
String _plain(String text) {
  const from = 'àâäáãéèêëíìîïóòôöõúùûüçñ';
  const to = 'aaaaaeeeeiiiiooooouuuucn';
  final lower = text.toLowerCase();
  final out = StringBuffer();
  for (final rune in lower.runes) {
    final c = String.fromCharCode(rune);
    final i = from.indexOf(c);
    out.write(i < 0 ? c : to[i]);
  }
  return out.toString();
}

String _name(Map state) {
  final attributes = state['attributes'];
  final name = attributes is Map ? attributes['friendly_name'] : null;
  return name is String && name.isNotEmpty ? name : state['entity_id'] as String;
}

String _summary(Map state) {
  final attributes = state['attributes'];
  final unit = attributes is Map ? attributes['unit_of_measurement'] : null;
  final value = unit is String ? '${state['state']} $unit' : '${state['state']}';
  return '${state['entity_id']} | ${_name(state)} | $value';
}

/// Entities whose name or id contains every word of [query] (up to 15).
String searchEntities(Object? states, String query) {
  if (states is! List) return 'Home Assistant ne donne pas la liste des appareils.';
  final words = _plain(query).split(RegExp(r'\s+')).where((w) => w.length > 1).toList();
  final found = <String>[];
  for (final state in states) {
    if (state is! Map || state['entity_id'] is! String) continue;
    final id = state['entity_id'] as String;
    if (!_searchable.contains(id.split('.').first)) continue;
    final haystack = _plain('$id ${_name(state)}');
    if (words.every(haystack.contains)) found.add(_summary(state));
    if (found.length == 15) break;
  }
  if (found.isEmpty) return 'Aucun appareil trouvé pour « $query ».';
  return 'identifiant | nom | état\n${found.join('\n')}';
}

/// The state of [id] with its attributes, as text.
String entityDetails(Object? states, String id) {
  if (states is List) {
    for (final state in states) {
      if (state is Map && state['entity_id'] == id) {
        return jsonEncode({
          'etat': state['state'],
          'attributs': state['attributes'],
        });
      }
    }
  }
  return "Appareil $id introuvable : utilise chercher_appareils d'abord.";
}

/// A Home Assistant service call.
class ServiceCall {
  const ServiceCall(this.domain, this.service, this.data);
  final String domain;
  final String service;
  final Map<String, Object?> data;
}

/// What [action] on [id] means for Home Assistant, or a refusal (String).
Object commandFor(String id, String action, num? value) {
  final domain = id.split('.').first;
  if (!id.contains('.') || !_commandable.contains(domain)) {
    return domain == 'lock' || domain == 'alarm_control_panel'
        ? 'Action sensible refusée : les serrures et alarmes se commandent depuis Home Assistant.'
        : "Cet appareil ($id) ne se commande pas.";
  }
  final target = <String, Object?>{'entity_id': id};
  ServiceCall call(String service, [Map<String, Object?> extra = const {}]) =>
      ServiceCall(domain, service, {...target, ...extra});
  switch (action) {
    case 'allumer':
      if (domain == 'scene' || domain == 'script') return call('turn_on');
      if (domain == 'cover') return call('open_cover');
      if (domain == 'vacuum') return call('start');
      return call('turn_on');
    case 'eteindre':
      if (domain == 'cover') return call('close_cover');
      if (domain == 'vacuum') return call('return_to_base');
      return call('turn_off');
    case 'basculer':
      return call('toggle');
    case 'ouvrir':
      return domain == 'cover' ? call('open_cover') : call('turn_on');
    case 'fermer':
      return domain == 'cover' ? call('close_cover') : call('turn_off');
    case 'activer':
      return call('turn_on');
    case 'luminosite':
      if (domain != 'light' || value == null) return 'Il faut une lumière et une valeur en %.';
      return call('turn_on', {'brightness_pct': value.clamp(0, 100).round()});
    case 'temperature':
      if (domain != 'climate' || value == null) return 'Il faut un thermostat et une valeur en °C.';
      return call('set_temperature', {'temperature': value});
    case 'position':
      if (domain != 'cover' || value == null) return 'Il faut un volet et une valeur en %.';
      return call('set_cover_position', {'position': value.clamp(0, 100).round()});
  }
  return 'Action inconnue : $action.';
}

/// Reads a tool call of Ollama: its name and arguments.
({String name, Map<String, Object?> arguments})? parseToolCall(Object? json) {
  if (json is! Map) return null;
  final function = json['function'];
  if (function is! Map || function['name'] is! String) return null;
  var arguments = function['arguments'];
  if (arguments is String) {
    try {
      arguments = jsonDecode(arguments);
    } on FormatException {
      arguments = null;
    }
  }
  return (
    name: function['name'] as String,
    arguments: arguments is Map ? arguments.cast<String, Object?>() : const <String, Object?>{},
  );
}
