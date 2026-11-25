import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'ha_client.dart';
import 'reminders.dart';

/// Where the reminders live (Home Assistant), seen by [ReminderService].
abstract class ReminderBackend {
  Future<List<Reminder>> fetch();
  Future<void> add(String summary, DateTime due, Repeat? repeat);
  Future<void> complete(String uid);
  Future<void> move(String uid, DateTime due);
}

class HaReminderBackend implements ReminderBackend {
  const HaReminderBackend(this.client, this.list);

  final HaClient client;
  final String list;

  @override
  Future<List<Reminder>> fetch() => client.fetchReminders(list);

  @override
  Future<void> add(String summary, DateTime due, Repeat? repeat) =>
      client.addReminder(list, summary, due, repeat);

  @override
  Future<void> complete(String uid) => client.completeReminder(list, uid);

  @override
  Future<void> move(String uid, DateTime due) => client.moveReminder(list, uid, due);
}

/// Keeps the reminders (copy of Home Assistant's list, for offline), rings
/// them on time, and sends changes made offline once Home Assistant is back.
class ReminderService extends ChangeNotifier {
  ReminderService({
    required this.read,
    required this.write,
    required this.backend,
    required this.onRing,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    _all = _decodeList(read(_cacheKey)) ?? [];
    final rung = read(_rungKey);
    if (rung != null && rung.isNotEmpty) _rung.addAll(rung.split('\n'));
    final ops = read(_opsKey);
    if (ops != null) {
      try {
        _ops.addAll([for (final o in jsonDecode(ops) as List) (o as Map).cast<String, Object?>()]);
      } catch (_) {
        // Lost: nothing to resend.
      }
    }
  }

  static const _cacheKey = 'reminders_cache';
  static const _rungKey = 'reminders_rung';
  static const _opsKey = 'reminders_ops';

  final String? Function(String key) read;
  final void Function(String key, String value) write;

  /// Null while Home Assistant or the reminder list is not set.
  final ReminderBackend? Function() backend;

  /// A reminder is due: the owl brings it, Windows and the phone show it.
  final void Function(Reminder reminder) onRing;
  final DateTime Function() _clock;

  List<Reminder> _all = [];
  final _rung = <String>{};
  final _ops = <Map<String, Object?>>[];
  final ringing = <Reminder>[];
  var _localIds = 0;

  /// Reminders to come, soonest first.
  List<Reminder> get upcoming {
    final now = _clock();
    return [for (final r in _all) if (r.due.isAfter(now)) r];
  }

  /// Changes made offline, not yet in Home Assistant.
  int get pending => _ops.length;

  static List<Reminder>? _decodeList(String? text) {
    if (text == null) return null;
    try {
      return [
        for (final r in jsonDecode(text) as List) ?Reminder.fromJson(r),
      ];
    } catch (_) {
      return null;
    }
  }

  void _save() {
    write(_cacheKey, jsonEncode([for (final r in _all) r.toJson()]));
    write(_rungKey, _rung.join('\n'));
    write(_opsKey, jsonEncode(_ops));
  }

  /// Sends the waiting changes, then reads the list again.
  Future<void> refresh() async {
    final b = backend();
    if (b == null || _refreshing) return;
    _refreshing = true;
    try {
      while (_ops.isNotEmpty) {
        await _apply(b, _ops.first);
        _ops.removeAt(0);
        _save();
      }
      final fresh = await b.fetch();
      // A reminder rung here but already put off on the phone rings again.
      _all = fresh;
      _rung.removeWhere((key) => !_all.any((r) => r.key == key));
      ringing.removeWhere((r) => !_all.any((a) => a.uid == r.uid));
      _save();
      notifyListeners();
    } catch (_) {
      // Offline: the copy and the queue wait.
    } finally {
      _refreshing = false;
    }
  }

  bool _refreshing = false;

  Future<void> _apply(ReminderBackend b, Map<String, Object?> op) async {
    final due = DateTime.tryParse('${op['due']}');
    switch (op['op']) {
      case 'add':
        await b.add(
          op['summary'] as String,
          due!,
          Repeat.values.where((r) => r.name == op['repeat']).firstOrNull,
        );
      case 'complete':
        await b.complete(op['uid'] as String);
      case 'move':
        await b.move(op['uid'] as String, due!);
    }
  }

  /// Queues [op] and tries to send it at once.
  void _queue(Map<String, Object?> op) {
    _ops.add(op);
    _save();
    notifyListeners();
    unawaited(refresh());
  }

  /// Every 30 s: rings what is due.
  void tick() {
    final now = _clock();
    final due = dueReminders(_all, now, _rung);
    if (due.isEmpty) return;
    for (final r in due) {
      _rung.add(r.key);
      ringing.add(r);
      onRing(r);
    }
    _save();
    notifyListeners();
  }

  void add(String summary, DateTime due, Repeat? repeat) {
    final local = Reminder(uid: 'local-${_localIds++}', summary: summary, due: due, repeat: repeat);
    _all = [..._all, local]..sort((a, b) => a.due.compareTo(b.due));
    _queue({'op': 'add', 'summary': summary, 'due': due.toIso8601String(), 'repeat': repeat?.name});
  }

  /// Done: off the list; a repeated reminder comes back at its next time.
  void done(Reminder r) {
    ringing.removeWhere((x) => x.uid == r.uid);
    _all = [for (final x in _all) if (x.uid != r.uid) x];
    if (r.uid.startsWith('local-')) {
      _ops.removeWhere((o) => o['op'] == 'add' && o['summary'] == r.summary);
    } else {
      _ops.add({'op': 'complete', 'uid': r.uid});
    }
    final repeat = r.repeat;
    if (repeat != null) {
      add(r.summary, nextDue(r.due, repeat, _clock()), repeat);
    } else {
      _save();
      notifyListeners();
      unawaited(refresh());
    }
  }

  /// "Dans 10 min".
  void snooze(Reminder r, Duration delay) {
    ringing.removeWhere((x) => x.uid == r.uid);
    final moved = r.withDue(_clock().add(delay));
    _all = [for (final x in _all) x.uid == r.uid ? moved : x];
    if (r.uid.startsWith('local-')) {
      for (final o in _ops) {
        if (o['op'] == 'add' && o['summary'] == r.summary) o['due'] = moved.due.toIso8601String();
      }
      _save();
      notifyListeners();
    } else {
      _queue({'op': 'move', 'uid': r.uid, 'due': moved.due.toIso8601String()});
    }
  }
}
