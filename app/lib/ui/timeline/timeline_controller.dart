import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

import '../../commands/document_store.dart';
import '../../commands/edits.dart';
import '../../model/clip.dart';
import '../../model/ids.dart';
import '../../model/project.dart';
import '../../model/time.dart';
import '../../model/track.dart';
import 'timeline_geometry.dart';

/// The playhead, from the timeline's point of view.
///
/// Narrow on purpose. The timeline does not know what an engine is; it knows
/// there is something that has a position, may be playing, and can be told to
/// go somewhere. That is the whole of the coupling, and it is why the
/// interaction below can be tested without a compositor.
abstract interface class TimelineTransport implements Listenable {
  int get positionTicks;
  int get durationTicks;
  bool get isPlaying;
  void seek(int ticks);
}

/// One clip on the clipboard: the clip itself, with its start rebased so the
/// earliest thing copied sits at zero, and where it came from.
typedef ClipboardEntry = ({String trackId, TrackKind kind, Clip clip});

/// What ⌘C put aside.
///
/// Rebased to zero on copy rather than on paste, so the shape of a
/// multi-clip copy — the gaps and the lane it each came from — is fixed at
/// the moment it is taken and cannot be changed by editing afterwards.
@immutable
final class TimelineClipboard {
  const TimelineClipboard(this.entries);

  final List<ClipboardEntry> entries;

  bool get isEmpty => entries.isEmpty;
  bool get isNotEmpty => entries.isNotEmpty;
}

/// What the pointer is currently doing.
enum TimelineDrag {
  none,

  /// Dragging the playhead: every move is a seek.
  scrub,

  /// Sliding a clip along its lane.
  move,

  /// Dragging a clip's leading edge, which takes the source window with it.
  trimStart,

  /// Dragging a clip's trailing edge, which only changes the length.
  trimEnd,
}

/// View state for the timeline: where it is looking, what is selected, and
/// what the pointer is doing.
///
/// The document is not in here — it is read live from the [DocumentStore] at
/// paint time — and neither is the playhead, which lives in the transport.
/// Keeping both out means there is exactly one copy of each and no way for
/// this to disagree with them.
class TimelineController extends ChangeNotifier {
  TimelineController({
    required this.store,
    required this.transport,
    IdGen? ids,
  }) : _ids = ids ?? IdGen() {
    store.addListener(_onExternalChange);
    transport.addListener(_onExternalChange);
  }

  final DocumentStore store;
  final TimelineTransport transport;
  final IdGen _ids;

  /// How close, in pixels, an edge has to be to snap to another one.
  static const double snapDistancePx = 7;

  /// How much of each end of a clip grabs its trim handle rather than its body.
  static const double handleWidthPx = 9;

  /// Below this width a clip would be all handle and no body, so it is all
  /// body instead: an edit you cannot start is worse than one you have to
  /// zoom in for.
  static const double minimumBodyPx = 26;

  TimelineGeometry _geometry = const TimelineGeometry();
  final Set<String> _selectedClipIds = {};
  TimelineClipboard _clipboard = const TimelineClipboard([]);
  TimelineDrag _drag = TimelineDrag.none;
  Set<String> _unreachableMediaIds = const {};

  String? _dragClipId;
  Tick _dragOriginStart = Tick.zero;
  Tick _dragOriginEnd = Tick.zero;
  double _dragAnchorX = 0;
  Tick? _snapGuide;

  /// True while playback should keep the playhead on screen. Turned off by a
  /// deliberate pan — someone who scrolled somewhere meant to look at it —
  /// and back on by a scrub or by playback reaching the view again.
  bool _following = true;

  TimelineGeometry get geometry => _geometry;

  /// Assets whose file the app cannot reach. Their clips are drawn as warnings
  /// rather than silently as black, because a clip that will play black is
  /// something to say out loud before export, not after.
  Set<String> get unreachableMediaIds => _unreachableMediaIds;

  set unreachableMediaIds(Set<String> value) {
    if (setEquals(_unreachableMediaIds, value)) return;
    _unreachableMediaIds = value;
    notifyListeners();
  }

  /// Every clip currently selected. Unmodifiable.
  Set<String> get selectedClipIds => Set.unmodifiable(_selectedClipIds);

  /// The selection when it is exactly one clip, and null when it is none or
  /// many. Trimming and the trim handles are single-clip ideas, so this is
  /// what asks whether they apply.
  String? get selectedClipId =>
      _selectedClipIds.length == 1 ? _selectedClipIds.first : null;

