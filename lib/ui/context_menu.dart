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

/// Opens a menu on right-click (and on long-press, so the same rows work by
/// touch on Android).
///
/// The menu is positioned at the pointer rather than at the widget, which is
/// what a right-click is expected to do on the desktop.
class ItemContextMenu extends StatelessWidget {
  const ItemContextMenu({
    super.key,
    required this.child,
    required this.actions,
  });

  final Widget child;
  final List<ContextMenuAction> actions;

  Future<void> _open(BuildContext context, Offset globalPosition) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
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

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (details) => _open(context, details.globalPosition),
      onLongPressStart: (details) => _open(context, details.globalPosition),
      child: child,
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
