import 'package:flutter/material.dart';

import '../storage/github_account.dart';
import '../storage/github_client.dart';

/// Picks the repo the notes live in, from the ones the token can actually
/// reach, so the name does not have to be typed from memory.
///
/// Returns the chosen repo, or null if the dialog was dismissed — in which
/// case whatever was typed in the field stays as it was.
Future<RepoRef?> showRepoPicker(
  BuildContext context, {
  required Future<List<RepoRef>> Function() load,
}) {
  return showDialog<RepoRef>(
    context: context,
    builder: (_) => _RepoPickerDialog(load: load),
  );
}

class _RepoPickerDialog extends StatefulWidget {
  const _RepoPickerDialog({required this.load});

  final Future<List<RepoRef>> Function() load;

  @override
  State<_RepoPickerDialog> createState() => _RepoPickerDialogState();
}

class _RepoPickerDialogState extends State<_RepoPickerDialog> {
  final _search = TextEditingController();

  List<RepoRef>? _repos;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _repos = null;
      _error = null;
    });

    try {
      final repos = await widget.load();
      if (!mounted) return;
      setState(() => _repos = repos);
    } on GitHubException catch (error) {
      if (!mounted) return;
      setState(() => _error = switch (error.statusCode) {
            401 => 'Token rejected. Sign in again.',
            403 => 'Token lacks permission to list repos.',
            _ => error.message,
          });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Could not reach GitHub.');
    }
  }

  /// Matches on the whole `owner/name`, so typing an org narrows to it and
  /// typing a fragment of the name finds it under any owner.
  List<RepoRef> get _matches {
    final repos = _repos ?? const <RepoRef>[];
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return repos;
    return repos
        .where((repo) => repo.fullName.toLowerCase().contains(query))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Choose a repository'),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          children: [
            TextField(
              controller: _search,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search',
              ),
            ),
            const SizedBox(height: 12),
            Expanded(child: _body(theme)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (_error != null)
          FilledButton(onPressed: _load, child: const Text('Try again')),
      ],
    );
  }

  Widget _body(ThemeData theme) {
    final error = _error;
    if (error != null) {
      return Center(
        child: Text(
          error,
          textAlign: TextAlign.center,
          style: TextStyle(color: theme.colorScheme.error),
        ),
      );
    }

    final repos = _repos;
    if (repos == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (repos.isEmpty) {
      return Center(
        child: Text(
          'No repositories to offer. Install ActionNotes on the repo your '
          'notes live in, then try again — signing in does not install it.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final matches = _matches;
    if (matches.isEmpty) {
      return Center(
        child: Text(
          'Nothing matches "${_search.text.trim()}".',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: matches.length,
      itemBuilder: (context, index) {
        final repo = matches[index];
        return ListTile(
          dense: true,
          leading: Icon(
            repo.isPrivate ? Icons.lock_outline : Icons.book_outlined,
            size: 20,
          ),
          title: Text(repo.fullName),
          subtitle: Text(repo.defaultBranch),
          onTap: () => Navigator.of(context).pop(repo),
        );
      },
    );
  }
}
