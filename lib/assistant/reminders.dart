/// Reminders: items with a due date-time in a Home Assistant to-do list
/// ("Rappels"), so they are shared with the phone. Noxo keeps a copy to ring
/// them even offline.
enum Repeat { daily, weekly, monthly }

const _repeatWords = {
  Repeat.daily: 'chaque jour',
  Repeat.weekly: 'chaque semaine',
  Repeat.monthly: 'chaque mois',
};

/// How the repetition is written in the item's description, readable on
/// the phone too: "Répéter : chaque semaine".
String repeatDescription(Repeat repeat) => 'Répéter : ${_repeatWords[repeat]}';

Repeat? parseRepeat(String? text) {
  if (text == null) return null;
  final lower = text.toLowerCase();
  if (!lower.contains('répéter')) return null;
  for (final e in _repeatWords.entries) {
    if (lower.contains(e.value)) return e.key;
  }
  return null;
}

/// "jour" / "semaine" / "mois" as said by the AI, or null.
Repeat? repeatFromWord(String? word) => switch (word?.toLowerCase().trim()) {
  'jour' || 'quotidien' || 'chaque jour' => Repeat.daily,
  'semaine' || 'hebdomadaire' || 'chaque semaine' => Repeat.weekly,
  'mois' || 'mensuel' || 'chaque mois' => Repeat.monthly,
  _ => null,
};

class Reminder {
  const Reminder({required this.uid, required this.summary, required this.due, this.repeat});

  final String uid;
  final String summary;

  /// Local time.
  final DateTime due;
  final Repeat? repeat;

  /// One occurrence: changes when the reminder is put off or repeated.
  String get key => '$uid@${due.toIso8601String()}';

  Reminder withDue(DateTime when) => Reminder(uid: uid, summary: summary, due: when, repeat: repeat);

  Map<String, Object?> toJson() => {
    'uid': uid,
    'summary': summary,
    'due': due.toIso8601String(),
    'repeat': repeat?.name,
  };

  static Reminder? fromJson(Object? json) {
    if (json is! Map) return null;
    final uid = json['uid'];
    final summary = json['summary'];
    final due = DateTime.tryParse('${json['due']}');
    if (uid is! String || summary is! String || due == null) return null;
    return Reminder(
      uid: uid,
      summary: summary,
      due: due,
      repeat: Repeat.values.where((r) => r.name == json['repeat']).firstOrNull,
    );
  }
}

/// A due date from Home Assistant, in local time. A date alone rings at 9 am.
DateTime? parseDue(Object? due) {
  if (due is! String || due.isEmpty) return null;
  final parsed = DateTime.tryParse(due);
  if (parsed == null) return null;
  if (due.length <= 10) return DateTime(parsed.year, parsed.month, parsed.day, 9);
  return parsed.isUtc ? parsed.toLocal() : parsed;
}

/// Reads `todo.get_items` for [list]: the items still to do that have a due
/// date, soonest first.
List<Reminder> parseReminders(Object? json, String list) {
  if (json is! Map) return const [];
  final response = json['service_response'] ?? json;
  if (response is! Map) return const [];
  final entry = response[list];
  final items = entry is Map ? entry['items'] : null;
  if (items is! List) return const [];
  final reminders = <Reminder>[];
  for (final item in items) {
    if (item is! Map || item['status'] == 'completed') continue;
    final uid = item['uid'];
    final summary = item['summary'];
    final due = parseDue(item['due']);
    if (uid is! String || summary is! String || due == null) continue;
    final description = item['description'];
    reminders.add(Reminder(
      uid: uid,
      summary: summary,
      due: due,
      repeat: parseRepeat(description is String ? description : null),
    ));
  }
  reminders.sort((a, b) => a.due.compareTo(b.due));
  return reminders;
}

/// The next occurrence after [due] that is after [now].
DateTime nextDue(DateTime due, Repeat repeat, DateTime now) {
  var next = due;
  do {
    next = switch (repeat) {
      Repeat.daily => DateTime(next.year, next.month, next.day + 1, next.hour, next.minute),
      Repeat.weekly => DateTime(next.year, next.month, next.day + 7, next.hour, next.minute),
      // Day clamped: the 31st falls on the last day of shorter months.
      Repeat.monthly => () {
        final last = DateTime(next.year, next.month + 2, 0).day;
        final day = due.day > last ? last : due.day;
        return DateTime(next.year, next.month + 1, day, next.hour, next.minute);
      }(),
    };
  } while (!next.isAfter(now));
  return next;
}

/// Reminders that must ring now and have not rung yet.
List<Reminder> dueReminders(List<Reminder> all, DateTime now, Set<String> rung) => [
  for (final r in all)
    if (!r.due.isAfter(now) && !rung.contains(r.key)) r,
];

