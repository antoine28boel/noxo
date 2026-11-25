import 'package:flutter/material.dart';

import 'chat.dart';
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

/// The conversation agent used by the chat, in the settings.
class AgentForm extends StatefulWidget {
  const AgentForm({super.key, required this.agent, required this.onSave});

  final String agent;
  final void Function(String agent) onSave;

  @override
  State<AgentForm> createState() => _AgentFormState();
}

class _AgentFormState extends State<AgentForm> {
  late final _agent = TextEditingController(text: widget.agent);
  bool _saved = false;

  @override
  void dispose() {
    _agent.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PanelSection(
      title: 'Discussion',
      children: [
        const PanelNote(
          'Agent de conversation de Home Assistant. Vide : Assist intégré, '
          'sans IA (commandes de la maison). Une fois une IA ajoutée à Home '
          'Assistant, indique son entité, par ex. conversation.ollama.',
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _agent,
          onChanged: (_) => setState(() => _saved = false),
          decoration: const InputDecoration(
            labelText: 'Agent (facultatif)',
            hintText: 'conversation.xxx',
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            onPressed: () {
              widget.onSave(_agent.text.trim());
              setState(() => _saved = true);
            },
            child: Text(_saved ? 'Enregistré' : 'Enregistrer'),
          ),
        ),
      ],
    );
  }
}
