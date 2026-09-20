import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../markdown/note_blocks.dart';
import 'block_type_menu.dart';
import 'inline_format.dart';
import 'markdown_text_controller.dart';
import 'note_history.dart';
import 'note_view.dart';
import 'theme.dart';
import 'touch_input.dart';

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

  /// The row's box in the list, so a drag across the note can work out which
  /// line the pointer is over.
  final GlobalKey boxKey = GlobalKey();

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
    this.onRequestImage,
    this.onPaste,
    this.shrinkWrap = false,
    this.placeholder,
  });

  final String initialMarkdown;

  /// Shown in the first line while the note is empty, so somewhere that can be
  /// typed into does not read as blank space.
  final String? placeholder;

  /// Lays the blocks out at their natural height instead of scrolling, for
  /// when the note is embedded in a list that scrolls for it.
  final bool shrinkWrap;

  /// Fires whenever the note's markdown changes, so the host can save it.
  final ValueChanged<String> onChanged;

  /// Asked for markdown to insert when `[[` is typed, as Obsidian does.
  /// Returning null leaves the line as it was, minus the brackets.
  final Future<String?> Function()? onRequestLink;

  /// Asked for a picture, from the markup menu. Null when the note has
  /// nowhere to put one.
  final Future<void> Function()? onRequestImage;

  final void Function(String slug)? onOpenProject;

  /// Takes over Paste in a block's own menu, so an image on the clipboard can
  /// be uploaded. Without it the menu pastes text, which is all a text field
  /// knows how to do — and is what a phone's paste would otherwise be
  /// limited to, there being no Ctrl+V to intercept.
  final Future<void> Function()? onPaste;

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

  /// Rows picked out together, so a block-type change lands on all of them.
  /// Empty when the caret is simply sitting in one row.
  final Set<int> _selectedIds = {};

  /// Where a shift-extended selection started, so extending it again grows
  /// from the same end rather than from wherever the caret drifted to.
  int? _anchorId;

  /// The end that moves. Kept apart from the anchor so shift and an arrow
  /// back the way you came shrinks the selection instead of sitting still.
  int? _reachId;

  /// The row a mouse drag started in, and whether it has left that row.
  /// Cleared when the button comes up.
  int? _dragFromId;
  bool _dragLeftItsRow = false;

  late final NoteHistory _history = NoteHistory(widget.initialMarkdown);

  /// Typing is coalesced, so undo steps over a word rather than a letter.
  Timer? _historyTimer;

  /// Set while restoring, so rebuilding the rows does not record the restore
  /// as a fresh edit.
  bool _restoring = false;

  bool get canUndo => _history.canUndo;
  bool get canRedo => _history.canRedo;

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
    _historyTimer?.cancel();
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

  void _clearRowSelection() {
    if (_selectedIds.isEmpty && _anchorId == null) return;
    setState(() {
      _selectedIds.clear();
      _anchorId = null;
      _reachId = null;
    });
  }

  /// Selects every row between [fromId] and [toId], whichever way round.
  void _selectRange(int fromId, int toId) {
    final from = _indexOfId(fromId);
    final to = _indexOfId(toId);
    if (from < 0 || to < 0) return;

    final first = from < to ? from : to;
    final last = from < to ? to : from;
    setState(() {
      _selectedIds
        ..clear()
        ..addAll([for (var i = first; i <= last; i++) _rows[i].id]);
    });
  }

  /// Moves the caret to the row above or below, the way an arrow key moves
  /// between the lines of one field.
  ///
  /// Every row is its own field, so without this the caret stops dead at the
  /// end of a line: the note reads as one piece of writing and has to be
  /// walked through as one. The caret only ever steps from the very edge of
  /// a row, so it lands at the near edge of the next one — the end of the
  /// row above, or the start of the row below. Images are stepped over
  /// rather than landed on, since there is nowhere in one to put a caret.
  bool _stepRow(_Row row, int delta) {
    var next = _indexOfId(row.id) + delta;
    while (next >= 0 && next < _rows.length && !_rows[next].block.isText) {
      next += delta;
    }
    if (next < 0 || next >= _rows.length) return false;

    final target = _rows[next];
    _clearRowSelection();
    target.focus?.requestFocus();
    target.controller!.selection = TextSelection.collapsed(
      offset: delta > 0 ? 0 : target.controller!.text.length,
    );
    return true;
  }

  /// Grows the selection by one row, the way shift and an arrow key do in a
  /// list. Starts one from the row the caret is in.
  void _extendRows(_Row row, int delta) {
    final anchor = _anchorId ?? row.id;
    final next = _indexOfId(_reachId ?? row.id) + delta;
    if (next < 0 || next >= _rows.length) return;

    _anchorId = anchor;
    _reachId = _rows[next].id;
    _selectRange(anchor, _reachId!);

    // Follow the selection with the caret, so a further shift-arrow keeps
    // going from the end it just reached. Focus is only asked for here, not
    // taken as a sign the person clicked away — that is what a tap is for.
    final target = _rows[next];
    if (target.block.isText) target.focus?.requestFocus();
  }

  /// Shift-clicking a handle reaches from wherever the caret was to that row.
  void _extendTo(_Row row) {
    final anchor = _anchorId ?? _activeId ?? row.id;
    _anchorId = anchor;
    _reachId = row.id;
    _selectRange(anchor, row.id);
  }

  /// Which row the pointer is over, by vertical position: a drag that strays
  /// past the end of a line is still a drag over that line.
  int? _rowIdAt(Offset position) {
    for (final row in _rows) {
      final box = row.boxKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;

      final top = box.localToGlobal(Offset.zero).dy;
      if (position.dy >= top && position.dy < top + box.size.height) {
        return row.id;
      }
    }
    return null;
  }

  /// Dragging from one line into another selects the lines between them.
  ///
  /// A pointer listener rather than a gesture: the field being dragged in has
  /// already claimed the gesture arena for its own text selection, and this
  /// has to see the same movement without taking it away.
  ///
  /// Mouse only. A touch drag on a note is a scroll, and taking that over
  /// would cost more than it gave; a phone selects across lines with shift
  /// and the arrow keys, or by reaching from a line's handle.
  void _onPointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    _dragFromId = _rowIdAt(event.position);
    _dragLeftItsRow = false;
  }

  void _onPointerMove(PointerMoveEvent event) {
    final from = _dragFromId;
    if (from == null || event.buttons & kPrimaryMouseButton == 0) return;

    final over = _rowIdAt(event.position);
    if (over == null) return;

    // Back inside the row it started in: hand selecting back to the field,
    // which is what a drag within one line should be.
    if (over == from) {
      if (_dragLeftItsRow) {
        _dragLeftItsRow = false;
        _clearRowSelection();
      }
      return;
    }

    _dragLeftItsRow = true;
    _anchorId = from;
    _reachId = over;
    _selectRange(from, over);
  }

  void _onPointerFinished(PointerEvent event) => _dragFromId = null;

  /// The selected rows, in the order they appear.
  Iterable<_Row> get _selectedRows =>
      _rows.where((row) => _selectedIds.contains(row.id));

  /// The markdown of the selected rows, which is what a copy puts on the
  /// clipboard — markdown, so pasting it anywhere else keeps the structure.
  String _selectionMarkdown() => NoteBlocks.serialize([
    for (final row in _selectedRows)
      row.block.isText
          ? row.block.copyWith(text: row.controller!.text)
          : row.block,
  ]);

  Future<void> copySelection({bool cut = false}) async {
    if (_selectedIds.isEmpty) return;

    await Clipboard.setData(ClipboardData(text: _selectionMarkdown()));
    if (cut) deleteSelection();
  }

  /// Removes the selected rows, leaving somewhere to type if that was all of
  /// them, and puts the caret where they were.
  void deleteSelection() {
    if (_selectedIds.isEmpty) return;

    final removed = _selectedRows.toList();
    final at = _indexOfId(removed.first.id);

    setState(() => _rows.removeWhere((row) => _selectedIds.contains(row.id)));
    for (final row in removed) {
      if (row.id == _activeId) _activeId = null;
      row.dispose();
    }
    _clearRowSelection();

    if (_rows.every((row) => !row.block.isText)) {
      setState(
        () => _rows.insert(
          at.clamp(0, _rows.length),
          _row(const NoteBlock.paragraph('')),
        ),
      );
    }

    final landing = _rows[(at - 1).clamp(0, _rows.length - 1)];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      landing.focus?.requestFocus();
    });
    _emit(structural: true);
  }

  /// Ctrl+A over a note of more than one line takes the whole note, rather
  /// than the one line the caret happens to be in. Returns false when there
  /// is nothing to do, so the field's own select-all still happens.
  bool selectAllRows() {
    if (_rows.length < 2) return false;

    _anchorId = _rows.first.id;
    _reachId = _rows.last.id;
    _selectRange(_rows.first.id, _rows.last.id);
    return true;
  }

  /// Applies a block type to the whole selection when [row] is part of one,
  /// and to that row alone otherwise.
  void _applyBlockType(_Row row, NoteBlock kind) {
    final selected = _selectedIds.contains(row.id)
        ? _rows.where((r) => _selectedIds.contains(r.id) && r.block.isText)
        : const Iterable<_Row>.empty();

    // A rule holds no text, so turning a run of lines into one would throw
    // the lines away. That stays a single-row change.
    if (selected.length < 2 || kind.type == NoteBlockType.divider) {
      _setBlockType(row, kind);
      return;
    }

    setState(() {
      for (final target in selected) {
        target.block = target.block.copyWith(
          type: kind.type,
          level: kind.level,
        );
      }
    });
    _emit(structural: true);
  }

  String get markdown => NoteBlocks.serialize([
    for (final row in _rows)
      row.block.isText
          ? row.block.copyWith(text: row.controller!.text)
          : row.block,
  ]);

  void _emit({bool structural = false}) {
    final current = markdown;
    widget.onChanged(current);
    if (_restoring) return;

    _historyTimer?.cancel();
    if (structural) {
      // Splitting, merging, changing a row's kind: worth a step of its own,
      // recorded at once so undo lands exactly before it.
      _history.record(current);
      setState(() {});
      return;
    }

    // Typing settles into one step per pause rather than one per keystroke.
    _historyTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      _history.record(markdown);
      setState(() {});
    });
  }

  /// Puts the note back to a recorded state, rebuilding the rows from it.
  void _restore(String? markdown) {
    if (markdown == null) return;

    _historyTimer?.cancel();
    _restoring = true;

    for (final row in _rows) {
      row.dispose();
    }
    _rows.clear();
    _activeId = null;

    for (final block in NoteBlocks.parse(markdown)) {
      _rows.add(_row(block));
    }
    if (_rows.every((row) => !row.block.isText)) {
      _rows.add(_row(const NoteBlock.paragraph('')));
    }

    setState(() {});
    widget.onChanged(markdown);
    _restoring = false;
  }

  void undo() => _restore(_history.undo());

  void redo() => _restore(_history.redo());

  int _indexOfId(int id) => _rows.indexWhere((row) => row.id == id);

  /// Turns a typed marker into the block it names, and `[[` into a link.
  void _onTextChanged(_Row row) {
    _clearRowSelection();
    final text = row.controller!.text;

    // A phone's keyboard sends Enter through the text connection rather than
    // as a key event, so the newline arrives here. Splitting on it is what
    // makes Return continue a list on Android as it does on a desktop.
    if (text.contains('\n')) {
      _splitOnNewline(row);
      return;
    }

    final shortcut = NoteBlocks.shortcutFor(row.block, text);

    if (shortcut != null) {
      setState(() => row.block = shortcut);
      // Drop the marker from the text now that the block itself carries it.
      row.controller!.value = TextEditingValue(
        text: shortcut.text,
        selection: TextSelection.collapsed(offset: shortcut.text.length),
      );
      _emit(structural: true);
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
        selection: TextSelection.collapsed(
          offset: before.length + insert.length,
        ),
      );
      row.focus?.requestFocus();
      _emit();
    });
  }

  /// Splits where a newline landed in the text, then removes it.
  void _splitOnNewline(_Row row) {
    final controller = row.controller!;
    final at = controller.text.indexOf('\n');

    final before = controller.text.substring(0, at);
    final after = controller.text.substring(at + 1);

    controller.value = TextEditingValue(
      text: before,
      selection: TextSelection.collapsed(offset: before.length),
    );
    _insertAfter(row, after);
  }

  /// Enter splits the block at the caret, as a new paragraph below.
  void _splitAt(_Row row) {
    final controller = row.controller!;
    final caret = controller.selection.baseOffset.clamp(
      0,
      controller.text.length,
    );
    final before = controller.text.substring(0, caret);
    final after = controller.text.substring(caret);

    controller.text = before;
    _insertAfter(row, after);
  }

  /// Adds a row below [row] carrying [text] and moves the caret into it.
  ///
  /// A list row continues the list at the same depth — a new bullet after a
  /// bullet, an unticked task after a task — and anything else starts a
  /// paragraph, which is what leaving a heading should do. An empty list row
  /// ends the list instead, the way every editor does it.
  void _insertAfter(_Row row, String text) {
    final continuing = row.block.isListRow && row.controller!.text.isNotEmpty;

    if (row.block.isListRow && row.controller!.text.isEmpty) {
      // Return on an empty list row drops out of the list.
      setState(() => row.block = const NoteBlock.paragraph(''));
      _emit(structural: true);
      return;
    }

    final next = _row(
      continuing
          ? row.block.copyWith(text: text, done: false)
          : NoteBlock(type: NoteBlockType.paragraph, text: text),
    );
    setState(() => _rows.insert(_indexOfId(row.id) + 1, next));

    // The new row's focus node only exists after it is built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      next.focus?.requestFocus();
      next.controller?.selection = const TextSelection.collapsed(offset: 0);
    });
    _emit(structural: true);
  }

  /// Tab and Shift+Tab nest a list row and lift it back out.
  void _nudgeIndent(_Row row, int delta) {
    if (!row.block.isListRow) return;
    setState(
      () => row.block = row.block.copyWith(
        indent: (row.block.indent + delta).clamp(0, 5),
      ),
    );
    row.focus?.requestFocus();
    _emit(structural: true);
  }

  void _toggleTask(_Row row) {
    setState(() => row.block = row.block.copyWith(done: !row.block.done));
    _emit(structural: true);
  }

  /// Backspace at the very start: first give a heading or bullet back its
  /// plain form, and only merge upwards once it is already a paragraph.
  bool _backspaceAtStart(_Row row) {
    if (row.block.type != NoteBlockType.paragraph) {
      setState(
        () => row.block = row.block.copyWith(
          type: NoteBlockType.paragraph,
          level: 1,
        ),
      );
      _emit(structural: true);
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
      _emit(structural: true);
      return true;
    }

    final joinAt = previous.controller!.text.length;
    previous.controller!.text =
        previous.controller!.text + row.controller!.text;

    setState(() => _rows.removeAt(index));
    row.dispose();

    previous.focus!.requestFocus();
    previous.controller!.selection = TextSelection.collapsed(offset: joinAt);
    _emit(structural: true);
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
    _emit(structural: true);
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
      _emit(structural: true);
      return;
    }

    setState(
      () => row.block = row.block.copyWith(type: kind.type, level: kind.level),
    );
    row.focus?.requestFocus();
    _emit(structural: true);
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
    _emit(structural: true);
  }

  @override
  Widget build(BuildContext context) {
    // A note is prose, so it gets a readable measure rather than running the
    // full width of a desktop window — but it sits against the left margin,
    // under the title, rather than floating in the middle of a wide one.
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerFinished,
          onPointerCancel: _onPointerFinished,
          child: _buildList(),
        ),
      ),
    );
  }

  Widget _buildList() {
    return ListView.builder(
      shrinkWrap: widget.shrinkWrap,
      physics: widget.shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      padding: widget.shrinkWrap
          ? const EdgeInsets.fromLTRB(16, 0, 0, 0)
          : const EdgeInsets.fromLTRB(16, 10, 16, 10),
      itemCount: _rows.length,
      itemBuilder: (context, index) => KeyedSubtree(
        key: _rows[index].boxKey,
        child: _buildRow(_rows[index]),
      ),
    );
  }

  Widget _buildRow(_Row row) {
    {
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
              // Only while there is nothing at all: a hint on the first of
              // several lines would be a label for the note.
              placeholder:
                  _rows.length == 1 && (row.controller?.text ?? "").isEmpty
                  ? widget.placeholder
                  : null,
              onChanged: () => _onTextChanged(row),
              onSplit: () => _splitAt(row),
              onBackspaceAtStart: () => _backspaceAtStart(row),
              selected: _selectedIds.contains(row.id),
              onSetType: (kind) => _applyBlockType(row, kind),
              onExtendRows: (delta) => _extendRows(row, delta),
              onStepRow: (delta) => _stepRow(row, delta),
              onExtendTo: () => _extendTo(row),
              onClearSelection: _clearRowSelection,
              onPaste: widget.onPaste,
              onCopySelection: copySelection,
              onDeleteSelection: deleteSelection,
              onSelectAllRows: selectAllRows,
              onMark: (mark) => _applyMark(row, mark),
              onClearMarks: () => _clearMarks(row),
              onIndent: (delta) => _nudgeIndent(row, delta),
              onToggleTask: () => _toggleTask(row),
              onRequestLink: widget.onRequestLink == null
                  ? null
                  : () async {
                      final snippet = await widget.onRequestLink!();
                      if (snippet != null) insertInline(snippet);
                    },
              onRequestImage: widget.onRequestImage,
            )
          : _ImageBlock(
              key: ValueKey(row.id),
              block: row.block,
              onOpenProject: widget.onOpenProject,
              onRemove: () => _removeRow(row),
            );
    }
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
    required this.onIndent,
    required this.onToggleTask,
    required this.selected,
    required this.onExtendRows,
    required this.onStepRow,
    required this.onExtendTo,
    required this.onClearSelection,
    required this.onCopySelection,
    required this.onDeleteSelection,
    required this.onSelectAllRows,
    this.onRequestLink,
    this.onRequestImage,
    this.onPaste,
    this.placeholder,
  });

  final _Row row;
  final String? placeholder;
  final VoidCallback onChanged;
  final VoidCallback onSplit;
  final bool Function() onBackspaceAtStart;
  final ValueChanged<NoteBlock> onSetType;
  final ValueChanged<InlineMark> onMark;
  final VoidCallback onClearMarks;
  final ValueChanged<int> onIndent;
  final VoidCallback onToggleTask;

  /// Whether this row is part of a run picked out for a block-type change.
  final bool selected;
  final ValueChanged<int> onExtendRows;

  /// Takes the caret to the row above or below. False when there is no row
  /// that way, so the key falls through.
  final bool Function(int delta) onStepRow;

  final VoidCallback onExtendTo;
  final VoidCallback onClearSelection;

  /// Copies the selected run of rows as markdown, cutting it if asked.
  final Future<void> Function({bool cut}) onCopySelection;
  final VoidCallback onDeleteSelection;

  /// Takes the whole note. False when there is only one row, so the field's
  /// own select-all is left to happen.
  final bool Function() onSelectAllRows;
  final Future<void> Function()? onRequestLink;
  final Future<void> Function()? onRequestImage;

  /// Replaces the menu's own Paste when the note can take an image.
  final Future<void> Function()? onPaste;

  TextStyle _styleFor(ThemeData theme) {
    // The same scale the rendered note uses, so a heading does not change
    // size the moment you stop editing it.
    final style = switch (row.block.type) {
      NoteBlockType.heading => NoteTypography.heading(theme, row.block.level),
      _ => NoteTypography.body(theme),
    };

    if (row.block.type == NoteBlockType.task && row.block.done) {
      return style.copyWith(
        decoration: TextDecoration.lineThrough,
        color: theme.colorScheme.outline,
      );
    }
    return style;
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

    final control =
        HardwareKeyboard.instance.isControlPressed ||
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
      if (event.logicalKey == LogicalKeyboardKey.keyT) {
        onSetType(const NoteBlock.task(''));
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.minus) {
        onSetType(const NoteBlock.divider());
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyA && onSelectAllRows()) {
        return KeyEventResult.handled;
      }
      // Copy and cut belong to the run of rows while there is one, or the
      // field would answer with the one line the caret is in.
      if (selected) {
        if (event.logicalKey == LogicalKeyboardKey.keyC) {
          onCopySelection();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.keyX) {
          onCopySelection(cut: true);
          return KeyEventResult.handled;
        }
      }
    }

    // Backspace or delete over a selected run takes the run, the way it takes
    // selected text anywhere else.
    if (selected &&
        (event.logicalKey == LogicalKeyboardKey.backspace ||
            event.logicalKey == LogicalKeyboardKey.delete)) {
      onDeleteSelection();
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      onClearSelection();
      return KeyEventResult.handled;
    }

    // Shift and an arrow key select whole rows, but only once the caret has
    // run out of text to select in this one — so shift-selecting inside a
    // wrapped paragraph still works the way it does anywhere else.
    if (HardwareKeyboard.instance.isShiftPressed) {
      final down = event.logicalKey == LogicalKeyboardKey.arrowDown;
      final up = event.logicalKey == LogicalKeyboardKey.arrowUp;
      if (down || up) {
        final selection = row.controller!.selection;
        final atEdge =
            selected ||
            (down && selection.extentOffset >= row.controller!.text.length) ||
            (up && selection.extentOffset <= 0);
        if (atEdge) {
          onExtendRows(down ? 1 : -1);
          return KeyEventResult.handled;
        }
      }
    }

    // A plain arrow key runs off the end of a row into the next one. The
    // field moves the caret within its own wrapped lines first and only parks
    // it at the very edge once there is nowhere left to go, so testing the
    // edge is enough to tell "next visual line" from "next row".
    {
      final down = event.logicalKey == LogicalKeyboardKey.arrowDown;
      final up = event.logicalKey == LogicalKeyboardKey.arrowUp;
      if ((down || up) && !HardwareKeyboard.instance.isShiftPressed) {
        final selection = row.controller!.selection;
        final text = row.controller!.text;
        final atEdge =
            selection.isCollapsed &&
            (down
                ? selection.extentOffset >= text.length
                : selection.extentOffset <= 0);
        if (atEdge && onStepRow(down ? 1 : -1)) {
          return KeyEventResult.handled;
        }
      }
    }

    if (event.logicalKey == LogicalKeyboardKey.tab) {
      onIndent(HardwareKeyboard.instance.isShiftPressed ? -1 : 1);
      return KeyEventResult.handled;
    }

    final enter =
        event.logicalKey == LogicalKeyboardKey.enter ||
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
    return _RowReveal(focus: row.focus, builder: _buildRow);
  }

  Widget _buildRow(BuildContext context, bool revealed) {
    final theme = Theme.of(context);
    final block = row.block;

    final style = _styleFor(theme);

    // Every marker beside the text — the handle, a bullet, a checkbox — is
    // centred on a box exactly one line tall, so they all sit on the first
    // line of the text instead of each being nudged into place by hand.
    final lineHeight = (style.fontSize ?? 14) * (style.height ?? 1.4);

    return Container(
      decoration: selected
          ? BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            )
          : null,
      padding: EdgeInsets.only(
        top: block.type == NoteBlockType.heading
            ? NoteTypography.spaceAbove(block.level)
            : 1,
        bottom: 1,
        // Each nesting level steps the whole row across, marker included.
        left: block.indent * 20,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ParagraphButton(
            row: row,
            onSetType: onSetType,
            onExtendTo: onExtendTo,
            lineHeight: lineHeight,
            // A selected row keeps its handle showing, so a run of them reads
            // as one thing rather than a gap with one mark in it.
            revealed: revealed || selected,
          ),
          if (block.type == NoteBlockType.bullet)
            SizedBox(
              width: 18,
              height: lineHeight,
              child: Center(
                child: Icon(
                  block.indent.isEven ? Icons.circle : Icons.circle_outlined,
                  size: 5,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (block.type == NoteBlockType.task)
            SizedBox(
              width: 28,
              height: lineHeight,
              child: Center(
                child: Checkbox(
                  value: block.done,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (_) => onToggleTask(),
                ),
              ),
            ),
          Expanded(
            child: Focus(
              onKeyEvent: _onKey,
              child: TextField(
                controller: row.controller,
                focusNode: row.focus,
                style: style,
                maxLines: null,
                // Enter is intercepted above to split the block, so the field
                // itself never needs to insert a newline.
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                onTap: onClearSelection,
                decoration: InputDecoration(
                  isDense: true,
                  filled: false,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: row.block.type == NoteBlockType.heading
                      ? 'Heading'
                      : placeholder,
                ),
                // The formatting toolbar rides on the selection toolbar, so
                // it appears at the selection and is positioned by Flutter
                // rather than guessed at.
                contextMenuBuilder: (context, editable) {
                  return AdaptiveTextSelectionToolbar.buttonItems(
                    anchors: editable.contextMenuAnchors,
                    buttonItems: [
                      // First, and only while a run is selected: the field's
                      // own Copy would answer with this line alone.
                      if (selected) ...[
                        ContextMenuButtonItem(
                          label: 'Copy lines',
                          onPressed: () {
                            ContextMenuController.removeAny();
                            onCopySelection();
                          },
                        ),
                        ContextMenuButtonItem(
                          label: 'Cut lines',
                          onPressed: () {
                            ContextMenuController.removeAny();
                            onCopySelection(cut: true);
                          },
                        ),
                        ContextMenuButtonItem(
                          label: 'Delete lines',
                          onPressed: () {
                            ContextMenuController.removeAny();
                            onDeleteSelection();
                          },
                        ),
                      ],
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
                      // Beside Link, because attaching a picture is the same
                      // kind of thing as attaching a link and was reachable
                      // only from the full editor's toolbar — which on a
                      // phone means opening the note properly first.
                      if (onRequestImage != null)
                        ContextMenuButtonItem(
                          label: 'Image',
                          onPressed: () {
                            ContextMenuController.removeAny();
                            onRequestImage!();
                          },
                        ),
                      ContextMenuButtonItem(
                        label: 'Clear',
                        onPressed: () {
                          ContextMenuController.removeAny();
                          onClearMarks();
                        },
                      ),
                      // The menu's own items, with Paste redirected when the
                      // note can take an image: the field's paste would put
                      // the text on the clipboard in and ignore a picture.
                      for (final item in editable.contextMenuButtonItems)
                        if (item.type == ContextMenuButtonType.paste &&
                            onPaste != null)
                          ContextMenuButtonItem(
                            label: item.label,
                            type: item.type,
                            onPressed: () {
                              ContextMenuController.removeAny();
                              onPaste!();
                            },
                          )
                        else
                          item,
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

/// Gives a row the hover and focus state its handle needs.
///
/// A wrapper rather than making the whole block stateful, so hovering rebuilds
/// one row and nothing else.
class _RowReveal extends StatefulWidget {
  const _RowReveal({required this.focus, required this.builder});

  final FocusNode? focus;
  final Widget Function(BuildContext context, bool revealed) builder;

  @override
  State<_RowReveal> createState() => _RowRevealState();
}

class _RowRevealState extends State<_RowReveal> {
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    widget.focus?.addListener(_onFocus);
  }

  @override
  void dispose() {
    widget.focus?.removeListener(_onFocus);
    super.dispose();
  }

  void _onFocus() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      // The caret being in a row counts as reaching for it, so the handle is
      // there for the block you are actually editing.
      child: widget.builder(
        context,
        _hovered || (widget.focus?.hasFocus ?? false),
      ),
    );
  }
}

/// The ¶ handle beside a block, which opens the block-type menu.
///
/// It keeps its space whether or not it is shown, so revealing it on hover
/// does not shuffle the text sideways.
class _ParagraphButton extends StatelessWidget {
  const _ParagraphButton({
    required this.row,
    required this.onSetType,
    required this.onExtendTo,
    required this.lineHeight,
    required this.revealed,
  });

  final _Row row;
  final ValueChanged<NoteBlock> onSetType;
  final VoidCallback onExtendTo;
  final double lineHeight;
  final bool revealed;

  /// Headings say which level they are; everything else shows the same
  /// handle. A bullet used to show a dot here, which read as a second bullet
  /// beside the real one.
  String get _label =>
      row.block.type == NoteBlockType.heading ? 'H${row.block.level}' : '¶';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AnimatedOpacity(
      opacity: revealed ? 1 : 0,
      duration: const Duration(milliseconds: 120),
      child: Builder(
        builder: (buttonContext) => InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () async {
            // Shift and a handle reaches from wherever you were down to here,
            // the way shift-clicking a list does.
            if (HardwareKeyboard.instance.isShiftPressed) {
              onExtendTo();
              return;
            }

            final box = buttonContext.findRenderObject() as RenderBox?;
            if (box == null) return;

            final kind = await showBlockTypeMenu(
              buttonContext,
              box.localToGlobal(box.size.bottomLeft(Offset.zero)),
            );
            if (kind != null) onSetType(kind);
          },
          child: SizedBox(
            // Narrower under a finger. It is the gutter down the left of
            // every note, and on a phone that width is a word a line.
            width: TouchInput.isPrimary ? 14 : 24,
            height: lineHeight,
            child: Center(
              child: Text(
                _label,
                style: theme.textTheme.labelSmall?.copyWith(
                  // Quiet enough to ignore while reading, close enough to
                  // reach for. The screenshot had these shouting.
                  color: theme.colorScheme.outlineVariant,
                  fontWeight: FontWeight.w600,
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
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(left: 24, top: 8, bottom: 8),
      child: Align(
        // Without this the image floated to the right: a Stack aligns its
        // non-positioned children too, so topRight moved the picture as well
        // as the button.
        alignment: Alignment.centerLeft,
        child: Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              // Reuses the note renderer, so an image resolves from the
              // same attachment cache here as in a rendered note.
              child: NoteView(
                markdown: '![${block.imageAlt}](${block.imagePath})',
                selectable: false,
                onOpenProject: onOpenProject,
                // Scaled down to fit rather than cut off at the bottom: a
                // tall photograph should still read as the whole
                // photograph while it is being written around.
                maxImageHeight: 340,
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: Material(
                color: theme.colorScheme.surface.withValues(alpha: 0.85),
                shape: const CircleBorder(),
                child: IconButton(
                  tooltip: 'Remove image',
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close),
                  onPressed: onRemove,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
