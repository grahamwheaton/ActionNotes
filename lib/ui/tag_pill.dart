import 'package:flutter/material.dart';

import '../markdown/item_tags.dart';
import 'search_screen.dart';

/// One tag, as a pill. Tapping it searches for everything carrying it.
class TagPill extends StatelessWidget {
  const TagPill({super.key, required this.tag, required this.faded});

  final String tag;
  final bool faded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme.labelSmall;

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => SearchScreen.open(context, query: ItemTags.marker(tag)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer.withValues(alpha: faded ? 0.4 : 1),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          tag,
          style: text?.copyWith(
            color: faded
                ? scheme.onSecondaryContainer.withValues(alpha: 0.6)
                : scheme.onSecondaryContainer,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// Says an item is waiting on someone — usually a model that has been asked
/// to pick it up. Tapping it finds everything waiting on that name.
class WaitingPill extends StatelessWidget {
  const WaitingPill({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme.labelSmall;

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => SearchScreen.open(context, query: '@$name'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: scheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.schedule,
              size: 11,
              color: scheme.onTertiaryContainer,
            ),
            const SizedBox(width: 4),
            Text(
              '@$name',
              style: text?.copyWith(
                color: scheme.onTertiaryContainer,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
