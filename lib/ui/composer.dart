import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'touch_input.dart';

/// What the composer will add when it is sent.
enum AddKind {
  task,
  note,
  canvas;

  String get label => switch (this) {
    AddKind.note => 'Note',
    AddKind.canvas => 'Canvas',
    AddKind.task => 'Task',
  };

  IconData get icon => switch (this) {
    AddKind.note => Icons.subject,
    AddKind.canvas => Icons.dashboard_customize_outlined,
    AddKind.task => Icons.check_box_outlined,
  };

  String get hint => switch (this) {
    AddKind.note => 'Name a section of notes',
    AddKind.canvas => 'Name a canvas',
    AddKind.task => 'Add an item',
  };
}

/// The box at the bottom of a project: what to add, and what sort of thing it
/// is.
///
/// Laid out after the Claude app's composer — a rounded card with the text
/// above and the controls on their own row below — because a phone has the
/// width for one row of either text or buttons, not both.
class Composer extends StatelessWidget {
  const Composer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.kind,
    required this.onKindChanged,
    required this.onSubmit,
    required this.onSubmitStarred,
    this.onAttach,
    this.onPasteImage,
    this.target,
    this.onClearTarget,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  final AddKind kind;
  final ValueChanged<AddKind> onKindChanged;

  final VoidCallback onSubmit;

  /// Ctrl+Enter, or holding the send button: add it and star it in one go,
  /// rather than adding it and then hunting for the star on a list that has
  /// just moved.
  final VoidCallback onSubmitStarred;

  /// Null where attaching makes no sense for what is being added.
  final VoidCallback? onAttach;

  /// Ctrl+V: takes a picture off the clipboard, and says whether it did. When
  /// it did not, this pastes the clipboard's text into the box itself —
  /// intercepting the key means owning both halves of what it means.
  final Future<bool> Function()? onPasteImage;

  /// The `##` section a new item will go into, or null for the top of the
  /// project. Shown rather than inferred silently: where a thing you add ends
  /// up is not something to have to guess at.
  final String? target;
  final VoidCallback? onClearTarget;

  Future<void> _paste() async {
    if (await onPasteImage!()) return;

    // No picture: put the clipboard's text in at the caret, which is what the
    // field would have done had the shortcut not taken the key.
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;

    final value = controller.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);

    controller.value = value.copyWith(
      text: value.text.replaceRange(selection.start, selection.end, text),
      selection: TextSelection.collapsed(offset: selection.start + text.length),
      composing: TextRange.empty,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final touch = TouchInput.isPrimary;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.6,
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CallbackShortcuts(
                bindings: {
                  const SingleActivator(
                    LogicalKeyboardKey.enter,
                    control: true,
                  ): onSubmitStarred,
                  const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                      onSubmitStarred,
                  const SingleActivator(
                    LogicalKeyboardKey.numpadEnter,
                    control: true,
                  ): onSubmitStarred,
                  if (onPasteImage != null) ...{
                    const SingleActivator(
                      LogicalKeyboardKey.keyV,
                      control: true,
                    ): _paste,
                    const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
                        _paste,
                  },
                },
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  textCapitalization: TextCapitalization.sentences,
                  // Grows with what is being typed and then scrolls, so a long
                  // item reads as it will read in the list. Wrapping, not
                  // newlines: an item is one line of text, so the action key
                  // stays "done" and Enter does not break it in half.
                  minLines: 1,
                  maxLines: 5,
                  keyboardType: TextInputType.text,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    hintText: kind.hint,
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  onSubmitted: (_) => onSubmit(),
                ),
              ),
              Row(
                children: [
                  _RoundButton(
                    icon: Icons.add,
                    tooltip: 'Attach a photo',
                    onTap: onAttach,
                    filled: false,
                  ),
                  const SizedBox(width: 6),
                  _KindPill(kind: kind, onChanged: onKindChanged),
                  if (target != null && kind == AddKind.task) ...[
                    const SizedBox(width: 6),
                    Flexible(
                      child: _TargetChip(
                        target: target!,
                        onClear: onClearTarget,
                      ),
                    ),
                  ],
                  const Spacer(),
                  // Holding it stars what is being added, which is what
                  // Ctrl+Enter does for a keyboard. One widget owns both
                  // gestures: a long-press wrapped round a button loses the
                  // hold to the button's own tap.
                  Tooltip(
                    message: 'Add — hold to add it starred',
                    child: Material(
                      color: theme.colorScheme.primary,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: onSubmit,
                        onLongPress: () {
                          HapticFeedback.mediumImpact();
                          onSubmitStarred();
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Icon(
                            Icons.arrow_upward,
                            size: 20,
                            color: theme.colorScheme.onPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 2, left: 2),
                child: Text(
                  touch
                      ? 'Hold ↑ to add it starred'
                      : 'Ctrl+Enter adds it starred',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Picks what the composer adds.
///
/// Worded as what will be added rather than as a mode, because it changes the
/// next thing written and not the project — the pill it is modelled on picks a
/// model for the next message, which is the same promise.
class _KindPill extends StatelessWidget {
  const _KindPill({required this.kind, required this.onChanged});

  final AddKind kind;
  final ValueChanged<AddKind> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopupMenuButton<AddKind>(
      tooltip: 'What to add',
      initialValue: kind,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final option in AddKind.values)
          PopupMenuItem(
            value: option,
            child: Row(
              children: [
                Icon(option.icon, size: 18),
                const SizedBox(width: 10),
                Text(option.label),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Add: ', style: theme.textTheme.labelMedium),
            Text(
              kind.label,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    );
  }
}

/// Says which section a new item is going into, and takes it back to the top
/// of the project when tapped.
class _TargetChip extends StatelessWidget {
  const _TargetChip({required this.target, this.onClear});

  final String target;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Tooltip(
      message: 'Adding to “$target” — tap to add at the top instead',
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onClear,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(18),
            border: BorderSide(
              color: theme.colorScheme.primary.withValues(alpha: 0.4),
            ).toBorder(),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  'in $target',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Icon(Icons.close, size: 15),
            ],
          ),
        ),
      ),
    );
  }
}

extension on BorderSide {
  Border toBorder() => Border.fromBorderSide(this);
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.filled = true,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Tooltip(
      message: tooltip,
      child: Material(
        color: filled
            ? theme.colorScheme.primary
            : theme.colorScheme.surfaceContainerHighest,
        shape: CircleBorder(
          side: filled
              ? BorderSide.none
              : BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(
              icon,
              size: 20,
              color: filled
                  ? theme.colorScheme.onPrimary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
