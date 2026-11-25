import 'package:flutter_test/flutter_test.dart';
import 'package:noxo/assistant/home_tools.dart';

void main() {
  final states = [
    {'entity_id': 'light.salon', 'state': 'off', 'attributes': {'friendly_name': 'Lumière du salon'}},
    {'entity_id': 'cover.volet_salon', 'state': 'open', 'attributes': {'friendly_name': 'Volet salon'}},
    {
      'entity_id': 'sensor.temp_salon',
      'state': '19.5',
      'attributes': {'friendly_name': 'Température salon', 'unit_of_measurement': '°C'},
    },
    {'entity_id': 'lock.porte', 'state': 'locked', 'attributes': {'friendly_name': "Porte d'entrée"}},
    {'entity_id': 'automation.nuit', 'state': 'on', 'attributes': {'friendly_name': 'Salon nuit'}},
  ];

  test('search ignores accents and case, and skips automations', () {
    final found = searchEntities(states, 'lumiere SALON');
    expect(found, contains('light.salon | Lumière du salon | off'));
    expect(found, isNot(contains('volet')));
    expect(searchEntities(states, 'salon'), contains('sensor.temp_salon | Température salon | 19.5 °C'));
    expect(searchEntities(states, 'salon'), isNot(contains('automation.nuit')));
    expect(searchEntities(states, 'garage'), startsWith('Aucun appareil'));
  });

  test('details of one entity', () {
    expect(entityDetails(states, 'light.salon'), contains('"etat":"off"'));
    expect(entityDetails(states, 'light.cuisine'), startsWith('Appareil light.cuisine introuvable'));
  });

  test('actions become service calls', () {
    var call = commandFor('light.salon', 'allumer', null) as ServiceCall;
    expect([call.domain, call.service, call.data], ['light', 'turn_on', {'entity_id': 'light.salon'}]);
    call = commandFor('light.salon', 'luminosite', 140) as ServiceCall;
    expect(call.data['brightness_pct'], 100);
    call = commandFor('cover.volet_salon', 'fermer', null) as ServiceCall;
    expect(call.service, 'close_cover');
    call = commandFor('climate.salon', 'temperature', 20.5) as ServiceCall;
    expect([call.service, call.data['temperature']], ['set_temperature', 20.5]);
  });

  test('locks, alarms and unknown things are refused', () {
    expect(commandFor('lock.porte', 'ouvrir', null), startsWith('Action sensible refusée'));
    expect(commandFor('alarm_control_panel.maison', 'eteindre', null), isA<String>());
    expect(commandFor('sensor.temp_salon', 'allumer', null), isA<String>());
    expect(commandFor('light.salon', 'danser', null), 'Action inconnue : danser.');
  });

  test('reads tool calls, arguments as map or JSON text', () {
    final a = parseToolCall({
      'function': {'name': 'etat_appareil', 'arguments': {'identifiant': 'light.salon'}},
    })!;
    expect([a.name, a.arguments['identifiant']], ['etat_appareil', 'light.salon']);
    final b = parseToolCall({
      'function': {'name': 'chercher_appareils', 'arguments': '{"texte":"salon"}'},
    })!;
    expect(b.arguments['texte'], 'salon');
    expect(parseToolCall({'oops': 1}), isNull);
  });
}
