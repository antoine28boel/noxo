import 'package:flutter/material.dart';

import 'panel_style.dart';
import 'reminder_service.dart';
import 'reminders.dart';

/// Reminders ringing now, on top of the panel: "Fait" or "Dans 10 min".
class RingingBanner extends StatelessWidget {
  const RingingBanner({super.key, required this.service});

  final ReminderService service;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        if (service.ringing.isEmpty) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
          decoration: BoxDecoration(
            color: panelAccent.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              for (final r in service.ringing)
                Row(
                  children: [
                    const Icon(Icons.alarm_rounded, size: 18, color: panelAccent),
                    const SizedBox(width: 8),
                    Expanded(child: Text(r.summary, style: const TextStyle(fontWeight: FontWeight.w600))),
                    TextButton(onPressed: () => service.done(r), child: const Text('Fait')),
                    TextButton(
                      onPressed: () => service.snooze(r, const Duration(minutes: 10)),
                      child: const Text('10 min'),
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The coming reminders and a form to add one (top of the "Tâches" tab).
class RemindersSection extends StatefulWidget {
  const RemindersSection({super.key, required this.service, required this.configured});

  final ReminderService service;

  /// A reminder list is chosen in the settings.
  final bool configured;

  @override
  State<RemindersSection> createState() => _RemindersSectionState();
}

class _RemindersSectionState extends State<RemindersSection> {
  final _what = TextEditingController();
  final _when = TextEditingController();
  Repeat? _repeat;
  String? _error;

  @override
  void dispose() {
    _what.dispose();
    _when.dispose();
    super.dispose();
  }

  void _add() {
    final what = _what.text.trim();
    final when = parseFrenchWhen(_when.text, DateTime.now());
    if (what.isEmpty || when == null) {
      setState(() => _error = 'Quoi, et quand : « demain 9h », « 14:30 », « 26/11 10h », « dans 20 min ».');
      return;
    }
    widget.service.add(what, when, _repeat);
    _what.clear();
    _when.clear();
    setState(() {
      _error = null;
      _repeat = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.configured) {
      return const PanelSection(
        title: 'Rappels',
        children: [PanelNote('Choisis la liste des rappels dans Réglages → Rappels.')],
      );
    }
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        final now = DateTime.now();
        final upcoming = widget.service.upcoming.take(5).toList();
        final pending = widget.service.pending;
        return PanelSection(
          title: 'Rappels',
          children: [
            if (upcoming.isEmpty) const PanelNote('Aucun rappel à venir.'),
            for (final r in upcoming)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    SizedBox(
                      width: 118,
                      child: Text(shortWhen(r.due, now), style: const TextStyle(color: panelMuted)),
                    ),
                    Expanded(child: Text(r.summary)),
                    if (r.repeat != null) const Icon(Icons.repeat_rounded, size: 16, color: panelMuted),
                  ],
                ),
              ),
            if (pending > 0)
              PanelNote('$pending changement(s) en attente de Home Assistant.'),
            const SizedBox(height: 8),
            TextField(
              controller: _what,
              decoration: const InputDecoration(isDense: true, hintText: 'Nouveau rappel…'),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _when,
                    onSubmitted: (_) => _add(),
                    decoration: const InputDecoration(isDense: true, hintText: 'Quand ? demain 9h'),
                  ),
                ),
                const SizedBox(width: 8),
                DropdownButton<Repeat?>(
                  value: _repeat,
                  dropdownColor: panelCard,
                  items: const [
                    DropdownMenuItem(value: null, child: Text('Une fois')),
                    DropdownMenuItem(value: Repeat.daily, child: Text('Chaque jour')),
                    DropdownMenuItem(value: Repeat.weekly, child: Text('Chaque semaine')),
                    DropdownMenuItem(value: Repeat.monthly, child: Text('Chaque mois')),
                  ],
                  onChanged: (value) => setState(() => _repeat = value),
                ),
                IconButton(
                  onPressed: _add,
                  tooltip: 'Ajouter',
                  icon: const Icon(Icons.add_alarm_rounded, color: panelAccent),
                ),
              ],
            ),
            if (_error != null) PanelNote(_error!, error: true),
          ],
        );
      },
    );
  }
}

/// Settings: the to-do list holding the reminders and the phone to notify.
class RemindersForm extends StatefulWidget {
  const RemindersForm({
    super.key,
    required this.loadLists,
    required this.loadServices,
    required this.list,
    required this.service,
    required this.onSave,
  });

  final Future<Map<String, String>> Function() loadLists;
  final Future<List<String>> Function() loadServices;
  final String list;
  final String service;
  final void Function(String list, String service) onSave;

  @override
  State<RemindersForm> createState() => _RemindersFormState();
}

class _RemindersFormState extends State<RemindersForm> {
  late String _list = widget.list;
  late String _service = widget.service;
  Map<String, String>? _lists;
  List<String>? _services;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final lists = await widget.loadLists();
      final services = await widget.loadServices();
      if (!mounted) return;
      setState(() {
        _lists = lists;
        _services = services;
        // The "Rappels" list by default.
        if (_list.isEmpty && lists.containsKey('todo.rappels')) {
          _list = 'todo.rappels';
          widget.onSave(_list, _service);
        }
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Home Assistant injoignable.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final lists = _lists;
    final services = _services;
    return PanelSection(
      title: 'Rappels',
      children: [
        const PanelNote(
          'Les rappels sont rangés dans une liste de tâches de Home Assistant, '
          'avec une date et une heure : visibles aussi dans l\'app Compagnon. '
          'Crée une liste « Rappels » (Paramètres → Appareils et services → '
          'Ajouter une intégration → To-do local) si besoin.',
        ),
        const SizedBox(height: 8),
        if (_error != null)
          PanelNote(_error!, error: true)
        else if (lists == null || services == null)
          const PanelNote('Chargement…')
        else ...[
          DropdownButton<String>(
            value: _list,
            isExpanded: true,
            dropdownColor: panelCard,
            items: [
              const DropdownMenuItem(value: '', child: Text('Liste des rappels : aucune')),
              for (final e in lists.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
              if (_list.isNotEmpty && !lists.containsKey(_list))
                DropdownMenuItem(value: _list, child: Text('$_list (introuvable)')),
            ],
            onChanged: (value) {
              setState(() => _list = value ?? '');
              widget.onSave(_list, _service);
            },
          ),
          DropdownButton<String>(
            value: _service,
            isExpanded: true,
            dropdownColor: panelCard,
            items: [
              const DropdownMenuItem(value: '', child: Text('Téléphone : pas de notification')),
              for (final s in services) DropdownMenuItem(value: s, child: Text(s)),
              if (_service.isNotEmpty && !services.contains(_service))
                DropdownMenuItem(value: _service, child: Text('$_service (introuvable)')),
            ],
            onChanged: (value) {
              setState(() => _service = value ?? '');
              widget.onSave(_list, _service);
            },
          ),
        ],
      ],
    );
  }
}
