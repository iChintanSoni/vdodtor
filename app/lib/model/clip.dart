import 'package:flutter/foundation.dart';

import 'media.dart';
import 'time.dart';

/// What fills the frame when a clip's shape does not match the project's.
enum ClipFit {
  /// The whole picture, with the space around it filled by a blurred,
  /// enlarged copy of itself. The default, because black bars make a clip
  /// look like a mistake and this makes it look deliberate.
  blurFill,

  /// The whole picture, on black.
  contain,

  /// Fills the frame; the edges that do not fit are cropped away.
  cover,

  /// Fills the frame by distorting the picture. Rarely what anyone wants,
  /// and never a default.
  stretch,
}

/// Where a clip sits inside the frame, and how much of it shows.
///
/// Everything here is relative rather than absolute: offsets are fractions of
/// the output, scale is a multiplier on whatever the fit produced, crop is a
/// fraction of the source. A project made at 1080p and later exported at 4K
/// has to look the same, and it only can if nothing in here is measured in
/// pixels.
///
/// Applied about the clip's own centre, in this order: crop, fit, scale,
/// rotation, offset. Crop first because cropping changes the aspect ratio, and
/// a fit computed before it would letterbox the part being thrown away.
@immutable
final class ClipTransform {
  const ClipTransform({
    this.fit = ClipFit.blurFill,
    this.offsetX = 0,
    this.offsetY = 0,
    this.scale = 1,
    this.rotationDegrees = 0,
    this.cropLeft = 0,
    this.cropTop = 0,
    this.cropRight = 0,
    this.cropBottom = 0,
    this.opacity = 1,
    this.flipHorizontal = false,
    this.flipVertical = false,
  });

  /// A clip that has not been touched. The default for every clip, and the
  /// value serialisation leaves out of the file entirely.
  static const identity = ClipTransform();

  /// How the picture fills a frame it does not match.
  final ClipFit fit;

  /// Offset from centre, as a fraction of the output's width and height.
  final double offsetX;
  final double offsetY;

  /// Multiplier on the fitted size. 1 is "as the fit mode left it".
  final double scale;

  /// Extra clockwise rotation, on top of the source's own orientation.
  final double rotationDegrees;

  /// How much of each edge is cropped away, as a fraction of the display-
  /// oriented source. Insets rather than a rectangle because that is how the
  /// gesture works — you drag an edge in — and because two opposite insets
  /// cannot disagree about a width.
  final double cropLeft;
  final double cropTop;
  final double cropRight;
  final double cropBottom;

  /// 0..1.
  final double opacity;

  final bool flipHorizontal;
  final bool flipVertical;

  double get cropWidth => (1 - cropLeft - cropRight).clamp(0.01, 1.0);
  double get cropHeight => (1 - cropTop - cropBottom).clamp(0.01, 1.0);

  bool get isIdentity => this == identity;

  ClipTransform copyWith({
    ClipFit? fit,
    double? offsetX,
    double? offsetY,
    double? scale,
    double? rotationDegrees,
    double? cropLeft,
    double? cropTop,
    double? cropRight,
    double? cropBottom,
    double? opacity,
    bool? flipHorizontal,
    bool? flipVertical,
  }) =>
      ClipTransform(
        fit: fit ?? this.fit,
        offsetX: offsetX ?? this.offsetX,
        offsetY: offsetY ?? this.offsetY,
        scale: scale ?? this.scale,
        rotationDegrees: rotationDegrees ?? this.rotationDegrees,
        cropLeft: cropLeft ?? this.cropLeft,
        cropTop: cropTop ?? this.cropTop,
        cropRight: cropRight ?? this.cropRight,
        cropBottom: cropBottom ?? this.cropBottom,
        opacity: opacity ?? this.opacity,
        flipHorizontal: flipHorizontal ?? this.flipHorizontal,
        flipVertical: flipVertical ?? this.flipVertical,
      );

  @override
  bool operator ==(Object other) =>
      other is ClipTransform &&
      other.fit == fit &&
      other.offsetX == offsetX &&
      other.offsetY == offsetY &&
      other.scale == scale &&
      other.rotationDegrees == rotationDegrees &&
      other.cropLeft == cropLeft &&
      other.cropTop == cropTop &&
      other.cropRight == cropRight &&
      other.cropBottom == cropBottom &&
      other.opacity == opacity &&
      other.flipHorizontal == flipHorizontal &&
      other.flipVertical == flipVertical;

  @override
  int get hashCode => Object.hash(fit, offsetX, offsetY, scale, rotationDegrees,
      cropLeft, cropTop, cropRight, cropBottom, opacity, flipHorizontal,
      flipVertical);

  @override
  String toString() => isIdentity
      ? 'ClipTransform.identity'
      : 'ClipTransform(offset $offsetX,$offsetY scale $scale '
          'rot $rotationDegrees opacity $opacity)';
}

/// One point on a clip's volume line.
///
/// [sourceTime] is in the *source's* own time — the coordinate [Clip.sourceIn]
/// is measured in — and not an offset from the head of the clip. That is what
/// keeps a duck on the word it was drawn for: trimming the head, splitting the
/// clip or copying it elsewhere all move the window over the file, and
/// automation anchored to the window would slide off the sound underneath it.
///
/// It also means a point can sit outside the clip that carries it. That is not
/// junk to be swept up: trimming in and back out has to bring the automation
/// back, or a trim would be a destructive edit to something the user never
/// touched.
@immutable
final class VolumePoint {
  const VolumePoint(this.sourceTime, this.value);

  final Tick sourceTime;

  /// Linear gain, on the same scale and with the same cap as
  /// [ClipAudio.volume]. A multiplier on it rather than a replacement for it,
  /// so the fader stays a trim over the whole curve.
  final double value;

  VolumePoint copyWith({Tick? sourceTime, double? value}) =>
      VolumePoint(sourceTime ?? this.sourceTime, value ?? this.value);

  @override
  bool operator ==(Object other) =>
      other is VolumePoint &&
      other.sourceTime == sourceTime &&
      other.value == value;

  @override
  int get hashCode => Object.hash(sourceTime.raw, value);

  @override
  String toString() => 'VolumePoint(${sourceTime.raw}, $value)';
}

/// How loud a clip is, and how it gets there.
///
/// The video half of a clip is [ClipTransform]; this is the other half. Both
/// hang off every clip regardless of what the clip actually carries, because a
/// clip does not know whether its source has a picture or a sound until the
/// media is probed, and the document must be describable without opening a
/// file.
///
/// [volume] is a linear multiplier, not decibels. Decibels are the right thing
/// to *show* — the ear is logarithmic and a fader marked in dB is the one
/// people can use — but the wrong thing to store: 0 is a legitimate volume and
/// has no logarithm, so a dB document would need a magic value for silence.
/// The conversion belongs at the fader, not in the file.
@immutable
final class ClipAudio {
  const ClipAudio({
    this.volume = 1,
    this.fadeIn = Tick.zero,
    this.fadeOut = Tick.zero,
    this.muted = false,
    this.points = const [],
  });

