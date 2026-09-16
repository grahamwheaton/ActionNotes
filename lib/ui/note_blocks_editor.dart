import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../markdown/note_blocks.dart';
import 'block_type_menu.dart';
import 'inline_format.dart';
import 'markdown_text_controller.dart';
import 'note_view.dart';

/// One editable row, holding the controller and focus that belong to a block
/// for as long as that block exists.
class _Row {
  _Row(this.id, this.block)
      : controller = block.isText
            ? MarkdownTextController(text: block.text)
            : null,
        focus = block.isText ? FocusNode() : null;

  final int id;
  NoteBlock block;
  final MarkdownTextController? controller;
  final FocusNode? focus;

  void dispose() {
    controller?.dispose();
    focus?.dispose();
  }
}

/// Edits a note as a stack of blocks, drawn the way they will read: headings
/// at heading size, bullets with their marker, images as the picture. Typing
/// `## ` at the start of a line turns it into a heading and takes the hashes
/// away, the way a word processor would.
class NoteBlocksEditor extends StatefulWidget {
  const NoteBlocksEditor({
    super.key,
    required this.initialMarkdown,
    required this.onChanged,
    this.onOpenProject,
    this.onRequestLink,
  });

  final String initialMarkdown;

  /// Fires whenever the note's markdown changes, so the host can save it.
  final ValueChanged<String> onChanged;

  /// Asked for markdown to insert when `[[` is typed, as Obsidian does.
  /// Returning null leaves the line as it was, minus the brackets.
  final Future<String?> Function()? onRequestLink;

  final void Function(String slug)? onOpenProject;

  @override
  State<NoteBlocksEditor> createState() => NoteBlocksEditorState();
}

class NoteBlocksEditorState extends State<NoteBlocksEditor> {
  final List<_Row> _rows = [];
  int _nextId = 0;

  /// The row that last had focus, so an inserted image or link lands where the
  /// person was working rather than at the end.
  int? _activeId;

  /// Guards against the `[[` handler firing again while the picker is up.
  bool _pickerOpen = false;

