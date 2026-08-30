import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

import '../../commands/document_store.dart';
import '../../model/clip.dart';
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
}

/// View state for the timeline: where it is looking, what is selected, and
/// what the pointer is doing.
///
/// The document is not in here — it is read live from the [DocumentStore] at
/// paint time — and neither is the playhead, which lives in the transport.
/// Keeping both out means there is exactly one copy of each and no way for
/// this to disagree with them.
class TimelineController extends ChangeNotifier {
  TimelineController({required this.store, required this.transport}) {
    store.addListener(_onExternalChange);
    transport.addListener(_onExternalChange);
  }

  final DocumentStore store;
  final TimelineTransport transport;

  TimelineGeometry _geometry = const TimelineGeometry();
  String? _selectedClipId;
  TimelineDrag _drag = TimelineDrag.none;
  Set<String> _unreachableMediaIds = const {};

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

    // The ruler is the scrub strip. Anywhere else, the pointer is about a
    // clip — which in M1 means selecting one.
    if (position.dy < TimelineGeometry.rulerHeight) {
      _drag = TimelineDrag.scrub;
      _following = true;
      seekTo(_geometry.tickAtX(position.dx));
      notifyListeners();
      return;
    }

    select(clipAt(position)?.clip.id);
  }

  void pointerMove(Offset position) {
    if (_drag != TimelineDrag.scrub) return;
    seekTo(_geometry.tickAtX(position.dx));
  }

  void pointerUp() {
    if (_drag == TimelineDrag.none) return;
    _drag = TimelineDrag.none;
    notifyListeners();
  }

  @override
  void dispose() {
    store.removeListener(_onExternalChange);
    transport.removeListener(_onExternalChange);
    super.dispose();
  }
}