  bool isSelected(String clipId) => _selectedClipIds.contains(clipId);

  /// What ⌘C last put aside. Lives with the timeline, so it goes when the
  /// project does — pasting a clip into a project whose media it names is not
  /// there would be a paste that plays black.
  TimelineClipboard get clipboard => _clipboard;

  TimelineDrag get drag => _drag;
  bool get isScrubbing => _drag == TimelineDrag.scrub;
  bool get isEditing =>
      _drag == TimelineDrag.move ||
      _drag == TimelineDrag.trimStart ||
      _drag == TimelineDrag.trimEnd;

  /// The edge a drag is currently snapped to, for the guide line. Null when
  /// nothing is snapped.
  Tick? get snapGuide => _snapGuide;
  bool get isFollowingPlayhead => _following;

  Project get project => store.project;
  Rational get frameRate => project.format.frameRate;

  /// Where the playhead is. The transport owns it; this is a read.
  Tick get playhead => Tick(transport.positionTicks);

  /// The longer of what the document says and what the engine says, so a
  /// timeline whose engine has not caught up yet still draws its own clips.
  Tick get duration =>
      Tick(math.max(project.duration.raw, transport.durationTicks));

  Clip? get selectedClip {
    final id = selectedClipId;
    return id == null ? null : project.clipById(id);
  }

  /// The selected clips that still exist, in lane and time order.
  List<({String trackId, Clip clip})> get selectedClips {
    final out = <({String trackId, Clip clip})>[];
    for (final track in project.tracks) {
      for (final clip in track.clips) {
        if (_selectedClipIds.contains(clip.id)) {
          out.add((trackId: track.id, clip: clip));
        }
      }
    }
    return out;
  }

  void _onExternalChange() {
    // Undo can take a clip out from under the selection, and a selection that
    // names clips the document no longer has is a selection that silently
    // does nothing when acted on.
    _pruneSelection();
    notifyListeners();
  }

  // --- view ----------------------------------------------------------------

  void zoomAround(double focusX, double factor) {
    _setGeometry(_geometry.zoomedAround(focusX, factor));
  }

  void panBy(double dx) {
    if (dx != 0) _following = false;
    _setGeometry(_geometry.pannedBy(dx));
  }

  /// Fits [duration] across [width], with a little room at the end so the last
  /// frame is not flush against the edge.
  void zoomToFit(double width) {
    final span = duration.raw;
    final available = width - TimelineGeometry.headerWidth - 24;
    if (span <= 0 || available <= 0) return;
    final seconds = Timebase.project.toSecondsForDisplay(Tick(span));
    _following = true;
    _setGeometry(TimelineGeometry(
      pxPerSecond: (available / seconds).clamp(
          TimelineGeometry.minPxPerSecond, TimelineGeometry.maxPxPerSecond),
    ));
  }

  void _setGeometry(TimelineGeometry next) {
    if (next == _geometry) return;
    _geometry = next;
    notifyListeners();
  }

  /// Called once per vsync while playing. Keeps the playhead on screen and
  /// repaints so it actually moves — the transport does not announce every
  /// frame, and asking it to would be a notification per frame for a value
  /// only this widget reads.
  void pump(double width) {
    if (_following) {
      _geometry = _geometry.scrolledToShow(playhead, width);
    }
    notifyListeners();
  }

  // --- selection -----------------------------------------------------------

