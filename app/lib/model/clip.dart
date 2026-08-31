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

  /// +6 dB. Enough to rescue a quiet recording, short of enough to destroy
  /// one by accident.
  static const double maxVolume = 2;

  bool get isUnity => this == unity;

  bool get hasFade => fadeIn.raw > 0 || fadeOut.raw > 0;

  /// What [volume] actually amounts to once mute is taken into account.
  double get effectiveVolume => muted ? 0 : volume.clamp(0.0, maxVolume);

  /// The multiplier at [offset] ticks into a clip [duration] long, fades and
  /// volume and mute all together.
  ///
  /// The engine computes the same envelope in C — `vd_audio_fade_gain` in
  /// `engine/src/vd_audio_renderer.c` — and the two are tested against the
  /// same table. Change one and you must change the other.
  ///
  /// The ramps are linear in amplitude. Linear is not the most flattering
  /// curve for a long fade, but it is the one where the handle position means
  /// what it looks like it means, and a shaped curve is an option to add later
  /// rather than a default to guess at now.
  double gainAt(Tick offset, Tick duration) =>
      effectiveVolume * fadeShapeAt(offset, duration, fadeIn, fadeOut);

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
  }) =>
      ClipAudio(
        volume: volume ?? this.volume,
        fadeIn: fadeIn ?? this.fadeIn,
        fadeOut: fadeOut ?? this.fadeOut,
        muted: muted ?? this.muted,
      );

  @override
  bool operator ==(Object other) =>
      other is ClipAudio &&
      other.volume == volume &&
      other.fadeIn == fadeIn &&
      other.fadeOut == fadeOut &&
      other.muted == muted;

  @override
  int get hashCode => Object.hash(volume, fadeIn.raw, fadeOut.raw, muted);

  @override
  String toString() => isUnity
      ? 'ClipAudio.unity'
      : 'ClipAudio(volume $volume${muted ? ' muted' : ''} '
          'fade ${fadeIn.raw}/${fadeOut.raw})';
}

/// One piece of media placed on a track.
///
/// A clip is a window onto its source: [sourceIn] is where the window opens in
/// the source, [start] is where it lands on the timeline, and [duration] is the
/// length of both. Trimming moves the window edges; moving slides [start].
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
  });

  final String id;

  /// Key into [Project.media]. Null is reserved for the generated clips that
  /// arrive in M3 (text, shapes), which have no source file.
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

  Tick get end => start + duration;
  Tick get sourceOut => sourceIn + duration;
  TimeSpan get span => TimeSpan(start, duration);
  TimeSpan get sourceSpan => TimeSpan(sourceIn, duration);

  /// Maps a timeline instant to the corresponding instant in the source.
  /// Callers must have checked [span].contains first.
  Tick sourceTimeAt(Tick timelineTime) => sourceIn + (timelineTime - start);

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
      other.audio == audio;

  @override
  int get hashCode => Object.hash(id, mediaId, start.raw, duration.raw,
      sourceIn.raw, label, enabled, transform, audio);

  @override
  String toString() =>
      'Clip($id, ${start.raw}+${duration.raw}, src ${sourceIn.raw})';
}

/// The longest a clip may be trimmed given the source it points at.
/// Images have no intrinsic length, so they are unbounded.
Tick maxDurationFor(Clip clip, MediaAsset? asset) {
  if (asset == null || asset.probe.kind == MediaKind.image) return Tick.zero;
  return asset.probe.duration - clip.sourceIn;
}
