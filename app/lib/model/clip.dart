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

/// One piece of media placed on a track.
///
/// A clip is a window onto its source: [sourceIn] is where the window opens in
/// the source, [start] is where it lands on the timeline, and [duration] is the
/// length of both. Trimming moves the window edges; moving slides [start].
///
/// Or it generates its own picture, and then it is a window onto nothing:
/// [text] is set, [mediaId] is not, and [sourceIn] means nothing because there
/// is no source to be offset into. Exactly one of the two is always present.
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
    this.text,
  }) : assert(mediaId == null || text == null,
            'a clip is a window onto a file or something the app draws, '
            'never both');

  /// A caption: a clip with no file behind it. The duration is whatever the
  /// caller asks for, because nothing bounds it — there is no source to run
  /// out of, exactly as for a still image.
  factory Clip.caption({
    required String id,
    required Tick start,
    required Tick duration,
    required ClipText text,
    ClipTransform transform = ClipTransform.identity,
  }) =>
      Clip(
        id: id,
        mediaId: null,
        start: start,
        duration: duration,
        transform: transform,
        text: text,
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

  /// The caption this clip draws, or null for a clip that shows a file.
  final ClipText? text;

  /// True for a clip the app draws rather than decodes.
  bool get isText => text != null;

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
    ClipText? text,
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
        // A caption never becomes a media clip and a media clip never becomes
        // a caption, so there is no need to be able to clear this.
        text: text ?? this.text,
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
      other.text == text;

  @override
  int get hashCode => Object.hash(id, mediaId, start.raw, duration.raw,
      sourceIn.raw, label, enabled, transform, audio, text);

  @override
  String toString() => isText
      ? 'Clip($id, ${start.raw}+${duration.raw}, $text)'
      : 'Clip($id, ${start.raw}+${duration.raw}, src ${sourceIn.raw})';
}

/// The longest a clip may be trimmed given the source it points at.
///
/// Zero means unbounded, which covers an image — no intrinsic length — and a
/// caption, which has no source to run out of at all.
Tick maxDurationFor(Clip clip, MediaAsset? asset) {
  if (asset == null || asset.probe.kind == MediaKind.image) return Tick.zero;
  return asset.probe.duration - clip.sourceIn;
}
