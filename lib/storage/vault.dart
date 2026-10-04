import 'dart:convert';
import 'dart:math';

import 'folder_backend.dart';
import 'remote_store.dart';

/// What a notebook folder says about itself.
///
/// A small file at `.actionnotes/vault.json`, written when a folder is first
/// set up and read whenever one is connected. It exists for one reason: a
/// notebook has to have the same identity on every device that opens it. The
/// folder's path differs between a phone and a laptop (and between two people
/// who share it), so the path cannot be what the app recognises it by.
class VaultInfo {
  const VaultInfo({required this.id, required this.name, this.created});

  /// Stable and shared by everyone who opens the folder.
  final String id;

  /// What it was called when it was set up. Each device may call it something
  /// else locally.
  final String name;

  final DateTime? created;

  static const path = '${StoreLayout.metaDir}/vault.json';
  static const format = 1;

  String serialize() {
    const encoder = JsonEncoder.withIndent('  ');
    final document = <String, Object>{
      'app': 'ActionNotes',
      'format': format,
      'id': id,
      'name': name,
      if (created != null) 'created': created!.toUtc().toIso8601String(),
    };
    return '${encoder.convert(document)}\n';
  }

  /// Null for anything that is not one of ours, however it came to be there.
  static VaultInfo? parse(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map<String, dynamic>) return null;
      final id = decoded['id'];
      if (id is! String || !_validId.hasMatch(id)) return null;
      return VaultInfo(
        id: id,
        name: (decoded['name'] as String?)?.trim() ?? '',
        created: DateTime.tryParse(decoded['created'] as String? ?? ''),
      );
    } on FormatException {
      return null;
    }
  }

  /// Letters, digits and dashes only: the id becomes part of a folder name on
  /// this device, so a file somebody edited by hand must not be able to put
  /// anything else there.
  static final _validId = RegExp(r'^[A-Za-z0-9-]{6,64}$');

  static String newId([Random? random]) {
    final source = random ?? Random.secure();
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(
      12,
      (_) => alphabet[source.nextInt(alphabet.length)],
    ).join();
  }
}

/// What looking inside a folder found.
enum FolderState {
  /// Already a notebook, and has been opened by this app before.
  notebook,

  /// Holds a `projects/` folder but has never been given an identity — a
  /// clone of a notes repo, say, or one set up by hand.
  unmarked,

  /// Nothing of ours in it. Setting one up will add two folders and leave
  /// everything else alone.
  empty,
}

class FolderProbe {
  const FolderProbe({required this.state, this.info, this.projects = 0});

  final FolderState state;

  /// Present for [FolderState.notebook].
  final VaultInfo? info;

  /// How many project files are already in it.
  final int projects;

  bool get exists => state != FolderState.empty;
}

/// Looking inside a folder, and setting one up.
class Vault {
  Vault(this.backend);

  final FolderBackend backend;

  /// Works out what is in a folder without changing it.
  Future<FolderProbe> probe() async {
    final bytes = await backend.read(VaultInfo.path);
    final info = bytes == null
        ? null
        : VaultInfo.parse(utf8.decode(bytes, allowMalformed: true));

    final entries = await backend.list(StoreLayout.projectsDir);
    final projects = entries == null
        ? 0
        : entries
              .where(
                (e) =>
                    !e.isDirectory &&
                    e.name.endsWith('.md') &&
                    !e.name.startsWith('.'),
              )
              .length;

    if (info != null) {
      return FolderProbe(
        state: FolderState.notebook,
        info: info,
        projects: projects,
      );
    }
    return FolderProbe(
      state: entries == null ? FolderState.empty : FolderState.unmarked,
      projects: projects,
    );
  }

  /// Connects to the notebook in a folder, setting one up if there is not one.
  ///
  /// Idempotent, and never overwrites an identity that is already there: two
  /// people connecting to the same folder at once end up with the same notebook
  /// rather than two.
  Future<VaultInfo> open({required String name, Random? random}) async {
    final probed = await probe();

    // Always, including for a notebook that is already there: the folder being
    // present is what tells the sync that an empty listing means "no projects"
    // rather than "not arrived yet".
    await backend.makeDirectory(StoreLayout.projectsDir);
    if (probed.info != null) return probed.info!;

    final info = VaultInfo(
      id: VaultInfo.newId(random),
      name: name.trim(),
      created: DateTime.now().toUtc(),
    );
    await backend.write(VaultInfo.path, utf8.encode(info.serialize()));

    // Written by two devices at the same moment, the last one wins — so what
    // is on disk now is the answer, not what this call wrote.
    final settled = await backend.read(VaultInfo.path);
    final read = settled == null
        ? null
        : VaultInfo.parse(utf8.decode(settled, allowMalformed: true));
    return read ?? info;
  }
}
