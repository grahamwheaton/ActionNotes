import 'package:flutter/material.dart';

/// A one-field dialog that owns its controller.
///
/// The controller has to live and die with the dialog's own State: disposing it
/// on the caller's side the moment `showDialog` returns tears it down while the
/// dialog is still animating out, and the TextField then reads a dead
/// controller.
class TextPromptDialog extends StatefulWidget {
  const TextPromptDialog({
    super.key,
    required this.title,
    this.initialValue = '',
    this.hintText,
    this.confirmLabel = 'Save',
    this.maxLines = 1,
    this.minLines,
  });

  final String title;
  final String initialValue;
  final String? hintText;
  final String confirmLabel;
  final int maxLines;
  final int? minLines;

  /// Returns the trimmed text, or null if cancelled or left empty.
  static Future<String?> show(
    BuildContext context, {
    required String title,
    String initialValue = '',
    String? hintText,
    String confirmLabel = 'Save',
    int maxLines = 1,
    int? minLines,
    bool allowEmpty = false,
  }) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => TextPromptDialog(
        title: title,
        initialValue: initialValue,
        hintText: hintText,
        confirmLabel: confirmLabel,
        maxLines: maxLines,
        minLines: minLines,
      ),
    );

    if (result == null) return null;
    final trimmed = result.trim();
    return (trimmed.isEmpty && !allowEmpty) ? null : trimmed;
  }

  @override
  State<TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<TextPromptDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: widget.maxLines,
        minLines: widget.minLines,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(hintText: widget.hintText),
        onSubmitted: widget.maxLines == 1 ? (_) => _submit() : null,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}