  /// Replaces the selection with [clipId], or clears it when null.
  void select(String? clipId) {
    final next = clipId == null ? const <String>{} : {clipId};
    if (setEquals(_selectedClipIds, next)) return;
    _selectedClipIds
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  /// Adds [clipId] to the selection, or takes it out if it is already in.
  void toggleSelection(String clipId) {
    if (!_selectedClipIds.remove(clipId)) _selectedClipIds.add(clipId);
    notifyListeners();
  }

  void selectAll() {
    final everything = {
      for (final track in project.tracks)
        for (final clip in track.clips) clip.id,
    };
    if (setEquals(_selectedClipIds, everything)) return;
    _selectedClipIds
      ..clear()
      ..addAll(everything);
    notifyListeners();
  }

  void clearSelection() => select(null);

  /// Drops ids that are no longer in the document — after an undo, or after
  /// something else deleted them.
  void _pruneSelection() {
    _selectedClipIds.removeWhere((id) => project.clipById(id) == null);
  }

  // --- the playhead --------------------------------------------------------

  /// Moves the playhead, snapped to a frame and clamped to the timeline.
  ///
  /// Frame-snapped because the engine renders frames: a playhead resting
  /// between two of them names a picture that does not exist, and the frame
  /// it would show is whichever one the rounding happened to pick.
  void seekTo(Tick t) {
    final clamped = t.raw < 0 ? Tick.zero : (t.raw > duration.raw ? duration : t);
    final snapped = Timebase.project.snapToFrame(clamped, frameRate);
    if (snapped.raw == transport.positionTicks) return;
    transport.seek(snapped.raw);
  }

  /// Steps [frames] frames from where the playhead is. Negative goes back.
  void nudge(int frames) {
    final per = Timebase.project.ticksPerFrame(frameRate);
    seekTo(Tick(playhead.raw + frames * per));
  }

  // --- pointer -------------------------------------------------------------

  /// Returns the clip at [position], or null. Later clips win, which matches
  /// what is drawn on top when two somehow overlap.
  ({Clip clip, Track track})? clipAt(Offset position) {
    final index = _geometry.trackIndexAt(position.dy, project.tracks.length);
    if (index == null) return null;
    final track = project.tracks[index];
    for (final clip in track.clips.reversed) {
      final x0 = _geometry.xOfTick(clip.start);
      final x1 = _geometry.xOfTick(clip.end);
      if (position.dx >= x0 && position.dx <= x1) {
        return (clip: clip, track: track);
      }
    }
    return null;
  }

  /// [additive] is ⌘ or ⇧ held: the press adds to or removes from the
  /// selection rather than replacing it, and starts no drag — a modified
  /// click is about *what* is chosen, never about moving it.
  void pointerDown(Offset position, {bool additive = false}) {
    if (position.dx < TimelineGeometry.headerWidth) return;

    // The ruler is the scrub strip; the lanes below it are about clips.
    if (position.dy < TimelineGeometry.rulerHeight) {
      _drag = TimelineDrag.scrub;
      _following = true;
      seekTo(_geometry.tickAtX(position.dx));
      notifyListeners();
      return;
    }

    final hit = clipAt(position);
    if (additive) {
      if (hit != null) toggleSelection(hit.clip.id);
      return;
    }

    // A plain press on a clip narrows the selection to it, even when it was
    // already part of a larger one: a drag moves one clip, and leaving four
    // outlined while one of them moves would say otherwise.
    select(hit?.clip.id);
    if (hit == null) return;

    // A locked lane is a lane the user asked not to touch.
    if (hit.track.locked) return;

    // Every edit in a gesture is measured from where the clip was when the
    // gesture began, never from where it is now: a magnetic lane repacks
    // under the pointer, and measuring from the current position would let
    // that feed back into the next move.
    _dragClipId = hit.clip.id;
    _dragOriginStart = hit.clip.start;
    _dragOriginEnd = hit.clip.end;
    _dragAnchorX = position.dx;
    _drag = _modeFor(hit.clip, position.dx);
    store.endGesture();
    notifyListeners();
  }

  TimelineDrag _modeFor(Clip clip, double x) {
    final x0 = _geometry.xOfTick(clip.start);
    final x1 = _geometry.xOfTick(clip.end);
    if (x1 - x0 < minimumBodyPx) return TimelineDrag.move;
    if (x - x0 <= handleWidthPx) return TimelineDrag.trimStart;
    if (x1 - x <= handleWidthPx) return TimelineDrag.trimEnd;
    return TimelineDrag.move;
  }

  void pointerMove(Offset position) {
    if (_drag == TimelineDrag.scrub) {
      seekTo(_geometry.tickAtX(position.dx));
      return;
    }
    final clipId = _dragClipId;
    if (clipId == null || _drag == TimelineDrag.none) return;

    final delta =
        ((position.dx - _dragAnchorX) / _geometry.pxPerTick).round();

    switch (_drag) {
      case TimelineDrag.move:
        final duration = _dragOriginEnd - _dragOriginStart;
        var wanted = Tick(_dragOriginStart.raw + delta);
        if (wanted.raw < 0) wanted = Tick.zero;
        // Both edges snap: lining a clip's end up with the next cut is as
        // much of an edit as lining its start up with the last one.
        wanted = _snapMove(wanted, duration, clipId);
        store.run(MoveClip(clipId, wanted), fromGestureStart: true);

      case TimelineDrag.trimStart:
        final wanted =
            _snapEdge(Tick(_dragOriginStart.raw + delta), clipId);
        store.run(TrimClip(clipId, start: wanted), fromGestureStart: true);

      case TimelineDrag.trimEnd:
        final wanted = _snapEdge(Tick(_dragOriginEnd.raw + delta), clipId);
        store.run(TrimClip(clipId, end: wanted), fromGestureStart: true);

      case TimelineDrag.none:
      case TimelineDrag.scrub:
        break;
    }
    notifyListeners();
  }

  void pointerUp() {
    if (_drag == TimelineDrag.none) return;
    _drag = TimelineDrag.none;
    _dragClipId = null;
    _snapGuide = null;
    // Closes the undo entry, so the next edit does not fold into this drag.
    store.endGesture();
    notifyListeners();
  }

  // --- snapping ------------------------------------------------------------

  /// Every edge worth landing on: the cuts on every lane, the playhead, and
  /// zero. [except] leaves out the clip being dragged, which would otherwise
  /// snap to itself and never move.
  List<Tick> _snapCandidates(String? except) {
    final out = <Tick>[Tick.zero, playhead];
    for (final track in project.tracks) {
      for (final clip in track.clips) {
        if (clip.id == except) continue;
        out.add(clip.start);
        out.add(clip.end);
      }
    }
    return out;
  }

  /// Snaps a single moving edge.
  Tick _snapEdge(Tick wanted, String? except) {
    final best = _nearest(wanted, _snapCandidates(except));
    _snapGuide = best;
    return best ?? wanted;
  }

  /// Snaps a whole clip, trying both of its edges and taking whichever lands
  /// closer. Returns the start the clip should take.
  Tick _snapMove(Tick wantedStart, Tick duration, String? except) {
    final candidates = _snapCandidates(except);
    final wantedEnd = wantedStart + duration;

    final byStart = _nearest(wantedStart, candidates);
    final byEnd = _nearest(wantedEnd, candidates);

    final startDistance = byStart == null
        ? double.infinity
        : (byStart.raw - wantedStart.raw).abs() * _geometry.pxPerTick;
    final endDistance = byEnd == null
        ? double.infinity
        : (byEnd.raw - wantedEnd.raw).abs() * _geometry.pxPerTick;

    if (startDistance.isInfinite && endDistance.isInfinite) {
      _snapGuide = null;
      return wantedStart;
    }
    if (startDistance <= endDistance) {
      _snapGuide = byStart;
      return byStart!;
    }
    _snapGuide = byEnd;
    return Tick(byEnd!.raw - duration.raw);
  }

  Tick? _nearest(Tick wanted, List<Tick> candidates) {
    Tick? best;
    var bestPx = snapDistancePx;
    for (final candidate in candidates) {
      final px = (candidate.raw - wanted.raw).abs() * _geometry.pxPerTick;
      if (px <= bestPx) {
        bestPx = px;
        best = candidate;
      }
    }
    return best;
  }

  // --- edits with no pointer in them ---------------------------------------

  /// Removes everything selected. On a magnetic lane the gaps close behind
  /// them, and the whole thing is one undo entry however many clips it was.
  bool deleteSelected() {
    final ids = _editableSelection();
    if (ids.isEmpty) return false;

    store.endGesture();
    store.run(DeleteClips(ids));
    store.endGesture();
    _selectedClipIds.removeAll(ids);
    notifyListeners();
    return true;
  }

  /// The selected clips that can actually be edited: still in the document,
  /// and not on a locked lane.
  Set<String> _editableSelection() => {
        for (final id in _selectedClipIds)
          if (project.clipById(id) != null &&
              !(project.trackOfClip(id)?.locked ?? true))
            id,
      };

  /// Cuts a clip in two at the playhead.
  ///
  /// The selected clip if the playhead is inside it, otherwise whatever the
  /// playhead is actually over on the main track — which is what someone who
  /// pressed the key without selecting anything meant.
  bool splitAtPlayhead() {
    final at = playhead;
    final target = _splitTarget(at);
    if (target == null) return false;
    if (target.track.locked) return false;

    store.endGesture();
    final tailId = _ids.next('c-');
    store.run(SplitClip(target.clip.id, at, newClipId: tailId));
    store.endGesture();
    if (project.clipById(tailId) == null) return false;

    // The tail is the part the playhead is now sitting at the start of, so it
    // is the part the next keystroke is about.
    _selectedClipIds
      ..clear()
      ..add(tailId);
    notifyListeners();
    return true;
  }

  ({Clip clip, Track track})? _splitTarget(Tick at) {
    final selected = selectedClip;
    if (selected != null && at > selected.start && at < selected.end) {
      final track = project.trackOfClip(selected.id);
      if (track != null) return (clip: selected, track: track);
    }
    for (final track in project.tracks) {
      final clip = track.clipAt(at);
      if (clip != null && at > clip.start) return (clip: clip, track: track);
    }
    return null;
  }

  /// Copies everything selected in next to itself, and selects the copies.
  bool duplicateSelected() {
    final ids = _editableSelection();
    if (ids.isEmpty) return false;

    final placements = <ClipPlacement>[];
    final copies = <String>{};
    for (final entry in selectedClips) {
      if (!ids.contains(entry.clip.id)) continue;
      final track = project.trackById(entry.trackId)!;
      final copyId = _ids.next('c-');
      copies.add(copyId);
      placements.add((
        trackId: entry.trackId,
        clip: entry.clip.copyWith(id: copyId, start: entry.clip.end),
        // Right after the original, by slot rather than by time: on a
        // magnetic lane order is the only thing that decides position.
        index: track.isMagnetic ? track.indexOfClip(entry.clip.id) + 1 : null,
      ));
    }

    store.endGesture();
    store.run(InsertClips(
      placements,
      label: placements.length == 1 ? 'Duplicate clip' : 'Duplicate clips',
    ));
    store.endGesture();
    _selectedClipIds
      ..clear()
      ..addAll(copies);
    notifyListeners();
    return true;
  }

  // --- the clipboard -------------------------------------------------------

  /// Puts the selection aside. Returns false when there was nothing to take.
  bool copySelection() {
    final entries = selectedClips;
    if (entries.isEmpty) return false;

    // Rebased so the earliest sits at zero; paste then only has to add the
    // playhead, and the shape of the copy is fixed at the moment it is taken.
    final origin = entries
        .map((e) => e.clip.start.raw)
        .reduce((a, b) => a < b ? a : b);
    _clipboard = TimelineClipboard([
      for (final entry in entries)
        (
          trackId: entry.trackId,
          kind: project.trackById(entry.trackId)!.kind,
          clip: entry.clip.movedTo(Tick(entry.clip.start.raw - origin)),
        ),
    ]);
    notifyListeners();
    return true;
  }

  /// Copy, then delete. Both halves are the ordinary ones, so a cut undoes
  /// like the delete it is.
  bool cutSelection() => copySelection() && deleteSelected();

  /// Drops the clipboard in at the playhead.
  ///
  /// Each clip goes back on the lane it came from when that lane still
  /// exists, and otherwise on the first lane of the same kind — pasting audio
  /// onto a video track would be a paste that does nothing anyone wanted.
  bool paste() {
    if (_clipboard.isEmpty) return false;
    final at = playhead;

    final placements = <ClipPlacement>[];
    final pasted = <String>{};
    for (final entry in _clipboard.entries) {
      final track = project.trackById(entry.trackId) ?? _firstTrackOfKind(entry.kind);
      if (track == null || track.locked) continue;
      if (entry.clip.mediaId != null &&
          !project.media.containsKey(entry.clip.mediaId)) {
        continue;
      }

      final id = _ids.next('c-');
      pasted.add(id);
      placements.add((
        trackId: track.id,
        clip: entry.clip.copyWith(
            id: id, start: Tick(at.raw + entry.clip.start.raw)),
        // After everything that starts before the playhead: pasting "here"
        // on a magnetic lane means after the clip you are looking at.
        index: track.isMagnetic
            ? track.clips.where((c) => c.start < at).length
            : null,
      ));
    }
    if (placements.isEmpty) return false;

    store.endGesture();
    store.run(InsertClips(
      placements,
      label: placements.length == 1 ? 'Paste clip' : 'Paste clips',
    ));
    store.endGesture();
    _selectedClipIds
      ..clear()
      ..addAll(pasted);
    notifyListeners();
    return true;
  }

  Track? _firstTrackOfKind(TrackKind kind) {
    for (final track in project.tracks) {
      if (track.kind == kind) return track;
    }
    return null;
  }

  @override
  void dispose() {
    store.removeListener(_onExternalChange);
    transport.removeListener(_onExternalChange);
    super.dispose();
  }
}
