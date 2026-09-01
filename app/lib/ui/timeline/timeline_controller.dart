import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

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

  /// Dragging a point on a clip's volume line, in both time and level.
  volumePoint,
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

  /// How close, in pixels, the pointer has to be to a point on the volume line
  /// to grab it rather than the clip under it. Measured in both axes, so a
  /// press at the same time but a different height still moves the clip — or
  /// trims it, when the point happens to sit over a trim handle.
  static const double volumePointGrabPx = 7;

  TimelineGeometry _geometry = const TimelineGeometry();
  final Set<String> _selectedClipIds = {};
  TimelineClipboard _clipboard = const TimelineClipboard([]);
  TimelineDrag _drag = TimelineDrag.none;
  Set<String> _unreachableMediaIds = const {};

  String? _dragClipId;
  String? _dragOriginTrackId;
  Tick _dragOriginStart = Tick.zero;
  Tick _dragOriginEnd = Tick.zero;
  double _dragAnchorX = 0;
  Tick? _snapGuide;

  /// The point being dragged, and the levels the clip had when the gesture
  /// began. [SetClipAudio] carries a whole [ClipAudio] rather than a delta, so
  /// a drag that re-applies to the gesture's opening document has to build its
  /// value from that document's levels and not from the ones it has since
  /// written.
  int _dragPointIndex = -1;
  ClipAudio? _dragOriginAudio;
  double _dragAnchorY = 0;

  /// The band the dragged point lives in, taken once at the start. Its height
  /// comes from the lane, which a level drag cannot change, so recomputing it
  /// from a document the drag is rewriting would only invite it to.
  Rect? _dragBand;

  /// True while playback should keep the playhead on screen. Turned off by a
  /// deliberate pan — someone who scrolled somewhere meant to look at it —
  /// and back on by a scrub or by playback reaching the view again.
  bool _following = true;

  /// How wide the timeline is being drawn, set by the view at layout.
  ///
  /// The controller needs it for anything that has to end with the playhead
  /// on screen, and the alternative was every caller passing it in: the Fit
  /// button was guessing at `MediaQuery.width - 240`, which is right until
  /// somebody changes the layout and wrong quietly afterwards.
  double _viewportWidth = 0;

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

  /// The lanes as the timeline shows them, top to bottom.
  ///
  /// Deliberately *not* document order. Order in the document is compositing
  /// order — later renders on top — and an editor shows what is on top at the
  /// top, so the visual lanes are reversed here. Audio follows underneath in
  /// its own order, because it composites nothing and its order means nothing.
  List<Track> get lanes {
    final visual = <Track>[];
    final rest = <Track>[];
    for (final track in project.tracks) {
      (track.kind.isVisual ? visual : rest).add(track);
    }
    return [...visual.reversed, ...rest];
  }

  /// The lane at [y], or null for the ruler and the gaps.
  Track? laneAt(double y) {
    final all = lanes;
    final index = _geometry.trackIndexAt(y, all.length);
    return index == null ? null : all[index];
  }

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

  set viewportWidth(double value) {
    if (value > 0) _viewportWidth = value;
  }

  double get viewportWidth => _viewportWidth;

  void zoomAround(double focusX, double factor) {
    _setGeometry(_geometry.zoomedAround(focusX, factor));
  }

  /// Zooms with no pointer to zoom towards — a key, or a toolbar button.
  ///
  /// The anchor is the **playhead**. A pointer zoom keeps what is under the
  /// pointer still because that is what the person is looking at; without a
  /// pointer the equivalent is the playhead, and the alternative the buttons
  /// used to take — the left edge of the view — walks whatever you were
  /// working on off the screen every second press.
  ///
  /// Then it makes sure the playhead is still visible, which matters when it
  /// was already off screen: anchoring on something you cannot see is not
  /// wrong so much as useless, and this is the one place the answer is free.
  void zoomBy(double factor) {
    var next = _geometry.zoomedAround(_geometry.xOfTick(playhead), factor);
    if (_viewportWidth > 0) {
      next = next.scrolledToShow(playhead, _viewportWidth);
    }
    _setGeometry(next);
  }

  void panBy(double dx) {
    if (dx != 0) _following = false;
    _setGeometry(_geometry.pannedBy(dx));
  }

  /// Fits [duration] across the view, with a little room at the end so the
  /// last frame is not flush against the edge.
  void zoomToFit() {
    final span = duration.raw;
    final available =
        _viewportWidth - TimelineGeometry.headerWidth - 24;
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
  void pump() {
    if (_following && _viewportWidth > 0) {
      _geometry = _geometry.scrolledToShow(playhead, _viewportWidth);
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

  /// Steps [seconds] seconds from where the playhead is. Negative goes back.
  ///
  /// Still frame-snapped, by [seekTo]: a second at 29.97 is not a whole number
  /// of frames, and a playhead resting between two of them names a picture
  /// that does not exist.
  void skip(int seconds) =>
      seekTo(Tick(playhead.raw + seconds * Timebase.project.ticksPerSecond));

  /// Moves the playhead to the next cut after it, in [direction]'s sense.
  ///
  /// A cut is any clip edge on any lane, plus zero and the end — the same
  /// points an edge snaps to while dragging, so what the keyboard lands on and
  /// what a drag sticks to are the same set rather than two ideas about where
  /// the interesting moments are.
  ///
  /// This is the shortcut that makes the arrow keys make sense: a frame is too
  /// small a step to cross a clip with and a second is an arbitrary one, where
  /// the next edit point is the thing anyone is actually aiming at.
  void jumpToCut(int direction) {
    final here = playhead.raw;
    int? best;
    for (final t in _cutPoints()) {
      if (direction < 0 ? t.raw >= here : t.raw <= here) continue;
      if (best == null || (direction < 0 ? t.raw > best : t.raw < best)) {
        best = t.raw;
      }
    }
    if (best != null) seekTo(Tick(best));
  }

  /// Every edge worth landing on, unordered and with duplicates.
  Iterable<Tick> _cutPoints() sync* {
    yield Tick.zero;
    yield duration;
    for (final track in project.tracks) {
      for (final clip in track.clips) {
        yield clip.start;
        yield clip.end;
      }
    }
  }

  // --- pointer -------------------------------------------------------------

  /// Returns the clip at [position], or null. Later clips win, which matches
  /// what is drawn on top when two somehow overlap.
  ({Clip clip, Track track})? clipAt(Offset position) {
    final track = laneAt(position.dy);
    if (track == null) return null;
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
  ///
  /// [alt] is ⌥ held, which is the volume line's modifier: it puts a point on
  /// the line under the pointer, or takes away the one already there.
  void pointerDown(Offset position,
      {bool additive = false, bool alt = false}) {
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

    if (_beginVolumeEdit(hit.clip, hit.track, position, alt: alt)) return;

    // Every edit in a gesture is measured from where the clip was when the
    // gesture began, never from where it is now: a magnetic lane repacks
    // under the pointer, and measuring from the current position would let
    // that feed back into the next move.
    _dragClipId = hit.clip.id;
    _dragOriginTrackId = hit.track.id;
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
        store.run(
          MoveClip(clipId, wanted, toTrackId: _laneTargetFor(clipId, position)),
          fromGestureStart: true,
        );

      case TimelineDrag.trimStart:
        final wanted =
            _snapEdge(Tick(_dragOriginStart.raw + delta), clipId);
        store.run(TrimClip(clipId, start: wanted), fromGestureStart: true);

      case TimelineDrag.trimEnd:
        final wanted = _snapEdge(Tick(_dragOriginEnd.raw + delta), clipId);
        store.run(TrimClip(clipId, end: wanted), fromGestureStart: true);

      case TimelineDrag.volumePoint:
        _moveVolumePoint(clipId, position);

      case TimelineDrag.none:
      case TimelineDrag.scrub:
        break;
    }
    notifyListeners();
  }

  /// Which lane a move should land the clip on, given where the pointer is.
  ///
  /// Null means "leave it where it started" — which is also the answer for a
  /// lane that will not have it, so dragging a video clip over the audio lane
  /// slides it along its own lane rather than dropping it somewhere it cannot
  /// play.
  String? _laneTargetFor(String clipId, Offset position) {
    final lane = laneAt(position.dy);
    if (lane == null) return _dragOriginTrackId;
    final clip = project.clipById(clipId);
    final asset = clip == null ? null : project.assetFor(clip);
    // The lane it started on decides what it is allowed to become: a detached
    // audio clip may cross to another audio lane, a video clip may not.
    final origin = project.trackOfClip(clipId)?.kind ?? TrackKind.main;
    if (!MoveClip.accepts(lane, asset,
        from: origin, isGenerated: clip?.isGenerated ?? false)) {
      return _dragOriginTrackId;
    }
    return lane.id;
  }

  void pointerUp() {
    if (_drag == TimelineDrag.none) return;
    _drag = TimelineDrag.none;
    _dragClipId = null;
    _dragOriginTrackId = null;
    _dragPointIndex = -1;
    _dragOriginAudio = null;
    _dragBand = null;
    _snapGuide = null;
    // Closes the undo entry, so the next edit does not fold into this drag.
    store.endGesture();
    notifyListeners();
  }

  // --- the volume line -------------------------------------------------------

  /// Whether [clip] gets a volume line drawn on it: it makes a sound, and it
  /// either already carries a curve or is the one clip the pointer is about.
  ///
  /// Hidden until then on purpose. A line across every clip in the project
  /// would be a lot of ink for a control almost nobody is using at that
  /// moment, and the line is only editable on the lone selection anyway.
  bool showsVolumeLine(Clip clip, Track track) {
    if (!clip.enabled) return false;
    final asset = project.assetFor(clip);
    if (asset == null || !asset.probe.hasAudio) return false;
    if (unreachableMediaIds.contains(asset.id)) return false;
    return clip.audio.hasAutomation || clip.id == selectedClipId;
  }

  /// The strip of [clip]'s body its sound is drawn in, or null when the lane
  /// is unknown or the strip is too thin to put a handle in.
  Rect? audioBandOf(Clip clip, Track track) {
    final index = _laneIndexOf(track.id);
    if (index == null) return null;
    final body = _geometry.clipBody(clip.start, clip.end, index);
    if (body.width <= 0) return null;
    final band = TimelineGeometry.audioBand(body,
        wholeClip: track.kind == TrackKind.audio);
    return band.height < 6 ? null : band;
  }

  /// The volume line as it is drawn: an anchor at each end of the clip's
  /// window and every point that falls inside it, left to right.
  ///
  /// [index] names the point in [ClipAudio.points], and is null for the two
  /// anchors, which are where the held-flat ends of the curve meet the clip
  /// rather than points anyone placed. One list for the painter and the
  /// pointer both, because a handle you can see and cannot hit is worse than
  /// no handle.
  List<({Offset at, int? index})> volumeLine(Clip clip, Track track) {
    final band = audioBandOf(clip, track);
    if (band == null) return const [];

    final points = clip.audio.points;
    final head = clip.sourceIn;
    final tail = clip.sourceOut;
    // Source ticks per timeline tick. A retimed clip crosses its own curve
    // faster or slower, so a point drawn at the source time it was placed at
    // lands somewhere else along the clip — which is exactly where it is heard.
    final rate = clip.speed.rate;

    Offset at(Tick sourceTime, double value) => Offset(
          _geometry.xOfTick(
              Tick(clip.start.raw + ((sourceTime - head).raw / rate).round())),
          TimelineGeometry.yOfLevel(band, value, ClipAudio.maxVolume),
        );

    final out = <({Offset at, int? index})>[];
    if (!points.any((p) => p.sourceTime == head)) {
      out.add((at: at(head, ClipAudio.automationAt(points, head)), index: null));
    }
    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      if (p.sourceTime < head || p.sourceTime > tail) continue;
      out.add((at: at(p.sourceTime, p.value), index: i));
    }
    if (!points.any((p) => p.sourceTime == tail)) {
      out.add((at: at(tail, ClipAudio.automationAt(points, tail)), index: null));
    }
    return out;
  }

  /// The point of [clip]'s volume line under [position], or null.
  int? volumePointAt(Clip clip, Track track, Offset position) {
    for (final handle in volumeLine(clip, track)) {
      final index = handle.index;
      if (index == null) continue;
      if ((position.dx - handle.at.dx).abs() <= volumePointGrabPx &&
          (position.dy - handle.at.dy).abs() <= volumePointGrabPx) {
        return index;
      }
    }
    return null;
  }

  int? _laneIndexOf(String trackId) {
    final all = lanes;
    for (var i = 0; i < all.length; i++) {
      if (all[i].id == trackId) return i;
    }
    return null;
  }

  /// Where [x] falls in the clip's source, clamped to its own window so a
  /// point cannot be dragged off the clip that carries it.
  Tick _sourceTimeAtX(Clip clip, double x) {
    final raw = clip.sourceTimeAt(_geometry.tickAtX(x)).raw;
    return Tick(raw.clamp(clip.sourceIn.raw, clip.sourceOut.raw));
  }

  /// Takes the press if it was about the volume line. Returns false when it
  /// was about the clip, and the caller carries on with move or trim.
  ///
  /// Checked before the trim handles rather than after: a point can sit
  /// anywhere along a clip, the ends included, and the two are told apart by
  /// height — a press at the same time but a different height still trims.
  bool _beginVolumeEdit(Clip clip, Track track, Offset position,
      {required bool alt}) {
    if (!showsVolumeLine(clip, track)) return false;
    final band = audioBandOf(clip, track);
    if (band == null) return false;
    final index = volumePointAt(clip, track, position);

    if (!alt) {
      // No modifier: an existing point is a handle, and everywhere else on the
      // clip is still the clip.
      if (index == null) return false;
      store.endGesture();
      _startPointDrag(clip, track, index, clip.audio, position);
      return true;
    }

    store.endGesture();
    if (index != null) {
      // ⌥ on a point takes it away. Adding with ⌥ and removing with ⌥ is one
      // key for one idea: this line is what I am editing.
      store.run(SetClipAudio(clip.id, clip.audio.withoutPoint(index)));
      store.endGesture();
      notifyListeners();
      return true;
    }

    final sourceTime = _sourceTimeAtX(clip, position.dx);
    final audio = clip.audio.withPoint(sourceTime,
        TimelineGeometry.levelAtY(band, position.dy, ClipAudio.maxVolume));
    final added = audio.points.indexWhere((p) => p.sourceTime == sourceTime);
    if (added < 0) return false;
    // No endGesture afterwards: the drag that follows folds into this, so
    // placing a point and pulling it down is one press of ⌘Z.
    store.run(SetClipAudio(clip.id, audio));
    _startPointDrag(clip, track, added, audio, position);
    return true;
  }

  void _startPointDrag(Clip clip, Track track, int index, ClipAudio origin,
      Offset position) {
    _drag = TimelineDrag.volumePoint;
    _dragClipId = clip.id;
    _dragOriginTrackId = track.id;
    _dragAnchorX = position.dx;
    _dragAnchorY = position.dy;
    _dragPointIndex = index;
    _dragOriginAudio = origin;
    _dragBand = audioBandOf(clip, track);
    notifyListeners();
  }

  void _moveVolumePoint(String clipId, Offset position) {
    final origin = _dragOriginAudio;
    final band = _dragBand;
    final clip = project.clipById(clipId);
    if (origin == null || band == null || clip == null) return;
    if (_dragPointIndex < 0 || _dragPointIndex >= origin.points.length) return;

    // Measured from where the point was when the gesture began, like every
    // other drag here — so a grab a few pixels off the handle does not snap it
    // under the pointer before it has moved.
    final was = origin.points[_dragPointIndex];
    final wanted = was.sourceTime.raw +
        ((position.dx - _dragAnchorX) / _geometry.pxPerTick *
                clip.speed.rate)
            .round();
    final wasY =
        TimelineGeometry.yOfLevel(band, was.value, ClipAudio.maxVolume);

    store.run(
      SetClipAudio(
        clipId,
        origin.movePoint(
          _dragPointIndex,
          sourceTime: Tick(
              wanted.clamp(clip.sourceIn.raw, clip.sourceOut.raw)),
          value: TimelineGeometry.levelAtY(
              band, wasY + (position.dy - _dragAnchorY), ClipAudio.maxVolume),
        ),
      ),
      fromGestureStart: true,
    );
  }

  /// Puts a point on [clipId]'s volume line at [sourceTime], at whatever level
  /// the line is already at there. What the inspector's button does: a point
  /// that changes nothing until it is dragged is the one you can safely add
  /// without looking.
  bool addVolumePoint(String clipId, Tick sourceTime) {
    final clip = project.clipById(clipId);
    if (clip == null) return false;
    if (project.trackOfClip(clipId)?.locked ?? true) return false;
    if (sourceTime < clip.sourceIn || sourceTime > clip.sourceOut) return false;

    final audio = clip.audio;
    store.endGesture();
    store.run(SetClipAudio(clipId,
        audio.withPoint(sourceTime, ClipAudio.automationAt(audio.points, sourceTime))));
    store.endGesture();
    notifyListeners();
    return true;
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

  // --- lanes ---------------------------------------------------------------

  bool get canAddOverlayTrack => project.canAddTrackOfKind(TrackKind.overlay);

  /// Adds an overlay lane above the visual lanes already there.
  bool addOverlayTrack() {
    if (!canAddOverlayTrack) return false;
    final number = project.trackCountOfKind(TrackKind.overlay) + 1;
    store.endGesture();
    store.run(AddTrack(Track.of(
      id: _ids.next('tr-'),
      kind: TrackKind.overlay,
      name: 'Overlay $number',
    )));
    store.endGesture();
    return true;
  }

  // --- captions and shapes -------------------------------------------------

  /// How long a caption is when it first appears. Three seconds is long enough
  /// to read a line and short enough that trimming it down is the exception.
  ///
  /// A shape gets the same length. It is not a length anybody reads, but two
  /// numbers would mean a caption and the shape behind it arriving at
  /// different times, which is a trim nobody asked for.
  static final Tick defaultCaptionDuration =
      Tick(3 * Timebase.project.ticksPerSecond);

  bool get canAddTextClip =>
      project.canAddTrackOfKind(TrackKind.text) ||
      _textLaneWithRoomAt(playhead) != null;

  /// A shape goes on a text lane, so it is the same question.
  bool get canAddShapeClip => canAddTextClip;

  /// Puts a caption on a text lane at the playhead and selects it. See
  /// [_addDrawnClip] for which lane, and for what happens when there is none.
  bool addTextClip({ClipText text = const ClipText(text: 'Text')}) =>
      _addDrawnClip(
        label: 'Add text',
        build: (id, at) => Clip.caption(
          id: id,
          start: at,
          duration: defaultCaptionDuration,
          text: text,
        ),
      );

  /// Puts a shape on a text lane at the playhead and selects it.
  ///
  /// Every word of [addTextClip] applies: the same lanes, the same "make one
  /// when there is no room", the same single undo entry. A shape is the other
  /// thing the app draws, and giving it lanes of its own would mean a second
  /// cap to keep in step with `VD_MAX_LAYERS` for no difference anybody could
  /// see on screen.
  bool addShapeClip({ShapeKind kind = ShapeKind.rectangle}) => _addDrawnClip(
        label: 'Add shape',
        build: (id, at) => Clip.drawing(
          id: id,
          start: at,
          duration: defaultCaptionDuration,
          shape: ClipShape.of(kind),
        ),
      );

  /// The half of adding a caption and adding a shape that is the same, which
  /// is all of it but the clip.
  ///
  /// It goes on the first text lane with room for it and makes a new lane when
  /// there is none — which is what someone adding a second caption over the
  /// first actually means. Stacking them on one lane is impossible (lanes hold
  /// no overlaps) and refusing would be a button that stops working the moment
  /// two things want to be on screen together.
  ///
  /// Returns false only when every lane is full and no more may be added.
  bool _addDrawnClip({
    required String label,
    required Clip Function(String id, Tick at) build,
  }) {
    final at = playhead;
    final existing = _textLaneWithRoomAt(at);
    if (existing == null && !project.canAddTrackOfKind(TrackKind.text)) {
      return false;
    }

    final track = existing ??
        Track.of(
          id: _ids.next('tr-'),
          kind: TrackKind.text,
          name: 'Text ${project.trackCountOfKind(TrackKind.text) + 1}',
        );
    final clip = build(_ids.next('c-'), at);

    store.endGesture();
    // One undo entry even when a lane had to be made: adding a caption is one
    // action, and pressing ⌘Z twice to take back one button is the bug
    // InsertClips.newTracks exists to avoid.
    store.run(InsertClips(
      [(trackId: track.id, clip: clip, index: null)],
      label: label,
      newTracks: existing == null ? [track] : const [],
    ));
    store.endGesture();

    _selectedClipIds
      ..clear()
      ..add(clip.id);
    notifyListeners();
    return true;
  }

  /// The first text lane where a caption starting at [at] would fit, or null.
  Track? _textLaneWithRoomAt(Tick at) {
    final end = Tick(at.raw + defaultCaptionDuration.raw);
    for (final track in project.tracks) {
      if (track.kind != TrackKind.text || track.locked) continue;
      final clash = track.clips.any((c) => c.start < end && at < c.end);
      if (!clash) return track;
    }
    return null;
  }

  bool get canAddAudioTrack => project.canAddTrackOfKind(TrackKind.audio);

  /// Adds an audio lane below the ones already there.
  bool addAudioTrack() {
    if (!canAddAudioTrack) return false;
    store.endGesture();
    store.run(AddTrack(_newAudioTrack()));
    store.endGesture();
    return true;
  }

  Track _newAudioTrack() => Track.of(
        id: _ids.next('tr-'),
        kind: TrackKind.audio,
        name: 'Audio ${project.trackCountOfKind(TrackKind.audio) + 1}',
      );

  // --- detaching audio -----------------------------------------------------

  /// The selected clips whose sound could be lifted onto a lane of its own:
  /// on a visual lane, with a source that has audio, and not already silent.
  List<Clip> get detachableClips {
    final out = <Clip>[];
    for (final id in _selectedClipIds) {
      final track = project.trackOfClip(id);
      if (track == null || !track.kind.isVisual) continue;
      final clip = track.clipById(id)!;
      if (clip.audio.muted) continue;
      final asset = project.assetFor(clip);
      if (asset == null || !asset.probe.hasAudio) continue;
      out.add(clip);
    }
    return out;
  }

  bool get canDetachAudio => detachableClips.isNotEmpty;

  /// Lifts each selected clip's sound onto an audio lane, muting the clip it
  /// came from. One undo entry however many clips are selected.
  ///
  /// Where each one lands is decided here rather than in the command: the
  /// first audio lane with room at that moment in time, and a new lane when
  /// none has any. Detaching two clips that overlap has to put them on
  /// different lanes, because one lane cannot hold two clips at once.
  bool detachAudio() {
    final sources = detachableClips;
    if (sources.isEmpty) return false;

    // What each lane already holds, plus what this edit is about to put there.
    final lanes = <String, List<TimeSpan>>{
      for (final t in project.tracks)
        if (t.kind == TrackKind.audio && !t.locked)
          t.id: [for (final c in t.clips) c.span],
    };
    final order = lanes.keys.toList();
    final created = <Track>[];
    final detachments = <AudioDetachment>[];

    for (final clip in sources) {
      String? target;
      for (final laneId in order) {
        if (lanes[laneId]!.every((s) => !s.overlaps(clip.span))) {
          target = laneId;
          break;
        }
      }
      if (target == null) {
        // Counting the ones this edit has already invented, so the cap holds
        // across a multi-clip detach rather than only against the saved file.
        if (project.trackCountOfKind(TrackKind.audio) + created.length >=
            Project.maxTracksOfKind(TrackKind.audio)) {
          continue; // out of lanes; the rest of the selection still detaches
        }
        final track = Track.of(
          id: _ids.next('tr-'),
          kind: TrackKind.audio,
          name: 'Audio ${project.trackCountOfKind(TrackKind.audio) + created.length + 1}',
        );
        created.add(track);
        lanes[track.id] = [];
        order.add(track.id);
        target = track.id;
      }

      lanes[target]!.add(clip.span);
      detachments.add((
        fromClipId: clip.id,
        toTrackId: target,
        clip: Clip(
          id: _ids.next('cl-'),
          mediaId: clip.mediaId,
          start: clip.start,
          duration: clip.duration,
          sourceIn: clip.sourceIn,
          // At the speed the picture was playing it. A detached sound that
          // reverted to 1x would be the same take drifting out of step with
          // the shot it came from.
          speed: clip.speed,
          label: clip.label,
          // The sound arrives at the level the video clip was playing it,
          // fades and all. Detaching is a change of where a sound lives, not
          // of how loud it is.
          audio: clip.audio,
        ),
      ));
    }

    if (detachments.isEmpty) return false;
    store.endGesture();
    store.run(DetachAudio(detachments, newTracks: created));
    store.endGesture();
    notifyListeners();
    return true;
  }

  /// Removes a lane and everything on it. One undo away, like every edit.
  bool removeTrack(String trackId) {
    final track = project.trackById(trackId);
    if (track == null || track.kind == TrackKind.main) return false;
    store.endGesture();
    store.run(RemoveTrack(trackId));
    store.endGesture();
    _pruneSelection();
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
