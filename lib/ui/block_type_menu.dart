import 'package:flutter/material.dart';

import '../markdown/note_blocks.dart';

/// One entry in the block-type menu.
class BlockTypeChoice {
  const BlockTypeChoice({
    required this.label,
    required this.hint,
    required this.icon,
    required this.shortcut,
    required this.block,
  });

  final String label;

  /// The markdown this produces, shown the way MarkText shows it.
  final String hint;
  final String icon;
  final String shortcut;
  final NoteBlock block;
}

/// The block kinds a line can be turned into, grouped as MarkText groups them.
class BlockTypes {
  BlockTypes._();

  static const basic = [
    BlockTypeChoice(
      label: 'Paragraph',
      hint: 'Input text content',
      icon: '¶',
      shortcut: 'Ctrl+0',
      block: NoteBlock.paragraph(''),
    ),
    BlockTypeChoice(
      label: 'Bullet list',
      hint: '- item',
      icon: '•',
      shortcut: 'Ctrl+L',
      block: NoteBlock.bullet(''),
    ),
    BlockTypeChoice(
      label: 'Checklist',
      hint: '- [ ] task',
      icon: '☑',
      shortcut: 'Ctrl+T',
      block: NoteBlock.task(''),
    ),
    BlockTypeChoice(
      label: 'Horizontal line',
      hint: '---',
      icon: '—',
      shortcut: 'Ctrl+-',
      block: NoteBlock.divider(),
    ),
  ];

  static const headers = [
    BlockTypeChoice(
      label: 'Header 1',
      hint: '# Header',
      icon: 'H1',
      shortcut: 'Ctrl+1',
      block: NoteBlock.heading('', level: 1),
    ),
    BlockTypeChoice(
      label: 'Header 2',
      hint: '## Header',
      icon: 'H2',
      shortcut: 'Ctrl+2',
      block: NoteBlock.heading('', level: 2),
    ),
    BlockTypeChoice(
      label: 'Header 3',
      hint: '### Header',
      icon: 'H3',
      shortcut: 'Ctrl+3',
      block: NoteBlock.heading('', level: 3),
    ),
    BlockTypeChoice(
      label: 'Header 4',
      hint: '#### Header',
      icon: 'H4',
      shortcut: 'Ctrl+4',
      block: NoteBlock.heading('', level: 4),
    ),
  ];

  /// Resolves a Ctrl+digit style shortcut to a block kind.
  static NoteBlock? forDigit(int digit) => switch (digit) {
        0 => const NoteBlock.paragraph(''),
        >= 1 && <= 6 => NoteBlock.heading('', level: digit),
        _ => null,
      };
}

/// Opens the block-type menu at [position] and returns the chosen kind.
Future<NoteBlock?> showBlockTypeMenu(
  BuildContext context,
  Offset position,
) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (overlay == null) return null;

  final theme = Theme.of(context);

  PopupMenuEntry<NoteBlock> header(String text) => PopupMenuItem<NoteBlock>(
        enabled: false,
        height: 30,
        child: Text(
          text,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.primary,
            letterSpacing: 1.1,
            fontWeight: FontWeight.w700,
          ),
        ),
      );

  PopupMenuEntry<NoteBlock> entry(BlockTypeChoice choice) =>
      PopupMenuItem<NoteBlock>(
        value: choice.block,
        child: _ChoiceRow(choice: choice),
      );

  return showMenu<NoteBlock>(
    context: context,
    position: RelativeRect.fromLTRB(
      position.dx,
      position.dy,
      overlay.size.width - position.dx,
      overlay.size.height - position.dy,
    ),
    constraints: const BoxConstraints(minWidth: 280, maxWidth: 340),
    items: [
      header('BASIC BLOCK'),
      ...BlockTypes.basic.map(entry),
      header('HEADER'),
      ...BlockTypes.headers.map(entry),
    ],
  );
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({required this.choice});

  final BlockTypeChoice choice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            choice.icon,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(choice.label, style: theme.textTheme.bodyMedium),
              Text(
                choice.hint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          choice.shortcut,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ],
    );
  }
}
