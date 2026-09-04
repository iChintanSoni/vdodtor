import 'dart:math' as math;
import 'dart:ui' show Rect;

import '../../model/time.dart';

/// Where things are: the mapping between ticks and pixels, and the lane
/// layout that follows from it.
///
/// A value type with no state of its own beyond a zoom and a scroll, kept
/// separate from the widget on purpose. Every interesting question a timeline
/// asks — what time is under the cursor, which lane is under it, does this
/// clip need drawing at all, where does the playhead go — is answered here,
/// and answering it needs no window.
///
/// Pixels are doubles because screens are. Ticks are not: everything that
/// crosses back into the document goes through [tickAtX], which returns a
/// whole [Tick], and callers snap that to a frame before it becomes a
/// playhead position.
final class TimelineGeometry {
  const TimelineGeometry({this.pxPerSecond = 80, this.scrollPx = 0});

  /// Zoom, as the width one second of timeline occupies.
  final double pxPerSecond;

  /// How far the view has scrolled right, in pixels. Never negative: there is
  /// nothing before zero and scrolling into it only wastes screen.
  final double scrollPx;

  /// The lane header strip, which does not scroll.
  static const double headerWidth = 116;
  static const double rulerHeight = 26;
  static const double trackHeight = 48;
  static const double trackGap = 4;

  /// The strip along the bottom that says how much timeline there is.
  static const double scrollbarHeight = 10;

  /// A thumb never shrinks below this, however long the project. A bar you
  /// cannot see is a bar you cannot grab, and the one place that bites is the
  /// long project — which is the only case it exists for.
  static const double minThumbWidth = 28;

  /// Zoom bounds. The low end fits about half an hour on a laptop screen; the
  /// high end puts a 30 fps frame at ~40 px, which is as far in as anyone can
  /// use before frames stop being the unit that matters.
  static const double minPxPerSecond = 2;
  static const double maxPxPerSecond = 1200;

  static const Timebase _timebase = Timebase.project;

  double get pxPerTick => pxPerSecond / _timebase.ticksPerSecond;

  double xOfTick(Tick t) => headerWidth + t.raw * pxPerTick - scrollPx;

  /// The time at [x]. Unclamped and unsnapped — callers decide whether a
  /// negative answer means zero and whether it should land on a frame.
  Tick tickAtX(double x) =>
      Tick(((x - headerWidth + scrollPx) / pxPerTick).round());

  /// The first and last tick the view can currently show. Used to cull: a
  /// timeline with a thousand clips draws the dozen that are on screen.
  Tick get firstVisibleTick => tickAtX(headerWidth);
  Tick lastVisibleTick(double width) => tickAtX(width);

  double topOfTrack(int index) =>
      rulerHeight + index * (trackHeight + trackGap);

  /// The rounded block a clip is drawn and grabbed as, on lane [laneIndex].
  ///
  /// Half a pixel of inset on each side, so two clips butted flush on a
  /// magnetic track still read as two clips rather than one long one. Here
  /// rather than in the painter because the pointer has to hit exactly what
  /// the eye sees, and two copies of that rectangle is one copy too many.
  Rect clipBody(Tick start, Tick end, int laneIndex) {
    final top = topOfTrack(laneIndex);
    return Rect.fromLTRB(xOfTick(start) + 0.5, top + 3, xOfTick(end) - 0.5,
        top + trackHeight - 3);
  }

  /// The strip inside a clip's body where its sound is drawn: the waveform,
  /// and the volume line over it.
  ///
  /// An audio lane gives the whole clip to it. A picture lane gives a strip
  /// along the bottom, because what identifies a video clip is its name and
  /// its sound is the thing you look for underneath.
  static Rect audioBand(Rect body, {required bool wholeClip}) => wholeClip
      ? body.deflate(5)
      : Rect.fromLTRB(
          body.left, body.bottom - body.height * 0.40, body.right,
          body.bottom - 3);

  /// Where a level sits inside [band]: 0 at the bottom, [maxValue] at the top,
  /// so unity lands exactly halfway up.
  ///
  /// Linear in amplitude, on the same scale as the fader, for the reason the
  /// fades are: the handle position means what it looks like it means. It does
  /// spend half the travel above unity, where little of the work happens — a
  /// scale that gave ducking more room would have to bend somewhere, and a
  /// bent scale is one nobody can read a number off.
  static double yOfLevel(Rect band, double value, double maxValue) =>
      band.bottom - (value.clamp(0.0, maxValue) / maxValue) * band.height;

  /// The inverse of [yOfLevel], clamped to the ends of the band.
  static double levelAtY(Rect band, double y, double maxValue) {
    if (band.height <= 0) return maxValue / 2;
    final level = (band.bottom - y) / band.height * maxValue;
    return level.clamp(0.0, maxValue);
  }

  /// The lane at [y], or null for the ruler, the gaps between lanes, and the
  /// empty space below the last one.
  int? trackIndexAt(double y, int trackCount) {
    if (y < rulerHeight) return null;
    final index = ((y - rulerHeight) / (trackHeight + trackGap)).floor();
    if (index < 0 || index >= trackCount) return null;
    final within = (y - rulerHeight) - index * (trackHeight + trackGap);
    return within <= trackHeight ? index : null;
  }

