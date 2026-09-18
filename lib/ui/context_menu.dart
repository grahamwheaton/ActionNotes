import 'package:flutter/material.dart';

class ContextMenuAction {
  const ContextMenuAction({
    required this.label,
    required this.icon,
    required this.onSelected,
    this.destructive = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onSelected;
  final bool destructive;
}

/// Shows the actions as a menu at a point on the screen.
///
/// Shared so that a right-click, a long-press and a button all open the same
/// menu — the phone reaches it from a button, because long-press is what picks
/// a row up to move it there.
Future<void> showItemMenu(
  BuildContext context,
  List<ContextMenuAction> actions,
  Offset globalPosition,
) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (overlay == null) return;

  final selected = await showMenu<ContextMenuAction>(
    context: context,
    position: RelativeRect.fromLTRB(
      globalPosition.dx,
      globalPosition.dy,
      overlay.size.width - globalPosition.dx,
      overlay.size.height - globalPosition.dy,
    ),
    items: [
      for (final action in actions)
        PopupMenuItem<ContextMenuAction>(
          value: action,
          child: _ActionRow(action: action),
        ),
    ],
  );

  selected?.onSelected();
}

/// Opens a menu on right-click, and on long-press where nothing else wants it.
///
/// The menu is positioned at the pointer rather than at the widget, which is
/// what a right-click is expected to do on the desktop.
class ItemContextMenu extends StatelessWidget {
  const ItemContextMenu({
    super.key,
    required this.child,
    required this.actions,
    this.longPress = true,
  });

  final Widget child;
  final List<ContextMenuAction> actions;

  /// Whether a long-press opens the menu. Off where long-press already means
  /// something — picking a row up to move it — and the menu is on a button
  /// instead, since one gesture cannot do both.
  final bool longPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (details) =>
          showItemMenu(context, actions, details.globalPosition),
      onLongPressStart: longPress
          ? (details) => showItemMenu(context, actions, details.globalPosition)
          : null,
      child: child,
    );
  }
}

/// The same menu, on a button, for where long-press is not free.
class ItemMenuButton extends StatelessWidget {
  const ItemMenuButton({super.key, required this.actions, this.tooltip});

  final List<ContextMenuAction> actions;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return IconButton(
      tooltip: tooltip ?? 'More',
      visualDensity: VisualDensity.compact,
      icon: Icon(Icons.more_vert, size: 20, color: theme.colorScheme.outline),
      onPressed: () {
        // Anchored under the button rather than at the tap, so the menu opens
        // where the thing that opened it is.
        final box = context.findRenderObject() as RenderBox?;
        final at = box == null
            ? Offset.zero
            : box.localToGlobal(Offset(0, box.size.height));
        showItemMenu(context, actions, at);
      },
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.action});

  final ContextMenuAction action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = action.destructive ? theme.colorScheme.error : null;

    return Row(
      children: [
        Icon(action.icon, size: 18, color: color),
        const SizedBox(width: 12),
        Text(action.label, style: TextStyle(color: color)),
      ],
    );
  }
}
