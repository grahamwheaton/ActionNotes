import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'state/app_state.dart';
import 'markdown/feed_days.dart';
import 'models/project.dart';
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
  StreamSubscription<List<SharedMediaFile>>? _incomingShares;
  late final Future<void> _loaded;
  bool _handlingShare = false;

  @override
  void initState() {
    super.initState();
    _loaded = _state.init();
    if (Platform.isAndroid) {
      _incomingShares = ReceiveSharingIntent.instance.getMediaStream().listen(
        (files) => unawaited(_receiveImages(files)),
      );
      unawaited(ReceiveSharingIntent.instance.getInitialMedia().then(
        _receiveImages,
      ));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await _loaded;
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
    _incomingShares?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _receiveImages(List<SharedMediaFile> files) async {
    final images = files.where((file) => file.type == SharedMediaType.image).toList();
    if (images.isEmpty || _handlingShare) return;
    _handlingShare = true;
    try {
      await _loaded;
      await WidgetsBinding.instance.endOfFrame;
      final context = _navigator.currentContext;
      if (!mounted || context == null || !context.mounted) return;
      final project = await showDialog<String>(
        context: context,
        builder: (dialog) => SimpleDialog(
          title: const Text('Add shared photos to project'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialog, '__daily__'),
              child: const Text('Daily note'),
            ),
            for (final project in _state.projects)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(dialog, project.slug),
                child: Text(project.title),
              ),
          ],
        ),
      );
      if (project == null || !context.mounted) return;
      var destination = project;
      if (project == '__daily__') {
        var daily = _state.projectBySlug('daily-note');
        daily ??= await _state.createProject('Daily note');
        if (daily.mode != ProjectMode.feed) {
          await _state.setMode(daily.slug, ProjectMode.feed);
        }
        destination = daily.slug;
        final today = FeedDays.titleFor(DateTime.now());
        await _state.addBlock(destination, today);
        await _state.addItem(destination, 'Shared photo', block: today);
      }
      final selected = _state.projectBySlug(destination);
      if (selected == null) return;
      final index = project == '__daily__' ? selected.items.indexWhere(
        (item) => item.text == 'Shared photo' &&
            item.block == FeedDays.titleFor(DateTime.now()),
      ) : await showDialog<int>(
        context: context,
        builder: (dialog) => SimpleDialog(
          title: const Text('Where should they go?'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialog, -1),
              child: const Text('Project notes'),
            ),
            for (var i = 0; i < selected.items.length; i++)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(dialog, i),
                child: Text(selected.items[i].title),
              ),
          ],
        ),
      );
      if (index == null) return;
      final references = <String>[];
      for (final image in images) {
        final file = File(image.path);
        final reference = await _state.attachImage(destination,
          fileName: file.uri.pathSegments.last,
          bytes: await file.readAsBytes(),
        );
        if (reference != null) references.add(reference);
      }
      if (references.isEmpty) return;
      final addition = references.join('\n\n');
      if (index < 0) {
        await _state.setNotes(destination,
          [selected.notes, addition].where((part) => part.trim().isNotEmpty).join('\n\n'));
      } else {
        final note = _state.projectBySlug(destination)?.items.elementAtOrNull(index);
        if (note == null) return;
        await _state.setItemNotes(destination, index,
          [note.notes, addition].where((part) => part.trim().isNotEmpty).join('\n\n'));
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Added ${references.length} photo${references.length == 1 ? '' : 's'}'),
        ));
      }
    } finally {
      _handlingShare = false;
      await ReceiveSharingIntent.instance.reset();
    }
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
