import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/app_state.dart';
import '../storage/update_check.dart';
import '../storage/update_installer.dart';

/// Offers the newer release when there is one.
///
/// Where the system can install the file — Android — this fetches it and
/// hands it over, so the update is one tap here and then Android's own
/// "update this app?" prompt. That prompt cannot be skipped and should not
/// be: Android will not replace an installed app without the person agreeing.
///
/// Everywhere else it is still a link. The Windows release is a zip to unpack
/// wherever you keep it, which is not something an app can do to itself while
/// it is running, so opening the download is the honest offer there.
class UpdateBanner extends StatefulWidget {
  const UpdateBanner({super.key, this.installer});

  /// Injectable so a test can drive the download without a network or a
  /// package installer.
  final UpdateInstaller? installer;

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> {
  late final UpdateInstaller _installer = widget.installer ?? UpdateInstaller();

  /// How far the download has got, or null when none is running.
  double? _progress;

  bool get _canInstall =>
      (widget.installer != null || UpdateInstaller.supportedHere);

  Future<void> _open(AvailableUpdate update) async {
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

  Future<void> _install(AvailableUpdate update) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _progress = 0);

    final file = await _installer.fetch(
      update,
      onProgress: (progress) {
        if (mounted) setState(() => _progress = progress);
      },
    );

    if (file == null) {
      if (!mounted) return;
      setState(() => _progress = null);
      // Not a dead end: the release page still works, so say what happened
      // and leave the other way open rather than only apologising.
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not download the update.')),
      );
      return;
    }

    final handed = await _installer.install(file);
    if (!mounted) return;
    setState(() => _progress = null);

    if (!handed) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not open the downloaded update.')),
      );
      return;
    }
    // Android takes it from here. The banner stays until the new build
    // actually runs, because an update offered and not taken is still an
    // update waiting.
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final update = context.watch<AppState>().update;
    if (update == null) return const SizedBox.shrink();

    final installs = _canInstall && update.downloadUrl != null;
    final busy = _progress != null;

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
                busy
                    // A percentage rather than a spinner, because an APK is
                    // sixty megabytes and "working…" says nothing about
                    // whether it is worth waiting for.
                    ? 'Downloading ${update.version}… '
                          '${(_progress! * 100).round()}%'
                    : 'Version ${update.version} is out.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
            if (busy)
              SizedBox(
                width: 18,
                height: 18,
                // Always determinate, even at nothing: a ring that spins
                // for ever says "something is happening" where the number
                // beside it already says how much.
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: _progress,
                ),
              )
            else
              TextButton(
                onPressed: () => installs ? _install(update) : _open(update),
                child: Text(
                  installs
                      ? 'Install'
                      : update.downloadUrl == null
                      ? 'Open'
                      : 'Download',
                ),
              ),
            IconButton(
              tooltip: 'Not now',
              iconSize: 18,
              icon: const Icon(Icons.close),
              onPressed: busy ? null : context.read<AppState>().dismissUpdate,
            ),
          ],
        ),
      ),
    );
  }
}
