import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/notes_source.dart';
import 'github_client.dart';

/// Repo coordinates go in preferences; the token goes in the platform keystore.
class SettingsStore {
  static const _ownerKey = 'github_owner';
  static const _repoKey = 'github_repo';
  static const _branchKey = 'github_branch';
  static const _tokenKey = 'github_token';
  static const _themeKey = 'theme_mode';
  static const _loginKey = 'github_login';
  static const _sharedKey = 'shared_sources';
  static const _nameKey = 'display_name';

  /// A shared repo's token, kept in the keystore beside your own.
  static String _sharedTokenKey(String id) => 'shared_token_$id';

  final _secure = const FlutterSecureStorage();

  /// Light, dark, or whatever the system says. Stored by name rather than by
  /// index, so reordering [ThemeMode] could never silently change someone's
  /// setting.
  Future<ThemeMode> loadThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    return switch (prefs.getString(_themeKey)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> saveThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, mode.name);
  }

  /// The signed-in account's name, used to sign a message in a note. Not a
  /// secret — it is written into the markdown — so preferences are the right
  /// place for it.
  Future<String?> loadLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final login = prefs.getString(_loginKey);
    return (login == null || login.isEmpty) ? null : login;
  }

  Future<void> saveLogin(String? login) async {
    final prefs = await SharedPreferences.getInstance();
    if (login == null || login.trim().isEmpty) {
      await prefs.remove(_loginKey);
    } else {
      await prefs.setString(_loginKey, login.trim());
    }
  }

  /// What to sign notes with when there is no GitHub account to take a name
  /// from. Someone who joined a shared notebook with a code has no account
  /// and no repo of their own, so without this every message they leave is
  /// signed the same as everybody else's.
  Future<String?> loadName() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_nameKey);
    return (name == null || name.trim().isEmpty) ? null : name.trim();
  }

  Future<void> saveName(String? name) async {
    final prefs = await SharedPreferences.getInstance();
    if (name == null || name.trim().isEmpty) {
      await prefs.remove(_nameKey);
    } else {
      await prefs.setString(_nameKey, name.trim());
    }
  }

  Future<GitHubConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    return GitHubConfig(
      owner: prefs.getString(_ownerKey) ?? '',
      repo: prefs.getString(_repoKey) ?? '',
      branch: prefs.getString(_branchKey) ?? 'main',
      token: await _readToken(),
    );
  }

  Future<void> save(GitHubConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ownerKey, config.owner.trim());
    await prefs.setString(_repoKey, config.repo.trim());
    await prefs.setString(_branchKey, config.branch.trim());

    if (config.token.isEmpty) {
      await _secure.delete(key: _tokenKey);
    } else {
      await _secure.write(key: _tokenKey, value: config.token.trim());
    }
  }

  /// Every notebook the app knows about: yours first, then any shared.
  ///
  /// Yours is read from the keys it has always used, so nothing that already
  /// exists on a device has to be moved or converted — sharing is additive.
  /// A shared notebook whose token has gone from the keystore is left out
  /// rather than offered in a state where nothing it does can work.
  Future<List<NotesSource>> loadSources() async {
    final prefs = await SharedPreferences.getInstance();
    final sources = <NotesSource>[NotesSource.ownedBy(await load())];

    final raw = prefs.getString(_sharedKey);
    if (raw == null || raw.isEmpty) return sources;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return sources;

      for (final entry in decoded) {
        if (entry is! Map<String, dynamic>) continue;
        final id = entry['id'];
        if (id is! String || id.isEmpty) continue;

        final token = await _readSharedToken(id);
        if (token.isEmpty) continue;

        final source = NotesSource.fromJson(entry, token);
        if (source != null && source.config.isComplete) sources.add(source);
      }
    } on FormatException {
      // A settings blob that cannot be read is treated as no shared
      // notebooks, not as a reason to refuse to start.
    }
    return sources;
  }

  /// Writes the shared notebooks. Yours is saved by [save] as it always was.
  Future<void> saveSharedSources(List<NotesSource> sources) async {
    final prefs = await SharedPreferences.getInstance();
    final shared = sources.where((source) => !source.isMine).toList();

    await prefs.setString(
      _sharedKey,
      jsonEncode([for (final source in shared) source.toJson()]),
    );

    for (final source in shared) {
      await _secure.write(
        key: _sharedTokenKey(source.id),
        value: source.config.token,
      );
    }
  }

  /// Forgets one shared notebook, token and all.
  Future<void> forgetSharedSource(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_sharedKey);

    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          await prefs.setString(
            _sharedKey,
            jsonEncode([
              for (final entry in decoded)
                if (!(entry is Map && entry['id'] == id)) entry,
            ]),
          );
        }
      } on FormatException {
        await prefs.remove(_sharedKey);
      }
    }

    // The token goes with it. Leaving one behind would mean a repo you
    // thought you had let go of was still reachable from this device.
    try {
      await _secure.delete(key: _sharedTokenKey(id));
    } catch (_) {
      // Nothing to be done, and the notebook is gone from the list either
      // way.
    }
  }

  Future<String> _readSharedToken(String id) async {
    try {
      return await _secure.read(key: _sharedTokenKey(id)) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<String> _readToken() async {
    try {
      return await _secure.read(key: _tokenKey) ?? '';
    } catch (_) {
      // A keystore that cannot be read (wiped credentials, restored backup)
      // should look like "not signed in", not crash the app on launch.
      return '';
    }
  }
}
