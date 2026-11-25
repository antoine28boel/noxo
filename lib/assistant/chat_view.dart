import 'package:flutter/material.dart';

import 'chat.dart';
import 'ha_client.dart';
import 'panel_style.dart';

/// The chat with the owl: his answers come from Home Assistant's
/// conversation agent.
class ChatTab extends StatefulWidget {
  const ChatTab({
    super.key,
    required this.messages,
    required this.thinking,
    required this.onSend,
  });

  final List<ChatMessage> messages;

  /// Waiting for an answer.
  final bool thinking;
  final void Function(String text) onSend;

  @override
  State<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<ChatTab> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _focus.requestFocus();
    _scrollToEnd();
  }

  @override
  void didUpdateWidget(ChatTab old) {
    super.didUpdateWidget(old);
    if (widget.messages.length != old.messages.length || widget.thinking != old.thinking) {
      _scrollToEnd();
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
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
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.messages;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
            children: [
              if (messages.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(4),
                  child: PanelNote(
                    'Demande-moi quelque chose : « allume la lumière du salon », '
                    '« quelle heure est-il ? »…',
                  ),
                ),
              for (final m in messages) _Bubble(message: m),
              if (widget.thinking) const _Bubble(message: ChatMessage(text: '…', fromUser: false)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 6, 12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: 'Écris-moi…',
                    filled: true,
                    fillColor: panelCard,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              IconButton(
                onPressed: widget.thinking ? null : _send,
                tooltip: 'Envoyer',
                icon: const Icon(Icons.send_rounded, size: 20),
                color: panelAccent,
              ),
            ],
          ),
        ),
      ],
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
        constraints: const BoxConstraints(maxWidth: 300),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: user ? panelAccent : panelCard,
          borderRadius: BorderRadius.circular(14),
        ),
        child: SelectableText(
          message.text,
          style: TextStyle(
            height: 1.35,
            color: user ? panelBackground : (message.error ? panelError : panelText),
          ),
        ),
      ),
    );
  }
}

/// The conversation agent used by the chat, chosen in the settings among
/// those Home Assistant offers.
class AgentForm extends StatefulWidget {
  const AgentForm({super.key, required this.client, required this.agent, required this.onSave});

  final HaClient client;
  final String agent;
  final void Function(String agent) onSave;

  @override
  State<AgentForm> createState() => _AgentFormState();
}

class _AgentFormState extends State<AgentForm> {
  late String _agent = widget.agent;
  List<ConversationAgent>? _agents;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final agents = parseConversationAgents(await widget.client.states());
      if (mounted) setState(() => _agents = agents);
    } catch (_) {
      if (mounted) setState(() => _error = 'Liste des agents indisponible (Home Assistant injoignable).');
    }
  }

  @override
  Widget build(BuildContext context) {
    final agents = _agents;
    final ids = {for (final a in agents ?? const <ConversationAgent>[]) a.id};
    return PanelSection(
      title: 'Discussion',
      children: [
        const PanelNote(
          'IA qui te répond, parmi les agents de conversation de Home Assistant. '
          'Pour en avoir une, ajoute une intégration IA à Home Assistant '
          '(Ollama, Anthropic, OpenAI, Google…) ; elle apparaîtra ici.',
        ),
        const SizedBox(height: 8),
        if (_error != null)
          PanelNote(_error!, error: true)
        else if (agents == null)
          const PanelNote('Chargement…')
        else
          DropdownButton<String>(
            value: _agent,
            isExpanded: true,
            dropdownColor: panelCard,
            items: [
              const DropdownMenuItem(value: '', child: Text('Assist (intégré, sans IA)')),
              for (final a in agents) DropdownMenuItem(value: a.id, child: Text(a.name)),
              if (_agent.isNotEmpty && !ids.contains(_agent))
                DropdownMenuItem(value: _agent, child: Text('$_agent (introuvable)')),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() => _agent = value);
              widget.onSave(value);
            },
          ),
      ],
    );
  }
}
