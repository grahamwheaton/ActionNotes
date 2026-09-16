import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../storage/github_auth.dart';

/// Signs in to GitHub without anything being typed into this app.
///
/// Shows the code GitHub minted, opens the browser to approve it, and waits.
/// Returns the access token, or null if the person backed out.
Future<String?> showGitHubSignIn(BuildContext context) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _SignInDialog(),
  );
}

class _SignInDialog extends StatefulWidget {
  const _SignInDialog();

  @override
  State<_SignInDialog> createState() => _SignInDialogState();
}

class _SignInDialogState extends State<_SignInDialog> {
  final _flow = GitHubDeviceFlow();

  DeviceCode? _code;
  String? _error;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  @override
  void dispose() {
    _flow.cancel();
    super.dispose();
  }

  Future<void> _begin() async {
    setState(() {
      _error = null;
      _code = null;
    });

    try {
      final code = await _flow.start();
      if (!mounted) return;
      setState(() => _code = code);

      // Put the code on the clipboard and open the browser straight away, so
      // the usual path is paste-and-approve rather than copying by eye.
      await _copyCode();
      await _openBrowser();

      final token = await _flow.awaitToken(code);
      if (!mounted) return;
      Navigator.of(context).pop(token);
    } on GitHubAuthException catch (error) {
      if (!mounted) return;
      if (error.isCancelled) {
        Navigator.of(context).pop();
      } else {
        setState(() => _error = error.message);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Could not reach GitHub. $error');
    }
  }

  Future<void> _copyCode() async {
    final code = _code;
    if (code == null) return;

    await Clipboard.setData(ClipboardData(text: code.userCode));
    if (!mounted) return;
    setState(() => _copied = true);
  }

  Future<void> _openBrowser() async {
    final code = _code;
    if (code == null) return;

    await launchUrl(code.verificationUri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final code = _code;

    return AlertDialog(
      title: const Text('Sign in to GitHub'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              )
            else if (code == null)
              const Row(
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text('Asking GitHub for a code...'),
                ],
              )
            else ...[
              Text(
                'Enter this code on github.com to let ActionNotes in. '
                'Your password never comes near this app.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              Center(
                child: SelectableText(
                  code.userCode,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontFamily: 'monospace',
                    letterSpacing: 4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  _copied ? 'Copied to the clipboard' : code.verificationUri.toString(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Waiting for you to approve it...',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            _flow.cancel();
            Navigator.of(context).pop();
          },
          child: const Text('Cancel'),
        ),
        if (_error != null)
          FilledButton(onPressed: _begin, child: const Text('Try again'))
        else if (code != null) ...[
          TextButton(onPressed: _copyCode, child: const Text('Copy code')),
          FilledButton(onPressed: _openBrowser, child: const Text('Open GitHub')),
        ],
      ],
    );
  }
}
