import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../markdown/canvas_cards.dart';
import '../markdown/canvas_placement.dart';
import '../markdown/project_links.dart';
import '../models/canvas_layout.dart';
import '../models/checklist_item.dart';
import '../models/notes_source.dart';
import '../models/project.dart';
import '../models/sidebar_layout.dart';
import '../storage/attachment_store.dart';
import '../storage/github_client.dart';
import '../storage/share_code.dart';
import '../storage/image_encoder.dart';
import '../storage/local_store.dart';
import '../storage/notebook_index.dart';
import '../storage/settings_store.dart';
import '../storage/sync_service.dart';
import '../storage/update_check.dart';

/// Which item's notes the desktop layout is editing in its detail pane.
///
/// The index is into the project's own item list, which is what every other
/// item operation takes; [NoteTarget] exists so the pane can tell "no note
/// open" from "the first item's note".
class NoteTarget {
  const NoteTarget(this.slug, this.index);

  final String slug;
  final int index;

  @override
  bool operator ==(Object other) =>
      other is NoteTarget && other.slug == slug && other.index == index;

  @override
  int get hashCode => Object.hash(slug, index);
}

/// Single source of truth for the UI.
///
/// Every mutation writes to the local cache immediately and schedules a push,
/// so the UI never waits on the network to feel responsive.
class AppState extends ChangeNotifier {
  AppState({
    LocalStore? localStore,
    SettingsStore? settingsStore,
    SyncService? syncService,
    AttachmentStore? attachmentStore,
    Duration pushDelay = defaultPushDelay,
    Duration syncInterval = defaultSyncInterval,
    Duration sharedInterval = sharedSyncInterval,
    UpdateCheck? updateCheck,
  }) : _updateCheck = updateCheck,
       _localStore = localStore ?? LocalStore(),
       _settingsStore = settingsStore ?? SettingsStore(),
       _pushDelay = pushDelay,
       _syncInterval = syncInterval,
       _sharedInterval = sharedInterval,
       attachments = attachmentStore ?? AttachmentStore() {
    _syncService = syncService ?? SyncService(localStore: _localStore);
  }

  static const defaultPushDelay = Duration(seconds: 2);

  /// How often to look for changes made elsewhere while the app is open and
  /// nothing is shared — a second device of your own, or a model editing the
  /// repo, neither of which anybody is sitting watching.
  static const defaultSyncInterval = Duration(seconds: 45);

  /// How often to look when a notebook is shared and somebody might be
  /// writing in it right now.
  ///
  /// Five seconds is what makes a list feel like one list rather than two
  /// copies: tick a box here and it appears over there before the other
  /// person has looked away. It is affordable because a check is one request
  /// per notebook — the listing says which files have moved, and only those
  /// are fetched — and because everyone shares one token, so the rate limit
  /// is shared too and a check that downloaded every list would not be.
  static const sharedSyncInterval = Duration(seconds: 5);

  /// How long a shared notebook goes quiet before checking slows down again.
  ///
  /// Two people writing at once is a burst, not a state: it lasts minutes,
  /// not hours, and polling every five seconds all evening afterwards spends
  /// the shared rate limit on nothing.
  static const busyFor = Duration(minutes: 3);

  /// How long an edit settles before it is pushed. A test shortens it rather
  /// than waiting two seconds per edit.
  final Duration _pushDelay;
  final Duration _syncInterval;
  final Duration _sharedInterval;
  Timer? _watch;

  /// Left null in tests that do not care, so nothing reaches the network for
  /// an update nobody asked about.
  final UpdateCheck? _updateCheck;
  AvailableUpdate? _update;
  bool _checkingUpdate = false;

  final LocalStore _localStore;
  final SettingsStore _settingsStore;

  /// Exposed so note rendering can resolve image references.
  final AttachmentStore attachments;
  late final SyncService _syncService;

  final Map<String, Timer> _pendingPushes = {};

  /// Projects with a push in flight, so a second one waits rather than racing
  /// it with a SHA that is about to be out of date.
  final Set<String> _pushing = {};

  List<Project> _projects = [];

  /// Yours, plus any shared notebook a code has been pasted for. Yours is
  /// always first and always present, even before it is signed in to.
  List<NotesSource> _sources = const [];
  GitHubConfig _config = const GitHubConfig(
    owner: '',
    repo: '',
    branch: 'main',
    token: '',
  );
  bool _loading = true;
  bool _syncing = false;
  String? _message;
  String? _selectedSlug;
  NoteTarget? _openNote;
  NoteTarget? _revealed;
  DateTime? _lastSynced;
  String? _login;
  String? _displayName;
  ThemeMode _themeMode = ThemeMode.system;

  List<Project> get projects => List.unmodifiable(_projects);
  GitHubConfig get config => _config;

  /// Every notebook: yours first, then any shared with you.
  List<NotesSource> get sources => List.unmodifiable(_sources);

  List<NotesSource> get sharedSources =>
      _sources.where((source) => !source.isMine).toList();

  /// The notebook a project belongs to, or your own when it is not one the
  /// app knows about — which is what everything was before sharing.
  NotesSource sourceOf(String slug) {
    final id = projectBySlug(slug)?.sourceId ?? NotesSource.mineId;
    return _sources.firstWhere(
      (source) => source.id == id,
      orElse: () => NotesSource.ownedBy(_config),
    );
  }

  SidebarLayout _sidebar = SidebarLayout.empty;

  /// How the project list is arranged, with anything it has never heard of
  /// added at the end so a new project is never invisible.
  SidebarLayout get sidebar => _sidebar;

  /// The projects in no group, in order, followed by any the arrangement has
  /// not placed yet.
  List<Project> get looseProjects {
    final placed = _sidebar.known;
    return [
      for (final slug in _sidebar.loose)
        if (projectBySlug(slug) case final project?) project,
      for (final project in _projects)
        if (!placed.contains(project.slug)) project,
    ];
  }

  /// The projects in one group, in the order it holds them.
  List<Project> projectsIn(ProjectGroup group) => [
    for (final slug in group.slugs)
      if (projectBySlug(slug) case final project?) project,
  ];

  /// The group a project belongs to, or null.
  ProjectGroup? groupOf(String slug) => _sidebar.groupOf(slug);

  Future<void> _saveSidebar(SidebarLayout next) async {
    _sidebar = next;
    notifyListeners();
    await _settingsStore.saveSidebar(next);

    // Written to your own repo as well, so the arrangement follows you from
    // the phone to the desktop the way the notebooks do. A device with no
    // repo of its own keeps it locally and nowhere else, which is the most
    // it can do.
    //
    // The SHA it comes back with is kept: GitHub accepts a write only
    // against the one the file has now, so without it every rearrangement
    // after the first would be refused and never leave the device.
    final sha = await _syncService.writeSidebar(_config, next);
    if (sha == null || _sidebar != next) return;
    _sidebar = next.copyWith(sha: sha);
  }

  /// Moves a project within the list, or into or out of a group.
  ///
  /// [group] null means loose. [at] null means the end.
  Future<void> placeProject(String slug, {String? group, int? at}) =>
      _saveSidebar(_sidebar.place(slug, group: group, at: at));

  /// Makes a group. Returns false when one is already called that, since two
  /// groups with the same name could not be told apart afterwards.
  Future<bool> addGroup(String name, {String colour = ''}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    if (_sidebar.groups.any((group) => group.name == trimmed)) return false;

    await _saveSidebar(
      _sidebar.withGroup(ProjectGroup(name: trimmed, colour: colour)),
    );
    return true;
  }

  /// Puts a group away. What was in it goes loose rather than being deleted:
  /// a group is a way of looking at a list, and putting one away should
  /// never lose what it held.
  Future<void> removeGroup(String name) =>
      _saveSidebar(_sidebar.withoutGroup(name));

  Future<bool> renameGroup(String from, String to) async {
    final trimmed = to.trim();
    if (trimmed.isEmpty || trimmed == from) return false;
    if (_sidebar.groups.any((group) => group.name == trimmed)) return false;

    await _saveSidebar(_sidebar.renameGroup(from, trimmed));
    return true;
  }

  Future<void> setGroupColour(String name, String colour) =>
      _saveSidebar(_sidebar.withGroupChanged(name, colour: colour));

  Future<void> toggleGroup(String name) {
    final group = _sidebar.groups.firstWhere((one) => one.name == name);
    return _saveSidebar(
      _sidebar.withGroupChanged(name, collapsed: !group.collapsed),
    );
  }

  Future<void> moveGroup(String name, int to) =>
      _saveSidebar(_sidebar.withGroupAt(name, to));

