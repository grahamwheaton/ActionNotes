import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../storage/github_client.dart';

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
          _Field(controller: _repo, label: 'Repository', hint: 'notes'),
          _Field(controller: _branch, label: 'Branch', hint: 'main'),
          _Field(
            controller: _token,
            label: 'Personal access token',
            hint: 'github_pat_...',
            obscure: true,
          ),
          const SizedBox(height: 8),
          Text(
            'Create a fine-grained token scoped to this one repo with '
            'Contents: Read and write. It is stored in this device\'s keystore.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
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

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    required this.hint,
    this.obscure = false,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(labelText: label, hintText: hint),
      ),
    );
  }
}
