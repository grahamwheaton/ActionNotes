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
