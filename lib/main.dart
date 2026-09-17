import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'state/app_state.dart';
import 'ui/home_shell.dart';
import 'ui/theme.dart';

void main() {
  runApp(const ActionNotesApp());
}

class ActionNotesApp extends StatefulWidget {
  const ActionNotesApp({super.key});

  @override
  State<ActionNotesApp> createState() => _ActionNotesAppState();
}

class _ActionNotesAppState extends State<ActionNotesApp>
    with WidgetsBindingObserver {
  late final AppState _state = AppState()..init();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _state.startWatching();
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
