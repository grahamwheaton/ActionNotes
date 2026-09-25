import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/app_state.dart';
import '../storage/update_check.dart';
import '../storage/update_installer.dart';

/// Installs on Android, or verifies, saves and restarts into a Windows update.
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
        SnackBar(
          content: Text(
            _installer.lastError ?? 'Could not download the update.',
          ),
          action: SnackBarAction(
            label: 'Release page',
            onPressed: () => _openPage(update),
          ),
        ),
      );
      return;
    }

    if (!mounted) return;
    final state = context.read<AppState>();
    final navigator = Navigator.of(context, rootNavigator: true);
    DialogRoute<void>? saving;
    var handed = false;
    String? problem;
    try {
      if (_installer.restartsApp) {
        FocusManager.instance.primaryFocus?.unfocus();
        saving = DialogRoute<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => const PopScope(
            canPop: false,
            child: AlertDialog(
              title: Text('Preparing update'),
              content: Row(
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 16),
                  Expanded(
                    child: Text('Saving your notes and preparing to restart…'),
                  ),
                ],
              ),
            ),
          ),
        );
        unawaited(navigator.push(saving));
        await state.prepareForUpdate();
      }
      handed = await _installer.install(file);
      if (!handed) problem = _installer.lastError;
    } catch (_) {
      problem =
          'Your notes could not finish saving. The app has stayed open. '
          'Please try the update again.';
    } finally {
      if (saving != null) {
        state.resumeAfterUpdate();
        navigator.removeRoute(saving);
      }
    }
    if (!mounted) return;
    setState(() => _progress = null);
    if (!handed) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(problem ?? 'Could not open the downloaded update.'),
          action: SnackBarAction(
            label: 'Release page',
            onPressed: () => _openPage(update),
          ),
        ),
      );
    }
  }

  Future<void> _openPage(AvailableUpdate update) => launchUrl(
    Uri.parse(update.pageUrl),
    mode: LaunchMode.externalApplication,
  ).then((_) {});

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
                      ? (_installer.restartsApp
                            ? 'Update and restart'
                            : 'Install')
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
