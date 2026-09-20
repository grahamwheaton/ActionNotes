import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/notes_source.dart';
import '../models/project.dart';
import '../state/app_state.dart';
import '../storage/github_account.dart';
import '../storage/github_client.dart';
import '../storage/share_code.dart';
import 'repo_picker.dart';

/// Everything a person sees about notebooks shared with them.
///
/// Written for someone who has never made a token and never will. The words
/// on screen are "notebook", "code" and "share"; the words owner, repo,
/// branch and token appear nowhere, because none of them is a decision
/// anybody is being asked to make here. What they get instead is one string
/// to paste and one string to hand out.
class SharedNotebooksCard extends StatelessWidget {
  const SharedNotebooksCard({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<AppState>();
    final shared = state.sharedSources;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Shared notebooks',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          shared.isEmpty
              ? 'A notebook you share with other people. Paste the code '
                    'somebody sent you and their projects appear here beside '
                    'your own.'
              : 'Projects in these are shared with everyone who has the code. '
                    'Anything they change, you see; anything you change, they '
                    'see.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        for (final source in shared) _NotebookRow(source: source),
        if (shared.isNotEmpty) const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => AddNotebookDialog.show(context),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add a notebook'),
        ),
      ],
    );
  }
}

class _NotebookRow extends StatelessWidget {
  const _NotebookRow({required this.source});

  final NotesSource source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.read<AppState>();
    final count = state.projects.where((p) => p.sourceId == source.id).length;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(
          children: [
            Icon(
              Icons.folder_shared_outlined,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    source.name,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    count == 1 ? '1 project' : '$count projects',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => ShareCodeDialog.show(context, source),
              child: const Text('Share'),
            ),
            IconButton(
              icon: const Icon(Icons.more_horiz),
              tooltip: 'More',
              onPressed: () => _confirmStopUsing(context, source),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmStopUsing(
    BuildContext context,
    NotesSource source,
  ) async {
    final state = context.read<AppState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Stop using ${source.name}?'),
        // Said plainly, because the difference between this and deleting is
        // the whole of what someone is worried about when they press it.
        content: const Text(
          'It disappears from your devices. Nothing in it is deleted, and the '
          'other people keep it exactly as it is. You can paste the code '
          'again later to get it back.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Stop using it'),
          ),
        ],
      ),
    );

    if (ok == true) await state.forgetSharedNotebook(source.id);
  }
}

/// Two ways into a shared notebook: paste a code somebody sent, or set one
/// up from a repo of your own.
///
/// Both exist because somebody has to be first. Everyone after them pastes a
/// code; the first person has an empty repo and a token they made for it, and
/// nothing to paste.
class AddNotebookDialog extends StatefulWidget {
  const AddNotebookDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => const AddNotebookDialog(),
  );

  @override
  State<AddNotebookDialog> createState() => _AddNotebookDialogState();
}

class _AddNotebookDialogState extends State<AddNotebookDialog> {
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _token = TextEditingController();
  final _owner = TextEditingController();
  final _repo = TextEditingController();
  String _branch = 'main';

  /// False while someone is pasting a code, true while they are setting a
  /// notebook up from a repo of their own.
  bool _setUp = false;
  bool _busy = false;
  String? _problem;

  @override
  void dispose() {
    for (final controller in [_code, _name, _token, _owner, _repo]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _pickRepo() async {
    final token = _token.text.trim();
    if (token.isEmpty) return;

    final account = GitHubAccount(token);
    try {
      final picked = await showRepoPicker(context, load: account.repos);
      if (picked == null || !mounted) return;
      setState(() {
        _owner.text = picked.owner;
        _repo.text = picked.name;
        _branch = picked.defaultBranch;
        _problem = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _problem =
            'That token could not list any repositories. Check it and try '
            'again.',
      );
    } finally {
      account.dispose();
    }
  }

  /// Both routes end in the same place: a code. Setting one up just builds
  /// the code here instead of being handed it, so there is one way in and
  /// one thing to get right.
  String get _codeToUse => _setUp
      ? ShareCode.encode(
          GitHubConfig(
            owner: _owner.text.trim(),
            repo: _repo.text.trim(),
            branch: _branch,
            token: _token.text.trim(),
          ),
        )
      : _code.text.trim();

  Future<void> _add() async {
    if (_setUp &&
        (_owner.text.trim().isEmpty ||
            _repo.text.trim().isEmpty ||
            _token.text.trim().isEmpty)) {
      setState(() => _problem = 'Paste the token, then pick the repository.');
      return;
    }

    setState(() {
      _busy = true;
      _problem = null;
    });

    final problem = await context.read<AppState>().addSharedNotebook(
      _codeToUse,
      label: _name.text.trim(),
    );

    if (!mounted) return;
    if (problem == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      _problem = problem;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Add a shared notebook'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('I have a code')),
                  ButtonSegment(value: true, label: Text('Set one up')),
                ],
                selected: {_setUp},
                onSelectionChanged: _busy
                    ? null
                    : (choice) => setState(() {
                        _setUp = choice.first;
                        _problem = null;
                      }),
              ),
              const SizedBox(height: 16),
              if (_setUp) ..._setUpFields(theme) else ..._codeFields(theme),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Call it (optional)',
                  hintText: 'Kitchen, Holiday, Work…',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_problem != null) ...[
                const SizedBox(height: 14),
                Text(
                  _problem!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              if (_busy) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _add,
          child: Text(_setUp ? 'Set it up' : 'Add'),
        ),
      ],
    );
  }

