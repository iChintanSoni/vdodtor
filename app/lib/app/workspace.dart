import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../commands/document_store.dart';
import '../media/file_access.dart';
import '../model/ids.dart';
import '../model/project.dart';
import '../model/time.dart';
import '../persistence/app_paths.dart';
import '../persistence/autosave.dart';
import '../persistence/library.dart';
import '../persistence/project_file.dart';
import '../persistence/recents.dart';
import '../persistence/session.dart';
import '../pro/entitlement.dart';

/// What the window is showing.
enum WorkspaceStage {
  /// Resolving paths and reading the recents list. Milliseconds, normally.
  starting,

  /// The project chooser: create a project, or reopen one.
  chooser,

  /// A project is open.
  editing,

  /// The app could not reach its own storage. Nothing else will work.
  failed,
}

/// A project file, as the chooser lists it.
final class ProjectEntry {
  const ProjectEntry({
    required this.path,
    required this.name,
    required this.lastOpened,
    required this.exists,
    required this.inLibrary,
  });

  final String path;
  final String name;
  final DateTime lastOpened;

  /// False for a project that has been moved or deleted behind the app's back.
  /// Listed anyway, greyed out, because "where did my project go" deserves an
  /// answer rather than a shorter list.
  final bool exists;

  /// True when the file lives in vdodtor's own library folder.
  final bool inLibrary;
}

/// The project that was open when the app died.
final class RecoveryNotice {
  const RecoveryNotice({required this.path, required this.name});

  final String path;
  final String name;
}

/// A project, open: the document, where it lives, and the autosave keeping the
/// two in step.
final class OpenProject {
  OpenProject({
    required this.path,
    required this.store,
    required this.file,
    required this.autosaver,
  });

  final String path;
  final DocumentStore store;
  final ProjectFile file;
  final Autosaver autosaver;

  Project get project => store.project;
  String get name => store.project.name;

  /// Assets whose file the app cannot currently reach — moved, deleted, or on
  /// a volume that is not mounted. The bin greys these out.
  Set<String> unreachableMediaIds = const {};
}

/// The app shell: which project is open, and everything about getting there.
///
/// Splitting this out of the widget tree is what lets the whole lifecycle —
/// create, open, autosave, crash recovery, quit — be tested without a window,
/// which matters because that lifecycle is the part where losing someone's
/// work is possible.
class Workspace extends ChangeNotifier {
  Workspace({
    AppPaths? paths,
    IdGen? ids,
    FileAccess? access,
    Entitlement? entitlement,
    Future<AppPaths> Function()? resolvePaths,
    this.autosaveDebounce = const Duration(milliseconds: 400),
  })  : _ids = ids ?? IdGen(),
        _access = access ?? const SystemFileAccess(),
        entitlement = entitlement ?? Entitlement.free(),
        _resolvePaths = resolvePaths ?? AppPaths.resolve {
    _paths = paths;
  }

  final IdGen _ids;

  /// What this installation has paid for. Owned here, beside the paths and
  /// the recents list, because it is app-wide and outlives every project —
  /// and because the licence it will be read from lives under [AppPaths] with
  /// the rest of the app's private state.
  final Entitlement entitlement;

  /// How the app gets at the user's own media. Injected so opening a project
  /// full of bookmarked footage is testable without a sandbox.
  final FileAccess _access;

  /// Paths whose security scope this run has opened, to be closed when the
  /// project does. Not a leak worth ignoring: macOS caps how many a process
  /// may hold at once, and an editor opened and closed all day would run out.
  final Set<String> _granted = {};

  /// Injected so the "cannot reach storage" path has a test.
  final Future<AppPaths> Function() _resolvePaths;

  final Duration autosaveDebounce;

  AppPaths? _paths;
  // Assigned by start(), which may run more than once: a workspace that
  // failed to reach its storage is allowed to try again.
  late ProjectLibrary _library;
  late RecentProjects _recents;
  late SessionMarker _session;

  WorkspaceStage _stage = WorkspaceStage.starting;
  List<ProjectEntry> _projects = const [];
  OpenProject? _open;
  RecoveryNotice? _recovery;
  String? _notice;
  Object? _failure;

  WorkspaceStage get stage => _stage;
  List<ProjectEntry> get projects => _projects;
  OpenProject? get open => _open;

  /// Set when the previous run ended without closing its project.
  RecoveryNotice? get recovery => _recovery;

  /// The last thing that went wrong and the user should know about: a project
  /// that would not open, a save that failed, a document read from its backup.
  String? get notice => _notice;

