import 'package:flutter/material.dart';

import '../../model/clip.dart';
import '../../model/media.dart';
import '../../model/time.dart';
import '../../model/track.dart';
import '../theme.dart';
import '../timecode.dart';
import 'timeline_controller.dart';
import 'timeline_geometry.dart';

/// Draws the whole timeline onto one canvas.
///
/// One painter rather than a widget per clip, which is the finding S2 was run
/// to get: at a thousand clips, widget-per-clip is what makes an editor feel
/// heavy, and the cost of a canvas is flat in clip count once offscreen clips
/// are culled. [shouldRepaint] returns false on purpose — the controller is
/// the repaint signal, and it already fires for the document, the transport
/// and the view.
class TimelinePainter extends CustomPainter {
  TimelinePainter(this.controller) : super(repaint: controller);

  final TimelineController controller;

  /// Laid-out text is expensive and the same strings recur every frame —
  /// lane names, ruler labels, clip labels. Bounded because a scrub across a
  /// long timeline generates a lot of distinct ruler labels.
  static final Map<String, TextPainter> _labels = {};

  static TextPainter _text(String value, Color color, double size,
      [FontWeight weight = FontWeight.w400]) {
    final key = '$value|${color.toARGB32()}|$size|${weight.value}';
    if (_labels.length > 900) _labels.clear();
    return _labels.putIfAbsent(key, () {
      return TextPainter(
        text: TextSpan(
          text: value,
          style: TextStyle(color: color, fontSize: size, fontWeight: weight),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
    });
  }

  static Color _colorOf(TrackKind kind) => switch (kind) {
        TrackKind.main => VdColors.clipVideo,
        TrackKind.overlay => VdColors.clipOverlay,
        TrackKind.audio => VdColors.clipAudio,
        TrackKind.text => VdColors.clipText,
      };

  @override
  void paint(Canvas canvas, Size size) {
    final geometry = controller.geometry;
    final project = controller.project;

    canvas.drawRect(Offset.zero & size, Paint()..color = VdColors.rail);

    final step = geometry.rulerStep(project.format.frameRate);
    _paintGrid(canvas, size, step);

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(TimelineGeometry.headerWidth, 0,
        size.width - TimelineGeometry.headerWidth, size.height));
    for (var i = 0; i < project.tracks.length; i++) {
      _paintTrack(canvas, size, i, project.tracks[i]);
    }
    _paintRulerLabels(canvas, size, step);
    _paintPlayhead(canvas, size);
    canvas.restore();

    _paintHeaders(canvas, size);
  }

  /// Gridlines run the full height rather than stopping at the ruler: reading
  /// a cut against a time is the whole reason the ruler is there.
  void _paintGrid(Canvas canvas, Size size, Tick step) {
    final geometry = controller.geometry;
    final line = Paint()..color = VdColors.line.withValues(alpha: 0.55);

    var t = (geometry.firstVisibleTick.raw ~/ step.raw) * step.raw;
    while (true) {
      final x = geometry.xOfTick(Tick(t));
      if (x > size.width) break;
      if (x >= TimelineGeometry.headerWidth) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
      }
      t += step.raw;
    }
  }