  /// A clip nobody has touched: full volume, no fades, audible. The default
  /// for every clip, and the value serialisation leaves out of the file.
  static const unity = ClipAudio();

  /// Linear gain. 1 is the source as recorded; 0 is silence. Above 1 is a
  /// boost, capped at [maxVolume] — a fader that goes to infinity is a fader
  /// that turns everything into clipping.
  final double volume;

  /// Ramp from silence over this long at the head, and to silence over this
  /// long at the tail. Ticks, like every other length in the document.
  final Tick fadeIn;
  final Tick fadeOut;

  /// Silent, without forgetting how loud it was. That distinction is the whole
  /// point of having both this and [volume]: unmuting has to give the level
  /// back, so mute cannot be spelled `volume = 0`.
  final bool muted;

  /// The volume line: a curve of gain over the source, sorted by
  /// [VolumePoint.sourceTime] and empty for almost every clip.
  ///
  /// This is where ducking lives. [volume] sets the level of the whole clip
  /// and these bend it over time; the two multiply, so pulling the fader after
  /// drawing a duck moves the whole curve rather than flattening it.
  ///
  /// Sortedness is an invariant every mutator here maintains and the decoder
  /// restores. Nothing enforces it on a hand-built literal, which is what the
  /// assert in [automationAt] is for.
  final List<VolumePoint> points;

  /// +6 dB. Enough to rescue a quiet recording, short of enough to destroy
  /// one by accident.
  static const double maxVolume = 2;

  bool get isUnity => this == unity;

  bool get hasFade => fadeIn.raw > 0 || fadeOut.raw > 0;

  bool get hasAutomation => points.isNotEmpty;

  /// What [volume] actually amounts to once mute is taken into account.
  double get effectiveVolume => muted ? 0 : volume.clamp(0.0, maxVolume);

  /// The multiplier at [offset] ticks into a clip [duration] long: volume,
  /// mute, the fades and the volume line, all together.
  ///
  /// [sourceIn] is the clip's own, because [points] are measured in the
  /// source's time and this is given an offset into the clip. A caller that
  /// leaves it out gets the fades and the fader and no automation, which is
  /// the right answer for a clip that has none.
  ///
  /// The engine computes the same two envelopes in C — `vd_audio_fade_gain`
  /// and `vd_audio_automation_gain` in `engine/src/vd_audio_renderer.c` — and
  /// each pair is tested against the same table. Change one and you must
  /// change the other.
  ///
  /// The ramps are linear in amplitude. Linear is not the most flattering
  /// curve for a long fade, but it is the one where the handle position means
  /// what it looks like it means, and a shaped curve is an option to add later
  /// rather than a default to guess at now.
  double gainAt(Tick offset, Tick duration, {Tick sourceIn = Tick.zero}) {
    final shape = fadeShapeAt(offset, duration, fadeIn, fadeOut);
    if (shape == 0 || points.isEmpty) return effectiveVolume * shape;
    return effectiveVolume *
        shape *
        automationAt(points, Tick(sourceIn.raw + offset.raw));
  }

  /// The volume line alone, at a time in the *source*. 1 where there is no
  /// line at all.
  ///
  /// Held flat outside the points rather than ramped to unity: a curve that
  /// slid back to full volume before the first point would move audio the user
  /// never touched, and the first thing anyone does is drop one point and
  /// expect everything before it to stay put.
  ///
  /// Static, because the engine needs exactly this function and nothing
  /// around it.
  static double automationAt(List<VolumePoint> points, Tick sourceTime) {
    assert(_isSorted(points), 'volume points are out of order: $points');
    if (points.isEmpty) return 1;
    if (sourceTime <= points.first.sourceTime) return points.first.value;
    final last = points.last;
    if (sourceTime >= last.sourceTime) return last.value;

    for (var i = points.length - 1; i >= 0; i--) {
      final a = points[i];
      if (a.sourceTime > sourceTime) continue;
      final b = points[i + 1];
      final span = b.sourceTime.raw - a.sourceTime.raw;
      // Two points at the same tick are a step, not a division by zero: the
      // later one wins, so a level can change instantly where that is what
      // was drawn.
      if (span <= 0) return b.value;
      final t = (sourceTime.raw - a.sourceTime.raw) / span;
      return a.value + (b.value - a.value) * t;
    }
    return points.first.value;
  }

  static bool _isSorted(List<VolumePoint> points) {
    for (var i = 1; i < points.length; i++) {
      if (points[i].sourceTime < points[i - 1].sourceTime) return false;
    }
    return true;
  }

  /// The line with a point set at [sourceTime]. Replaces the point already
  /// there, so ⌥-clicking the same spot twice does not stack two.
  ClipAudio withPoint(Tick sourceTime, double value) {
    final clamped = value.clamp(0.0, maxVolume);
    final next = <VolumePoint>[];
    var placed = false;
    for (final p in points) {
      if (!placed && p.sourceTime == sourceTime) {
        next.add(VolumePoint(sourceTime, clamped));
        placed = true;
        continue;
      }
      if (!placed && p.sourceTime > sourceTime) {
        next.add(VolumePoint(sourceTime, clamped));
        placed = true;
      }
      next.add(p);
    }
    if (!placed) next.add(VolumePoint(sourceTime, clamped));
    return copyWith(points: next);
  }

  /// The line without the point at [index]. Out of range is a no-op rather
  /// than a throw: an index is a fact about a document that undo can change
  /// underneath the pointer holding it.
  ClipAudio withoutPoint(int index) {
    if (index < 0 || index >= points.length) return this;
    return copyWith(points: [
      for (var i = 0; i < points.length; i++)
        if (i != index) points[i],
    ]);
  }

  /// Moves the point at [index], clamped between its neighbours so a drag
  /// cannot reorder the list under itself. Landing exactly on a neighbour is
  /// allowed, because that is how a step gets drawn.
  ClipAudio movePoint(int index, {Tick? sourceTime, double? value}) {
    if (index < 0 || index >= points.length) return this;
    final current = points[index];
    var time = sourceTime ?? current.sourceTime;
    if (index > 0 && time < points[index - 1].sourceTime) {
      time = points[index - 1].sourceTime;
    }
    if (index + 1 < points.length && time > points[index + 1].sourceTime) {
      time = points[index + 1].sourceTime;
    }
    final next = VolumePoint(
        time, (value ?? current.value).clamp(0.0, maxVolume));
    if (next == current) return this;
    return copyWith(points: [
      for (var i = 0; i < points.length; i++)
        if (i == index) next else points[i],
    ]);
  }

  /// The same levels with the line taken away.
  ClipAudio get withoutAutomation =>
      points.isEmpty ? this : copyWith(points: const []);

