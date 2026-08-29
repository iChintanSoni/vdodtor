// Canvas timeline for the S2 spike: drag, trim, snap, ripple, zoom.
//
// Everything is drawn by one CustomPainter rather than a widget per clip —
// with a few hundred clips, widget-per-clip is what makes editors feel heavy.

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'model.dart';

const double kRulerHeight = 30;
const double kTrackHeight = 54;
const double kTrackGap = 6;
const double kHeaderWidth = 112;
const double kHandleWidth = 9;
const double kSnapPx = 8;

enum DragMode { none, move, trimStart, trimEnd, scrub }

class TimelineController extends ChangeNotifier {
  TimelineController(this.doc);

  TimelineDoc doc;

  double pxPerSecond = 60;
  double scrollPx = 0;
  int playhead = 0;
  bool snapping = true;

  Clip? selected;
  Track? selectedTrack;

  // live drag state
  DragMode mode = DragMode.none;
  Clip? dragClip;
  Track? dragTrack;
  int _dragOriginStart = 0;
  int _dragOriginDuration = 0;
  double _dragStartX = 0;
  int? snapGuide;

  // instrumentation
  int dragUpdates = 0;

  double xForTicks(int ticks) =>
      kHeaderWidth + secondsFromTicks(ticks) * pxPerSecond - scrollPx;

  int ticksForX(double x) =>
      ticksFromSeconds((x - kHeaderWidth + scrollPx) / pxPerSecond);

  double trackTop(int index) => kRulerHeight + index * (kTrackHeight + kTrackGap);

  int? trackIndexAt(double y) {
    if (y < kRulerHeight) return null;
    final i = ((y - kRulerHeight) / (kTrackHeight + kTrackGap)).floor();
    if (i < 0 || i >= doc.tracks.length) return null;
    final within = (y - kRulerHeight) - i * (kTrackHeight + kTrackGap);
    return within <= kTrackHeight ? i : null;
  }

  void zoomAround(double focusX, double factor) {
    final ticksAtFocus = ticksForX(focusX);
    pxPerSecond = (pxPerSecond * factor).clamp(4.0, 1200.0);
    // Keep the time under the cursor pinned while zooming.
    scrollPx = secondsFromTicks(ticksAtFocus) * pxPerSecond - (focusX - kHeaderWidth);
    if (scrollPx < 0) scrollPx = 0;
    notifyListeners();
  }

  void panBy(double dx) {
    scrollPx = (scrollPx + dx).clamp(0.0, double.infinity);
    notifyListeners();
  }

  /// Snaps [ticks] to a nearby clip edge or the playhead, if within [kSnapPx].
  int _snap(int ticks, {Clip? except}) {
    if (!snapping) {
      snapGuide = null;
      return ticks;
    }
    final candidates = doc.snapEdges(except: except)..add(playhead);
    final x = xForTicks(ticks);
    int? best;
    var bestDist = double.infinity;
    for (final c in candidates) {
      final d = (xForTicks(c) - x).abs();
      if (d < bestDist) {
        bestDist = d;
        best = c;
      }
    }
    if (best != null && bestDist <= kSnapPx) {
      snapGuide = best;
      return best;
    }
    snapGuide = null;
    return ticks;
  }

  void pointerDown(Offset p) {
    _dragStartX = p.dx;
    if (p.dy < kRulerHeight) {
      mode = DragMode.scrub;
      playhead = ticksForX(p.dx).clamp(0, 1 << 40);
      notifyListeners();
      return;
    }

    final ti = trackIndexAt(p.dy);
    if (ti == null) {
      selected = null;
      mode = DragMode.none;
      notifyListeners();
      return;
    }

    final track = doc.tracks[ti];
    for (final c in track.clips.reversed) {
      final x0 = xForTicks(c.start), x1 = xForTicks(c.end);
      if (p.dx >= x0 && p.dx <= x1) {
        selected = c;
        selectedTrack = track;
        dragClip = c;
        dragTrack = track;
        _dragOriginStart = c.start;
        _dragOriginDuration = c.duration;
        if (p.dx - x0 <= kHandleWidth) {
          mode = DragMode.trimStart;
        } else if (x1 - p.dx <= kHandleWidth) {
          mode = DragMode.trimEnd;
        } else {
          mode = DragMode.move;
        }
        notifyListeners();
        return;
      }
    }
    selected = null;
    mode = DragMode.none;
    notifyListeners();
  }

