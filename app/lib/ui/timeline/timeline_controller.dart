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
  String? _selectedClipId;
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

  String? get selectedClipId => _selectedClipId;
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

  Clip? get selectedClip =>
      _selectedClipId == null ? null : project.clipById(_selectedClipId!);

  void _onExternalChange() => notifyListeners();

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

  void select(String? clipId) {
    if (_selectedClipId == clipId) return;
    _selectedClipId = clipId;
    notifyListeners();
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

  void pointerDown(Offset position) {
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

  /// Removes the selected clip. On a magnetic lane the gap closes behind it.
  bool deleteSelected() {
    final id = _selectedClipId;
    if (id == null || project.clipById(id) == null) return false;
    if (project.trackOfClip(id)?.locked ?? false) return false;

    store.endGesture();
    store.run(DeleteClip(id));
    store.endGesture();
    _selectedClipId = null;
    notifyListeners();
    return true;
  }

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
    _selectedClipId = tailId;
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

  /// Copies the selected clip in next to itself, and selects the copy.
  bool duplicateSelected() {
    final id = _selectedClipId;
    if (id == null || project.clipById(id) == null) return false;
    if (project.trackOfClip(id)?.locked ?? false) return false;

    store.endGesture();
    final copyId = _ids.next('c-');
    store.run(DuplicateClip(id, newClipId: copyId));
    store.endGesture();
    _selectedClipId = copyId;
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    store.removeListener(_onExternalChange);
    transport.removeListener(_onExternalChange);
    super.dispose();
  }
}