  /// Height needed to show [trackCount] lanes without scrolling.
  static double heightFor(int trackCount) =>
      rulerHeight + trackCount * (trackHeight + trackGap) + trackGap +
          scrollbarHeight;

  /// The strip the scrollbar occupies in a view [width] by [height].
  ///
  /// Measured from the **bottom** rather than from the last lane, because
  /// [heightFor] is clamped by the editor and a project with many lanes gets
  /// less room than it asked for. Pinned to the bottom it is where the eye
  /// looks for it either way, and the pointer and the paint agree because both
  /// ask here.
  static Rect scrollbarBand(double width, double height) =>
      Rect.fromLTRB(headerWidth, height - scrollbarHeight, width, height);

  /// The thumb for a project [content] long shown in a view [width] wide, or
  /// null when the whole thing fits and a scrollbar would be saying nothing.
  ///
  /// `scale` is content pixels per thumb pixel, so dragging the thumb needs no
  /// second copy of this arithmetic.
  ///
  /// What there is to reach is the longer of the film and wherever the view has
  /// actually been panned to. [TimelineController] bounds scrolling at the end
  /// of the film, so the second half of that is normally moot — but the bound
  /// needs a window width and this function does not, and a film that has just
  /// got shorter leaves the view beyond its own end until something re-applies
  /// it. A bar drawing the view outside its own track would be lying about
  /// where you are, and it costs one `max` not to.
  ({double left, double width, double scale})? scrollbarThumb(
      Tick content, double width) {
    final track = width - headerWidth;
    if (track <= 0) return null;

    final contentPx = math.max(content.raw * pxPerTick, scrollPx + track);
    if (contentPx <= track + 0.5) return null;

    final thumb = math.max(minThumbWidth, track * track / contentPx);
    final travel = track - thumb;
    final reach = contentPx - track;
    return (
      left: travel <= 0 ? 0 : (scrollPx / reach) * travel,
      width: thumb,
      scale: travel <= 0 ? 0 : reach / travel,
    );
  }

  TimelineGeometry copyWith({double? pxPerSecond, double? scrollPx}) =>
      TimelineGeometry(
        pxPerSecond: pxPerSecond ?? this.pxPerSecond,
        scrollPx: math.max(0, scrollPx ?? this.scrollPx),
      );

  /// Zooms by [factor] while keeping whatever time is under [focusX] under it.
  ///
  /// Zooming towards the pointer rather than the left edge is the difference
  /// between a timeline that can be navigated and one that has to be
  /// re-found after every scroll wheel notch.
  TimelineGeometry zoomedAround(double focusX, double factor) {
    final anchor = tickAtX(focusX);
    final next = (pxPerSecond * factor).clamp(minPxPerSecond, maxPxPerSecond);
    final nextPxPerTick = next / _timebase.ticksPerSecond;
    return TimelineGeometry(
      pxPerSecond: next,
      scrollPx: math.max(0, anchor.raw * nextPxPerTick - (focusX - headerWidth)),
    );
  }

  TimelineGeometry pannedBy(double dx) => copyWith(scrollPx: scrollPx + dx);

  /// Scrolled so [t] is inside the visible span, leaving [margin] px of room.
  ///
  /// Returns the same geometry when it already is, so following the playhead
  /// during playback does not repaint on every frame — only on the ones that
  /// actually move the view.
  TimelineGeometry scrolledToShow(Tick t, double width,
      {double margin = 80}) {
    final x = xOfTick(t);
    final left = headerWidth + margin;
    final right = width - margin;
    if (x >= left && x <= right) return this;

    // Past the right edge, jump so the playhead sits a third of the way in:
    // scrolling it back to the very edge means doing it again next frame.
    final target = x > right ? headerWidth + (width - headerWidth) / 3 : left;
    return copyWith(scrollPx: scrollPx + (x - target));
  }

  /// The ruler's label spacing, in ticks: the smallest candidate wide enough
  /// that labels do not collide.
  ///
  /// Candidates are whole frames at the low end and whole seconds above, so a
  /// gridline always lands on something real. A ruler ticking every 0.37 s is
  /// a ruler nobody can read a time off.
  Tick rulerStep(Rational frameRate, {double minLabelPx = 78}) {
    final perFrame = _timebase.ticksPerFrame(frameRate);
    final candidates = <int>[
      perFrame,
      perFrame * 2,
      perFrame * 5,
      perFrame * 10,
      for (final seconds in const [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800])
        _timebase.ticksPerSecond * seconds,
    ];
    for (final step in candidates) {
      if (step * pxPerTick >= minLabelPx) return Tick(step);
    }
    return Tick(candidates.last);
  }

  @override
  bool operator ==(Object other) =>
      other is TimelineGeometry &&
      other.pxPerSecond == pxPerSecond &&
      other.scrollPx == scrollPx;

  @override
  int get hashCode => Object.hash(pxPerSecond, scrollPx);

  @override
  String toString() =>
      'TimelineGeometry(${pxPerSecond.toStringAsFixed(1)} px/s, '
      'scroll ${scrollPx.toStringAsFixed(1)})';
}
