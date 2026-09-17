import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'github_client.dart';

/// Repo coordinates go in preferences; the token goes in the platform keystore.
class SettingsStore {
  static const _ownerKey = 'github_owner';
  static const _repoKey = 'github_repo';
  static const _branchKey = 'github_branch';
  static const _tokenKey = 'github_token';
  static const _themeKey = 'theme_mode';

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
