import 'package:flutter/material.dart';

import 'brief.dart';
import 'chat.dart';
import 'today.dart';

/// Size of the panel window, in logical pixels.
const kPanelSize = Size(380, 540);

const _background = Color(0xFF2B211A);
const _card = Color(0xFF3A2D23);
const _text = Color(0xFFF5E9D3);
const _muted = Color(0xFFBFAE95);
const _accent = Color(0xFFF2B53A);

/// Noxo's panel: the chat with him, the "Aujourd'hui" view (weather, agenda
/// and tasks read from Home Assistant) and the form to connect to it.
class TodayPanel extends StatefulWidget {
  const TodayPanel({
    super.key,
    required this.now,
    required this.data,
    this.brief,
    required this.status,
    required this.configured,
    required this.haUrl,
    required this.haAgent,
    this.startInChat = false,
    required this.messages,
    required this.thinking,
    required this.onSend,
    required this.onRefresh,
    required this.onClose,
    required this.onSaveSettings,
  });

  final DateTime now;

  /// Last data fetched (possibly from the offline cache), or null.
  final TodayData? data;

  /// Today's brief, if Noxo has brought one.
  final Brief? brief;

  /// One line about freshness: "À jour à 09:12", "Hors ligne…".
  final String status;

  /// Whether a Home Assistant address and token are saved.
  final bool configured;
  final String haUrl;

  /// Conversation agent entity, empty for Home Assistant's built-in one.
  final String haAgent;

  /// Opens on the chat (Noxo called from his island) instead of the day.
  final bool startInChat;

  final List<ChatMessage> messages;

  /// Waiting for Noxo's answer.
  final bool thinking;
  final void Function(String text) onSend;

  final VoidCallback onRefresh;
  final VoidCallback onClose;

  /// Saves the address, token (an empty one keeps the saved one) and agent.
  /// Returns an error message, or null when the connection works.
  final Future<String?> Function(String url, String token, String agent) onSaveSettings;

  @override
  State<TodayPanel> createState() => _TodayPanelState();
}

enum _View { chat, today, settings }