  /// The fade envelope alone, without volume or mute. Static because the
  /// engine needs exactly this function and nothing around it.
  static double fadeShapeAt(
      Tick offset, Tick duration, Tick fadeIn, Tick fadeOut) {
    if (duration.raw <= 0) return 0;
    if (offset.raw < 0 || offset.raw >= duration.raw) return 0;

    var gain = 1.0;
    if (fadeIn.raw > 0 && offset.raw < fadeIn.raw) {
      gain *= offset.raw / fadeIn.raw;
    }
    // Measured from the far edge, so the last tick of a clip is as quiet as
    // the first — a fade out that reached zero one tick early would leave an
    // audible click exactly where the fade existed to prevent one.
    final remaining = duration.raw - offset.raw;
    if (fadeOut.raw > 0 && remaining < fadeOut.raw) {
      gain *= remaining / fadeOut.raw;
    }
    return gain;
  }

  /// The same fades, shortened so they fit inside a clip [duration] long.
  ///
  /// Two fades that overlap are not wrong so much as unaskable-for: the
  /// envelope multiplies them and the result dips in the middle, which is
  /// nobody's intent. Trimming a clip shorter than its own fades is the
  /// ordinary way to arrive there, so the clamp lives here rather than in the
  /// setter — every path that shortens a clip goes through it.
  ClipAudio clampedTo(Tick duration) {
    if (duration.raw <= 0) {
      return copyWith(fadeIn: Tick.zero, fadeOut: Tick.zero);
    }
    var inTicks = fadeIn.raw < 0 ? 0 : fadeIn.raw;
    var outTicks = fadeOut.raw < 0 ? 0 : fadeOut.raw;
    final total = inTicks + outTicks;
    if (total > duration.raw) {
      // Shared in the proportion asked for, taken from the lengths as
      // requested. Clamping each to the whole clip first and proportioning
      // afterwards would turn a 1:3 request into 3:4 — moving a fade the user
      // never touched, because the other one was too long.
      inTicks = (inTicks * duration.raw) ~/ total;
      outTicks = duration.raw - inTicks;
    }
    if (inTicks == fadeIn.raw && outTicks == fadeOut.raw) return this;
    return copyWith(fadeIn: Tick(inTicks), fadeOut: Tick(outTicks));
  }

  ClipAudio copyWith({
    double? volume,
    Tick? fadeIn,
    Tick? fadeOut,
    bool? muted,
    List<VolumePoint>? points,
  }) =>
      ClipAudio(
        volume: volume ?? this.volume,
        fadeIn: fadeIn ?? this.fadeIn,
        fadeOut: fadeOut ?? this.fadeOut,
        muted: muted ?? this.muted,
        points: points ?? this.points,
      );

  @override
  bool operator ==(Object other) =>
      other is ClipAudio &&
      other.volume == volume &&
      other.fadeIn == fadeIn &&
      other.fadeOut == fadeOut &&
      other.muted == muted &&
      listEquals(other.points, points);

  @override
  int get hashCode => Object.hash(
      volume, fadeIn.raw, fadeOut.raw, muted, Object.hashAll(points));

  @override
  String toString() => isUnity
      ? 'ClipAudio.unity'
      : 'ClipAudio(volume $volume${muted ? ' muted' : ''} '
          'fade ${fadeIn.raw}/${fadeOut.raw}'
          '${points.isEmpty ? '' : ' ${points.length} points'})';
}

/// Where each line sits inside a caption.
///
/// The block is laid out in a box as wide as wrapping allows, so this moves a
/// single line as well as a ragged one. A box that hugged the words would
/// leave "align left" doing nothing to one line, which is the case it is asked
/// for most.
enum TextAlignment { left, center, right }

/// A caption: what it says and how it looks.
///
/// The third thing that can hang off a clip, beside [ClipTransform] and
/// [ClipAudio] — but unlike those two it is *nullable*, and its presence is
/// what makes a clip a caption rather than a window onto a file. A clip has a
/// [Clip.mediaId] or a [Clip.text], never both.
///
/// **Nothing here is measured in pixels.** Sizes, offsets, padding and spacing
/// are fractions — of the output height, or of the font size they hang off —
/// for the same reason [ClipTransform] has no pixels in it: a project cut at
/// 1080p and exported at 4K has to put the same words in the same place at the
/// same size, and a point size stored in the file would be right at exactly
/// one resolution.
///
/// Colours are 0xAARRGGBB. Alpha 0 is how the two optional parts are switched
/// off — a shadow colour with no alpha casts no shadow, a box colour with no
/// alpha draws no box — which is one rule rather than two booleans that could
/// disagree with the colours beside them. It also means turning a shadow back
/// on does not mean guessing what offset and blur it had.
@immutable
final class ClipText {
  const ClipText({
    this.text = '',
    this.font = '',
    this.size = 0.08,
    this.color = 0xFFFFFFFF,
    this.strokeColor = 0xFF000000,
    this.strokeWidth = 0,
    this.shadowColor = 0x00000000,
    this.shadowOffsetX = 0,
    this.shadowOffsetY = 0.04,
    this.shadowBlur = 0.06,
    this.boxColor = 0x00000000,
    this.boxPadding = 0.25,
    this.boxRadius = 0.15,
    this.letterSpacing = 0,
    this.lineSpacing = 1,
    this.maxWidth = 0.9,
    this.alignment = TextAlignment.center,
  });

  /// What a caption looks like before anybody styles it: white, unstroked,
  /// unboxed, centred, at a readable size. The value serialisation leaves out
  /// of the file, field by field.
  static const plain = ClipText();

  /// What the words are. Empty draws nothing at all rather than a placeholder:
  /// a caption someone has cleared must not black out the picture under it.
  final String text;

  /// Family name, from the engine's catalogue. Empty means the system's own
  /// face, which is what a project made with a font pack falls back to on a
  /// machine without it.
  final String font;

  /// Cap height as a fraction of the output height.
  final double size;

  final int color;

  /// An outline, drawn under the fill so only its outer half shows. Width is a
  /// fraction of the font size.
  final int strokeColor;
  final double strokeWidth;

  /// Cast by the ink — fill and outline together — onto whatever is behind it.
  /// Offsets and blur are fractions of the font size; +y is down.
  final int shadowColor;
  final double shadowOffsetX;
  final double shadowOffsetY;
  final double shadowBlur;

  /// A rounded rectangle behind the block, hugging the words rather than
  /// filling the layout box. Padding and radius are fractions of the font
  /// size, so the box keeps its proportions as the type grows.
  final int boxColor;
  final double boxPadding;
  final double boxRadius;

  /// Extra space between glyphs, as a fraction of the font size. Negative
  /// tightens.
  final double letterSpacing;

  /// Multiple of the font's own line height. Applied between lines rather than
  /// above every one of them, so leading grows the block about its own centre
  /// instead of sinking it down the frame.
  final double lineSpacing;

  /// How much of the frame's width the block may fill before it wraps.
  final double maxWidth;

  final TextAlignment alignment;