  /// The file behind a picture in a note or on a canvas, fetched from
  /// whichever notebook the picture belongs to.
  ///
  /// Every caller used to hand this your own repo, whatever notebook the
  /// project was in. A picture in a shared list therefore could not be
  /// fetched by anybody except whoever uploaded it and still had it cached,
  /// and for somebody who joined with a code — no repo of their own at
  /// all — no picture could ever be fetched.
  ///
  /// The notebook is worked out from the reference rather than passed in.
  /// A reference is `../attachments/<project>/<file>`, so the project it
  /// belongs to is in the string already, and a note does not have to be
  /// told which project it is being drawn inside to show its own pictures.
  Future<File?> attachmentFor(String reference) async {
    final repoPath = AttachmentStore.resolveRepoPath(reference);
    if (repoPath == null) return null;

    // Already here: no notebook needs deciding, and nothing is fetched.
    final local = await attachments.cached(repoPath);
    if (local != null) return local;

    final folder = repoPath.split('/').elementAtOrNull(1);
    final candidates = [
      // The project on screen first, for the ordinary case where a picture
      // belongs to the list you are looking at.
      if (projectBySlug(_selectedSlug ?? '') case final open?)
        if (open.fileSlug == folder) open,
      for (final project in _projects)
        if (project.fileSlug == folder && project.slug != _selectedSlug)
          project,
    ];

    for (final project in candidates) {
      final config = _configFor(project.slug);
      if (!config.isComplete) continue;
      final file = await attachments.resolve(repoPath, config);
      if (file != null) return file;
    }

    // Nothing claims it — an old reference, or a project not loaded yet.
    // Your own repo is the only sensible guess left.
    return attachments.resolve(repoPath, _config);
  }

  /// Which repo a project's edits are written to.
  GitHubConfig _configFor(String slug) => sourceOf(slug).config;

  /// The file's own name in its repo, which is what every remote path is
  /// built from.
  String _fileSlug(String slug) => projectBySlug(slug)?.fileSlug ?? slug;
  bool get loading => _loading;
  bool get syncing => _syncing;
  String? get message => _message;
  bool get isConfigured => _config.isComplete;
  int get pendingCount => _projects.where((p) => p.dirty).length;

  /// Which project the desktop layout is showing in its detail pane.
  String? get selectedSlug => _selectedSlug;

  void select(String? slug) {
    if (_selectedSlug == slug) return;
    _selectedSlug = slug;
    // A note belongs to the project it was opened from, and its index means
    // nothing in another one.
    _openNote = null;
    notifyListeners();
  }

  /// A newer release than the running build, once asked for. Null means
  /// either "up to date" or "not asked", which the UI treats the same: it
  /// only ever shows something when there is something to show.
  AvailableUpdate? get update => _update;
  bool get checkingUpdate => _checkingUpdate;

  /// Asks GitHub for the latest release and compares it with the running
  /// build. Silent about failure: a version check is a convenience.
  Future<AvailableUpdate?> checkForUpdate() async {
    final checker = _updateCheck;
    if (checker == null || _checkingUpdate) return _update;

    _checkingUpdate = true;
    notifyListeners();
    try {
      final info = await PackageInfo.fromPlatform();
      _update = await checker.latest(info.version);
    } catch (_) {
      _update = null;
    } finally {
      _checkingUpdate = false;
      notifyListeners();
    }
    return _update;
  }

  /// Stops the banner offering the same version again.
  void dismissUpdate() {
    if (_update == null) return;
    _update = null;
    notifyListeners();
  }

  /// When the app last heard from GitHub, or null if it has not yet. Shown
  /// in the sidebar, because a list is only as trustworthy as its last sync —
  /// especially on a phone that has been in a pocket.
  DateTime? get lastSynced => _lastSynced;

  /// Counts the syncs that have finished, so something that failed to load
  /// can tell whether it is worth trying again.
  ///
  /// A picture is fetched once and the answer kept, which is right: a
  /// project with thirty pictures must not ask GitHub for all thirty every
  /// time anything on screen changes. But a fetch that failed — the file was
  /// uploaded a moment ago and had not landed yet — was kept just as firmly,
  /// so a picture added on the phone stayed a grey square on the desktop
  /// until the app was restarted. A sync is the only thing that can have
  /// changed the answer, so it is the only thing that lets one be asked
  /// again.
  int get syncGeneration => _syncGeneration;
  int _syncGeneration = 0;

  /// An item a search asked to be shown, for the list to scroll to and mark
  /// for a moment. Cleared as soon as the list has taken it, so coming back
  /// to a project later does not flash a line again.
  NoteTarget? get revealed => _revealed;

  void revealItem(String slug, int index) {
    _revealed = NoteTarget(slug, index);
    notifyListeners();
  }

  /// Called by the list once it has scrolled to it.
  void clearRevealed() {
    if (_revealed == null) return;
    _revealed = null;
    notifyListeners();
  }

  /// The note being edited beside the sidebar, or null when the pane is
  /// showing the checklist. Only the wide layout sets this; a phone pushes
  /// the editor as a screen instead.
  NoteTarget? get openNote => _openNote;

  void showNote(String slug, int index) {
    final target = NoteTarget(slug, index);
    if (_openNote == target) return;
    _openNote = target;
    _selectedSlug = slug;
    notifyListeners();
  }

  void hideNote() {
    if (_openNote == null) return;
    _openNote = null;
    notifyListeners();
  }

  Project? projectBySlug(String slug) {
    for (final project in _projects) {
      if (project.slug == slug) return project;
    }
    return null;
  }

