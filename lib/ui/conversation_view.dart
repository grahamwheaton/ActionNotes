import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../markdown/note_conversation.dart';
import '../state/app_state.dart';
import 'note_view.dart';

/// A note as a conversation: one bubble per signed message, yours on the
/// right, a model's on the left.
///
/// The markdown is still the note — this reads the signatures the file
/// already holds — so anything written here is as editable in the block
/// editor, in a text editor, or on GitHub as it ever was.
class ConversationView extends StatefulWidget {
  const ConversationView({
    super.key,
    required this.markdown,
    required this.onSend,
    this.onOpenProject,
  });

  final String markdown;

  /// Called with the whole note once a message has been added to it.
  final ValueChanged<String> onSend;
  final void Function(String slug)? onOpenProject;

  @override
  State<ConversationView> createState() => _ConversationViewState();
}

class _ConversationViewState extends State<ConversationView> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final said = _composer.text.trim();
    if (said.isEmpty) return;

    widget.onSend(NoteConversation.append(
      widget.markdown,
      speaker: context.read<AppState>().me,
      body: said,
    ));
    _composer.clear();

    // A new message goes to the bottom, which is where the eye already is in
    // anything shaped like a chat.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final me = context.watch<AppState>().me;
    final messages = NoteConversation.parse(widget.markdown);

    return Column(
      children: [
        Expanded(
          child: messages.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Nothing said yet. Write below, and a model working on '
                      'this repo can answer in the same note.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  itemCount: messages.length,
                  itemBuilder: (context, index) => _Bubble(
                    message: messages[index],
                    mine: _isMine(messages[index].speaker, me),
                    onOpenProject: widget.onOpenProject,
                  ),
                ),
        ),
        _Composer(controller: _composer, onSend: _send),
      ],
    );
  }

  /// Yours if it carries your name, or if it carries none — an older note was
  /// written by you, not by a model. A model's messages are known by name.
  static bool _isMine(String? speaker, String me) {
    if (NoteConversation.isModel(speaker)) return false;
    if (speaker == null) return true;
    return speaker.toLowerCase() == me.toLowerCase() ||
        !NoteConversation.isModel(speaker);
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.mine,
    this.onOpenProject,
  });

  final NoteMessage message;
  final bool mine;
  final void Function(String slug)? onOpenProject;

  /// Local time, since it is read by a person; the file keeps UTC.
  String? get _when {
    final at = message.at;
    if (at == null) return null;
    final local = at.toLocal();
    final today = DateTime.now();
    final sameDay = local.year == today.year &&
        local.month == today.month &&
        local.day == today.day;

    String two(int value) => value.toString().padLeft(2, '0');
    final time = '${two(local.hour)}:${two(local.minute)}';
    return sameDay ? time : '${two(local.day)}/${two(local.month)} $time';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final when = _when;

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: mine
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(12),
            topRight: const Radius.circular(12),
            bottomLeft: Radius.circular(mine ? 12 : 2),
            bottomRight: Radius.circular(mine ? 2 : 12),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.speaker != null || when != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (message.speaker != null)
                      Text(
                        message.speaker!,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: mine
                              ? theme.colorScheme.onPrimaryContainer
                              : theme.colorScheme.primary,
                        ),
                      ),
                    if (when != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        when,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            // The body is markdown, as it is everywhere else in a note, so a
            // model can answer with a list or a picture.
            NoteView(
              markdown: message.body,
              selectable: true,
              onOpenProject: onOpenProject,
            ),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({required this.controller, required this.onSend});

  final TextEditingController controller;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 8, 10),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 6,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'Write a message',
                  isDense: true,
                ),
                onSubmitted: (_) => onSend(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: 'Send',
              icon: const Icon(Icons.send, size: 18),
              onPressed: onSend,
            ),
          ],
        ),
      ),
    );
  }
}
