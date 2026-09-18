import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One keyboard shortcut, and what it does.
class Shortcut {
  const Shortcut(this.keys, this.description);

  /// As it would be pressed, e.g. `Ctrl+K`.
  final String keys;
  final String description;
}

/// A group of shortcuts and where they apply.
class ShortcutGroup {
  const ShortcutGroup(this.where, this.shortcuts);

  final String where;
  final List<Shortcut> shortcuts;
}

/// Every shortcut the app has, in one place.
///
/// The sheet is built from this list, so a shortcut added here shows up
/// without anyone remembering to write it down twice. The app-level ones are
/// registered from it too; the editors register their own, because a binding
/// that only exists while a note is open belongs with the note.
const shortcutGroups = [
  ShortcutGroup('Anywhere', [
    Shortcut('Ctrl+K', 'Search across every project'),
    Shortcut('Ctrl+/ or ?', 'This list'),
    Shortcut('Click an image', 'Open it full size; right-click for more'),
    Shortcut('Star button', 'Everything starred, from every project'),
  ]),
  ShortcutGroup('A checklist', [
    Shortcut('Enter', 'Add the item you have typed'),
    Shortcut('Ctrl+Enter', 'Add it starred'),
    Shortcut('Alt+click a notes marker', "Open or close every item's notes"),
    Shortcut('Right-click an item', 'Star, notes, rename, move, delete'),
  ]),
  ShortcutGroup('A note', [
    Shortcut('# , ## , ###', 'Heading, as you type the marker'),
    Shortcut('- ', 'Bullet'),
    Shortcut('- [ ] ', 'Checkbox'),
    Shortcut('[[', 'Link to another project'),
    Shortcut('Tab / Shift+Tab', 'Nest a list row, or lift it out'),
    Shortcut('Ctrl+0 to Ctrl+6', 'Paragraph, or heading 1 to 6'),
    Shortcut('Ctrl+L', 'Bullet'),
    Shortcut('Ctrl+T', 'Checkbox'),
    Shortcut('Ctrl+-', 'Horizontal line'),
    Shortcut('Ctrl+B / Ctrl+I', 'Bold, italic'),
    Shortcut('Ctrl+V', 'Paste, including an image'),
    Shortcut('Ctrl+Z / Ctrl+Shift+Z', 'Undo, redo'),
  ]),
  ShortcutGroup('Across lines in a note', [
    Shortcut('Drag, or Shift+↑ / ↓', 'Select whole lines'),
    Shortcut('Ctrl+A', 'Select the whole note'),
    Shortcut('Ctrl+C / Ctrl+X', 'Copy or cut the lines as markdown'),
    Shortcut('Backspace', 'Remove the selected lines'),
  ]),
];

/// Shows the shortcuts. Opened with `?` or from the sidebar's menu.
Future<void> showShortcutsSheet(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _ShortcutsDialog(),
  );
}

/// Both ways in. `?` is shift and the slash key, which is how a keyboard
/// sends it; Ctrl+/ is there because `?` is also an ordinary character, and a
/// shortcut that cannot be typed by accident is the one to rely on.
const shortcutsSheetActivators = [
  SingleActivator(LogicalKeyboardKey.slash, control: true),
  SingleActivator(LogicalKeyboardKey.slash, shift: true),
];

class _ShortcutsDialog extends StatelessWidget {
  const _ShortcutsDialog();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Keyboard shortcuts'),
      content: SizedBox(
        width: 460,
        height: 520,
        child: ListView(
          children: [
            for (final group in shortcutGroups) ...[
              Padding(
                padding: const EdgeInsets.only(top: 14, bottom: 6),
                child: Text(
                  group.where,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              for (final shortcut in group.shortcuts)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 168,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            shortcut.keys,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          shortcut.description,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
