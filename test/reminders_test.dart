import 'package:flutter_test/flutter_test.dart';
import 'package:noxo/assistant/reminder_service.dart';
import 'package:noxo/assistant/reminders.dart';

class FakeBackend implements ReminderBackend {
  bool online = true;
  final items = <Reminder>[];
  final calls = <String>[];
  var _ids = 0;

  void _check() {
    if (!online) throw Exception('offline');
  }

  @override
  Future<List<Reminder>> fetch() async {
    _check();
    return [...items]..sort((a, b) => a.due.compareTo(b.due));
  }

  @override
  Future<void> add(String summary, DateTime due, Repeat? repeat) async {
    _check();
    calls.add('add $summary ${haDateTime(due)} ${repeat?.name}');
    items.add(Reminder(uid: 'u${_ids++}', summary: summary, due: due, repeat: repeat));
  }

  @override
  Future<void> complete(String uid) async {
    _check();
    calls.add('complete $uid');
    items.removeWhere((r) => r.uid == uid);
  }

  @override
  Future<void> move(String uid, DateTime due) async {
    _check();
    calls.add('move $uid ${haDateTime(due)}');
    final i = items.indexWhere((r) => r.uid == uid);
    items[i] = items[i].withDue(due);
  }
}

void main() {
  final now = DateTime(2026, 11, 25, 14, 0);

  test('reads the reminders of a to-do list', () {
    final json = {
      'service_response': {
        'todo.rappels': {
          'items': [
            {'uid': 'a', 'summary': 'Garage', 'status': 'needs_action', 'due': '2026-11-26T10:00:00+01:00'},
            {'uid': 'b', 'summary': 'Pain', 'status': 'needs_action'},
            {'uid': 'c', 'summary': 'Fini', 'status': 'completed', 'due': '2026-11-20'},
            {
              'uid': 'd',
              'summary': 'Poubelles',
              'status': 'needs_action',
              'due': '2026-11-25',
              'description': 'Répéter : chaque semaine',
            },
          ],
        },
      },
    };
    final reminders = parseReminders(json, 'todo.rappels');
    expect([for (final r in reminders) r.summary], ['Poubelles', 'Garage']);
    expect(reminders.first.due, DateTime(2026, 11, 25, 9));
    expect(reminders.first.repeat, Repeat.weekly);
    expect(reminders.last.due, DateTime.utc(2026, 11, 26, 9).toLocal());
  });

  test('next occurrence of a repeated reminder', () {
    expect(nextDue(DateTime(2026, 11, 24, 8), Repeat.daily, now), DateTime(2026, 11, 26, 8));
    expect(nextDue(DateTime(2026, 11, 25, 8), Repeat.weekly, now), DateTime(2026, 12, 2, 8));
    expect(nextDue(DateTime(2026, 1, 31, 8), Repeat.monthly, DateTime(2026, 2, 1)), DateTime(2026, 2, 28, 8));
  });

  test('understands what the user types', () {
    expect(parseFrenchWhen('demain 9h', now), DateTime(2026, 11, 26, 9));
    expect(parseFrenchWhen('16:30', now), DateTime(2026, 11, 25, 16, 30));
    expect(parseFrenchWhen('10h', now), DateTime(2026, 11, 26, 10));
    expect(parseFrenchWhen('3/12 à 8h15', now), DateTime(2026, 12, 3, 8, 15));
    expect(parseFrenchWhen('dans 20 min', now), DateTime(2026, 11, 25, 14, 20));
    expect(parseFrenchWhen('dans 2 h', now), DateTime(2026, 11, 25, 16));
    expect(parseFrenchWhen('plus tard', now), isNull);
    expect(parseWhen('2026-11-26 10:00'), DateTime(2026, 11, 26, 10));
  });

  test('phones first among notification services', () {
    final services = parseNotifyServices([
      {'domain': 'light', 'services': {'turn_on': {}}},
      {
        'domain': 'notify',
        'services': {'send_message': {}, 'notify': {}, 'mobile_app_pixel': {}, 'persistent_notification': {}},
      },
    ]);
    expect(services, ['notify.mobile_app_pixel', 'notify.notify']);
  });

  group('ReminderService', () {
    late Map<String, String> prefs;
    late FakeBackend backend;
    late List<String> rung;
    late DateTime clock;

    ReminderService make() => ReminderService(
      read: (k) => prefs[k],
      write: (k, v) => prefs[k] = v,
      backend: () => backend,
      onRing: (r) => rung.add(r.summary),
      clock: () => clock,
    );

    setUp(() {
      prefs = {};
      backend = FakeBackend();
      rung = [];
      clock = now;
    });

    test('rings once on time, even offline, from its copy', () async {
      backend.items.add(Reminder(uid: 'a', summary: 'Garage', due: DateTime(2026, 11, 25, 14, 5)));
      await make().refresh();
      backend.online = false;
      final service = make(); // Restarted offline: reads its copy.
      service.tick();
      expect(rung, isEmpty);
      clock = DateTime(2026, 11, 25, 14, 5);
      service.tick();
      service.tick();
      expect(rung, ['Garage']);
      expect(service.ringing.single.summary, 'Garage');
    });

    test('done offline is sent later; a repeated one comes back', () async {
      backend.items.add(
        Reminder(uid: 'a', summary: 'Poubelles', due: DateTime(2026, 11, 25, 9), repeat: Repeat.weekly),
      );
      final service = make();
      await service.refresh();
      service.tick();
      backend.online = false;
      service.done(service.ringing.single);
      await Future<void>.delayed(Duration.zero);
      expect(service.pending, 2);
      expect(service.upcoming.single.due, DateTime(2026, 12, 2, 9));
      backend.online = true;
      await service.refresh();
      expect(backend.calls, ['complete a', 'add Poubelles 2026-12-02 09:00:00 weekly']);
      expect(service.pending, 0);
      expect(service.upcoming.single.uid, isNot('a'));
    });

    test('snooze moves it 10 minutes later and it rings again', () async {
      backend.items.add(Reminder(uid: 'a', summary: 'Four', due: DateTime(2026, 11, 25, 13, 59)));
      final service = make();
      await service.refresh();
      service.tick();
      service.snooze(service.ringing.single, const Duration(minutes: 10));
      await Future<void>.delayed(Duration.zero);
      expect(backend.calls, ['move a 2026-11-25 14:10:00']);
      clock = DateTime(2026, 11, 25, 14, 10);
      service.tick();
      expect(rung, ['Four', 'Four']);
    });
  });
}