  // The ends of every slider in the inspector, so the control and the document
  // cannot disagree about what is allowed.
  static const double minSize = 0.02;
  static const double maxSize = 0.4;
  static const double maxStrokeWidth = 0.3;
  static const double maxShadowOffset = 0.5;
  static const double maxShadowBlur = 0.5;
  static const double maxBoxPadding = 1.5;
  static const double maxBoxRadius = 1.5;
  static const double minLetterSpacing = -0.2;
  static const double maxLetterSpacing = 0.5;
  static const double minLineSpacing = 0.5;
  static const double maxLineSpacing = 3;
  static const double minMaxWidth = 0.2;

  bool get hasStroke => strokeWidth > 0 && _visible(strokeColor);
  bool get hasShadow => _visible(shadowColor);
  bool get hasBox => _visible(boxColor);

  /// A one-line summary for the timeline and the bin. Blank captions still
  /// need something to be called, and "Text" is what the button that made it
  /// was called.
  String get label {
    final first = text.split('\n').first.trim();
    return first.isEmpty ? 'Text' : first;
  }

  static bool _visible(int argb) => (argb >> 24) & 0xFF != 0;

  /// Every number pulled inside the range the inspector offers. Applied on the
  /// way into the document rather than on the way out of it, so a file written
  /// by a future version with a wider range opens as something this one can
  /// still edit.
  ClipText clamped() => ClipText(
        text: text,
        font: font,
        size: size.clamp(minSize, maxSize),
        color: color,
        strokeColor: strokeColor,
        strokeWidth: strokeWidth.clamp(0.0, maxStrokeWidth),
        shadowColor: shadowColor,
        shadowOffsetX:
            shadowOffsetX.clamp(-maxShadowOffset, maxShadowOffset),
        shadowOffsetY:
            shadowOffsetY.clamp(-maxShadowOffset, maxShadowOffset),
        shadowBlur: shadowBlur.clamp(0.0, maxShadowBlur),
        boxColor: boxColor,
        boxPadding: boxPadding.clamp(0.0, maxBoxPadding),
        boxRadius: boxRadius.clamp(0.0, maxBoxRadius),
        letterSpacing:
            letterSpacing.clamp(minLetterSpacing, maxLetterSpacing),
        lineSpacing: lineSpacing.clamp(minLineSpacing, maxLineSpacing),
        maxWidth: maxWidth.clamp(minMaxWidth, 1.0),
        alignment: alignment,
      );

  ClipText copyWith({
    String? text,
    String? font,
    double? size,
    int? color,
    int? strokeColor,
    double? strokeWidth,
    int? shadowColor,
    double? shadowOffsetX,
    double? shadowOffsetY,
    double? shadowBlur,
    int? boxColor,
    double? boxPadding,
    double? boxRadius,
    double? letterSpacing,
    double? lineSpacing,
    double? maxWidth,
    TextAlignment? alignment,
  }) =>
      ClipText(
        text: text ?? this.text,
        font: font ?? this.font,
        size: size ?? this.size,
        color: color ?? this.color,
        strokeColor: strokeColor ?? this.strokeColor,
        strokeWidth: strokeWidth ?? this.strokeWidth,
        shadowColor: shadowColor ?? this.shadowColor,
        shadowOffsetX: shadowOffsetX ?? this.shadowOffsetX,
        shadowOffsetY: shadowOffsetY ?? this.shadowOffsetY,
        shadowBlur: shadowBlur ?? this.shadowBlur,
        boxColor: boxColor ?? this.boxColor,
        boxPadding: boxPadding ?? this.boxPadding,
        boxRadius: boxRadius ?? this.boxRadius,
        letterSpacing: letterSpacing ?? this.letterSpacing,
        lineSpacing: lineSpacing ?? this.lineSpacing,
        maxWidth: maxWidth ?? this.maxWidth,
        alignment: alignment ?? this.alignment,
      );

  @override
  bool operator ==(Object other) =>
      other is ClipText &&
      other.text == text &&
      other.font == font &&
      other.size == size &&
      other.color == color &&
      other.strokeColor == strokeColor &&
      other.strokeWidth == strokeWidth &&
      other.shadowColor == shadowColor &&
      other.shadowOffsetX == shadowOffsetX &&
      other.shadowOffsetY == shadowOffsetY &&
      other.shadowBlur == shadowBlur &&
      other.boxColor == boxColor &&
      other.boxPadding == boxPadding &&
      other.boxRadius == boxRadius &&
      other.letterSpacing == letterSpacing &&
      other.lineSpacing == lineSpacing &&
      other.maxWidth == maxWidth &&
      other.alignment == alignment;

  @override
  int get hashCode => Object.hash(
        text,
        font,
        size,
        color,
        strokeColor,
        strokeWidth,
        shadowColor,
        Object.hash(shadowOffsetX, shadowOffsetY, shadowBlur),
        boxColor,
        boxPadding,
        boxRadius,
        letterSpacing,
        lineSpacing,
        maxWidth,
        alignment,
      );

  @override
  String toString() => 'ClipText("$label", ${font.isEmpty ? 'system' : font} '
      '${(size * 100).toStringAsFixed(1)}%)';
}

/// What a shape is.
///
/// Order matches `VdShapeKind` in `engine/include/vdodtor/vd_shape.h`; the
/// index crosses the FFI boundary as an integer, so these may be appended to
/// and never reordered.
///
/// **Four kinds, not six.** A rounded rectangle is a [rectangle] with a
/// [ClipShape.corner] and a circle is an [ellipse] with equal sides, because
/// both are one slider away from the entry beside them — and a picker with two
/// rows that draw the same thing makes the reader look for a difference that
/// is not there.
enum ShapeKind {
  rectangle('Rectangle'),
  ellipse('Ellipse'),
  line('Line'),
  arrow('Arrow');

  const ShapeKind(this.label);
  final String label;

  /// True for the two kinds that are all outline. They have no interior, so
  /// [ClipShape.fillColor] says nothing about them and the stroke *is* the
  /// shape.
  bool get isStroke => this == ShapeKind.line || this == ShapeKind.arrow;
}

/// A rectangle, an ellipse, a line or an arrow: what it looks like.
///
/// The second thing a clip can draw instead of showing a file, and it works on
/// exactly the terms [ClipText] does — nullable, exclusive with [Clip.mediaId],
/// rasterised in the engine and handed to the compositor as an ordinary layer,
/// so the transform, the opacity and the in/out animation all reach it without
/// anything here knowing they do.
///
/// **Every length is a fraction of the output height.** Not of the width, and
/// not one of each: a shape measured half against the width and half against
/// the height changes shape when the project's aspect does, and then a circle
/// is only round at 16:9. One unit for all four numbers also makes them
/// comparable by eye.
///
/// That is one rule where [ClipText] has two — a size against the output, and
/// everything else against the font size. A caption has a single size to hang
/// the rest off; a shape has two, so there is no single one to choose and
/// picking either would make the other axis surprising.
///
/// Colours are 0xAARRGGBB and alpha 0 is off, the same rule captions follow: a
/// fill with no alpha draws no fill, a stroke with none draws no outline, a
/// shadow colour with none casts no shadow.
@immutable
final class ClipShape {
  const ClipShape({
    this.kind = ShapeKind.rectangle,
    this.width = 0.5,
    this.height = 0.28,
    this.corner = 0,
    this.fillColor = 0xFFFFFFFF,
    this.strokeColor = 0xFF000000,
    this.strokeWidth = 0,
    this.shadowColor = 0x00000000,
    this.shadowOffsetX = 0,
    this.shadowOffsetY = 0,
    this.shadowBlur = 0,
    this.headSize = 0.25,
  });

