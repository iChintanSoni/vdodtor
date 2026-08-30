import 'package:flutter/foundation.dart';

import '../model/project.dart';
import 'command.dart';

/// Holds the current document and the undo history.
///
/// Undo is snapshot-based: because [Project] is immutable and shares structure,
/// keeping the whole document from before each edit costs about as much as the
/// part that changed. That buys correctness — there is no inverse-command to
/// get subtly wrong — at a price the profile does not notice.
class DocumentStore extends ChangeNotifier {
  DocumentStore(Project initial, {this.historyLimit = 200})
      : _project = initial;

  /// Oldest entries are dropped past this depth. 200 edits is far more than a
  /// session needs and bounds memory on a long timeline.
  final int historyLimit;

  Project _project;
  final List<_HistoryEntry> _undo = [];
  final List<_HistoryEntry> _redo = [];
  int _revision = 0;
  int _savedRevision = 0;
  bool _coalescingBarrier = true;

  Project get project => _project;

  /// Increments on every edit that changed the document. Cheap identity for
  /// caches and for deciding whether the engine needs a fresh document.
  int get revision => _revision;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// `"Move clip"`, for the Edit menu. Null when there is nothing to undo.
  String? get undoLabel => _undo.isEmpty ? null : _undo.last.command.label;
  String? get redoLabel => _redo.isEmpty ? null : _redo.last.command.label;

  /// True when there are edits the autosave has not written yet.
  bool get isDirty => _revision != _savedRevision;

  /// Applies [command]. A command that returns the same document is dropped:
  /// it does not dirty the project, push undo, or notify.
  ///
  /// Set [fromGestureStart] for the repeated commands a drag emits. They are
  /// then applied to the document as it stood when the gesture began rather
  /// than to the document the gesture has left behind — a drag is one edit
  /// that keeps changing its mind, not a run of edits that accumulate.
  ///
  /// It matters most on a magnetic track, where committing a move repacks the
  /// *neighbours* too. Measured against the repacked lane, the next move of
  /// the same drag compares the clip to positions the drag itself created, so
  /// dragging back the way you came does not undo the reorder — the clip is
  /// stuck wherever it first landed.
  void run(EditCommand command, {bool fromGestureStart = false}) {
    final top = _undo.isEmpty ? null : _undo.last;
    final merged =
        _coalescingBarrier ? null : top?.command.mergeWith(command);

    final before =
        fromGestureStart && merged != null ? top!.snapshot : _project;
    final after = command.apply(before);
    // Compared against the current document, not the base: mid-gesture, an
    // edit that lands back where the project already is has changed nothing.
    if (identical(after, _project)) return;

    if (merged != null) {
      // Same gesture: keep the older snapshot, adopt the newer command so the
      // undo label describes the whole run.
      _undo[_undo.length - 1] = _HistoryEntry(top!.snapshot, merged);
    } else {
      _undo.add(_HistoryEntry(before, command));
      if (_undo.length > historyLimit) _undo.removeAt(0);
    }

    _coalescingBarrier = false;
    _redo.clear();
    _project = after;
    _revision++;
    notifyListeners();
  }

  /// Ends the current gesture, so the next [run] starts a fresh undo entry.
  /// Call on pointer-up, on focus loss, and before any menu action.
  void endGesture() => _coalescingBarrier = true;

  void undo() {
    if (_undo.isEmpty) return;
    final entry = _undo.removeLast();
    _redo.add(_HistoryEntry(_project, entry.command));
    _project = entry.snapshot;
    _revision++;
    _coalescingBarrier = true;
    notifyListeners();
  }

  void redo() {
    if (_redo.isEmpty) return;
    final entry = _redo.removeLast();
    _undo.add(_HistoryEntry(_project, entry.command));
    _project = entry.snapshot;
    _revision++;
    _coalescingBarrier = true;
    notifyListeners();
  }

  /// Replaces the document wholesale and drops the history — opening a file.
  void load(Project project) {
    _undo.clear();
    _redo.clear();
    _project = project;
    _revision++;
    _savedRevision = _revision;
    _coalescingBarrier = true;
    notifyListeners();
  }

  /// Records that [revision] has been persisted. Passing a stale revision is
  /// ignored, so a slow write cannot mark newer edits as saved.
  void markSaved(int revision) {
    if (revision > _savedRevision && revision <= _revision) {
      _savedRevision = revision;
    }
  }

  @visibleForTesting
  List<String> get undoLabels =>
      [for (final e in _undo) e.command.label];
}

class _HistoryEntry {
  const _HistoryEntry(this.snapshot, this.command);

  /// The document as it stood *before* [command] ran.
  final Project snapshot;
  final EditCommand command;
}