  @override
  void initState() {
    super.initState();
    final blocks = NoteBlocks.parse(widget.initialMarkdown);
    for (final block in blocks) {
      _rows.add(_row(block));
    }
    // A note always needs somewhere to type.
    if (_rows.every((row) => !row.block.isText)) {
      _rows.add(_row(const NoteBlock.paragraph('')));
    }
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  _Row _row(NoteBlock block) {
    final row = _Row(_nextId++, block);
    row.focus?.addListener(() {
      if (row.focus!.hasFocus) _activeId = row.id;
    });
    return row;
  }

  String get markdown => NoteBlocks.serialize(
        [
          for (final row in _rows)
            row.block.isText
                ? row.block.copyWith(text: row.controller!.text)
                : row.block,
        ],
      );

  void _emit() => widget.onChanged(markdown);

  int _indexOfId(int id) => _rows.indexWhere((row) => row.id == id);

  /// Turns a typed marker into the block it names, and `[[` into a link.
  void _onTextChanged(_Row row) {
    final text = row.controller!.text;
    final shortcut = NoteBlocks.shortcutFor(row.block, text);

    if (shortcut != null) {
      setState(() => row.block = shortcut);
      // Drop the marker from the text now that the block itself carries it.
      row.controller!.value = TextEditingValue(
        text: shortcut.text,
        selection: TextSelection.collapsed(offset: shortcut.text.length),
      );
      _emit();
      return;
    }

    _maybeCompleteLink(row);
    _emit();
  }

  void _maybeCompleteLink(_Row row) {
    if (_pickerOpen || widget.onRequestLink == null) return;

    final controller = row.controller!;
    final caret = controller.selection.baseOffset;
    if (caret < 2) return;
    if (controller.text.substring(caret - 2, caret) != '[[') return;

    _pickerOpen = true;
    // Let the field settle before putting a dialog over it.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final snippet = await widget.onRequestLink!();
      _pickerOpen = false;

      final at = controller.selection.baseOffset;
      if (at < 2) return;

      // Replace the `[[` that triggered this, whether or not one was chosen.
      final before = controller.text.substring(0, at - 2);
      final after = controller.text.substring(at);
      final insert = snippet ?? '';

      controller.value = TextEditingValue(
        text: '$before$insert$after',
        selection:
            TextSelection.collapsed(offset: before.length + insert.length),
      );
      row.focus?.requestFocus();
      _emit();
    });
  }

  /// Enter splits the block at the caret, as a new paragraph below.
  void _splitAt(_Row row) {
    final controller = row.controller!;
    final caret = controller.selection.baseOffset.clamp(0, controller.text.length);
    final before = controller.text.substring(0, caret);
    final after = controller.text.substring(caret);

    controller.text = before;

    // Continuing a list keeps making bullets; anything else starts a
    // paragraph, which is what leaving a heading should do.
    final nextType = row.block.type == NoteBlockType.bullet
        ? NoteBlockType.bullet
        : NoteBlockType.paragraph;

    final next = _row(NoteBlock(type: nextType, text: after));
    setState(() => _rows.insert(_indexOfId(row.id) + 1, next));

    // The new row's focus node only exists after it is built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      next.focus?.requestFocus();
      next.controller?.selection = const TextSelection.collapsed(offset: 0);
    });
    _emit();
  }

  /// Backspace at the very start: first give a heading or bullet back its
  /// plain form, and only merge upwards once it is already a paragraph.
  bool _backspaceAtStart(_Row row) {
    if (row.block.type != NoteBlockType.paragraph) {
      setState(() => row.block = row.block.copyWith(
            type: NoteBlockType.paragraph,
            level: 1,
          ));
      _emit();
      return true;
    }

    final index = _indexOfId(row.id);
    if (index <= 0) return false;

    final previous = _rows[index - 1];
    if (!previous.block.isText) {
      // Backspacing into an image removes it, which is the only sensible
      // reading and saves hunting for a delete button.
      setState(() {
        _rows.removeAt(index - 1);
      });
      previous.dispose();
      _emit();
      return true;
    }

    final joinAt = previous.controller!.text.length;
    previous.controller!.text = previous.controller!.text + row.controller!.text;

    setState(() => _rows.removeAt(index));
    row.dispose();

    previous.focus!.requestFocus();
    previous.controller!.selection = TextSelection.collapsed(offset: joinAt);
    _emit();
    return true;
  }

  /// Inserts a block after whichever row was last focused.
  void insertBlock(NoteBlock block) {
    final active = _activeId == null ? -1 : _indexOfId(_activeId!);
    final at = active < 0 ? _rows.length : active + 1;

    final inserted = _row(block);
    final trailing = _row(const NoteBlock.paragraph(''));

    setState(() => _rows.insertAll(at, [inserted, trailing]));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      trailing.focus?.requestFocus();
    });
    _emit();
  }

  /// Puts text into the focused block at its caret, for a link.
  void insertInline(String snippet) {
    final active = _activeId == null ? -1 : _indexOfId(_activeId!);
    final row = active < 0
        ? _rows.lastWhere((row) => row.block.isText, orElse: () => _rows.last)
        : _rows[active];
    final controller = row.controller;
    if (controller == null) return;

    final selection = controller.selection;
    final start = selection.isValid ? selection.start : controller.text.length;
    final end = selection.isValid ? selection.end : start;

    final text = controller.text.replaceRange(start, end, snippet);
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: start + snippet.length),
    );
    row.focus?.requestFocus();
    _emit();
  }

  /// Turns the focused block into [kind], keeping whatever text it held.
  void _setBlockType(_Row row, NoteBlock kind) {
    if (kind.type == NoteBlockType.divider) {
      // A rule holds no text, so put the text in a fresh block below it
      // rather than discarding what was typed.
      final index = _indexOfId(row.id);
      final text = row.controller?.text ?? '';
      final rule = _row(const NoteBlock.divider());
      setState(() => _rows.insert(index, rule));

      if (text.trim().isEmpty) {
        setState(() => _rows.remove(row));
        row.dispose();
        if (_rows.every((r) => !r.block.isText)) {
          setState(() => _rows.add(_row(const NoteBlock.paragraph(''))));
        }
      }
      _emit();
      return;
    }

    setState(() => row.block = row.block.copyWith(
          type: kind.type,
          level: kind.level,
        ));
    row.focus?.requestFocus();
    _emit();
  }

  void _applyMark(_Row row, InlineMark mark) {
    final controller = row.controller;
    if (controller == null) return;
    controller.value = InlineFormat.toggle(controller.value, mark);
    _emit();
  }

  void _clearMarks(_Row row) {
    final controller = row.controller;
    if (controller == null) return;
    controller.value = InlineFormat.clear(controller.value);
    _emit();
  }

  void _removeRow(_Row row) {
    setState(() => _rows.remove(row));
    row.dispose();
    if (_rows.every((r) => !r.block.isText)) {
      final fresh = _row(const NoteBlock.paragraph(''));
      setState(() => _rows.add(fresh));
    }
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      itemCount: _rows.length,
      itemBuilder: (context, index) {
        final row = _rows[index];

        if (row.block.type == NoteBlockType.divider) {
          return _DividerBlock(
            key: ValueKey(row.id),
            onRemove: () => _removeRow(row),
          );
        }

        return row.block.isText
            ? _TextBlock(
                key: ValueKey(row.id),
                row: row,
                onChanged: () => _onTextChanged(row),
                onSplit: () => _splitAt(row),
                onBackspaceAtStart: () => _backspaceAtStart(row),
                onSetType: (kind) => _setBlockType(row, kind),
                onMark: (mark) => _applyMark(row, mark),
                onClearMarks: () => _clearMarks(row),
                onRequestLink: widget.onRequestLink == null
                    ? null
                    : () async {
                        final snippet = await widget.onRequestLink!();
                        if (snippet != null) insertInline(snippet);
                      },
              )
            : _ImageBlock(
                key: ValueKey(row.id),
                block: row.block,
                onOpenProject: widget.onOpenProject,
                onRemove: () => _removeRow(row),
              );
      },
    );
  }
}