  /// Why the app cannot run at all. Only set in [WorkspaceStage.failed].
  Object? get failure => _failure;

  AppPaths get paths => _paths!;

  /// How the app reaches the user's own media. The editor imports through it.
  FileAccess get fileAccess => _access;

  /// Resolves storage, reads the recents list, and works out whether the last
  /// run ended badly.
  Future<void> start() async {
    try {
      _paths ??= await _resolvePaths();
      _library = ProjectLibrary(paths.library);
      _recents = RecentProjects(paths.recentsFile);
      _session = SessionMarker(paths.sessionFile);

      final unfinished = await _session.unfinishedProjectPath();
      if (unfinished != null && File(unfinished).existsSync()) {
        _recovery = RecoveryNotice(
          path: unfinished,
          name: ProjectLibrary.nameOfFile(unfinished),
        );
      } else if (unfinished != null) {
        // The project it names is gone; there is nothing to offer.
        await _session.close();
      }

      await _refreshProjects();
      _stage = WorkspaceStage.chooser;
    } catch (error) {
      _failure = error;
      _stage = WorkspaceStage.failed;
    }
    notifyListeners();
  }

  /// Creates a project in the library and opens it.
  ///
  /// No file panel: the app owns the folder, so a new project is one click and
  /// is guaranteed to be reachable again next launch.
  Future<void> create({
    required String name,
    required ProjectAspect aspect,
    required Rational frameRate,
  }) async {
    if (_open != null) await close();

    _notice = null;
    final trimmed = name.trim().isEmpty ? 'Untitled' : name.trim();
    final path = _library.pathFor(trimmed);
    final project = Project.empty(
      id: _ids.next('pr-'),
      name: trimmed,
      format: ProjectFormat.fromAspect(aspect, frameRate: frameRate),
      mainTrackId: _ids.next('tr-'),
      audioTrackId: _ids.next('tr-'),
    );

    try {
      final file = ProjectFile(path);
      await file.save(project);
      await _adopt(file, project);
    } catch (error) {
      _notice = 'Could not create "$trimmed": $error';
      notifyListeners();
    }
  }

  /// Opens the project at [path], replacing whatever is open.
  Future<void> openAt(String path) async {
    if (_open != null) await close();

    _notice = null;
    final file = ProjectFile(path);
    try {
      if (file.hasInterruptedWrite) await file.cleanUpInterruptedWrite();
      final project = await file.load(onRecovered: (_) {
        _notice = 'The last save of "${ProjectLibrary.nameOfFile(path)}" did '
            'not finish. Opened the previous version instead.';
      });
      await _adopt(file, project);
    } catch (error) {
      _notice = 'Could not open "${ProjectLibrary.nameOfFile(path)}": $error';
      await _refreshProjects();
      notifyListeners();
    }
  }

  /// Reopens the project the app died with, and clears the offer.
  Future<void> recoverLastSession() async {
    final target = _recovery;
    _recovery = null;
    if (target != null) await openAt(target.path);
  }

  /// Declines the offer. The marker goes, so it is not made twice.
  Future<void> dismissRecovery() async {
    _recovery = null;
    await _session.close();
    notifyListeners();
  }

  /// Re-reads the library and the recents list — after a project is deleted
  /// in Finder, or when the chooser comes back into view.
  Future<void> refresh() async {
    if (_stage == WorkspaceStage.failed) return;
    await _refreshProjects();
    notifyListeners();
  }

  void dismissNotice() {
    if (_notice == null) return;
    _notice = null;
    notifyListeners();
  }

  /// Removes a project from the chooser without touching the file. Only
  /// offered for entries that are already gone.
  Future<void> forget(String path) async {
    await _recents.remove(path);
    await _refreshProjects();
    notifyListeners();
  }

  /// Closes the open project: last write, then the session marker goes, so a
  /// later launch knows this run ended on purpose.
  Future<void> close() async {
    final open = _open;
    if (open == null) return;

    _open = null;
    await open.autosaver.flush();
    open.autosaver.dispose();
    open.store.dispose();
    await _releaseMediaAccess();
    await _session.close();

    await _refreshProjects();
    _stage = WorkspaceStage.chooser;
    notifyListeners();
  }

  /// Called when the app is quitting. Same as [close] without the repaint.
  Future<void> shutdown() async {
    final open = _open;
    if (open != null) {
      _open = null;
      await open.autosaver.flush();
      open.autosaver.dispose();
      open.store.dispose();
    }
    await _releaseMediaAccess();
    await _session.close();
  }

