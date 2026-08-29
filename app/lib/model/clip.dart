import 'media.dart';
import 'time.dart';

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
  }) =>
      Clip(
        id: id ?? this.id,
        mediaId: mediaId ?? this.mediaId,
        start: start ?? this.start,
        duration: duration ?? this.duration,
        sourceIn: sourceIn ?? this.sourceIn,
        label: label ?? this.label,
        enabled: enabled ?? this.enabled,
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
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(
      id, mediaId, start.raw, duration.raw, sourceIn.raw, label, enabled);

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