class _TextBlock extends StatelessWidget {
  const _TextBlock({
    super.key,
    required this.row,
    required this.onChanged,
    required this.onSplit,
    required this.onBackspaceAtStart,
    required this.onSetType,
    required this.onMark,
    required this.onClearMarks,
    this.onRequestLink,
  });

  final _Row row;
  final VoidCallback onChanged;
  final VoidCallback onSplit;
  final bool Function() onBackspaceAtStart;
  final ValueChanged<NoteBlock> onSetType;
  final ValueChanged<InlineMark> onMark;
  final VoidCallback onClearMarks;
  final Future<void> Function()? onRequestLink;

  TextStyle _styleFor(ThemeData theme) {
    final text = theme.textTheme;
    return switch (row.block.type) {
      NoteBlockType.heading => switch (row.block.level) {
          1 => text.headlineSmall!.copyWith(fontWeight: FontWeight.w700),
          2 => text.titleLarge!.copyWith(fontWeight: FontWeight.w700),
          3 => text.titleMedium!.copyWith(fontWeight: FontWeight.w700),
          _ => text.titleSmall!.copyWith(fontWeight: FontWeight.w700),
        },
      _ => text.bodyMedium!,
    };
  }

  /// Ctrl+0 for a paragraph and Ctrl+1..6 for headers, as MarkText has them,
  /// plus Ctrl+B and Ctrl+I for the marks.
  // Not const: LogicalKeyboardKey defines its own ==, which a const map key
  // may not do.
  static final _digits = <LogicalKeyboardKey, int>{
    LogicalKeyboardKey.digit0: 0,
    LogicalKeyboardKey.digit1: 1,
    LogicalKeyboardKey.digit2: 2,
    LogicalKeyboardKey.digit3: 3,
    LogicalKeyboardKey.digit4: 4,
    LogicalKeyboardKey.digit5: 5,
    LogicalKeyboardKey.digit6: 6,
  };

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final control = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;

    if (control) {
      final digit = _digits[event.logicalKey];
      if (digit != null) {
        final kind = BlockTypes.forDigit(digit);
        if (kind != null) {
          onSetType(kind);
          return KeyEventResult.handled;
        }
      }
      if (event.logicalKey == LogicalKeyboardKey.keyB) {
        onMark(InlineMark.bold);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyI) {
        onMark(InlineMark.italic);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyL) {
        onSetType(const NoteBlock.bullet(''));
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.minus) {
        onSetType(const NoteBlock.divider());
        return KeyEventResult.handled;
      }
    }