  Future<void> _adopt(ProjectFile file, Project opened) async {
    final unreachable = <String>{};
    final project = await _restoreMediaAccess(opened, unreachable);
    if (!identical(project, opened)) {
      // Where the media moved to is a fact about the disk, not an edit the
      // user made, so it is written straight through rather than pushed onto
      // the undo stack — and written now, so the next launch does not have to
      // resolve the same stale bookmarks again.
      try {
        await file.save(project);
      } catch (error) {
        _notice = 'Could not record where the media moved to: $error';
      }
    }

    final store = DocumentStore(project);
    final autosaver = Autosaver(
      store: store,
      file: file,
      debounce: autosaveDebounce,
      onError: (error, stack) {
        _notice = 'Autosave failed: $error';
        notifyListeners();
      },
    )..start();

    _open = OpenProject(
      path: file.path,
      store: store,
      file: file,
      autosaver: autosaver,
    )..unreachableMediaIds = unreachable;
    _recovery = null;
    _stage = WorkspaceStage.editing;

    await _recents.record(file.path, project.name);
    await _session.open(file.path);
    notifyListeners();
  }

  /// Opens the security scope of every asset the project remembers, and
  /// relinks the ones that moved.
  ///
  /// This is the moment the sandbox and the document meet. A project file
  /// records a path *and* a bookmark; the path is advisory and the bookmark is
  /// the permission, so the bookmark is what gets resolved and the path is
  /// what gets corrected. Files whose bookmark will not resolve at all are
  /// named in [unreachable] rather than dropped: an asset the user has to
  /// point at again is worth keeping, and a clip that quietly vanished is not.
  Future<Project> _restoreMediaAccess(
      Project project, Set<String> unreachable) async {
    var result = project;

    for (final asset in project.media.values) {
      final bookmark = asset.bookmark;
      if (bookmark == null) {
        // Nothing was ever minted — a project made before bookmarks, or a
        // file the sandbox refused one for. The path is all there is.
        if (!File(asset.path).existsSync()) unreachable.add(asset.id);
        continue;
      }

      final resolved = await _access.resolve(bookmark);
      if (resolved == null) {
        if (!File(asset.path).existsSync()) unreachable.add(asset.id);
        continue;
      }

      _granted.add(resolved.path);
      if (!resolved.granted && !File(resolved.path).existsSync()) {
        unreachable.add(asset.id);
      }

      final movedTo = resolved.path == asset.path ? null : resolved.path;
      final refreshed = resolved.refreshedBookmark;
      if (movedTo != null || refreshed != null) {
        result = result.addMedia(asset.copyWith(
          path: movedTo ?? asset.path,
          bookmark: refreshed ?? bookmark,
        ));
      }
    }

    if (unreachable.isNotEmpty) {
      final names = [
        for (final asset in project.media.values)
          if (unreachable.contains(asset.id)) asset.displayName,
      ];
      _notice = names.length == 1
          ? 'vdodtor cannot find "${names.single}". Its clips will play black '
              'until you import it again.'
          : 'vdodtor cannot find ${names.length} of this project\'s media '
              'files, starting with "${names.first}".';
    }
    return result;
  }

  /// Closes every scope this run opened. Called when a project closes and
  /// when the app quits, because the sandbox counts them per process.
  Future<void> _releaseMediaAccess() async {
    if (_granted.isEmpty) return;
    final paths = _granted.toList();
    _granted.clear();
    for (final path in paths) {
      await _access.release(path);
    }
  }

  Future<void> _refreshProjects() async {
    final byPath = <String, ProjectEntry>{};

    for (final entry in _library.list()) {
      byPath[entry.path] = ProjectEntry(
        path: entry.path,
        name: entry.name,
        lastOpened: entry.modified,
        exists: true,
        inLibrary: true,
      );
    }

    // Recents win on order and on name: "last opened" is what a chooser sorts
    // by, and it knows the document's own name even for files outside the
    // library.
    for (final recent in await _recents.load()) {
      final known = byPath[recent.path];
      byPath[recent.path] = ProjectEntry(
        path: recent.path,
        name: known?.name ?? recent.name,
        lastOpened: recent.lastOpened,
        exists: known != null || recent.stillExists,
        inLibrary: known?.inLibrary ?? false,
      );
    }

    _projects = byPath.values.toList()
      ..sort((a, b) => b.lastOpened.compareTo(a.lastOpened));
  }

  @override
  void dispose() {
    final open = _open;
    if (open != null) {
      open.autosaver.dispose();
      open.store.dispose();
      _open = null;
    }
    entitlement.dispose();
    super.dispose();
  }
}
