import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/project.dart';
import '../state/app_state.dart';
import 'checklist_view.dart';
import 'home_shell.dart';

class ProjectCopyActions {
  ProjectCopyActions._();

  static Future<void> share(BuildContext context, Project project) async {
    try {
      final bytes = await context.read<AppState>().exportProjectCopy(project.slug);
      final name = '${project.fileSlug}.actionnotes.zip';
      if (Platform.isAndroid) {
        final directory = await getTemporaryDirectory();
        final file = File('${directory.path}${Platform.pathSeparator}$name');
        await file.writeAsBytes(bytes);
        await SharePlus.instance.share(ShareParams(
          files: [XFile(file.path, mimeType: 'application/zip')],
          title: project.title,
        ));
      } else {
        final location = await getSaveLocation(suggestedName: name,
          acceptedTypeGroups: const [XTypeGroup(label: 'ActionNotes copy',
            extensions: ['zip'])]);
        if (location == null) return;
        await File(location.path).writeAsBytes(bytes);
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not share a copy: $error')));
      }
    }
  }

  static Future<void> import(BuildContext context) async {
    final file = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'ActionNotes copy', extensions: ['zip']),
    ]);
    if (file == null || !context.mounted) return;
    try {
      final state = context.read<AppState>();
      final project = await state.importProjectCopy(await file.readAsBytes());
      state.select(project.slug);
      if (context.mounted &&
          MediaQuery.sizeOf(context).width < HomeShell.sidebarBreakpoint) {
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => ChecklistView(slug: project.slug),
        ));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not import the copy: $error')));
      }
    }
  }
}