  /// A shape of [kind] that somebody would recognise as one the moment it
  /// appears.
  ///
  /// The defaults differ by kind and have to. A line's colour lives in
  /// [strokeColor] and its thickness in [strokeWidth], so the plain
  /// constructor's unstroked rectangle would draw *nothing* as a line — and a
  /// button that adds an invisible clip is a button that looks broken. An
  /// ellipse starts square, so the first thing it is is a circle.
  factory ClipShape.of(ShapeKind kind) => switch (kind) {
        ShapeKind.rectangle => const ClipShape(),
        ShapeKind.ellipse =>
          const ClipShape(kind: ShapeKind.ellipse, width: 0.4, height: 0.4),
        ShapeKind.line => const ClipShape(
            kind: ShapeKind.line,
            width: 0.7,
            strokeColor: 0xFFFFFFFF,
            strokeWidth: defaultStrokeWidth,
          ),
        ShapeKind.arrow => const ClipShape(
            kind: ShapeKind.arrow,
            width: 0.7,
            strokeColor: 0xFFFFFFFF,
            strokeWidth: defaultStrokeWidth,
          ),
      };

  /// What a shape looks like before anybody styles it — the value the
  /// serialisation compares against nothing, because a shape is written out
  /// whole. Kept for the same reason [ClipText.plain] is: a test that wants
  /// "an ordinary one" should not have to list twelve fields.
  static const plain = ClipShape();

  final ShapeKind kind;

  /// The box the shape is drawn in, centred in the frame, as fractions of the
  /// output height. Equal values are a square — and so, for an ellipse, a
  /// circle — in a 16:9 project and in a 9:16 one.
  final double width;
  final double height;

  /// How round a rectangle's corners are: 0 square, 1 as round as the box
  /// allows, which is a pill on an oblong. A proportion rather than a length,
  /// so a rectangle keeps its corners when it is resized. Ignored by every
  /// other kind.
  final double corner;

  /// Ignored by the two [ShapeKind.isStroke] kinds, which have no interior.
  final int fillColor;

  /// Drawn over the fill, straddling the edge, which is what keeps a filled
  /// shape the size its box says it is. For a line or an arrow this *is* the
  /// shape.
  final int strokeColor;
  final double strokeWidth;

  /// Cast by the whole shape — fill and stroke as one silhouette — onto
  /// whatever is behind it. +y is down.
  final int shadowColor;
  final double shadowOffsetX;
  final double shadowOffsetY;
  final double shadowBlur;

  /// How much of an arrow is head, as a fraction of its length. A proportion
  /// for the same reason [corner] is one: a stretched arrow should still look
  /// like an arrow. Ignored by every other kind.
  final double headSize;

  /// Thick enough to see at 1080p and thin enough to read as a line.
  static const double defaultStrokeWidth = 0.012;

  // The ends of every slider in the inspector, so the control and the document
  // cannot disagree about what is allowed. Sizes go past 1 because a shape
  // used as a background wash has to cover a 16:9 frame, and 16/9 of the
  // height is 1.78 of it.
  static const double minSize = 0.01;
  static const double maxSize = 2.0;
  static const double maxStrokeWidth = 0.1;
  static const double maxShadowOffset = 0.2;
  static const double maxShadowBlur = 0.2;
  static const double minHeadSize = 0.05;
  static const double maxHeadSize = 1.0;

  bool get hasFill => !kind.isStroke && _visible(fillColor);
  bool get hasStroke => strokeWidth > 0 && _visible(strokeColor);
  bool get hasShadow => _visible(shadowColor);

  /// True when nothing about this shape would mark the frame. A shape someone
  /// has made invisible is still a clip on the timeline — the label has to
  /// come from the kind rather than from what is left of it.
  bool get isBlank => !hasFill && !hasStroke;

  /// A one-line summary for the timeline and the bin.
  String get label => kind.label;

  static bool _visible(int argb) => (argb >> 24) & 0xFF != 0;

  /// Every number pulled inside the range the inspector offers. Applied on the
  /// way into the document rather than on the way out, so a file written by a
  /// future version with a wider range opens as something this one can still
  /// edit.
  ClipShape clamped() => ClipShape(
        kind: kind,
        width: width.clamp(minSize, maxSize),
        height: height.clamp(minSize, maxSize),
        corner: corner.clamp(0.0, 1.0),
        fillColor: fillColor,
        strokeColor: strokeColor,
        strokeWidth: strokeWidth.clamp(0.0, maxStrokeWidth),
        shadowColor: shadowColor,
        shadowOffsetX: shadowOffsetX.clamp(-maxShadowOffset, maxShadowOffset),
        shadowOffsetY: shadowOffsetY.clamp(-maxShadowOffset, maxShadowOffset),
        shadowBlur: shadowBlur.clamp(0.0, maxShadowBlur),
        headSize: headSize.clamp(minHeadSize, maxHeadSize),
      );

  /// The same shape as another kind, with whatever that kind needs to still be
  /// visible.
  ///
  /// Not `copyWith(kind: …)`, because changing the kind is not only changing
  /// the kind. A filled rectangle turned into a line has its colour in the
  /// wrong field and no thickness at all, so it would vanish — and a picker
  /// whose third entry blanks the clip is a picker nobody presses twice. The
  /// colour moves across and the stroke is given a width, once, and only when
  /// there is nothing there already.
  ClipShape withKind(ShapeKind next) {
    if (next == kind) return this;
    if (!next.isStroke || hasStroke) return copyWith(kind: next);
    return copyWith(
      kind: next,
      strokeColor: _visible(strokeColor) ? strokeColor : fillColor,
      strokeWidth: strokeWidth > 0 ? strokeWidth : defaultStrokeWidth,
    );
  }

  ClipShape copyWith({
    ShapeKind? kind,
    double? width,
    double? height,
    double? corner,
    int? fillColor,
    int? strokeColor,
    double? strokeWidth,
    int? shadowColor,
    double? shadowOffsetX,
    double? shadowOffsetY,
    double? shadowBlur,
    double? headSize,
  }) =>
      ClipShape(
        kind: kind ?? this.kind,
        width: width ?? this.width,
        height: height ?? this.height,
        corner: corner ?? this.corner,
        fillColor: fillColor ?? this.fillColor,
        strokeColor: strokeColor ?? this.strokeColor,
        strokeWidth: strokeWidth ?? this.strokeWidth,
        shadowColor: shadowColor ?? this.shadowColor,
        shadowOffsetX: shadowOffsetX ?? this.shadowOffsetX,
        shadowOffsetY: shadowOffsetY ?? this.shadowOffsetY,
        shadowBlur: shadowBlur ?? this.shadowBlur,
        headSize: headSize ?? this.headSize,
      );