  void _paintRulerLabels(Canvas canvas, Size size, Tick step) {
    final geometry = controller.geometry;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, TimelineGeometry.rulerHeight),
      Paint()..color = VdColors.panel.withValues(alpha: 0.92),
    );

    // Frames below a second a step, a clock above it: a ruler labelled
    // 00:03:11 every 40 px is unreadable, and one labelled 00:03 four times
    // in a row is a lie.
    final showFrames = step.raw < Timebase.project.ticksPerSecond;
    final fps = controller.frameRate;

    var t = (geometry.firstVisibleTick.raw ~/ step.raw) * step.raw;
    while (true) {
      final x = geometry.xOfTick(Tick(t));
      if (x > size.width) break;
      if (x >= TimelineGeometry.headerWidth && t >= 0) {
        canvas.drawLine(
          Offset(x, TimelineGeometry.rulerHeight - 6),
          Offset(x, TimelineGeometry.rulerHeight),
          Paint()..color = VdColors.dim.withValues(alpha: 0.7),
        );
        _text(showFrames ? timecode(t, fps) : clockLabel(t), VdColors.dim, 9.5)
            .paint(canvas, Offset(x + 4, 5));
      }
      t += step.raw;
    }

    canvas.drawLine(
      Offset(0, TimelineGeometry.rulerHeight),
      Offset(size.width, TimelineGeometry.rulerHeight),
      Paint()..color = VdColors.line,
    );
  }

  void _paintTrack(Canvas canvas, Size size, int index, Track track) {
    final geometry = controller.geometry;
    final top = geometry.topOfTrack(index);
    if (top > size.height) return;

    canvas.drawRect(
      Rect.fromLTWH(TimelineGeometry.headerWidth, top,
          size.width - TimelineGeometry.headerWidth,
          TimelineGeometry.trackHeight),
      Paint()..color = VdColors.canvas.withValues(alpha: 0.6),
    );

    for (final clip in track.clips) {
      final x0 = geometry.xOfTick(clip.start);
      final x1 = geometry.xOfTick(clip.end);
      // Culled here, which is what keeps the cost flat in clip count.
      if (x1 < TimelineGeometry.headerWidth || x0 > size.width) continue;
      _paintClip(canvas, clip, track, x0, x1, top);
    }
  }

  void _paintClip(Canvas canvas, Clip clip, Track track, double x0, double x1,
      double top) {
    final asset = controller.project.assetFor(clip);
    final missing = asset == null ||
        controller.unreachableMediaIds.contains(asset.id);
    final selected = clip.id == controller.selectedClipId;

    // Half a pixel of inset on each side, so two clips butted flush on a
    // magnetic track still read as two clips rather than one long one.
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTRB(x0 + 0.5, top + 3, x1 - 0.5,
          top + TimelineGeometry.trackHeight - 3),
      const Radius.circular(3),
    );

    final base = _colorOf(track.kind);
    canvas.drawRRect(
      rect,
      Paint()
        ..color = missing
            ? VdColors.warn.withValues(alpha: 0.22)
            : base.withValues(alpha: clip.enabled ? 0.92 : 0.4),
    );

    if (missing) {
      canvas.drawRRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = VdColors.warn.withValues(alpha: 0.8),
      );
    }
    if (selected) {
      canvas.drawRRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = VdColors.text,
      );
    }

    final width = x1 - x0;
    if (width < 34) return;

    canvas.save();
    canvas.clipRRect(rect);
    final label = clip.label.isEmpty
        ? (asset?.displayName ?? 'clip')
        : clip.label;
    _text(label, VdColors.text.withValues(alpha: missing ? 0.75 : 0.95), 11,
            FontWeight.w500)
        .paint(canvas, Offset(x0 + 7, top + 8));
    if (width > 92) {
      _text(
        missing ? 'missing' : _clipDetail(clip, asset),
        (missing ? VdColors.warn : VdColors.text).withValues(alpha: 0.7),
        9.5,
      ).paint(canvas, Offset(x0 + 7, top + 25));
    }
    canvas.restore();
  }

  String _clipDetail(Clip clip, MediaAsset? asset) {
    final length = timecode(clip.duration.raw, controller.frameRate);
    if (asset == null || !asset.probe.hasVideo) return length;
    return '$length · ${asset.probe.displayWidth}×${asset.probe.displayHeight}';
  }

  void _paintHeaders(Canvas canvas, Size size) {
    final geometry = controller.geometry;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, TimelineGeometry.headerWidth, size.height),
      Paint()..color = VdColors.panel,
    );

    for (var i = 0; i < controller.project.tracks.length; i++) {
      final track = controller.project.tracks[i];
      final top = geometry.topOfTrack(i);
      if (top > size.height) break;

      canvas.drawCircle(
        Offset(14, top + TimelineGeometry.trackHeight / 2),
        3.5,
        Paint()..color = _colorOf(track.kind),
      );
      _text(track.name, VdColors.text.withValues(alpha: 0.9), 11,
              FontWeight.w500)
          .paint(canvas, Offset(26, top + 10));

      final marks = [
        if (track.isMagnetic) 'magnetic',
        if (track.muted) 'muted',
        if (track.locked) 'locked',
        if (track.hidden) 'hidden',
      ];
      if (marks.isNotEmpty) {
        _text(marks.join(' · '), VdColors.dim, 9)
            .paint(canvas, Offset(26, top + 26));
      }
    }

    canvas.drawLine(
      Offset(TimelineGeometry.headerWidth, 0),
      Offset(TimelineGeometry.headerWidth, size.height),
      Paint()..color = VdColors.line,
    );
  }

  void _paintPlayhead(Canvas canvas, Size size) {
    final x = controller.geometry.xOfTick(controller.playhead);
    if (x < TimelineGeometry.headerWidth - 1 || x > size.width) return;

    final paint = Paint()
      ..color = VdColors.playhead
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    canvas.drawPath(
      Path()
        ..moveTo(x - 5, 0)
        ..lineTo(x + 5, 0)
        ..lineTo(x, 8)
        ..close(),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant TimelinePainter oldDelegate) => false;

  @override
  bool shouldRebuildSemantics(covariant TimelinePainter oldDelegate) => false;
}