/// "2026-11-26 10:00:00", the format of `todo.add_item`'s `due_datetime`.
String haDateTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:00';
}

/// "jeu. 26/11 10:00", for lists.
String shortWhen(DateTime t, DateTime now) {
  const days = ['lun.', 'mar.', 'mer.', 'jeu.', 'ven.', 'sam.', 'dim.'];
  String two(int n) => n.toString().padLeft(2, '0');
  final time = '${two(t.hour)}:${two(t.minute)}';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = day.difference(today).inDays;
  if (diff == 0) return "aujourd'hui $time";
  if (diff == 1) return 'demain $time';
  return '${days[t.weekday - 1]} ${two(t.day)}/${two(t.month)} $time';
}

/// The phone notification services in `/api/services` (`notify.mobile_app_…`
/// first), as "notify.xxx".
List<String> parseNotifyServices(Object? json) {
  if (json is! List) return const [];
  for (final domain in json) {
    if (domain is! Map || domain['domain'] != 'notify') continue;
    final services = domain['services'];
    if (services is! Map) return const [];
    final names = [
      for (final name in services.keys)
        if (name is String && name != 'send_message' && name != 'persistent_notification')
          'notify.$name',
    ];
    names.sort((a, b) {
      final ma = a.startsWith('notify.mobile_app_') ? 0 : 1;
      final mb = b.startsWith('notify.mobile_app_') ? 0 : 1;
      return ma != mb ? ma - mb : a.compareTo(b);
    });
    return names;
  }
  return const [];
}

/// Reads "2026-11-26 10:00" (or with seconds, or ISO) as local time.
DateTime? parseWhen(String text) {
  final t = text.trim().replaceFirst(' ', 'T');
  final parsed = DateTime.tryParse(t);
  if (parsed == null) return null;
  return parsed.isUtc ? parsed.toLocal() : parsed;
}

/// The reminder tool given to the PC's AI.
const reminderToolDefinition = {
  'type': 'function',
  'function': {
    'name': 'creer_rappel',
    'description':
        "Crée un rappel qui sonnera sur le PC et le téléphone. Calcule la date "
        "et l'heure à partir de la date du jour.",
    'parameters': {
      'type': 'object',
      'properties': {
        'texte': {'type': 'string', 'description': 'Ce dont il faut se souvenir'},
        'quand': {'type': 'string', 'description': 'Date et heure, format AAAA-MM-JJ HH:MM'},
        'repetition': {
          'type': 'string',
          'enum': ['aucune', 'jour', 'semaine', 'mois'],
        },
      },
      'required': ['texte', 'quand'],
    },
  },
};

/// What the user types in "Quand ?": "10:00", "demain 9h", "26/11 14:30",
/// "dans 20 min", "dans 2 h". A time already past today means tomorrow.
DateTime? parseFrenchWhen(String text, DateTime now) {
  final t = text.trim().toLowerCase();
  final inMatch = RegExp(r'^dans\s+(\d+)\s*(min|minutes?|h|heures?)$').firstMatch(t);
  if (inMatch != null) {
    final n = int.parse(inMatch.group(1)!);
    final minutes = inMatch.group(2)!.startsWith('m') ? n : n * 60;
    return now.add(Duration(minutes: minutes));
  }
  final m = RegExp(
    r'^(?:(aujourd.hui|demain|apr[eè]s-demain)|(\d{1,2})/(\d{1,2})(?:/(\d{4}))?)?\s*(?:à\s*)?(\d{1,2})\s*(?:h|:)\s*(\d{2})?$',
  ).firstMatch(t);
  if (m == null) return null;
  final hour = int.parse(m.group(5)!);
  final minute = int.tryParse(m.group(6) ?? '') ?? 0;
  if (hour > 23 || minute > 59) return null;
  final word = m.group(1);
  if (m.group(2) != null) {
    final day = int.parse(m.group(2)!);
    final month = int.parse(m.group(3)!);
    var year = int.tryParse(m.group(4) ?? '') ?? now.year;
    var when = DateTime(year, month, day, hour, minute);
    if (m.group(4) == null && when.isBefore(now)) when = DateTime(++year, month, day, hour, minute);
    if (when.month != month) return null;
    return when;
  }
  final shift = switch (word) {
    'demain' => 1,
    final w? when w.startsWith('apr') => 2,
    _ => 0,
  };
  var when = DateTime(now.year, now.month, now.day + shift, hour, minute);
  if (word == null && !when.isAfter(now)) when = when.add(const Duration(days: 1));
  return when;
}
