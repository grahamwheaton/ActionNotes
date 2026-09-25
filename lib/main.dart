import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'state/app_state.dart';
import 'storage/update_check.dart';
import 'storage/windows_updater.dart';
import 'ui/home_shell.dart';
import 'ui/theme.dart';

void main(List<String> arguments) {
  runApp(ActionNotesApp(arguments: arguments));
}

class ActionNotesApp extends StatefulWidget {
  const ActionNotesApp({super.key, this.arguments = const []});

  final List<String> arguments;

  @override
  State<ActionNotesApp> createState() => _ActionNotesAppState();
}

class _ActionNotesAppState extends State<ActionNotesApp>
    with WidgetsBindingObserver {
  late final AppState _state = AppState(updateCheck: UpdateCheck());
  final _navigator = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    final loaded = _state.init();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await loaded;
        final marker = WindowsUpdater.launchMarker(
          widget.arguments,
          '--update-ready',
        );
        if (marker != null) await marker.writeAsString('started', flush: true);
        final error = WindowsUpdater.launchMarker(
          widget.arguments,
          '--update-error',
        );
        if (error != null && await error.exists() && mounted) {
          final message = await error.readAsString();
          final context = _navigator.currentContext;
          if (context != null && context.mounted) {
            unawaited(
              showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Update could not be completed'),
                  content: Text(message),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('OK'),
                    ),
                  ],
                ),
              ),
            );
          }
        }
      } on Object {
        // No acknowledgement means the updater can restore the old bundle.
      }
    });
    WidgetsBinding.instance.addObserver(this);
    _state.startWatching();
    // Once, on start: often enough to stop a build going stale for weeks,
    // rarely enough that it is not a request per launch of the window.
    _state.checkForUpdate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Coming back to the app syncs at once and starts looking again; leaving it
  /// stops, so nothing polls GitHub from a pocket.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _state.sync();
      _state.startWatching();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _state.stopWatching();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _state,
      // Watches rather than reads: choosing light or dark in Settings has to
      // reach the MaterialApp, which is above every screen.
      child: Consumer<AppState>(
        builder: (context, state, _) => MaterialApp(
          title: 'ActionNotes',
          navigatorKey: _navigator,
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: state.themeMode,
          home: const HomeShell(),
        ),
      ),
    );
  }
}