  @override
  bool operator ==(Object other) =>
      other is ClipShape &&
      other.kind == kind &&
      other.width == width &&
      other.height == height &&
      other.corner == corner &&
      other.fillColor == fillColor &&
      other.strokeColor == strokeColor &&
      other.strokeWidth == strokeWidth &&
      other.shadowColor == shadowColor &&
      other.shadowOffsetX == shadowOffsetX &&
      other.shadowOffsetY == shadowOffsetY &&
      other.shadowBlur == shadowBlur &&
      other.headSize == headSize;

  @override
  int get hashCode => Object.hash(
        kind,
        width,
        height,
        corner,
        fillColor,
        strokeColor,
        strokeWidth,
        shadowColor,
        Object.hash(shadowOffsetX, shadowOffsetY, shadowBlur),
        headSize,
      );

  @override
  String toString() => 'ClipShape(${kind.name} '
      '${(width * 100).toStringAsFixed(0)}x${(height * 100).toStringAsFixed(0)}%)';
}

/// How a clip arrives and how it leaves.
///
/// **A preset names the direction the clip travels, not the edge it comes
/// from.** [slideUp] moves upwards both times: on the way in it rises into
/// place from below, and on the way out it carries on and leaves through the
/// top. One rule for both halves, where "in from the left, out to the left"
/// would be two — and the second one nobody can predict.
///
/// Order matches `VdAnimPreset` in `engine/include/vdodtor/vd_anim.h`; the
/// index crosses the FFI boundary as an integer, so these may be appended to
/// and never reordered.
enum AnimationPreset {
  none('None'),

  /// Opacity alone. The one that suits anything.
  fade('Fade'),
  slideUp('Slide up'),
  slideDown('Slide down'),
  slideLeft('Slide left'),
  slideRight('Slide right'),

  /// Overshoots its resting size and settles back — the only preset that ever
  /// does, and what makes it read as a pop rather than a grow.
  pop('Pop'),

  /// Grows from small. A pop without the overshoot.
  zoom('Zoom'),

  /// A turn and a grow together.
  spin('Spin'),

  /// Reveals the text a character at a time, and does nothing at all to a clip
  /// that has none. It is in this list rather than a list of its own because
  /// it is chosen from the same menu, and a preset that quietly does nothing
  /// on a video clip beats a menu that changes shape with the selection.
  typewriter('Typewriter');

  const AnimationPreset(this.label);

  /// What the picker calls it.
  final String label;

  bool get isNone => this == AnimationPreset.none;
}

/// The entrance and the exit on one clip.
///
/// The fourth thing that can hang off a clip, beside [ClipTransform],
/// [ClipAudio] and [ClipText] — and the only one that is a function of *time*
/// rather than a set of values. Which is why nothing here evaluates it: the
/// engine does, once per layer per frame, because it is the thing that knows
/// what time it is. See `vd_anim.h`.
///
/// The result composes with [ClipTransform] rather than replacing it: offsets
/// add, scale multiplies, rotation adds, opacity multiplies. A caption parked
/// at the bottom of the frame that slides up has to slide up from below *its
/// own* position.
@immutable
final class ClipAnimation {
  const ClipAnimation({
    this.inPreset = AnimationPreset.none,
    this.inDuration = Tick.zero,
    this.outPreset = AnimationPreset.none,
    this.outDuration = Tick.zero,
  });

  /// A clip nobody has animated. The default for every clip, and the value
  /// serialisation leaves out of the file.
  static const still = ClipAnimation();

  final AnimationPreset inPreset;
  final Tick inDuration;
  final AnimationPreset outPreset;
  final Tick outDuration;

  /// How long an animation is when a preset is first chosen. Long enough to
  /// read as a movement, short enough not to delay the words.
  static const Tick defaultDuration = Tick(400 * 120000 ~/ 1000);

  /// The longest either half may be. Beyond about a second an entrance stops
  /// being an entrance and becomes the clip.
  static const Tick maxDuration = Tick(2 * 120000);

  bool get isStill => this == still;

  /// True when either half actually runs. A preset with no time to run in is
  /// not an animation, and neither is [AnimationPreset.none] with all the time
  /// in the world.
  bool get hasIn => !inPreset.isNone && inDuration.raw > 0;
  bool get hasOut => !outPreset.isNone && outDuration.raw > 0;
  bool get isAnimated => hasIn || hasOut;

  /// The same animations, shortened so both fit inside a clip [duration] long.
  ///
  /// The same problem the audio fades have and the same answer: two
  /// animations that overlap are not wrong so much as unaskable-for, and
  /// trimming a clip shorter than its own entrance is the ordinary way to
  /// arrive there. Shared in the proportion asked for, so a 1:3 request does
  /// not come back as 3:4.
  ClipAnimation clampedTo(Tick duration) {
    var inTicks = inDuration.raw < 0 ? 0 : inDuration.raw;
    var outTicks = outDuration.raw < 0 ? 0 : outDuration.raw;

    // The share of the clip first, then the absolute cap. The other order
    // turns a 1:3 request into something else: capping 1s and 3s at two
    // seconds gives 1s and 2s, and *that* proportioned into a two-second clip
    // is 2:1 — a ratio nobody asked for, arrived at by two clamps that were
    // each reasonable alone.
    if (duration.raw <= 0) {
      inTicks = 0;
      outTicks = 0;
    } else {
      final total = inTicks + outTicks;
      if (total > duration.raw) {
        inTicks = (inTicks * duration.raw) ~/ total;
        outTicks = duration.raw - inTicks;
      }
    }
    if (inTicks > maxDuration.raw) inTicks = maxDuration.raw;
    if (outTicks > maxDuration.raw) outTicks = maxDuration.raw;
    if (inTicks == inDuration.raw && outTicks == outDuration.raw) return this;
    return copyWith(inDuration: Tick(inTicks), outDuration: Tick(outTicks));
  }

  ClipAnimation copyWith({
    AnimationPreset? inPreset,
    Tick? inDuration,
    AnimationPreset? outPreset,
    Tick? outDuration,
  }) =>
      ClipAnimation(
        inPreset: inPreset ?? this.inPreset,
        inDuration: inDuration ?? this.inDuration,
        outPreset: outPreset ?? this.outPreset,
        outDuration: outDuration ?? this.outDuration,
      );

