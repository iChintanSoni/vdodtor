import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../media/waveforms.dart';
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
  TimelinePainter(this.controller, {this.waveforms})
      : super(
          repaint: waveforms == null
              ? controller
              : Listenable.merge([controller, waveforms]),
        );

  final TimelineController controller;

  /// Where the clips' waveforms come from, or null to draw none — which is
  /// what a widget test that is not about waveforms wants, and what the
  /// timeline shows for the moment before the first analysis lands.
  final WaveformCache? waveforms;

  /// Scratch for the envelope and the line segments it becomes.
  ///
  /// Static and grown on demand rather than owned: a painter is constructed
  /// on every build, and a timeline that allocated two buffers per clip per
  /// frame would spend more of playback in the collector than on the canvas.
  static Float32List _envelope = Float32List(0);
  static Float32List _columns = Float32List(0);

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
    final lanes = controller.lanes;
    _paintGrid(canvas, size, step);

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(TimelineGeometry.headerWidth, 0,
        size.width - TimelineGeometry.headerWidth, size.height));
    for (var i = 0; i < lanes.length; i++) {
      _paintTrack(canvas, size, i, lanes[i]);
    }
    _paintRulerLabels(canvas, size, step);
    _paintSnapGuide(canvas, size);
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
      _paintClip(canvas, clip, track, index, x0, x1, top, size.width);
    }
  }

  void _paintClip(Canvas canvas, Clip clip, Track track, int laneIndex,
      double x0, double x1, double top, double viewWidth) {
    final asset = controller.project.assetFor(clip);
    // A caption or a shape has no asset and is not missing one: it draws
    // itself. Without the first clause every drawn clip on the timeline would
    // be painted as broken media, which is a warning about nothing.
    final missing = !clip.isGenerated &&
        (asset == null || controller.unreachableMediaIds.contains(asset.id));
    final selected = controller.isSelected(clip.id);
    // Handles mean "you can trim this", and trimming is a single-clip idea.
    final lone = clip.id == controller.selectedClipId;

    // The same rectangle the pointer hits, from the same place, so what the
    // eye grabs and what the controller grabs cannot drift apart.
    final body = controller.geometry.clipBody(clip.start, clip.end, laneIndex);
    final rect = RRect.fromRectAndRadius(body, const Radius.circular(3));

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
    final width = x1 - x0;

    // A caption falls through both: there is no file to have a waveform, and
    // nothing on a text lane makes a sound to draw a line over.
    if (!missing && asset != null) {
      _paintWaveform(canvas, clip, track, asset, rect, x0, x1, viewWidth);
      _paintVolumeLine(canvas, clip, track, rect);
    }

    _paintTransition(canvas, clip, track, body);

    if (selected) {
      canvas.drawRRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = VdColors.text,
      );
      // Handles only on the selected clip. Drawing them on every clip would
      // put a grab target on every cut in the project and make a busy lane
      // unreadable; the edges stay grabbable either way.
      if (lone && width >= TimelineController.minimumBodyPx) {
        _paintHandles(canvas, rect, x0, x1, top);
      }
    }

    if (width < 34) return;

    canvas.save();
    canvas.clipRRect(rect);
    // A caption is named by what it says. Every other clip is named by its
    // file, and a caption has none — "clip" on a lane full of them would tell
    // you nothing about which is which.
    final label = clip.label.isNotEmpty
        ? clip.label
        : (clip.text?.label ?? asset?.displayName ?? 'clip');
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

  /// The clip's sound, drawn as one vertical line per pixel column.
  ///
  /// The envelope comes from the file and the height comes from the clip:
  /// A transition, drawn at the cut it happens at rather than on the clip that
  /// records it.
  ///
  /// The document keeps it on the incoming clip because a cut has two sides and
  /// a transition is one decision — but on screen it belongs to *both*, and a
  /// mark that sat only on the second clip would read as a property of that
  /// clip rather than of the join. So it straddles: half over each, exactly
  /// where the engine puts the window.
  ///
  /// Nothing is drawn when the clip has no neighbour to join. A transition with
  /// no cut under it does nothing, and drawing one would be a promise the
  /// picture does not keep.
  void _paintTransition(Canvas canvas, Clip clip, Track track, Rect body) {
    final transition = clip.transition;
    if (!transition.isActive) return;

    final index = track.indexOfClip(clip.id);
    if (index <= 0) return;
    final previous = track.clips[index - 1];
    if (previous.end != clip.start) return;

    // The same clamp the engine applies: half a window either side, and never
    // past either clip.
    final half = math.min(
      transition.duration.raw ~/ 2,
      math.min(previous.duration.raw, clip.duration.raw),
    );
    if (half <= 0) return;

    final cut = body.left;
    final pixels = half * controller.geometry.pxPerTick;
    // A cut is a line, so at any sensible zoom the window is a sliver. Widened
    // to something a pointer could aim at, because a mark nobody can see is a
    // setting nobody knows is on.
    final reach = math.max(pixels, 4.0);
    final area = Rect.fromLTRB(cut - reach, body.top, cut + reach, body.bottom);

    canvas.drawRect(
      area,
      Paint()..color = VdColors.accent.withValues(alpha: 0.34),
    );
    // The bow tie every editor draws at a cut, and the reason it is two
    // triangles rather than a block: it says which way the picture is going.
    final middle = area.center.dy;
    final path = Path()
      ..moveTo(area.left, area.top)
      ..lineTo(area.left, area.bottom)
      ..lineTo(area.right, area.top)
      ..lineTo(area.right, area.bottom)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = VdColors.accent.withValues(alpha: 0.9),
    );
    canvas.drawLine(
      Offset(area.left, middle),
      Offset(area.right, middle),
      Paint()
        ..strokeWidth = 1
        ..color = VdColors.accent.withValues(alpha: 0.9),
    );
  }

  /// volume, fades and mute scale it here, at paint time. That split is what
  /// makes a fader instant — pulling one repaints, where anything cached per
  /// clip would have to be rebuilt — and it is also what lets one analysis
  /// serve every clip cut from the same file.
  ///
  /// A lane's worth of columns is filled from the pyramid in one pass, at
  /// whatever level matches the zoom, so this costs the same whether the view
  /// is showing two seconds or half an hour.
  void _paintWaveform(Canvas canvas, Clip clip, Track track, MediaAsset asset,
      RRect clipRect, double clipLeft, double clipRight, double viewWidth) {
    final waveforms = this.waveforms;
    if (waveforms == null || !asset.probe.hasAudio) return;
    // A clip on a picture lane whose sound was detached is silent here and
    // drawn on the audio lane the sound went to; `enabled` covers the rest.
    if (!clip.enabled) return;

    waveforms.request(asset);
    final peaks = waveforms.peaksOf(asset.id);
    if (peaks == null) return;

    // Only the part on screen. A ten-minute clip scrolled mostly out of view
    // costs what its visible sliver costs, which is what keeps this flat in
    // clip length as well as in clip count.
    final left = math.max(clipLeft, TimelineGeometry.headerWidth);
    final right = math.min(clipRight, viewWidth);
    final columns = (right - left).floor();
    if (columns < 2) return;

    final band = TimelineGeometry.audioBand(clipRect.outerRect,
        wholeClip: track.kind == TrackKind.audio);
    if (band.height < 4) return;

    final ticksPerPixel = 1 / controller.geometry.pxPerTick;
    final into = (left - clipLeft) * ticksPerPixel;

    // Peaks belong to the *file*, so a retimed clip reads more or less of them
    // across the same pixels: at 2x a column covers two ticks of source for
    // every one of timeline, and the envelope drawn on the clip is the shape
    // it will play at.
    final rate = clip.speed.rate;

    if (_envelope.length < columns * 2) _envelope = Float32List(columns * 2);
    peaks.envelopeInto(
      _envelope,
      from: Tick((clip.sourceIn.raw + into * rate).round()),
      ticksPerPixel: ticksPerPixel * rate,
      pixels: columns,
    );

    if (_columns.length < columns * 4) _columns = Float32List(columns * 4);
    final centre = band.center.dy;
    final half = band.height / 2;
    final last = clip.duration.raw - 1;

    for (var i = 0; i < columns; i++) {
      final offset = (into + i * ticksPerPixel).round();
      final gain = clip.gainAt(Tick(offset > last ? last : offset));
      // Clamped after the gain rather than before it: a clip boosted past full
      // scale draws as a block against the rails, which is what it will sound
      // like.
      final low = (_envelope[i * 2] * gain).clamp(-1.0, 1.0);
      final high = (_envelope[i * 2 + 1] * gain).clamp(-1.0, 1.0);

      var upper = centre - high * half;
      var lower = centre - low * half;
      // Silence is a line through the middle, not a gap. A lane that went
      // blank wherever a recording went quiet would read as missing media,
      // and a muted clip — every column of which lands here — would look like
      // no clip at all.
      if (lower - upper < 1) {
        upper = centre - 0.5;
        lower = centre + 0.5;
      }
      final x = left + i + 0.5;
      _columns[i * 4] = x;
      _columns[i * 4 + 1] = upper;
      _columns[i * 4 + 2] = x;
      _columns[i * 4 + 3] = lower;
    }

    canvas.save();
    // The rounded rect, not its bounds: a column at the very edge of a clip
    // would otherwise paint the half pixel outside the corner.
    canvas.clipRRect(clipRect);
    canvas.drawRawPoints(
      ui.PointMode.lines,
      Float32List.sublistView(_columns, 0, columns * 4),
      Paint()
        ..color = VdColors.waveform.withValues(alpha: 0.55)
        ..strokeWidth = 1,
    );
    canvas.restore();
  }

  /// The clip's volume line, over its waveform.
  ///
  /// Piecewise linear, so it is drawn as the segments it actually is rather
  /// than sampled per column: the curve has a handful of points and a polyline
  /// through them is exact, where a per-pixel evaluation would be an
  /// approximation that costs more.
  ///
  /// The two ends are anchors rather than points — the curve is held flat
  /// outside the outermost point — and they get no handle, because there is
  /// nothing there to grab.
  void _paintVolumeLine(Canvas canvas, Clip clip, Track track, RRect clipRect) {
    if (!controller.showsVolumeLine(clip, track)) return;
    final line = controller.volumeLine(clip, track);
    if (line.length < 2) return;

    final path = Path()..moveTo(line.first.at.dx, line.first.at.dy);
    for (var i = 1; i < line.length; i++) {
      path.lineTo(line[i].at.dx, line[i].at.dy);
    }

    canvas.save();
    canvas.clipRRect(clipRect);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = VdColors.automation.withValues(alpha: 0.95),
    );

    final fill = Paint()..color = VdColors.automation;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = VdColors.rail;
    for (final handle in line) {
      if (handle.index == null) continue;
      canvas.drawCircle(handle.at, 3.5, fill);
      canvas.drawCircle(handle.at, 3.5, ring);
    }
    canvas.restore();
  }

  void _paintHandles(
      Canvas canvas, RRect clipRect, double x0, double x1, double top) {
    final paint = Paint()..color = VdColors.text.withValues(alpha: 0.9);
    const handle = TimelineController.handleWidthPx;
    const height = TimelineGeometry.trackHeight - 6;

    canvas.save();
    canvas.clipRRect(clipRect);
    for (final left in [x0, x1 - handle]) {
      canvas.drawRect(Rect.fromLTWH(left, top + 3, handle, height), paint);
      // Two grip lines, so a handle reads as something to grab rather than as
      // a white edge on the clip.
      final grip = Paint()
        ..color = VdColors.rail
        ..strokeWidth = 1;
      for (final offset in [handle / 2 - 1.5, handle / 2 + 1.5]) {
        canvas.drawLine(
          Offset(left + offset, top + height / 2 - 4),
          Offset(left + offset, top + height / 2 + 10),
          grip,
        );
      }
    }
    canvas.restore();
  }

  /// The edge a drag has snapped to. Amber rather than red, so it is never
  /// mistaken for the playhead it is sometimes sitting exactly on top of.
  void _paintSnapGuide(Canvas canvas, Size size) {
    final guide = controller.snapGuide;
    if (guide == null || !controller.isEditing) return;
    final x = controller.geometry.xOfTick(guide);
    if (x < TimelineGeometry.headerWidth || x > size.width) return;

    canvas.drawLine(
      Offset(x, TimelineGeometry.rulerHeight),
      Offset(x, size.height),
      Paint()
        ..color = VdColors.warn
        ..strokeWidth = 1.5,
    );
  }

  String _clipDetail(Clip clip, MediaAsset? asset) {
    final length = timecode(clip.duration.raw, controller.frameRate);
    final caption = clip.text;
    if (caption != null) {
      final face = caption.font.isEmpty ? 'system' : caption.font;
      return '$length · $face';
    }
    // Before the size, and deliberately: this line is clipped from the right
    // on a busy lane, and a retimed clip that looks exactly like every other
    // one is the surprise worth spending the first characters on.
    final rate = clip.speed.isRetimed ? ' · ${clip.speed.label}' : '';
    if (asset == null || !asset.probe.hasVideo) return '$length$rate';
    return '$length$rate · '
        '${asset.probe.displayWidth}×${asset.probe.displayHeight}';
  }

  void _paintHeaders(Canvas canvas, Size size) {
    final geometry = controller.geometry;
    canvas.drawRect(
      Rect.fromLTWH(0, 0, TimelineGeometry.headerWidth, size.height),
      Paint()..color = VdColors.panel,
    );

    final lanes = controller.lanes;
    for (var i = 0; i < lanes.length; i++) {
      final track = lanes[i];
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