    final enter = event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (enter && !HardwareKeyboard.instance.isShiftPressed) {
      onSplit();
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      final selection = row.controller!.selection;
      if (selection.isCollapsed && selection.baseOffset == 0) {
        return onBackspaceAtStart()
            ? KeyEventResult.handled
            : KeyEventResult.ignored;
      }
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isBullet = row.block.type == NoteBlockType.bullet;

    return Padding(
      padding: EdgeInsets.only(
        top: row.block.type == NoteBlockType.heading ? 14 : 2,
        bottom: 2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ParagraphButton(row: row, onSetType: onSetType),
          if (isBullet)
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 8, left: 4),
              child: Icon(
                Icons.circle,
                size: 6,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          Expanded(
            child: Focus(
              onKeyEvent: _onKey,
              child: TextField(
                controller: row.controller,
                focusNode: row.focus,
                style: _styleFor(theme),
                maxLines: null,
                // Enter is intercepted above to split the block, so the field
                // itself never needs to insert a newline.
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  isDense: true,
                  filled: false,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 4),
                  hintText: row.block.type == NoteBlockType.heading
                      ? 'Heading'
                      : null,
                ),
                // The formatting toolbar rides on the selection toolbar, so
                // it appears at the selection and is positioned by Flutter
                // rather than guessed at.
                contextMenuBuilder: (context, editable) {
                  return AdaptiveTextSelectionToolbar.buttonItems(
                    anchors: editable.contextMenuAnchors,
                    buttonItems: [
                      for (final mark in InlineMark.values)
                        ContextMenuButtonItem(
                          label: mark.label,
                          onPressed: () {
                            ContextMenuController.removeAny();
                            onMark(mark);
                          },
                        ),
                      if (onRequestLink != null)
                        ContextMenuButtonItem(
                          label: 'Link',
                          onPressed: () {
                            ContextMenuController.removeAny();
                            onRequestLink!();
                          },
                        ),
                      ContextMenuButtonItem(
                        label: 'Clear',
                        onPressed: () {
                          ContextMenuController.removeAny();
                          onClearMarks();
                        },
                      ),
                      ...editable.contextMenuButtonItems,
                    ],
                  );
                },
                onChanged: (_) => onChanged(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The ¶ handle beside a block, which opens the block-type menu.
class _ParagraphButton extends StatelessWidget {
  const _ParagraphButton({required this.row, required this.onSetType});

  final _Row row;
  final ValueChanged<NoteBlock> onSetType;

  String get _label => switch (row.block.type) {
        NoteBlockType.heading => 'H${row.block.level}',
        NoteBlockType.bullet => '•',
        _ => '¶',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(top: 4, right: 4),
      child: Builder(
        builder: (buttonContext) => InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () async {
            final box = buttonContext.findRenderObject() as RenderBox?;
            if (box == null) return;

            final kind = await showBlockTypeMenu(
              buttonContext,
              box.localToGlobal(box.size.bottomLeft(Offset.zero)),
            );
            if (kind != null) onSetType(kind);
          },
          child: SizedBox(
            width: 28,
            height: 26,
            child: Center(
              child: Text(
                _label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A horizontal rule, with the same remove affordance an image has.
class _DividerBlock extends StatelessWidget {
  const _DividerBlock({super.key, required this.onRemove});

  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          const Expanded(child: Divider(thickness: 1)),
          IconButton(
            tooltip: 'Remove line',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _ImageBlock extends StatelessWidget {
  const _ImageBlock({
    super.key,
    required this.block,
    required this.onRemove,
    this.onOpenProject,
  });

  final NoteBlock block;
  final VoidCallback onRemove;
  final void Function(String slug)? onOpenProject;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Stack(
        alignment: Alignment.topRight,
        children: [
          // Reuses the note renderer, so an image resolves from the same
          // attachment cache here as it does in a rendered note.
          NoteView(
            markdown: '![${block.imageAlt}](${block.imagePath})',
            selectable: false,
            onOpenProject: onOpenProject,
          ),
          Material(
            color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.8),
            shape: const CircleBorder(),
            child: IconButton(
              tooltip: 'Remove image',
              iconSize: 18,
              icon: const Icon(Icons.close),
              onPressed: onRemove,
            ),
          ),
        ],
      ),
    );
  }
}