  /// Choosing a preset gives it a length to run in, because a preset with no
  /// duration does nothing and a picker whose entries do nothing is a picker
  /// nobody trusts. Choosing [AnimationPreset.none] takes the length away
  /// again, so the file does not carry a duration for an animation that is
  /// not there.
  ClipAnimation withInPreset(AnimationPreset preset) => copyWith(
        inPreset: preset,
        inDuration: preset.isNone
            ? Tick.zero
            : (inDuration.raw > 0 ? inDuration : defaultDuration),
      );

  ClipAnimation withOutPreset(AnimationPreset preset) => copyWith(
        outPreset: preset,
        outDuration: preset.isNone
            ? Tick.zero
            : (outDuration.raw > 0 ? outDuration : defaultDuration),
      );

  @override
  bool operator ==(Object other) =>
      other is ClipAnimation &&
      other.inPreset == inPreset &&
      other.inDuration == inDuration &&
      other.outPreset == outPreset &&
      other.outDuration == outDuration;

  @override
  int get hashCode =>
      Object.hash(inPreset, inDuration.raw, outPreset, outDuration.raw);

  @override
  String toString() => isStill
      ? 'ClipAnimation.still'
      : 'ClipAnimation(in ${inPreset.name} ${inDuration.raw}, '
          'out ${outPreset.name} ${outDuration.raw})';
}

/// How a clip joins the one before it on the same track.
///
/// Order matches `VdTransitionPreset` in
/// `engine/include/vdodtor/vd_transition.h`; the index crosses the FFI
/// boundary as an integer, so these may be appended to and never reordered.
///
/// One direction each. [wipe] wipes left to right and [slide] brings the new
/// clip in from the right, because a picker with four arrows on every entry is
/// a picker with twenty entries — and the enum may be appended to, so the other
/// directions can arrive as presets of their own the way [AnimationPreset]'s
/// slides did.
enum TransitionPreset {
  none('None'),

  /// The new clip fades up over the old one. The one that suits anything.
  dissolve('Dissolve'),

  /// Down to a colour and back out of it. Black and white are two presets
  /// rather than a preset and a colour well, because these two are the ones
  /// anybody asks for.
  fadeBlack('Fade to black'),
  fadeWhite('Fade to white'),

  /// The new clip slides in from the right over one that stays put.
  slide('Slide'),

  /// The same slide, with the old clip shoved out of frame ahead of it.
  push('Push'),

  /// A hard edge travelling left to right, the new clip behind it.
  wipe('Wipe');

  const TransitionPreset(this.label);
  final String label;
}

/// A transition at a clip's head: what happens at the cut above it.
///
/// **It belongs to the incoming clip and names only its own head.** A cut has
/// two sides and a transition is one decision, so recording it on both would
/// be two places to keep in step and one of them eventually wrong. The engine
/// finds the outgoing clip itself — the one on the same lane whose end is
/// exactly this clip's start.
///
/// **The transition straddles the cut and nothing moves.** Half of it sits
/// either side, so the middle of a dissolve lands where the clips meet, and
/// the overlap it needs is made by the engine rather than by the document:
/// [Track] keeps its clips butt-joined and non-overlapping, which is what
/// [Track.clipAt]'s binary search rests on. Editors more often consume handles
/// and shorten the sequence; that would move every clip downstream and repack
/// the magnetic lane, which is a far larger surprise than the alternative —
/// through its half of the window each clip is asked for a source time outside
/// its own trim, and the decoder clamps, so a cut between two clips trimmed to
/// their very ends still dissolves with a held frame rather than failing.
@immutable
final class ClipTransition {
  const ClipTransition({
    this.preset = TransitionPreset.none,
    this.duration = Tick.zero,
  });

  /// A plain cut.
  static const none = ClipTransition();

  final TransitionPreset preset;

  /// The whole window, half of it either side of the cut.
  final Tick duration;

  /// What a transition is when somebody picks one without saying how long.
  /// Half a second reads as deliberate without holding up the edit.
  static final defaultDuration =
      Tick(Timebase.project.ticksPerSecond ~/ 2);

  static final minDuration = Tick(Timebase.project.ticksPerSecond ~/ 10);
  static final maxDuration = Tick(3 * Timebase.project.ticksPerSecond);

  /// True when this would change a frame. A preset with no length and a length
  /// with no preset are both "a plain cut", and saying so once here keeps
  /// every reader from working it out again.
  bool get isActive =>
      preset != TransitionPreset.none && duration.raw > 0;

  /// Pulled inside the range the inspector offers, on the way into the
  /// document — so a file written by a version with a wider slider opens as
  /// something this one can still edit.
  ClipTransition clamped() => !isActive
      ? ClipTransition.none
      : ClipTransition(
          preset: preset,
          duration: Tick(
              duration.raw.clamp(minDuration.raw, maxDuration.raw)),
        );

  /// Shortened so it cannot reach beyond either clip it joins.
  ///
  /// Half the window sits on each side, so the longest a transition may be is
  /// twice the shorter neighbour. Clamped rather than refused: the duration is
  /// a slider, and one that stops moving at a length nobody can see looks
  /// broken.
  ClipTransition clampedBetween(Tick before, Tick after) {
    if (!isActive) return ClipTransition.none;
    final room = 2 * (before.raw < after.raw ? before.raw : after.raw);
    if (room <= 0) return ClipTransition.none;
    return duration.raw <= room
        ? this
        : ClipTransition(preset: preset, duration: Tick(room));
  }

  ClipTransition copyWith({TransitionPreset? preset, Tick? duration}) =>
      ClipTransition(
        preset: preset ?? this.preset,
        duration: duration ?? this.duration,
      );

  @override
  bool operator ==(Object other) =>
      other is ClipTransition &&
      other.preset == preset &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(preset, duration.raw);

  @override
  String toString() => isActive
      ? 'ClipTransition(${preset.name} ${duration.raw})'
      : 'ClipTransition.none';
}

/// One piece of media placed on a track.
///
/// A clip is a window onto its source: [sourceIn] is where the window opens in
/// the source, [start] is where it lands on the timeline, and [duration] is the
/// length of both. Trimming moves the window edges; moving slides [start].
///
/// Or it generates its own picture, and then it is a window onto nothing:
/// [text] or [shape] is set, [mediaId] is not, and [sourceIn] means nothing
/// because there is no source to be offset into. Exactly one of the three is
/// always present.
final class Clip {
  const Clip({
    required this.id,
    required this.mediaId,
    required this.start,
    required this.duration,
    this.sourceIn = Tick.zero,
    this.label = '',
    this.enabled = true,
    this.transform = ClipTransform.identity,
    this.audio = ClipAudio.unity,
    this.animation = ClipAnimation.still,
    this.transition = ClipTransition.none,
    this.text,
    this.shape,
  }) : assert(
            (mediaId == null ? 0 : 1) +
                    (text == null ? 0 : 1) +
                    (shape == null ? 0 : 1) ==
                1,
            'a clip is a window onto a file or one of the things the app '
            'draws, never two of them and never none');