  void pointerMove(Offset p) {
    dragUpdates++;
    if (mode == DragMode.scrub) {
      playhead = ticksForX(p.dx).clamp(0, 1 << 40);
      notifyListeners();
      return;
    }
    final c = dragClip;
    if (c == null || mode == DragMode.none) return;

    final deltaTicks = ticksFromSeconds((p.dx - _dragStartX) / pxPerSecond);
    switch (mode) {
      case DragMode.move:
        var want = _dragOriginStart + deltaTicks;
        if (want < 0) want = 0;
        c.start = _snap(want, except: c);
      case DragMode.trimStart:
        final minTicks = ticksPerFrame(60);
        var wantStart = _dragOriginStart + deltaTicks;
        wantStart = _snap(wantStart, except: c);
        final maxStart = _dragOriginStart + _dragOriginDuration - minTicks;
        if (wantStart < 0) wantStart = 0;
        if (wantStart > maxStart) wantStart = maxStart;
        c.duration = _dragOriginStart + _dragOriginDuration - wantStart;
        c.start = wantStart;
      case DragMode.trimEnd:
        final minTicks = ticksPerFrame(60);
        var wantEnd = _dragOriginStart + _dragOriginDuration + deltaTicks;
        wantEnd = _snap(wantEnd, except: c);
        if (wantEnd < c.start + minTicks) wantEnd = c.start + minTicks;
        c.duration = wantEnd - c.start;
      case DragMode.none:
      case DragMode.scrub:
        break;
    }
    notifyListeners();
  }

  void pointerUp() {
    // A magnetic track never keeps gaps: committing repacks it end-to-end,
    // which also turns a drag past a neighbour into a reorder.
    if (dragTrack != null && dragTrack!.magnetic) dragTrack!.repack();
    mode = DragMode.none;
    dragClip = null;
    dragTrack = null;
    snapGuide = null;
    notifyListeners();
  }

  /// Delete with ripple: on a magnetic track the gap closes.
  void deleteSelected() {
    final c = selected, t = selectedTrack;
    if (c == null || t == null) return;
    t.clips.remove(c);
    if (t.magnetic) t.repack();
    selected = null;
    notifyListeners();
  }

  /// Splits the selected clip at the playhead.
  void splitAtPlayhead() {
    final t = selectedTrack ?? doc.tracks.first;
    for (final c in List.of(t.clips)) {
      if (playhead > c.start && playhead < c.end) {
        final tail = Clip(
          id: '${c.id}b',
          start: playhead,
          duration: c.end - playhead,
          label: c.label,
          color: c.color,
        );
        c.duration = playhead - c.start;
        t.clips.add(tail);
        t.sortByStart();
        selected = tail;
        selectedTrack = t;
        notifyListeners();
        return;
      }
    }
  }

  void toggleSnapping() {
    snapping = !snapping;
    notifyListeners();
  }
}

// ------------------------------------------------------------------ painter

class TimelinePainter extends CustomPainter {
  TimelinePainter(this.c) : super(repaint: c);

  final TimelineController c;
  static final Map<String, TextPainter> _labelCache = {};

