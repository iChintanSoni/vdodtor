import 'package:flutter/foundation.dart';

import 'media.dart';
import 'time.dart';

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
  int get hashCode => Object.hash(offsetX, offsetY, scale, rotationDegrees,
      cropLeft, cropTop, cropRight, cropBottom, opacity, flipHorizontal,
      flipVertical);

  @override
  String toString() => isIdentity
      ? 'ClipTransform.identity'
      : 'ClipTransform(offset $offsetX,$offsetY scale $scale '
          'rot $rotationDegrees opacity $opacity)';
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
      );

  /// Moves the clip on the timeline without touching its source window.
  Clip movedTo(Tick newStart) => copyWith(start: newStart);

  /// Trims the head. Positive [delta] shortens the clip from the left, which
  /// moves both [start] and [sourceIn]; the tail stays put.
  Clip trimHeadBy(Tick delta) => copyWith(
        start: start + delta,
        sourceIn: sourceIn + delta,
        duration: duration - delta,
      );

  /// Trims the tail. Positive [delta] lengthens the clip to the right.
  Clip trimTailBy(Tick delta) => copyWith(duration: duration + delta);

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
      other.transform == transform;

  @override
  int get hashCode => Object.hash(id, mediaId, start.raw, duration.raw,
      sourceIn.raw, label, enabled, transform);

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
