import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

/// When the app last heard from GitHub.
///
/// Ticks on its own, because the answer changes with time rather than with
/// anything the app does: without it the label would say "just now" for as
/// long as nothing else happened to rebuild it.
class SyncStatus extends StatefulWidget {
  const SyncStatus({super.key});

  @override
  State<SyncStatus> createState() => _SyncStatusState();
}

/// How long ago, in the roundest terms that are still true. Free-standing so
/// it can be tested without pumping a widget.
String syncAgo(DateTime then, {DateTime? now}) {
  final seconds = (now ?? DateTime.now()).difference(then).inSeconds;
  if (seconds < 45) return 'just now';
  if (seconds < 90) return 'a minute ago';
  if (seconds < 3600) return '${(seconds / 60).round()} minutes ago';
  if (seconds < 5400) return 'an hour ago';
  if (seconds < 86400) return '${(seconds / 3600).round()} hours ago';
  if (seconds < 172800) return 'yesterday';
  return '${(seconds / 86400).round()} days ago';
}

class _SyncStatusState extends State<SyncStatus> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(
      const Duration(seconds: 20),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<AppState>();

    final label = switch ((state.syncing, state.lastSynced)) {
      (true, _) => 'Syncing...',
      (false, null) when !state.isConfigured => 'Not connected',
      (false, null) => 'Not synced yet',
      (false, final DateTime at) => 'Synced ${syncAgo(at)}',
    };

    final pending = state.pendingCount;

    return Text(
      pending == 0
          ? label
          : '$label · $pending ${pending == 1 ? 'edit' : 'edits'} to push',
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
