import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../storage/github_account.dart';
import '../storage/github_client.dart';
import 'repo_picker.dart';
import 'sign_in_dialog.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _owner;
  late final TextEditingController _repo;
  late final TextEditingController _branch;
  late final TextEditingController _token;

  bool _busy = false;
  String? _result;
  bool _resultIsError = false;

  /// Who the token in [_token] belongs to, once GitHub has been asked. Only
  /// known after signing in on this screen, so an empty one means unasked
  /// rather than signed out.
  String? _login;

  @override
  void initState() {
    super.initState();
    final config = context.read<AppState>().config;
    _owner = TextEditingController(text: config.owner);
    _repo = TextEditingController(text: config.repo);
    _branch = TextEditingController(text: config.branch);
    _token = TextEditingController(text: config.token);
  }

  @override
  void dispose() {
    for (final controller in [_owner, _repo, _branch, _token]) {
      controller.dispose();
    }
    super.dispose();
  }

  GitHubConfig get _config => GitHubConfig(
        owner: _owner.text.trim(),
        repo: _repo.text.trim(),
        branch: _branch.text.trim().isEmpty ? 'main' : _branch.text.trim(),
        token: _token.text.trim(),
      );

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _result = null;
    });

    final problem = await context.read<AppState>().testConnection(_config);
    if (!mounted) return;

    setState(() {
      _busy = false;
      _resultIsError = problem != null;
      _result = problem ?? 'Connected. The token can read and write this repo.';
    });
  }

  Future<void> _signIn() async {
    final token = await showGitHubSignIn(context);
    if (token == null || !mounted) return;

    setState(() {
      _token.text = token;
      _resultIsError = false;
      _result = 'Signed in. Test the connection, or save to sync.';
    });

    await _fillInAccount();
  }

  /// Asks GitHub who just signed in, and uses it for the owner if nothing has
  /// been typed there. It is only a default: notes kept under an org have an
  /// owner that is not the person signing in, so an owner already filled in is
  /// left alone.
  Future<void> _fillInAccount() async {
    final account = GitHubAccount(_token.text.trim());
    try {
      final login = await account.login();
      if (!mounted) return;
      setState(() {
        _login = login;
        if (_owner.text.trim().isEmpty) _owner.text = login;
      });
    } catch (_) {
      // Nothing is lost: the owner can still be typed, and testing the
      // connection reports anything actually wrong with the token.
    } finally {
      account.dispose();
    }
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
        _branch.text = picked.defaultBranch;
        _result = null;
      });
    } finally {
      account.dispose();
    }
  }

  void _signOut() {
    setState(() {
      _token.clear();
      _login = null;
      _result = null;
    });
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    await context.read<AppState>().updateConfig(_config);
    if (!mounted) return;

    setState(() => _busy = false);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Text(
            'Where your notes live',
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'Projects are written as markdown files under projects/ in this repo.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          _Field(
            controller: _owner,
            label: 'Owner',
            hint: 'your GitHub username or org',
          ),
          _Field(
            controller: _repo,
            label: 'Repository',
            hint: 'notes',
            suffix: IconButton(
              icon: const Icon(Icons.travel_explore),
              tooltip: _token.text.trim().isEmpty
                  ? 'Sign in to browse your repositories'
                  : 'Browse your repositories',
              onPressed: _token.text.trim().isEmpty ? null : _pickRepo,
            ),
          ),
          _Field(controller: _branch, label: 'Branch', hint: 'main'),
          const SizedBox(height: 4),
          Text(
            'Access',
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          _AccessCard(
            hasToken: _token.text.trim().isNotEmpty,
            login: _login,
            busy: _busy,
            onSignIn: _signIn,
            onSignOut: _signOut,
          ),
          const SizedBox(height: 8),
          Text(
            'Signing in approves ActionNotes on github.com and keeps the token '
            'in this device\'s keystore. It reaches only the repos you install '
            'the app on.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          _TokenFallback(controller: _token, onChanged: () => setState(() {})),
          const SizedBox(height: 20),
          Text(
            'Appearance',
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          const _ThemePicker(),
          const SizedBox(height: 24),
          Text(
            'Updates',
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const _UpdateRow(),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _test,
                  child: const Text('Test connection'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : _save,
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
          if (_busy) ...[
            const SizedBox(height: 20),
            const Center(child: CircularProgressIndicator()),
          ],
          if (_result != null) ...[
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _resultIsError
                    ? theme.colorScheme.errorContainer
                    : theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _result!,
                style: TextStyle(
                  color: _resultIsError
                      ? theme.colorScheme.onErrorContainer
                      : theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Says whether this build is current, and offers the newer one.
class _UpdateRow extends StatelessWidget {
  const _UpdateRow();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<AppState>();
    final update = state.update;

    return Row(
      children: [
        Expanded(
          child: Text(
            state.checkingUpdate
                ? 'Checking...'
                : update == null
                    ? 'Checked against the latest release on GitHub. '
                        'An update shows up beside the projects.'
                    : 'Version ${update.version} is out.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: 12),
        OutlinedButton(
          onPressed: state.checkingUpdate
              ? null
              : () => context.read<AppState>().checkForUpdate(),
          child: const Text('Check now'),
        ),
      ],
    );
  }
}

/// Light, dark, or whatever the system is doing.
///
/// An override rather than a replacement: System stays the default, because
/// most of the time following the phone or the desktop is right.
class _ThemePicker extends StatelessWidget {
  const _ThemePicker();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Align(
      alignment: Alignment.centerLeft,
      child: SegmentedButton<ThemeMode>(
        segments: const [
          ButtonSegment(
            value: ThemeMode.system,
            icon: Icon(Icons.brightness_auto_outlined),
            label: Text('System'),
          ),
          ButtonSegment(
            value: ThemeMode.light,
            icon: Icon(Icons.light_mode_outlined),
            label: Text('Light'),
          ),
          ButtonSegment(
            value: ThemeMode.dark,
            icon: Icon(Icons.dark_mode_outlined),
            label: Text('Dark'),
          ),
        ],
        selected: {state.themeMode},
        showSelectedIcon: false,
        onSelectionChanged: (selected) =>
            context.read<AppState>().setThemeMode(selected.first),
      ),
    );
  }
}

/// Says whether this device holds a token, and offers the one button that
/// changes that.
class _AccessCard extends StatelessWidget {
  const _AccessCard({
    required this.hasToken,
    required this.login,
    required this.busy,
    required this.onSignIn,
    required this.onSignOut,
  });

  final bool hasToken;
  final String? login;
  final bool busy;
  final VoidCallback onSignIn;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            hasToken ? Icons.check_circle_outline : Icons.lock_outline,
            color: hasToken
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              switch ((hasToken, login)) {
                (true, final String login) => 'Signed in as $login',
                (true, _) => 'Signed in to GitHub',
                _ => 'Not signed in',
              },
              style: theme.textTheme.bodyMedium,
            ),
          ),
          if (hasToken)
            TextButton(onPressed: busy ? null : onSignOut, child: const Text('Sign out'))
          else
            FilledButton(onPressed: busy ? null : onSignIn, child: const Text('Sign in')),
        ],
      ),
    );
  }
}

/// The old way in, kept for anyone who would rather mint their own token —
/// folded away so it is not the first thing anyone reads.
class _TokenFallback extends StatelessWidget {
  const _TokenFallback({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 8),
        title: Text(
          'Use a personal access token instead',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        children: [
          _Field(
            controller: controller,
            label: 'Personal access token',
            hint: 'github_pat_...',
            obscure: true,
            onChanged: onChanged,
          ),
          Text(
            'A fine-grained token scoped to this one repo, with '
            'Contents: Read and write.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    required this.hint,
    this.obscure = false,
    this.onChanged,
    this.suffix,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final bool obscure;
  final VoidCallback? onChanged;
  final Widget? suffix;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        autocorrect: false,
        enableSuggestions: false,
        onChanged: onChanged == null ? null : (_) => onChanged!(),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          suffixIcon: suffix,
        ),
      ),
    );
  }
}