  List<Widget> _codeFields(ThemeData theme) => [
    Text(
      'Paste the code somebody sent you. That is all — there is nothing to '
      'sign in to.',
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    ),
    const SizedBox(height: 16),
    TextField(
      controller: _code,
      autofocus: true,
      maxLines: 3,
      minLines: 2,
      enabled: !_busy,
      decoration: const InputDecoration(
        labelText: 'Code',
        hintText: 'AN1-…',
        border: OutlineInputBorder(),
      ),
    ),
  ];

  List<Widget> _setUpFields(ThemeData theme) => [
    // The only screen in the app that asks for a token, and it asks for a
    // particular one: made for this repo and nothing else, because the code
    // built from it is what gets handed around. A token that reaches
    // everything would hand everything around with it.
    Text(
      'Make an empty private repository on GitHub for the notebook, then a '
      'fine-grained token that can read and write that one repository and '
      'nothing else. Paste it here and pick the repository.',
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    ),
    const SizedBox(height: 16),
    TextField(
      controller: _token,
      autofocus: true,
      obscureText: true,
      enabled: !_busy,
      onChanged: (_) => setState(() {}),
      decoration: const InputDecoration(
        labelText: 'Token for that repository',
        hintText: 'github_pat_…',
        border: OutlineInputBorder(),
      ),
    ),
    const SizedBox(height: 12),
    Row(
      children: [
        Expanded(
          child: Text(
            _repo.text.trim().isEmpty
                ? 'No repository picked yet'
                : '${_owner.text.trim()}/${_repo.text.trim()} on $_branch',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        OutlinedButton(
          onPressed: _busy || _token.text.trim().isEmpty ? null : _pickRepo,
          child: const Text('Pick repository'),
        ),
      ],
    ),
  ];
}

/// Shows the code for a notebook, to hand to somebody else.
class ShareCodeDialog extends StatelessWidget {
  const ShareCodeDialog({super.key, required this.source});

  final NotesSource source;

  static Future<void> show(BuildContext context, NotesSource source) {
    final code = context.read<AppState>().shareCodeFor(source.id);
    if (code == null) {
      // Your own notebook has no code, and that is not an oversight: the key
      // it would carry reaches every repo you have, not one notebook.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Your own notes cannot be shared with a code. Move a project '
            'into a shared notebook instead.',
          ),
        ),
      );
      return Future.value();
    }
    return showDialog<void>(
      context: context,
      builder: (_) => ShareCodeDialog(source: source),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final code = context.read<AppState>().shareCodeFor(source.id) ?? '';

    return AlertDialog(
      title: Text('Share ${source.name}'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Send this code to whoever you want in. They paste it into '
              'Add a notebook and they are in — no account, no sign-in.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                code,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
            ),
            const SizedBox(height: 14),
            // The one thing that has to be understood before it is sent, and
            // it is a plain sentence rather than a warning triangle: whoever
            // holds this can read and change everything in the notebook, and
            // can pass it on. There is no way to give somebody one project.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Anybody with this code can read and change everything in '
                    'this notebook, and can pass it on. It is a key, not a '
                    'link — send it the way you would send a door key.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: code));
            if (!context.mounted) return;
            Navigator.of(context).pop();
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('Code copied')));
          },
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Copy code'),
        ),
      ],
    );
  }
}

/// Moves a project into a shared notebook, or back out of one.
///
/// Moved rather than copied, which is the part worth saying on screen: after
/// this there is one list in one place, and everybody is looking at it.
class ShareProjectDialog {
  ShareProjectDialog._();

  static Future<void> show(BuildContext context, Project project) async {
    final state = context.read<AppState>();
    final shared = state.sharedSources;

    if (shared.isEmpty) {
      final add = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('No shared notebook yet'),
          content: const Text(
            'Projects are shared by moving them into a shared notebook. You '
            'have not got one yet — add one with the code somebody sent you, '
            'or make one in Settings.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Add a notebook'),
            ),
          ],
        ),
      );
      if (add != true || !context.mounted) return;
      await AddNotebookDialog.show(context);
      return;
    }

    final target = await showDialog<NotesSource>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Move "${project.title}" into'),
        children: [
          for (final source in shared)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(source),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.folder_shared_outlined),
                title: Text(source.name),
                subtitle: Text(
                  'Everyone with this notebook will see it and can change it',
                ),
              ),
            ),
        ],
      ),
    );

    if (target == null || !context.mounted) return;
    await _move(context, state, project.slug, target.id);
  }

  /// Brings a shared project home again: the same move the other way.
  static Future<void> stopSharing(BuildContext context, Project project) async {
    final state = context.read<AppState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop sharing this?'),
        content: const Text(
          'It moves back into your own notes. The other people lose it — for '
          'them it is gone, not read-only.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Stop sharing'),
          ),
        ],
      ),
    );

    if (ok != true || !context.mounted) return;
    await _move(context, state, project.slug, NotesSource.mineId);
  }

  static Future<void> _move(
    BuildContext context,
    AppState state,
    String slug,
    String toSourceId,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final problem = await state.moveProject(slug, toSourceId);
    messenger.showSnackBar(SnackBar(content: Text(problem ?? 'Moved.')));

    // A moved project has a new name underneath, so a screen opened on the
    // old one is looking at something that is no longer there. Stepping back
    // to the list lands on it where it now is, rather than on a page saying
    // it has gone when it plainly has not.
    if (problem == null && navigator.canPop()) navigator.pop();
  }
}