  TextPainter _label(String text, Color color, double size, FontWeight w) {
    final key = '$text|${color.toARGB32()}|$size|${w.value}';
    // Duration labels change every frame while trimming; bound the cache.
    if (_labelCache.length > 1500) _labelCache.clear();
    return _labelCache.putIfAbsent(key, () {
      final tp = TextPainter(
        text: TextSpan(
            text: text,
            style: TextStyle(color: color, fontSize: size, fontWeight: w)),
        textDirection: TextDirection.ltr,
      )..layout();
      return tp;
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFF16181D);
    canvas.drawRect(Offset.zero & size, bg);

    _paintRuler(canvas, size);

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(kHeaderWidth, kRulerHeight,
        size.width - kHeaderWidth, size.height - kRulerHeight));
    for (var i = 0; i < c.doc.tracks.length; i++) {
      _paintTrack(canvas, size, i, c.doc.tracks[i]);
    }
    _paintSnapGuide(canvas, size);
    canvas.restore();

    _paintHeaders(canvas, size);
    _paintPlayhead(canvas, size);
  }

  void _paintRuler(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, kRulerHeight),
      Paint()..color = const Color(0xFF1E2128),
    );

    // Choose a tick step that keeps labels ~80px apart at any zoom.
    const steps = [0.04, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600];
    var step = steps.last.toDouble();
    for (final s in steps) {
      if (s * c.pxPerSecond >= 80) {
        step = s.toDouble();
        break;
      }
    }

    final line = Paint()..color = const Color(0xFF3A3F4B);
    final startSec = (c.scrollPx / c.pxPerSecond / step).floor() * step;
    final endSec = startSec + (size.width - kHeaderWidth) / c.pxPerSecond + step;
    for (var t = startSec; t <= endSec; t += step) {
      final x = c.xForTicks(ticksFromSeconds(t));
      if (x < kHeaderWidth - 1) continue;
      canvas.drawLine(Offset(x, kRulerHeight - 7), Offset(x, kRulerHeight), line);
      final label = step >= 1
          ? '${(t ~/ 60).toString().padLeft(2, '0')}:${(t % 60).toInt().toString().padLeft(2, '0')}'
          : '${t.toStringAsFixed(2)}s';
      _label(label, const Color(0xFF8A93A5), 10, FontWeight.w400)
          .paint(canvas, Offset(x + 3, 5));
    }
  }

  void _paintTrack(Canvas canvas, Size size, int index, Track track) {
    final top = c.trackTop(index);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(kHeaderWidth, top, size.width, kTrackHeight),
          const Radius.circular(3)),
      Paint()..color = const Color(0xFF1A1D23),
    );

    for (final clip in track.clips) {
      final x0 = c.xForTicks(clip.start);
      final x1 = c.xForTicks(clip.end);
      if (x1 < kHeaderWidth || x0 > size.width) continue;  // cull offscreen

      final r = RRect.fromRectAndRadius(
        Rect.fromLTRB(x0, top + 3, x1, top + kTrackHeight - 3),
        const Radius.circular(4),
      );
      final isSelected = identical(clip, c.selected);
      canvas.drawRRect(r, Paint()..color = clip.color.withValues(alpha: 0.85));

      if (track.kind == TrackKind.audio) {
        _paintFakeWaveform(canvas, Rect.fromLTRB(x0, top + 3, x1, top + kTrackHeight - 3));
      }

      if (isSelected) {
        canvas.drawRRect(
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Colors.white,
        );
        // Trim handles, only on the selected clip.
        final hp = Paint()..color = Colors.white.withValues(alpha: 0.9);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(x0, top + 3, kHandleWidth, kTrackHeight - 6),
              const Radius.circular(4)),
          hp,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(x1 - kHandleWidth, top + 3, kHandleWidth, kTrackHeight - 6),
              const Radius.circular(4)),
          hp,
        );
      }

      if (x1 - x0 > 44) {
        canvas.save();
        canvas.clipRect(Rect.fromLTRB(x0 + 6, top, x1 - 6, top + kTrackHeight));
        _label(clip.label, Colors.white.withValues(alpha: 0.95), 11, FontWeight.w500)
            .paint(canvas, Offset(x0 + 12, top + 8));
        _label('${secondsFromTicks(clip.duration).toStringAsFixed(2)}s',
                Colors.white.withValues(alpha: 0.65), 10, FontWeight.w400)
            .paint(canvas, Offset(x0 + 12, top + 24));
        canvas.restore();
      }
    }
  }

  void _paintFakeWaveform(Canvas canvas, Rect r) {
    final p = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    final mid = r.center.dy;
    for (var x = r.left + 2; x < r.right - 2; x += 3) {
      // Deterministic pseudo-waveform: real peaks come from peak files in M2.
      final n = ((x * 12.9898).remainder(7.0)).abs() / 7.0;
      final h = (r.height / 2 - 6) * (0.25 + n * 0.75);
      canvas.drawLine(Offset(x, mid - h), Offset(x, mid + h), p);
    }
  }

  void _paintSnapGuide(Canvas canvas, Size size) {
    final g = c.snapGuide;
    if (g == null) return;
    final x = c.xForTicks(g);
    canvas.drawLine(
      Offset(x, kRulerHeight),
      Offset(x, size.height),
      Paint()
        ..color = const Color(0xFFFFD166)
        ..strokeWidth = 1.5,
    );
  }

  void _paintHeaders(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, kRulerHeight, kHeaderWidth, size.height - kRulerHeight),
      Paint()..color = const Color(0xFF1E2128),
    );
    for (var i = 0; i < c.doc.tracks.length; i++) {
      final t = c.doc.tracks[i];
      final top = c.trackTop(i);
      final icon = switch (t.kind) {
        TrackKind.video => '▶',
        TrackKind.overlay => '◈',
        TrackKind.audio => '♪',
      };
      _label('$icon  ${t.name}', const Color(0xFFC9D1E0), 11, FontWeight.w500)
          .paint(canvas, Offset(10, top + 12));
      if (t.magnetic) {
        _label('magnetic', const Color(0xFF6B7385), 9, FontWeight.w400)
            .paint(canvas, Offset(10, top + 30));
      }
    }
    canvas.drawLine(
      Offset(kHeaderWidth, 0),
      Offset(kHeaderWidth, size.height),
      Paint()..color = const Color(0xFF2C313B),
    );
  }

  void _paintPlayhead(Canvas canvas, Size size) {
    final x = c.xForTicks(c.playhead);
    if (x < kHeaderWidth) return;
    final p = Paint()..color = const Color(0xFFFF5C5C);
    canvas.drawLine(Offset(x, 0), Offset(x, size.height), p..strokeWidth = 1.5);
    final path = Path()
      ..moveTo(x - 6, 0)
      ..lineTo(x + 6, 0)
      ..lineTo(x, 9)
      ..close();
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(covariant TimelinePainter old) => false;  // repaint: c drives it
}

// ------------------------------------------------------------------ widget

class TimelineView extends StatelessWidget {
  const TimelineView({super.key, required this.controller});
  final TimelineController controller;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (e) => controller.pointerDown(e.localPosition),
      onPointerMove: (e) => controller.pointerMove(e.localPosition),
      onPointerUp: (_) => controller.pointerUp(),
      onPointerSignal: (e) {
        if (e is PointerScrollEvent) {
          final keys = HardwareKeyboard.instance;
          if (keys.isMetaPressed || keys.isControlPressed) {
            controller.zoomAround(
                e.localPosition.dx, e.scrollDelta.dy > 0 ? 0.92 : 1.08);
          } else {
            controller.panBy(e.scrollDelta.dx != 0 ? e.scrollDelta.dx : e.scrollDelta.dy);
          }
        }
      },
      child: RepaintBoundary(
        child: CustomPaint(
          painter: TimelinePainter(controller),
          size: Size.infinite,
        ),
      ),
    );
  }
}