class _TodayPanelState extends State<TodayPanel> {
  late _View _view = !widget.configured
      ? _View.settings
      : (widget.startInChat ? _View.chat : _View.today);
  late final _url = TextEditingController(text: widget.haUrl);
  final _token = TextEditingController();
  late final _agent = TextEditingController(text: widget.haAgent);
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    if (_view == _View.chat) _inputFocus.requestFocus();
  }

  @override
  void didUpdateWidget(TodayPanel old) {
    super.didUpdateWidget(old);
    if (widget.messages.length != old.messages.length || widget.thinking != old.thinking) {
      _scrollToEnd();
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty || widget.thinking) return;
    _input.clear();
    widget.onSend(text);
    _inputFocus.requestFocus();
  }

  void _show(_View view) {
    setState(() => _view = view);
    if (view == _View.chat) {
      _inputFocus.requestFocus();
      _scrollToEnd();
    }
  }
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    _agent.dispose();
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await widget.onSaveSettings(_url.text, _token.text, _agent.text);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = error;
      if (error == null) {
        _token.clear();
        _view = _View.today;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Material(
        color: _background,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: DefaultTextStyle(
          style: const TextStyle(color: _text, fontSize: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              Expanded(
                child: switch (_view) {
                  _View.chat => _chat(),
                  _View.today => _today(),
                  _View.settings => _settingsForm(),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 6, 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    switch (_view) {
                      _View.chat => 'Noxo',
                      _View.today => "Aujourd'hui",
                      _View.settings => 'Home Assistant',
                    },
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                Text(frenchDate(widget.now), style: const TextStyle(color: _muted)),
              ],
            ),
          ),
          if (_view == _View.today && widget.configured)
            _HeaderIcon(icon: Icons.refresh, tooltip: 'Actualiser', onTap: widget.onRefresh),
          if (_view == _View.chat)
            _HeaderButton(label: "Aujourd'hui", onTap: () => _show(_View.today))
          else if (_view == _View.today && widget.configured)
            _HeaderButton(label: 'Discuter', onTap: () => _show(_View.chat)),
          _HeaderButton(
            label: _view == _View.settings ? 'Retour' : 'Réglages',
            onTap: () => _show(_view == _View.settings ? _View.today : _View.settings),
          ),
          _HeaderIcon(icon: Icons.close, tooltip: 'Fermer', onTap: widget.onClose),
        ],
      ),
    );
  }

  Widget _today() {
    final data = widget.data;
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(widget.status, style: const TextStyle(color: _muted, fontSize: 12)),
        ),
        if (widget.brief case final brief?)
          _Section(title: 'Brief', children: [
            Text(brief.text, style: const TextStyle(height: 1.4)),
            if (brief.byAi)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('Rédigé par l\'IA de Home Assistant',
                    style: TextStyle(color: _muted, fontSize: 11)),
              ),
          ]),
        if (!widget.configured)
          const _Section(title: 'Connexion', children: [
            Text('Noxo n\'est pas encore relié à Home Assistant. Ouvre « Réglages ».'),
          ])
        else if (data == null)
          const _Section(title: 'En attente', children: [
            Text('Aucune donnée pour l\'instant.'),
          ])
        else ...[
          if (data.weather != null)
            _Section(title: 'Météo', children: [Text(weatherLabel(data.weather!))]),
          _Section(title: 'Agenda', children: [
            if (data.events.isEmpty) const Text('Rien de prévu.', style: TextStyle(color: _muted)),
            for (final e in data.events) _EventRow(event: e),
          ]),
          _Section(title: 'Tâches', children: [
            if (data.tasks.isEmpty)
              const Text('Aucune tâche en attente.', style: TextStyle(color: _muted)),
            for (final t in data.tasks)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('•  $t'),
              ),
          ]),
        ],
      ],
    );
  }

  Widget _chat() {
    final messages = widget.messages;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
            children: [
              if (messages.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text(
                    'Demande-moi quelque chose : « allume la lumière du salon », '
                    '« quelle heure est-il ? »…',
                    style: TextStyle(color: _muted),
                  ),
                ),
              for (final m in messages) _Bubble(message: m),
              if (widget.thinking)
                const _Bubble(message: ChatMessage(text: '…', fromUser: false)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 8, 12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  focusNode: _inputFocus,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: 'Écris à Noxo…',
                    filled: true,
                    fillColor: _card,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              _HeaderIcon(
                icon: Icons.send,
                tooltip: 'Envoyer',
                onTap: widget.thinking ? null : _send,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _settingsForm() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
      children: [
        const Text(
          'Adresse de ton Home Assistant et jeton d\'accès longue durée '
          '(profil utilisateur → Sécurité → Jetons d\'accès longue durée). '
          'Le jeton reste sur ce PC.',
          style: TextStyle(color: _muted),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _url,
          enabled: !_saving,
          decoration: const InputDecoration(
              labelText: 'Adresse', hintText: 'https://ha.exemple.fr'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _token,
          enabled: !_saving,
          obscureText: true,
          decoration: InputDecoration(
            labelText: 'Jeton',
            hintText: widget.configured ? 'Laisser vide pour garder le jeton actuel' : null,
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _agent,
          enabled: !_saving,
          decoration: const InputDecoration(
            labelText: 'Agent de conversation (facultatif)',
            hintText: 'Vide : Assist intégré (sans IA)',
            helperText: 'Ex. conversation.ollama, une fois une IA ajoutée à Home Assistant',
          ),
        ),
        const SizedBox(height: 16),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_error!, style: const TextStyle(color: Color(0xFFFF8F8F))),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Test en cours…' : 'Tester et enregistrer'),
          ),
        ),
      ],
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: _accent,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 36),
      ),
      child: Text(label),
    );
  }
}

class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      icon: Icon(icon, size: 20),
      color: _accent,
      visualDensity: VisualDensity.compact,
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final user = message.fromUser;
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 280),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: user ? _accent : _card,
          borderRadius: BorderRadius.circular(14),
        ),
        child: SelectableText(
          message.text,
          style: TextStyle(
            height: 1.35,
            color: user
                ? _background
                : (message.error ? const Color(0xFFFF8F8F) : _text),
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(title.toUpperCase(),
                style: const TextStyle(
                    color: _accent, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1)),
          ),
          ...children,
        ],
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});

  final AgendaEvent event;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Text(eventTime(event), style: const TextStyle(color: _muted)),
          ),
          Expanded(child: Text(event.title)),
        ],
      ),
    );
  }
}
