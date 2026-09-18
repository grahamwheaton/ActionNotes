import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/app_state.dart';
import '../storage/update_check.dart';

/// Offers the newer release when there is one.
///
/// A link rather than a silent install: Android will not install a package
/// without the person agreeing, and an unsigned build cannot replace a
/// differently signed one at all — so the honest thing is to make the
/// download one tap instead of a trip to GitHub.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  Future<void> _open(BuildContext context, AvailableUpdate update) async {
    final messenger = ScaffoldMessenger.of(context);
    final target = update.downloadUrl ?? update.pageUrl;

    final opened = await launchUrl(
      Uri.parse(target),
      mode: LaunchMode.externalApplication,
    );
    if (!opened) {
      messenger.showSnackBar(SnackBar(content: Text('Open $target')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final update = context.watch<AppState>().update;
    if (update == null) return const SizedBox.shrink();

    return Material(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(
              Icons.system_update_alt,
              size: 18,
              color: theme.colorScheme.onSecondaryContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Version ${update.version} is out.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
            TextButton(
              onPressed: () => _open(context, update),
              child: Text(update.downloadUrl == null ? 'Open' : 'Download'),
            ),
            IconButton(
              tooltip: 'Not now',
              iconSize: 18,
              icon: const Icon(Icons.close),
              onPressed: context.read<AppState>().dismissUpdate,
            ),
          ],
        ),
      ),
    );
  }
}