  /// Light, dark, or the system's choice. Read once on start and written
  /// whenever it changes, so the override survives a restart.
  ThemeMode get themeMode => _themeMode;

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    await _settingsStore.saveThemeMode(mode);
  }

  /// Who a message in a note is signed as: a name that has been set, the
  /// signed-in account otherwise, then the repo owner, and a plain fallback
  /// if none of those — a note should still be able to hold a conversation
  /// before anyone has signed in.
  ///
  /// The name set by hand wins, because the person who set it meant it.
  String get me {
    final chosen = _displayName;
    if (chosen != null && chosen.isNotEmpty) return chosen;
    final login = _login;
    if (login != null && login.isNotEmpty) return login;
    if (_config.owner.isNotEmpty) return _config.owner;
    return 'me';
  }

  String? get displayName => _displayName;

  /// Whether this device has no idea who is using it.
  ///
  /// Somebody who joined with a code has no GitHub account and no repo of
  /// their own, so there is nothing to take a name from and everything they
  /// write is signed the same as everybody else. In a shared notebook that
  /// is not a cosmetic problem: a conversation where both sides are "me"
  /// cannot be read at all.
  bool get needsName =>
      (_displayName == null || _displayName!.isEmpty) &&
      (_login == null || _login!.isEmpty) &&
      _config.owner.isEmpty;

  Future<void> setDisplayName(String? name) async {
    _displayName = name?.trim();
    notifyListeners();
    await _settingsStore.saveName(_displayName);
  }

  /// Remembers the signed-in account's name, so notes can be signed with it.
  Future<void> setLogin(String? login) async {
    _login = login;
    notifyListeners();
    await _settingsStore.saveLogin(login);
  }

  Future<void> init() async {
    _themeMode = await _settingsStore.loadThemeMode();
    _login = await _settingsStore.loadLogin();
    _displayName = await _settingsStore.loadName();
    _sidebar = await _settingsStore.loadSidebar();
    _sources = await _settingsStore.loadSources();
    _config = _sources.first.config;

    _projects = [
      for (final source in _sources)
        ...await _localStore.loadAll(sourceId: source.id),
    ];
    for (final project in _projects) {
      await _loadLayout(project.slug);
    }
    _loading = false;
    notifyListeners();

    if (_sources.any((source) => source.config.isComplete)) {
      unawaited(sync());
    }
  }

  /// When something last changed in a shared notebook, here or elsewhere.
  DateTime? _lastSharedChange;

  /// How often to check, given what is going on.
  ///
  /// Fast while a shared notebook is being written in, and back to the slow
  /// interval once it has been quiet for a few minutes. A notebook nobody
  /// shares never needs the fast rate at all.
  Duration get watchInterval {
    if (sharedSources.isEmpty) return _syncInterval;
    final since = _lastSharedChange;
    if (since == null) return _syncInterval;
    return DateTime.now().difference(since) < busyFor
        ? _sharedInterval
        : _syncInterval;
  }

  /// Notes that a shared notebook is being written in, so checking speeds up.
  ///
  /// Called for a change made here as well as one that arrives: the moment
  /// somebody ticks something, the other person is probably about to.
  void _sharedActivity() {
    _lastSharedChange = DateTime.now();
    // Already fast, so the timer it is running on is the right one.
    if (_watch != null && _watching != _sharedInterval) _watchAtCurrentRate();
  }

  /// Pretends a shared notebook has been quiet since a given moment, so a
  /// test can reach the slow rate without waiting three minutes for it.
  @visibleForTesting
  void debugSharedQuietSince(DateTime when) => _lastSharedChange = when;

  /// The interval the running timer was built with, so it is only rebuilt
  /// when the answer actually changes.
  Duration? _watching;

  /// Starts checking for other people's changes while the app is in front.
  ///
  /// Without it a change made on the other device, or by a model editing the
  /// repo, is invisible until something local prompts a sync.
  ///
  /// Opening the app counts as activity, so a shared notebook starts at the
  /// fast rate rather than earning it. Waiting for evidence meant the first
  /// change either person made took up to three quarters of a minute to
  /// appear — the one moment the delay is most obvious, since it is when
  /// somebody is watching to see whether this works at all.
  void startWatching() {
    if (sharedSources.isNotEmpty) _lastSharedChange = DateTime.now();
    _watchAtCurrentRate();
  }

  void _watchAtCurrentRate() {
    _watch?.cancel();
    final every = watchInterval;
    _watching = every;
    _watch = Timer.periodic(every, (_) {
      // The right rate may have changed since the timer was made — a busy
      // notebook going quiet, or a quiet one waking up.
      if (watchInterval != _watching) {
        _watchAtCurrentRate();
        return;
      }
      if (_sources.any((s) => s.config.isComplete) && !_syncing) {
        unawaited(sync());
      }
    });
  }

  /// Stops it, for when the app goes to the background: a phone should not be
  /// polling GitHub in someone's pocket.
  void stopWatching() {
    _watch?.cancel();
    _watch = null;
    _watching = null;
  }

  /// How many syncs are outstanding: the one running, plus at most one
  /// waiting behind it.
  int _queuedSyncs = 0;
  Future<void> _syncChain = Future<void>.value();

  /// Brings every notebook into step, waiting for any sync already running.
  ///
  /// Waiting rather than returning. A caller that has just changed
  /// something — taken on a shared notebook, moved a project — asks for a
  /// sync *because* of that change, and a sync already in flight was started
  /// before it and cannot include it. Returning early there meant the new
  /// notebook showed nothing until the next poll three quarters of a minute
  /// later, for no reason anyone could see.
  ///
  /// At most one waits: past that, the one already waiting has not started
  /// yet and so will pick up whatever has changed by the time it does.
  Future<void> sync() {
    if (_queuedSyncs >= 2) return _syncChain;

    _queuedSyncs++;
    _syncChain = _syncChain.then((_) async {
      try {
        await _runSync();
      } finally {
        _queuedSyncs--;
      }
    });
    return _syncChain;
  }

  /// Takes the arrangement your other devices agreed on.
  ///
  /// The repo wins when it says something different, because the alternative
  /// is two devices each insisting on their own order for ever. Rearranging
  /// writes immediately, so the repo is almost always the newer of the two;
  /// the case this loses is reordering on a device that was offline, which
  /// costs a drag and is obvious when it happens.
  Future<void> _catchUpOnSidebar() async {
    final stored = await _syncService.readSidebar(_config);
    if (stored.isEmpty && _sidebar.isEmpty) return;
    if (stored.isEmpty) {
      // Nothing there yet: this device's arrangement becomes the shared one.
      unawaited(_syncService.writeSidebar(_config, _sidebar));
      return;
    }

    if (stored.sameAs(_sidebar)) {
      // Same arrangement, but the SHA may be newer, and a write without the
      // current one is refused.
      _sidebar = _sidebar.copyWith(sha: stored.sha);
      return;
    }

    _sidebar = stored;
    await _settingsStore.saveSidebar(stored);
    notifyListeners();
  }

  /// Brings this device's shared notebooks into step with the list kept in
  /// your own repo, in both directions.
  ///
  /// One added anywhere appears everywhere, and one given up anywhere goes
  /// everywhere — because "my devices" is one thing to the person holding
  /// them, and a notebook that exists on the phone but not the desktop is
  /// only ever experienced as the desktop having lost a list.
  ///
  /// Returns a sentence worth showing, or null.
  Future<String?> _catchUpOnNotebooks() async {
    if (!_config.isComplete) return null;

    await _catchUpOnSidebar();

    final stored = await _syncService.readNotebooks(_config);
    if (stored.isEmpty && sharedSources.isEmpty) return null;
    final here = NotebookIndex.of(sharedSources);

    // Anything this device has not got yet. Its token comes with it, so there
    // is nothing to paste and nothing to sign in to.
    final known = sharedSources.map((source) => source.id).toSet();
    final arrived = stored.sources
        .where((source) => !known.contains(source.id))
        .toList();

    if (arrived.isNotEmpty) {
      _sources = [..._sources, ...arrived];
      for (final source in arrived) {
        await _settingsStore.saveSharedSources(_sources);
        _projects = [
          ..._projects,
          ...await _localStore.loadAll(sourceId: source.id),
        ];
      }
      _sharedActivity();
      notifyListeners();
      return null;
    }

    // Nothing arrived, so this device is the one with something to say — but
    // only if it actually differs, or every sync would write a commit.
    if (stored.sameAs(here)) return null;
    return _syncService.writeNotebooks(
      _config,
      NotebookIndex.of(sharedSources, sha: stored.sha),
    );
  }

  Future<void> _runSync() async {
    _syncing = true;
    notifyListeners();
    try {
      await _syncOnce();
    } finally {
      // Whatever went wrong, the app is not syncing any more. Leaving this
      // set meant every later push saw a sync in flight and waited for it
      // forever: one unexpected answer from GitHub and nothing saved again
      // until the app was restarted.
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> _syncOnce() async {
    // A push already in flight holds the SHA this sync would write against,
    // so let it land first rather than racing it into a conflict.
    for (var waited = 0; _pushing.isNotEmpty && waited < 30; waited++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    // What was in hand when the sync started. The service works from the
    // copies it loaded then, so this is how a project edited while it ran can
    // be told from one it left alone.
    final before = {for (final project in _projects) project.slug: project};

    // Notebooks your other devices know about, before anything is fetched:
    // one added on the phone should be here on the desktop, with its
    // projects, rather than the desktop quietly missing a list.
    final notebookProblem = await _catchUpOnNotebooks();

    // Each notebook is its own repo, so each is its own sync. One that fails
    // says so without stopping the others: a shared notebook whose token has
    // been revoked should not take your own notes offline with it.
    final synced = <Project>[];
    final problems = <String>[];
    final combined = <String>[];

    for (final source in _sources) {
      if (!source.config.isComplete) {
        synced.addAll(
          _projects.where((project) => project.sourceId == source.id),
        );
        continue;
      }

      final result = await _syncService.sync(
        source.config,
        sourceId: source.id,
      );
      synced.addAll(result.projects);
      combined.addAll(result.merged);
      // An arrangement that arrived is what makes a section a canvas rather
      // than a list, so it goes in alongside the projects it belongs to.
      _layouts.addAll(result.layouts);
      if (result.error != null) {
        problems.add(
          source.isMine ? result.error! : '${source.name}: ${result.error!}',
        );
      }
    }

    // Anything that came back different in a shared notebook means somebody
    // else is writing, which is the moment to start checking often.
    for (final project in synced) {
      if (!project.isShared) continue;
      // One we already had, that has moved. A project appearing for the first
      // time is a notebook being taken on, which is not somebody writing.
      final had = before[project.slug];
      if (had != null && had.sha != project.sha) {
        _sharedActivity();
        break;
      }
    }

    _projects = _reconcile(before, synced);
    // A merge is said out loud but never asked about. Somebody should know
    // their list grew a line they did not write, and should not have to
    // decide anything about it.
    _message = [
      ...problems,
      if (notebookProblem != null) notebookProblem,
      if (combined.isNotEmpty) _mergeNotice(combined),
    ].join('\n');
    if (_message!.isEmpty) _message = null;
    final result = SyncResult(projects: synced, error: _message);
    // Only a sync that actually reached GitHub counts as having heard from
    // it: saying "synced a minute ago" after a failed attempt would be worse
    // than saying nothing.
    if (result.error == null) _lastSynced = DateTime.now();
    _syncGeneration++;
  }

  /// Folds a sync's answer into what is on screen, keeping anything edited
  /// while it was running.
  ///
  /// Taking the result wholesale would replace such a project with its own
  /// older self: the edit disappears from the list, and the SHA it carries is
  /// the one from before the sync wrote the file — which the next push sends,
  /// and GitHub refuses as a conflict nobody caused.
  List<Project> _reconcile(Map<String, Project> before, List<Project> synced) {
    final live = {for (final project in _projects) project.slug: project};
    final reconciled = <Project>[];

    for (final project in synced) {
      final current = live.remove(project.slug);
      final start = before[project.slug];

      // Every edit stamps a new time, so a changed stamp is an edit; the
      // dirty check is there for the edit that lands inside the same
      // millisecond the sync started.
      final editedDuringSync =
          current != null &&
          (start == null ||
              current.updated != start.updated ||
              (current.dirty && !start.dirty));

      // Keep the newer content, but take the SHA the sync learned: that is
      // what the file on GitHub has now, so it is what the next push has to
      // be sent against.
      reconciled.add(
        editedDuringSync
            ? current.copyWith(sha: project.sha, dirty: true)
            : project,
      );
    }

    // What is left is in hand but not in the sync's answer, which is two
    // different things. One made while the sync was running was never in its
    // question either, and must not be dropped for it. One that was there
    // when the sync started and is not in its answer has gone from the repo —
    // deleted, or moved into another notebook — and putting it back here
    // would resurrect it every time.
    for (final project in live.values) {
      if (!before.containsKey(project.slug)) reconciled.add(project);
    }

    return reconciled
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  }

  /// What to say when something was changed in two places at once.
  static String _mergeNotice(List<String> titles) {
    final what = titles.length == 1
        ? '"${titles.single}" was'
        : '${titles.length} lists were';
    return '$what changed here and elsewhere at the same time. '
        'Both sets of changes are in.';
  }

  Future<void> updateConfig(GitHubConfig config) async {
    _config = config;
    _sources = [
      NotesSource.ownedBy(config),
      ..._sources.where((source) => !source.isMine),
    ];
    await _settingsStore.save(config);
    notifyListeners();
    if (config.isComplete) await sync();
  }

  /// Takes on a notebook someone has shared, from the code they sent.
  ///
  /// Returns null when it worked, or a sentence saying why not. Everything
  /// that can go wrong here goes wrong in someone's hands rather than in a
  /// log, so each answer is the next thing they would need to do.
  Future<String?> addSharedNotebook(String code, {String label = ''}) async {
    final config = ShareCode.decode(code);
    if (config == null) {
      return ShareCode.looksLikeOne(code)
          ? 'That code is damaged — ask for it again, and paste the whole of it.'
          : 'That does not look like a share code.';
    }

    if (config.owner == _config.owner && config.repo == _config.repo) {
      return 'That is your own notebook, which you already have.';
    }

    final id = NotesSource.idFor(config);
    if (_sources.any((source) => source.id == id)) {
      return 'You already have that notebook.';
    }

    // Tried before it is kept, so a code that cannot reach anything says so
    // now rather than becoming a notebook that never loads.
    final problem = await testConnection(config);
    if (problem != null) return problem;

    _sources = [..._sources, NotesSource.sharedFrom(config, label: label)];
    await _settingsStore.saveSharedSources(_sources);
    // Somebody who has just pasted a code is about to try it with the person
    // who sent it, so this is the least good moment to be checking slowly.
    _sharedActivity();
    notifyListeners();
    await sync();
    return null;
  }

  /// Gives a shared notebook up: its projects, its local copy and its token.
  ///
  /// What is in the repo is untouched — this is letting go, not a deletion,
  /// and the other people keep it exactly as it was. The token goes, so the
  /// notebook is no longer reachable without the code again.
  ///
  /// Taken out of the list in your own repo at the same time, so it goes from
  /// your other devices too and does not come back on the next sync. That is
  /// the behaviour to want: "my devices" is one thing, and a notebook that
  /// reappeared on the desktop after being given up on the phone would be
  /// indistinguishable from a bug.
  Future<void> forgetSharedNotebook(String id) async {
    if (id == NotesSource.mineId) return;

    _sources = _sources.where((source) => source.id != id).toList();
    _projects = _projects.where((p) => p.sourceId != id).toList();
    if (projectBySlug(_selectedSlug ?? '') == null) _selectedSlug = null;

    await _settingsStore.forgetSharedSource(id);
    await _localStore.forget(id);
    notifyListeners();

    if (_config.isComplete) {
      final stored = await _syncService.readNotebooks(_config);
      if (!stored.isEmpty) {
        await _syncService.writeNotebooks(
          _config,
          NotebookIndex.of(sharedSources, sha: stored.sha),
        );
      }
    }
  }

  /// The code to hand someone so they can reach a shared notebook.
  ///
  /// Null for your own, which has no code: the token in it is the one that
  /// reaches everything you have.
  String? shareCodeFor(String sourceId) {
    final source = _sources.firstWhere(
      (source) => source.id == sourceId,
      orElse: () => NotesSource.ownedBy(_config),
    );
    return source.isMine ? null : ShareCode.encode(source.config);
  }

  /// Checks the repo is reachable with these details. Returns null on success,
  /// or a message explaining what went wrong.
  Future<String?> testConnection(GitHubConfig config) async {
    if (!config.isComplete) return 'Fill in owner, repo, branch and token.';

    final client = _syncService.clientFor(config);
    try {
      await client.checkAccess();
      return null;
    } on GitHubException catch (error) {
      return switch (error.statusCode) {
        401 =>
          'Token rejected. Check it was copied in full and has not expired.',
        403 =>
          'Token lacks permission for this repo. It needs Contents: Read and write.',
        // Signing in and installing the app are separate steps on GitHub, and
        // a sign-in that skipped the install lands here with a valid token
        // that can see nothing. Say so, rather than implying a typo.
        404 =>
          'Cannot see ${config.owner}/${config.repo}. Check the names, and '
              'that the ActionNotes app is installed on this repo — signing in '
              'does not install it, and an app installed nowhere can see '
              'nothing. Install it from its Install App tab under '
              'github.com/settings/apps.',
        _ => error.message,
      };
    } catch (_) {
      return 'Could not reach GitHub.';
    } finally {
      client.dispose();
    }
  }

  Future<Project> createProject(String title) async {
    final slug = _uniqueSlug(Project.slugify(title));
    final now = DateTime.now().toUtc();
    final project = Project(
      slug: slug,
      title: title.trim(),
      created: now,
      updated: now,
      dirty: true,
    );

    _projects = [..._projects, project]
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    await _localStore.save(project, sourceId: project.sourceId);
    notifyListeners();
    _schedulePush(slug);
    return project;
  }

  Future<void> renameProject(String slug, String title) =>
      _mutate(slug, (project) => project.copyWith(title: title.trim()));

  /// Moves a project into another notebook — which is what sharing one is.
  ///
  /// Moved rather than copied, deliberately. Two copies of a list drift apart
  /// within a day and there is no honest way to say afterwards which one was
  /// real; one copy in a place you both reach is the whole point. Bringing it
  /// back is the same move the other way.
  ///
  /// Returns null on success, or a sentence saying why not.
  Future<String?> moveProject(String slug, String toSourceId) async {
    final project = projectBySlug(slug);
    if (project == null) return 'That project is no longer here.';
    if (project.sourceId == toSourceId) return null;

    final target = _sources.where((s) => s.id == toSourceId).firstOrNull;
    if (target == null) return 'That notebook is no longer here.';
    if (!target.config.isComplete) {
      return '${target.name} is not set up to write to.';
    }

    // Written to the new notebook before it is taken out of the old one: a
    // move that failed half way should leave the project where it was, not
    // nowhere.
    final fileSlug = _uniqueSlug(project.fileSlug, sourceId: toSourceId);
    final moved = project.copyWith(
      sourceId: toSourceId,
      // A file in a new repo has never been seen there, so it carries no SHA
      // from the old one — sending that would be a conflict with a file that
      // has nothing to do with it.
      sha: null,
      dirty: true,
    );
    final landed = Project(
      slug: Project.keyOf(toSourceId, fileSlug),
      sourceId: toSourceId,
      title: moved.title,
      items: moved.items,
      notes: moved.notes,
      mode: moved.mode,
      blocks: moved.blocks,
      created: moved.created,
      updated: DateTime.now().toUtc(),
      extraFrontMatter: moved.extraFrontMatter,
      dirty: true,
    );

    await _localStore.save(landed, sourceId: toSourceId);

    // The arrangement goes too, or the canvases arrive as bare lists.
    final layout = layoutFor(slug);
    if (!layout.isEmpty) {
      _layouts[landed.slug] = layout.copyWith(sha: null);
      await _localStore.saveLayout(
        fileSlug,
        _layouts[landed.slug]!,
        sourceId: toSourceId,
      );
    }

    _projects = [..._projects.where((p) => p.slug != slug), landed]
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

    if (_selectedSlug == slug) _selectedSlug = landed.slug;
    _layouts.remove(slug);
    notifyListeners();

    // Now take it out of where it was. Its pictures go with it only as far as
    // the markdown refers to them; moving the files themselves is a thing to
    // do properly rather than quickly, so for now a project with pictures
    // keeps them where they were and says so.
    await _localStore.delete(project.fileSlug, sourceId: project.sourceId);
    final problem = await _syncService.deleteRemote(
      _configFor(project.slug),
      project,
    );

    _schedulePush(landed.slug);
    unawaited(_pushLayout(landed.slug));
    return problem;
  }

  /// Adds an item at the top, where it can be seen — the list is read
  /// newest-first, and the file keeps that same order.
  ///
  /// [block] names the `##` section it belongs to. Within a block the new item
  /// goes above that block's others rather than above the whole project, so it
  /// appears where it was added.
  Future<void> addItem(
    String slug,
    String text, {
    bool starred = false,
    String? block,
  }) => _mutate(slug, (project) {
    final item = ChecklistItem(
      text: text.trim(),
      starred: starred,
      block: block,
    );
    if (block == null) return project.copyWith(items: [item, ...project.items]);

    final items = [...project.items];
    final at = items.indexWhere((existing) => existing.block == block);
    items.insert(at < 0 ? items.length : at, item);
    return project.copyWith(items: items);
  });

  /// Adds a `##` section. A repeated name is left alone rather than making a
  /// second block that could not be told from the first.
  Future<void> addBlock(String slug, String title) => _mutate(slug, (project) {
    final name = title.trim();
    if (name.isEmpty || project.blocks.any((b) => b.title == name)) {
      return project;
    }
    return project.copyWith(
      blocks: [
        ...project.blocks,
        ProjectBlock(title: name),
      ],
    );
  });

  /// Moves a `##` section, and the items under it, to another place in the
  /// project.
  ///
  /// The flat item list is rebuilt to match, so the order on screen, the order
  /// in the file and the order of the indices everything else uses stay one
  /// order rather than three.
  Future<void> reorderBlocks(String slug, int oldIndex, int newIndex) =>
      _mutate(slug, (project) {
        final blocks = [...project.blocks];
        if (oldIndex < 0 || oldIndex >= blocks.length) return project;

        // A list that reorders downwards reports the index the row will sit
        // at once it has been taken out, so close the gap first.
        var target = newIndex;
        if (target > oldIndex) target -= 1;
        target = target.clamp(0, blocks.length - 1);
        if (target == oldIndex) return project;

        blocks.insert(target, blocks.removeAt(oldIndex));

        return project.copyWith(
          blocks: blocks,
          items: [
            ...project.itemsIn(null),
            for (final block in blocks) ...project.itemsIn(block.title),
          ],
        );
      });

  /// Removes a `##` section, its items and its prose.
  ///
  /// The one place in the app that deletes several things at once, so the
  /// caller asks first. Its canvas goes too, since a layout for a heading that
  /// no longer exists would sit in the file for ever.
  Future<void> deleteBlock(String slug, String title) async {
    final layout = layoutFor(slug);
    if (layout.isCanvas(title)) {
      _layouts[slug] = layout.withoutSection(title);
      unawaited(_pushLayout(slug));
    }

    await _mutate(
      slug,
      (project) => project.copyWith(
        blocks: [
          for (final block in project.blocks)
            if (block.title != title) block,
        ],
        items: [
          for (final item in project.items)
            if (item.block != title) item,
        ],
      ),
    );
  }

  Future<void> setBlockBody(String slug, String title, String body) =>
      _mutate(slug, (project) {
        final blocks = [
          for (final block in project.blocks)
            block.title == title ? block.copyWith(body: body) : block,
        ];
        return project.copyWith(blocks: blocks);
      });

  /// Renames a section, carrying its items with it — they name their block, so
  /// renaming one without the other would orphan them.
  Future<void> renameBlock(String slug, String from, String to) =>
      _mutate(slug, (project) {
        final name = to.trim();
        if (name.isEmpty || name == from) return project;
        if (project.blocks.any((block) => block.title == name)) return project;

        // The canvas is keyed by the section's name, so it has to follow or
        // it is left pointing at a heading that has gone.
        _renameCanvasSection(slug, from, name);

        return project.copyWith(
          blocks: [
            for (final block in project.blocks)
              block.title == from ? block.copyWith(title: name) : block,
          ],
          items: [
            for (final item in project.items)
              item.block == from ? item.copyWith(block: name) : item,
          ],
        );
      });

  Future<void> toggleItem(String slug, int index) => _mutate(slug, (project) {
    final items = [...project.items];
    items[index] = items[index].copyWith(done: !items[index].done);
    return project.copyWith(items: items);
  });

  Future<void> editItem(String slug, int index, String text) =>
      _mutate(slug, (project) {
        final items = [...project.items];
        items[index] = items[index].copyWith(text: text.trim());
        return project.copyWith(items: items);
      });

  Future<void> toggleStar(String slug, int index) => _mutate(slug, (project) {
    final items = [...project.items];
    items[index] = items[index].copyWith(starred: !items[index].starred);
    return project.copyWith(items: items);
  });

  Future<void> setItemNotes(String slug, int index, String notes) =>
      _mutate(slug, (project) {
        final items = [...project.items];
        items[index] = items[index].copyWith(notes: notes.trim());
        return project.copyWith(items: items);
      });

  /// Uploads [bytes] as an attachment on [slug] and returns the markdown
  /// reference to paste into a note, or null with a message set on failure.
  Future<String?> attachImage(
    String slug, {
    required String fileName,
    required List<int> bytes,
  }) async {
    if (!_configFor(slug).isComplete) {
      _message = 'Connect a GitHub repo in Settings before attaching images.';
      notifyListeners();
      return null;
    }

    final project = projectBySlug(slug);
    if (project == null) return null;

    // Names already referenced by this project's notes, so a second upload of
    // the same filename does not overwrite the first.
    final taken = <String>{};
    for (final item in project.items) {
      for (final match in RegExp(
        r'attachments/[^/]+/([^)\s]+)',
      ).allMatches(item.notes)) {
        taken.add(match.group(1)!);
      }
    }

    // The clipboard hands over bitmaps on Windows, so normalise before
    // naming: a file called .png has to actually be one.
    final encoded = ImageEncoder.prepare(fileName, bytes);
    final name = AttachmentStore.uniqueFileName(encoded.fileName, taken);
    final repoPath = AttachmentStore.repoPath(project.fileSlug, name);

    try {
      await _syncService.uploadAttachment(
        // The project's own notebook, not yours: an image attached to a
        // shared list belongs beside the list, or the markdown points at a
        // file nobody else can reach.
        _configFor(slug),
        path: repoPath,
        bytes: encoded.bytes,
        message: 'Add attachment $name to ${project.title}',
      );
      // Cache it so the note renders without a round trip.
      await attachments.save(repoPath, encoded.bytes);
      return '![$name]'
          '(${AttachmentStore.markdownPath(project.fileSlug, name)})';
    } on GitHubException catch (error) {
      _message = 'Could not upload the image: ${error.message}';
      notifyListeners();
      return null;
    } catch (_) {
      _message = 'Could not reach GitHub to upload the image.';
      notifyListeners();
      return null;
    }
  }

  /// Moves an item to another project, notes and attachments included.
  ///
  /// The attachments are the reason this is not two list edits: a note refers
  /// to `../attachments/<slug>/file`, and the tidy-up that follows a push
  /// deletes any file the project no longer mentions. Leaving the references
  /// pointing at the old project would have its images deleted underneath it,
  /// so each one is copied across and the references rewritten first. If a
  /// copy cannot be made the move does not happen, which is better than a
  /// move that loses the pictures.
  ///
  /// Returns null on success, or a message saying why not.
  Future<String?> moveItem(String fromSlug, int index, String toSlug) async {
    if (fromSlug == toSlug) return null;

    final from = projectBySlug(fromSlug);
    final to = projectBySlug(toSlug);
    if (from == null || to == null) return 'That project is no longer here.';
    if (index >= from.items.length) return 'That item is no longer here.';

    final item = from.items[index];

    // Names already used in the target, so a copy cannot overwrite one of its
    // own images.
    final taken = <String>{};
    for (final existing in to.items) {
      taken.addAll(ProjectLinks.attachmentNames(existing.notes));
    }

    var notes = item.notes;
    for (final name in ProjectLinks.attachmentNames(item.notes)) {
      final copied = await _copyAttachment(
        name: name,
        fromSlug: fromSlug,
        toSlug: toSlug,
        taken: taken,
      );
      if (copied == null) {
        return 'Could not copy "$name" to ${to.title}, so nothing was moved.';
      }
      taken.add(copied);
      notes = notes.replaceAll(
        AttachmentStore.markdownPath(fromSlug, name),
        AttachmentStore.markdownPath(toSlug, copied),
      );
    }

    // The note open on the source project cannot be trusted afterwards, for
    // the same reason a removal closes it: the indexes shift.
    if (_openNote?.slug == fromSlug) _openNote = null;

    await _mutate(fromSlug, (project) {
      final items = [...project.items]..removeAt(index);
      return project.copyWith(items: items);
    });
    await _mutate(
      toSlug,
      (project) => project.copyWith(
        items: [
          item.copyWith(notes: notes),
          ...project.items,
        ],
      ),
    );
    return null;
  }

  /// Copies one attachment into another project's folder, returning the name
  /// it was given, or null if it could not be copied.
  ///
  /// Read from the notebook it is in and written to the notebook it is going
  /// to, which are not always the same one: an item can be moved out of a
  /// shared list into your own, and its pictures have to make the same trip
  /// or the note arrives pointing at nothing.
  Future<String?> _copyAttachment({
    required String name,
    required String fromSlug,
    required String toSlug,
    required Set<String> taken,
  }) async {
    try {
      final bytes = await attachments.bytesFor(
        AttachmentStore.repoPath(_fileSlug(fromSlug), name),
        _configFor(fromSlug),
      );
      if (bytes == null) return null;

      final copied = AttachmentStore.uniqueFileName(name, taken);
      final path = AttachmentStore.repoPath(_fileSlug(toSlug), copied);
      await _syncService.uploadAttachment(
        _configFor(toSlug),
        path: path,
        bytes: bytes,
        message: 'Copy attachment $copied for a moved item',
      );
      await attachments.save(path, bytes);
      return copied;
    } catch (_) {
      return null;
    }
  }

  Future<void> removeItem(String slug, int index) {
    // Removing an item shifts the indexes after it, so a note open on this
    // project can no longer be trusted to point at the item it was opened on.
    if (_openNote?.slug == slug) _openNote = null;

    return _mutate(slug, (project) {
      final items = [...project.items]..removeAt(index);
      return project.copyWith(items: items);
    });
  }

  /// Reorders the items occupying [slots], which are positions in the
  /// project's own item list, ascending. [newIndex] counts within [slots] and
  /// is the destination index — what onReorderItem already gives us, so no
  /// off-by-one adjustment is needed here.
  ///
  /// The view passes the slots it is actually showing, so dragging within one
  /// group never disturbs items in another — a completed item, or an
  /// unstarred one, stays where it is in the file.
  Future<void> reorderSlots(
    String slug,
    List<int> slots,
    int oldIndex,
    int newIndex,
  ) => _mutate(slug, (project) {
    final picked = [for (final slot in slots) project.items[slot]];
    picked.insert(newIndex, picked.removeAt(oldIndex));

    final items = [...project.items];
    for (var i = 0; i < slots.length; i++) {
      items[slots[i]] = picked[i];
    }
    return project.copyWith(items: items);
  });

  /// Moves completed items out of the list and into `archive/<slug>.md`.
  ///
  /// It used to delete them, which is the one thing a checklist should not do
  /// to something you finished — and in my own notes repo, the one thing the
  /// working agreement forbids. They are written to the archive first and
  /// only then taken out of the list, so a failure leaves the list as it was.
  ///
  /// Returns null on success, or a message saying why nothing was archived.
  Future<String?> archiveCompleted(String slug) async {
    final project = projectBySlug(slug);
    if (project == null) return null;

    final done = project.items.where((item) => item.done).toList();
    if (done.isEmpty) return 'Nothing is completed yet.';

    final problem = await _syncService.archiveItems(
      _configFor(project.slug),
      project,
      done,
    );
    if (problem != null) return problem;

    await _mutate(
      slug,
      (current) => current.copyWith(
        items: current.items.where((item) => !item.done).toList(),
      ),
    );
    return null;
  }

  // --- Canvases -----------------------------------------------------------
  //
  // A canvas's content is the section's markdown, the same as any other
  // section. Only the arrangement lives here, in a file beside the project,
  // and it is the layout that says which sections are canvases at all — so a
  // project with no layout has no canvases and shows its sections as notes.

  final Map<String, CanvasLayout> _layouts = {};

  /// What a canvas looked like before each of the last few changes, and what
  /// was undone from it.
  ///
  /// A canvas is the one place in this app where a single action can rearrange
  /// a great deal of careful work — packing a board, or aligning the wrong
  /// selection — and where the result is a picture rather than a list, so
  /// putting it back by hand is not really possible. Both files are captured,
  /// the markdown and the arrangement, so adding and deleting cards can be
  /// taken back as well as moving them.
  final Map<String, List<CanvasStep>> _canvasUndo = {};
  final Map<String, List<CanvasStep>> _canvasRedo = {};

  static const _canvasHistoryDepth = 60;

  String _historyKey(String slug, String section) => '$slug\u0000$section';

  bool canUndoCanvas(String slug, String section) =>
      _canvasUndo[_historyKey(slug, section)]?.isNotEmpty ?? false;

  bool canRedoCanvas(String slug, String section) =>
      _canvasRedo[_historyKey(slug, section)]?.isNotEmpty ?? false;

  /// The canvas as it stands, for the history to hold on to.
  CanvasStep? _canvasStep(String slug, String section) {
    final project = projectBySlug(slug);
    if (project == null) return null;

    final block = project.blocks.firstWhere(
      (block) => block.title == section,
      orElse: () => const ProjectBlock(title: ''),
    );
    if (block.title.isEmpty) return null;

    return CanvasStep(
      body: block.body,
      spots: List.unmodifiable(layoutFor(slug).spotsFor(section)),
      shapes: List.unmodifiable(layoutFor(slug).drawingFor(section)),
    );
  }

  /// Remembers the canvas before something changes it.
  void _rememberCanvas(String slug, String section) {
    final step = _canvasStep(slug, section);
    if (step == null) return;

    final key = _historyKey(slug, section);
    final history = _canvasUndo.putIfAbsent(key, () => []);
    // Nothing changed: a repeated identical step would make undo look broken
    // by appearing to do nothing.
    if (history.isNotEmpty && history.last == step) return;

    history.add(step);
    if (history.length > _canvasHistoryDepth) history.removeAt(0);
    // A fresh change is a new branch, so what was undone is no longer ahead.
    _canvasRedo.remove(key);
  }

  Future<void> undoCanvas(String slug, String section) =>
      _stepCanvas(slug, section, from: _canvasUndo, to: _canvasRedo);

  Future<void> redoCanvas(String slug, String section) =>
      _stepCanvas(slug, section, from: _canvasRedo, to: _canvasUndo);

  Future<void> _stepCanvas(
    String slug,
    String section, {
    required Map<String, List<CanvasStep>> from,
    required Map<String, List<CanvasStep>> to,
  }) async {
    final key = _historyKey(slug, section);
    final history = from[key];
    if (history == null || history.isEmpty) return;

    final now = _canvasStep(slug, section);
    final step = history.removeLast();
    if (now != null) {
      (to.putIfAbsent(key, () => [])).add(now);
    }

    _layouts[slug] = layoutFor(
      slug,
    ).withSection(section, step.spots).withDrawing(section, step.shapes);
    unawaited(_pushLayout(slug));
    await setBlockBody(slug, section, step.body);
  }

  final Map<String, Timer> _layoutTimers = {};

  CanvasLayout layoutFor(String slug) => _layouts[slug] ?? CanvasLayout.empty;

  bool isCanvas(String slug, String section) =>
      layoutFor(slug).isCanvas(section);

  Future<void> _loadLayout(String slug) async {
    final layout = await _localStore.loadLayout(
      _fileSlug(slug),
      sourceId: sourceOf(slug).id,
    );
    if (layout.isEmpty) return;
    _layouts[slug] = layout;
    notifyListeners();
  }

  /// Turns a section into a canvas, or back into notes.
  ///
  /// Nothing is rewritten either way: the section's markdown is the same list
  /// of pictures and notes, and only whether there is an arrangement for it
  /// changes. Turning a canvas back into notes forgets where things were —
  /// which is the cost of the arrangement living in its own file, and is said
  /// plainly rather than hidden.
  /// How a canvas is drawn: its height in a project, its background, whether
  /// it keeps its own light or dark.
  CanvasSettings canvasSettings(String slug, String section) =>
      layoutFor(slug).settingsFor(section);

  Future<void> setCanvasSettings(
    String slug,
    String section,
    CanvasSettings settings,
  ) async {
    final layout = layoutFor(slug);
    if (layout.settingsFor(section) == settings) return;

    _layouts[slug] = layout.withSettings(section, settings);
    notifyListeners();
    await _pushLayout(slug);
  }

  Future<void> setCanvas(String slug, String section, bool canvas) async {
    final layout = layoutFor(slug);
    if (layout.isCanvas(section) == canvas) return;

    _layouts[slug] = canvas
        ? layout.withSection(section, const [])
        : layout.withoutSection(section);
    notifyListeners();
    await _pushLayout(slug);
  }

  /// Puts a new card on a canvas.
  ///
  /// Appended to the section's markdown as another bullet, which is all a card
  /// is — the arrangement follows on its own, since a card with no position is
  /// laid down in free space rather than on the pile.
  Future<void> addCanvasCard(
    String slug,
    String section,
    String markdown,
  ) async {
    final project = projectBySlug(slug);
    if (project == null) return;

    final block = project.blocks.firstWhere(
      (block) => block.title == section,
      orElse: () => const ProjectBlock(title: ''),
    );
    if (block.title.isEmpty) return;

    _rememberCanvas(slug, section);

    final cards = [
      ...CanvasCards.parse(block.body),
      CanvasCards.text(markdown),
    ];
    await setBlockBody(slug, section, CanvasCards.serialize(cards));
  }

  /// What has been drawn on a canvas: the arrows, boxes and pen strokes that
  /// are marks on the board rather than things written on it.
  List<CanvasShape> canvasDrawing(String slug, String section) =>
      layoutFor(slug).drawingFor(section);

  /// Adds one mark to a canvas.
  Future<void> addCanvasShape(
    String slug,
    String section,
    CanvasShape shape,
  ) async {
    if (!shape.isDrawable) return;
    _rememberCanvas(slug, section);

    _layouts[slug] = layoutFor(
      slug,
    ).withDrawing(section, [...layoutFor(slug).drawingFor(section), shape]);
    notifyListeners();
    await _pushLayout(slug);
  }

  /// Replaces one mark — a node added, moved or taken out, or a line bent.
  Future<void> setCanvasShape(
    String slug,
    String section,
    int index,
    CanvasShape shape,
  ) async {
    final shapes = layoutFor(slug).drawingFor(section);
    if (index < 0 || index >= shapes.length) return;
    if (shapes[index] == shape || !shape.isDrawable) return;

    _rememberCanvas(slug, section);
    _layouts[slug] = layoutFor(slug).withDrawing(section, [
      for (var i = 0; i < shapes.length; i++)
        if (i == index) shape else shapes[i],
    ]);
    notifyListeners();
    await _pushLayout(slug);
  }

  /// Rubs marks out. Nothing to rub out is not a change, so it does not make
  /// a step for undo to come back to.
  Future<void> removeCanvasShapes(
    String slug,
    String section,
    Set<int> indices,
  ) async {
    final shapes = layoutFor(slug).drawingFor(section);
    final going = indices.where((at) => at >= 0 && at < shapes.length).toSet();
    if (going.isEmpty) return;

    _rememberCanvas(slug, section);
    _layouts[slug] = layoutFor(slug).withDrawing(section, [
      for (var i = 0; i < shapes.length; i++)
        if (!going.contains(i)) shapes[i],
    ]);
    notifyListeners();
    await _pushLayout(slug);
  }

  /// Puts a card on a canvas at a given spot, rather than wherever there was
  /// room.
  ///
  /// This is how everything the side tools place arrives: a sticky note, a
  /// caption, a frame. The text is a bullet in the section's markdown like
  /// every other card, so a canvas read anywhere else is still a readable
  /// list; what sort of card it is and where it sits are the layout file's
  /// business.
  Future<void> placeCanvasCard(
    String slug,
    String section, {
    required String markdown,
    required CanvasSpot spot,
    bool behind = false,
  }) async {
    final project = projectBySlug(slug);
    if (project == null) return;

    final block = project.blocks.firstWhere(
      (block) => block.title == section,
      orElse: () => const ProjectBlock(title: ''),
    );
    if (block.title.isEmpty) return;

    _rememberCanvas(slug, section);

    final existing = CanvasPlacement.place(
      CanvasCards.parse(block.body),
      layoutFor(slug).spotsFor(section),
    );

    var z = 0;
    for (final other in existing) {
      if (behind) {
        if (other.z <= z) z = other.z - 1;
      } else if (other.z >= z) {
        z = other.z + 1;
      }
    }

    final card = CanvasCards.text(markdown);
    _layouts[slug] = layoutFor(
      slug,
    ).withSection(section, [...existing, spot.copyWith(ref: card.ref, z: z)]);
    unawaited(_pushLayout(slug));

    await setBlockBody(
      slug,
      section,
      CanvasCards.serialize([...CanvasCards.parse(block.body), card]),
    );
  }

  /// Puts a frame on a canvas: a labelled rectangle to group things inside.
  ///
  /// Behind the cards, because a frame is what the others stand on.
  Future<void> addCanvasFrame(
    String slug,
    String section, {
    String title = 'Frame',
    double x = 40,
    double y = 40,
    double width = 560,
    double height = 400,
  }) => placeCanvasCard(
    slug,
    section,
    markdown: title,
    behind: true,
    spot: CanvasSpot(
      x: x,
      y: y,
      width: width,
      height: height,
      kind: CanvasSpotKind.frame,
    ),
  );

  /// Rewrites one card's markdown, leaving where it sits alone.
  ///
  /// Renaming a frame and editing a note on the board are the same operation:
  /// a card is its markdown, and its position is somewhere else entirely.
  Future<void> setCanvasCard(
    String slug,
    String section,
    int index,
    String markdown,
  ) async {
    final project = projectBySlug(slug);
    if (project == null) return;

    final block = project.blocks.firstWhere(
      (block) => block.title == section,
      orElse: () => const ProjectBlock(title: ''),
    );
    if (block.title.isEmpty) return;

    final cards = CanvasCards.parse(block.body);
    if (index < 0 || index >= cards.length) return;
    if (markdown.trim().isEmpty) return;

    _rememberCanvas(slug, section);
    cards[index] = CanvasCards.text(markdown);

    // The position points at the card by what the card said, so a renamed
    // card takes its position's ref with it rather than looking like a new
    // one that has never been placed.
    final spots = [...layoutFor(slug).spotsFor(section)];
    if (index < spots.length) {
      final was = spots[index].ref;
      final now = cards[index].ref;
      spots[index] = spots[index].copyWith(ref: now);

      // An arrow holding on to this card names it by what it said, so the
      // hold has to follow the rename or the arrow would quietly let go.
      CanvasAnchor? renamed(CanvasAnchor? anchor) =>
          anchor == null || anchor.ref != was
          ? anchor
          : CanvasAnchor(ref: now, ax: anchor.ax, ay: anchor.ay);

      final drawing = [
        for (final shape in layoutFor(slug).drawingFor(section))
          shape.isStuck
              ? CanvasShape(
                  kind: shape.kind,
                  points: shape.points,
                  colour: shape.colour,
                  thickness: shape.thickness,
                  from: renamed(shape.from),
                  to: renamed(shape.to),
                )
              : shape,
      ];

      _layouts[slug] = layoutFor(
        slug,
      ).withSection(section, spots).withDrawing(section, drawing);
      unawaited(_pushLayout(slug));
    }

    await setBlockBody(slug, section, CanvasCards.serialize(cards));
  }

  /// Takes a card off a canvas, which is to say out of the section's markdown.
  ///
  /// The position goes with it: a spot whose card has gone would be dropped
  /// the next time the two were paired anyway, and leaving it would shift
  /// every later card along by one until it was.
  Future<void> removeCanvasCard(String slug, String section, int index) async {
    final project = projectBySlug(slug);
    if (project == null) return;

    final block = project.blocks.firstWhere(
      (block) => block.title == section,
      orElse: () => const ProjectBlock(title: ''),
    );
    if (block.title.isEmpty) return;

    final cards = CanvasCards.parse(block.body);
    if (index < 0 || index >= cards.length) return;
    _rememberCanvas(slug, section);
    cards.removeAt(index);

    final spots = [...layoutFor(slug).spotsFor(section)];
    if (index < spots.length) {
      spots.removeAt(index);
      _layouts[slug] = layoutFor(slug).withSection(section, spots);
      unawaited(_pushLayout(slug));
    }

    await setBlockBody(slug, section, CanvasCards.serialize(cards));
  }

  /// Puts a copy of a card on the canvas beside the original.
  ///
  /// Both the markdown and the arrangement gain an entry, so the copy is a
  /// card in its own right rather than the same one drawn twice.
  Future<void> duplicateCanvasCard(
    String slug,
    String section,
    int index,
  ) async {
    final project = projectBySlug(slug);
    if (project == null) return;

    final block = project.blocks.firstWhere(
      (block) => block.title == section,
      orElse: () => const ProjectBlock(title: ''),
    );
    if (block.title.isEmpty) return;

    final cards = CanvasCards.parse(block.body);
    if (index < 0 || index >= cards.length) return;
    _rememberCanvas(slug, section);
    cards.insert(index + 1, cards[index]);

    final spots = [...layoutFor(slug).spotsFor(section)];
    if (index < spots.length) {
      final from = spots[index];
      spots.insert(
        index + 1,
        // Offset a little, so the copy is visibly a second card rather than
        // one exactly on top of another.
        from.copyWith(x: from.x + 24, y: from.y + 24, locked: false),
      );
      _layouts[slug] = layoutFor(slug).withSection(section, spots);
      unawaited(_pushLayout(slug));
    }

    await setBlockBody(slug, section, CanvasCards.serialize(cards));
  }

  Future<void> setCanvasSpots(
    String slug,
    String section,
    List<CanvasSpot> spots, {
    bool remember = true,
  }) async {
    if (remember) _rememberCanvas(slug, section);
    _layouts[slug] = layoutFor(slug).withSection(section, spots);
    notifyListeners();

    // Settled for a moment first: dragging a card across a canvas would
    // otherwise be a commit per frame.
    _layoutTimers[slug]?.cancel();
    _layoutTimers[slug] = Timer(_pushDelay, () => _pushLayout(slug));
  }

  Future<void> _renameCanvasSection(String slug, String from, String to) async {
    final layout = layoutFor(slug);
    if (!layout.isCanvas(from)) return;
    _layouts[slug] = layout.renameSection(from, to);
    await _pushLayout(slug);
  }

  Future<void> _pushLayout(String slug) async {
    _layoutTimers.remove(slug)?.cancel();
    final layout = layoutFor(slug);
    await _localStore.saveLayout(
      _fileSlug(slug),
      layout,
      sourceId: sourceOf(slug).id,
    );
    if (!_configFor(slug).isComplete) return;

    try {
      final pushed = await _syncService.writeLayout(
        _configFor(slug),
        _fileSlug(slug),
        layout,
      );
      // Adopt the SHA whatever else has happened in the meantime, the same as
      // a project push does: throwing it away is what made every later write
      // fail against a SHA GitHub had already moved past.
      _layouts[slug] = layoutFor(slug).copyWith(sha: pushed.sha);
      await _localStore.saveLayout(
        _fileSlug(slug),
        _layouts[slug]!,
        sourceId: sourceOf(slug).id,
      );
    } catch (_) {
      // An arrangement is worth no interruption. It is saved on the device and
      // the next change will try again.
    }
  }

  Future<void> setNotes(String slug, String notes) =>
      _mutate(slug, (project) => project.copyWith(notes: notes));

  /// Switches a project between a checklist and a document.
  ///
  /// Nothing is converted: the items and the body are both kept, so a project
  /// turned into notes and back is the file it was. Only which view opens
  /// changes, and a checklist keeps its front matter untouched.
  Future<void> setMode(String slug, ProjectMode mode) =>
      _mutate(slug, (project) => project.copyWith(mode: mode));

  Future<void> deleteProject(String slug) async {
    final project = projectBySlug(slug);
    if (project == null) return;

    _pendingPushes.remove(slug)?.cancel();
    if (_selectedSlug == slug) _selectedSlug = null;
    if (_openNote?.slug == slug) _openNote = null;
    _projects = _projects.where((p) => p.slug != slug).toList();
    await _localStore.delete(project.fileSlug, sourceId: project.sourceId);
    notifyListeners();

    final problem = await _syncService.deleteRemote(
      _configFor(project.slug),
      project,
    );
    if (problem != null) {
      _message = problem;
      notifyListeners();
    }
  }

  void dismissMessage() {
    if (_message == null) return;
    _message = null;
    notifyListeners();
  }

  Future<void> _mutate(String slug, Project Function(Project) change) async {
    final current = projectBySlug(slug);
    if (current == null) return;

    final updated = change(
      current,
    ).copyWith(updated: DateTime.now().toUtc(), dirty: true);

    _projects = _projects.map((p) => p.slug == slug ? updated : p).toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    await _localStore.save(updated, sourceId: updated.sourceId);
    notifyListeners();
    _schedulePush(slug);
  }

  /// Coalesces rapid edits into one commit, so ticking five boxes in a row
  /// does not produce five commits.
  ///
  /// Asks the project's own notebook whether it can be written to, not your
  /// own repo. Everybody after the first person has no repo of their own —
  /// they pasted a code and that is the whole of their setup — so gating this
  /// on yours meant nothing they wrote was ever pushed. It sat dirty until a
  /// sync happened to carry it, which is how two people editing the same list
  /// ended up in a conflict nobody caused.
  void _schedulePush(String slug) {
    if (!_configFor(slug).isComplete) return;
    if (projectBySlug(slug)?.isShared ?? false) _sharedActivity();

    _pendingPushes.remove(slug)?.cancel();
    _pendingPushes[slug] = Timer(_pushDelay, () => _pushNow(slug));
  }

  /// Pushes one project, one at a time.
  ///
  /// GitHub accepts a write only against the SHA the file currently has, so
  /// two pushes of the same project must not overlap: the second would send
  /// the SHA the first has already moved past, and come back as a conflict
  /// nobody caused. A push arriving while one is in flight waits instead, and
  /// goes out afterwards with the SHA that one brought back.
  Future<void> _pushNow(String slug) async {
    _pendingPushes.remove(slug);

    // A sync pushes the dirty projects itself, so pushing during one would be
    // the same two-writes-one-SHA race from the other direction.
    if (_syncing) {
      _schedulePush(slug);
      return;
    }

    if (_pushing.contains(slug)) {
      _schedulePush(slug);
      return;
    }

    final project = projectBySlug(slug);
    if (project == null || !project.dirty) return;

    _pushing.add(slug);
    final Project pushed;
    try {
      pushed = await _syncService.push(_configFor(project.slug), project);
    } finally {
      _pushing.remove(slug);
    }

    if (pushed.dirty) return; // Still pending; the next sync will retry.

    // An image dropped from a note leaves its file behind, so tidy up once
    // the note itself has landed.
    unawaited(
      _syncService.pruneAttachments(
        _configFor(pushed.slug),
        pushed,
        // A picture this device still holds but the repo has lost goes back
        // up. That is how the ones the old sweep deleted return: whoever
        // added them still has them, and everybody else has a broken square.
        recover: (path) async {
          final file = await attachments.cached(path);
          return file?.readAsBytes();
        },
      ),
    );

    final latest = projectBySlug(slug);
    if (latest == null) return;

    // The write landed, so GitHub's copy has this SHA whatever has been
    // edited here since. Keeping the old one is what made a later push look
    // like a conflict. What the edits do change is whether there is still
    // something to send.
    final editedWhilePushing = latest.updated != project.updated;
    final settled = latest.copyWith(sha: pushed.sha, dirty: editedWhilePushing);

    _projects = _projects.map((p) => p.slug == slug ? settled : p).toList();
    await _localStore.save(settled, sourceId: settled.sourceId);
    notifyListeners();

    if (editedWhilePushing) _schedulePush(slug);
  }

  /// A file name nothing in [sourceId] is already using.
  String _uniqueSlug(String base, {String sourceId = NotesSource.mineId}) {
    final taken = _projects
        .where((p) => p.sourceId == sourceId)
        .map((p) => p.fileSlug)
        .toSet();

    if (!taken.contains(base)) return base;
    var suffix = 2;
    while (taken.contains('$base-$suffix')) {
      suffix++;
    }
    return '$base-$suffix';
  }

  bool _disposed = false;

  /// Nothing to say once nobody is listening.
  ///
  /// A sync started before the app let go of this can land after it: the
  /// request is already in flight and cannot be recalled. Without this it
  /// arrives to find a disposed notifier and throws, which is a crash caused
  /// entirely by good timing.
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stopWatching();
    for (final timer in _pendingPushes.values) {
      timer.cancel();
    }
    _pendingPushes.clear();
    // The canvas layouts settle on their own timers too, and a canvas left
    // mid-drag when the app closes would otherwise keep one alive.
    for (final timer in _layoutTimers.values) {
      timer.cancel();
    }
    _layoutTimers.clear();
    super.dispose();
  }
}