  /// A caption: a clip with no file behind it. The duration is whatever the
  /// caller asks for, because nothing bounds it — there is no source to run
  /// out of, exactly as for a still image.
  factory Clip.caption({
    required String id,
    required Tick start,
    required Tick duration,
    required ClipText text,
    ClipTransform transform = ClipTransform.identity,
    ClipAnimation animation = ClipAnimation.still,
  }) =>
      Clip(
        id: id,
        mediaId: null,
        start: start,
        duration: duration,
        transform: transform,
        animation: animation,
        text: text,
      );

  /// A shape: the other clip with no file behind it, on the same terms as
  /// [Clip.caption].
  factory Clip.drawing({
    required String id,
    required Tick start,
    required Tick duration,
    required ClipShape shape,
    ClipTransform transform = ClipTransform.identity,
    ClipAnimation animation = ClipAnimation.still,
  }) =>
      Clip(
        id: id,
        mediaId: null,
        start: start,
        duration: duration,
        transform: transform,
        animation: animation,
        shape: shape,
      );

  final String id;

  /// Key into [Project.media], or null for a generated clip — see [text].
  final String? mediaId;

  /// Position on the timeline, in project ticks.
  final Tick start;

  /// Length on the timeline, in project ticks. Always > 0 for a live clip.
  final Tick duration;

  /// Offset into the source media where this clip begins.
  final Tick sourceIn;

  final String label;
  final bool enabled;

  /// Where the clip sits inside the frame. [ClipTransform.identity] for a clip
  /// nobody has moved, which is almost all of them.
  final ClipTransform transform;

  /// How loud it is. [ClipAudio.unity] for a clip nobody has faded, and
  /// present even on a clip whose source has no sound — see [ClipAudio].
  final ClipAudio audio;

  /// How it arrives and how it leaves. [ClipAnimation.still] for a clip nobody
  /// has animated, which is almost all of them.
  final ClipAnimation animation;

  /// How it joins the clip before it on the same track — see [ClipTransition].
  /// [ClipTransition.none] is a plain cut, which is almost every join.
  final ClipTransition transition;

  /// The caption this clip draws, or null for a clip that is not one.
  final ClipText? text;

  /// The shape this clip draws, or null for a clip that is not one.
  final ClipShape? shape;

  /// True for a clip whose picture is a caption.
  bool get isText => text != null;

  /// True for a clip whose picture is a shape.
  bool get isShape => shape != null;

  /// True for a clip the app draws rather than decodes — a caption or a shape.
  ///
  /// This is what the rules about lanes and about what an inspector offers are
  /// written against, rather than "has no asset": a clip whose media is merely
  /// missing is still a video clip and still belongs where video goes.
  bool get isGenerated => text != null || shape != null;

  Tick get end => start + duration;
  Tick get sourceOut => sourceIn + duration;
  TimeSpan get span => TimeSpan(start, duration);
  TimeSpan get sourceSpan => TimeSpan(sourceIn, duration);

  /// Maps a timeline instant to the corresponding instant in the source.
  /// Callers must have checked [span].contains first.
  Tick sourceTimeAt(Tick timelineTime) => sourceIn + (timelineTime - start);

  /// How loud this clip is [offset] ticks in: the fader, mute, the fades and
  /// the volume line together. The one place that knows the clip's own
  /// [sourceIn], which the volume line is measured against.
  double gainAt(Tick offset) =>
      audio.gainAt(offset, duration, sourceIn: sourceIn);

  Clip copyWith({
    String? id,
    String? mediaId,
    Tick? start,
    Tick? duration,
    Tick? sourceIn,
    String? label,
    bool? enabled,
    ClipTransform? transform,
    ClipAudio? audio,
    ClipAnimation? animation,
    ClipTransition? transition,
    ClipText? text,
    ClipShape? shape,
  }) =>
      Clip(
        id: id ?? this.id,
        mediaId: mediaId ?? this.mediaId,
        start: start ?? this.start,
        duration: duration ?? this.duration,
        sourceIn: sourceIn ?? this.sourceIn,
        label: label ?? this.label,
        enabled: enabled ?? this.enabled,
        transform: transform ?? this.transform,
        audio: audio ?? this.audio,
        animation: animation ?? this.animation,
        transition: transition ?? this.transition,
        // What a clip *is* never changes: a caption never becomes a shape or a
        // media clip and neither becomes a caption, so there is no need to be
        // able to clear either of these.
        text: text ?? this.text,
        shape: shape ?? this.shape,
      );

  /// Moves the clip on the timeline without touching its source window.
  Clip movedTo(Tick newStart) => copyWith(start: newStart);

  /// Trims the head. Positive [delta] shortens the clip from the left, which
  /// moves both [start] and [sourceIn]; the tail stays put.
  Clip trimHeadBy(Tick delta) => _withDuration(
        duration - delta,
        start: start + delta,
        sourceIn: sourceIn + delta,
      );

  /// Trims the tail. Positive [delta] lengthens the clip to the right.
  Clip trimTailBy(Tick delta) => _withDuration(duration + delta);

  /// Every change of length goes through here, so that fades longer than the
  /// clip they are on cannot outlive the trim that made them so.
  Clip _withDuration(Tick newDuration, {Tick? start, Tick? sourceIn}) =>
      copyWith(
        start: start,
        sourceIn: sourceIn,
        duration: newDuration,
        audio: audio.clampedTo(newDuration),
        // For the same reason the fades are clamped: an entrance longer than
        // the clip it is on is one the clip never finishes arriving from.
        animation: animation.clampedTo(newDuration),
        // And a transition longer than twice the clip would reach past the
        // far end of it. Only this clip's own half is bounded here — the other
        // half belongs to a neighbour this knows nothing about, and the engine
        // clamps against both when it pairs the cut.
        transition: transition.clampedBetween(newDuration, newDuration),
      );

  @override
  bool operator ==(Object other) =>
      other is Clip &&
      other.id == id &&
      other.mediaId == mediaId &&
      other.start == start &&
      other.duration == duration &&
      other.sourceIn == sourceIn &&
      other.label == label &&
      other.enabled == enabled &&
      other.transform == transform &&
      other.audio == audio &&
      other.animation == animation &&
      other.transition == transition &&
      other.text == text &&
      other.shape == shape;

  @override
  int get hashCode => Object.hash(id, mediaId, start.raw, duration.raw,
      sourceIn.raw, label, enabled, transform, audio, animation, transition,
      text, shape);

  @override
  String toString() => isGenerated
      ? 'Clip($id, ${start.raw}+${duration.raw}, ${text ?? shape})'
      : 'Clip($id, ${start.raw}+${duration.raw}, src ${sourceIn.raw})';
}

/// The longest a clip may be trimmed given the source it points at.
///
/// Zero means unbounded, which covers an image — no intrinsic length — a
/// sticker, which loops rather than running out, and a caption or a shape,
/// which have no source at all.
Tick maxDurationFor(Clip clip, MediaAsset? asset) {
  if (asset == null || asset.probe.kind.isEndless) return Tick.zero;
  return asset.probe.duration - clip.sourceIn;
}
