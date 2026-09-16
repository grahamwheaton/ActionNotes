import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'state/app_state.dart';
import 'ui/home_shell.dart';
import 'ui/theme.dart';

void main() {
  runApp(const ActionNotesApp());
}

class ActionNotesApp extends StatelessWidget {
  const ActionNotesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState()..init(),
      child: MaterialApp(
        title: 'ActionNotes',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        home: const HomeShell(),
      ),
    );
  }
}
