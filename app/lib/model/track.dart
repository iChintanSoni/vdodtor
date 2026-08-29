import 'clip.dart';
import 'time.dart';

/// The four kinds of track in the document model.
///
/// [main] is magnetic: its clips are packed end to end from zero with no gaps,
/// and deleting one ripples the rest closed. Every other kind is free-form.
enum TrackKind {
  main,
  overlay,
  audio,
  text;

  bool get isVisual => this != TrackKind.audio;
  bool get isMagnetic => this == TrackKind.main;
}

/// An ordered lane of non-overlapping clips.
///
/// Invariant: [clips] is sorted by [Clip.start] and no two clips overlap. Build
/// tracks through [Track.of] or [withClips], which restore that invariant, and
/// the rest of the model can assume it.
final class Track {
  const Track._({
    required this.id,
    required this.kind,
    required this.name,
    required this.clips,
    required this.muted,
    required this.locked,
    required this.hidden,
  });

  /// Sorts [clips] and asserts the no-overlap invariant in debug builds.
  factory Track.of({
    required String id,
    required TrackKind kind,
    required String name,
    List<Clip> clips = const [],
    bool muted = false,
    bool locked = false,
    bool hidden = false,
  }) {
    final sorted = List<Clip>.of(clips)
      ..sort((a, b) => a.start.compareTo(b.start));
    assert(_noOverlaps(sorted), 'clips on track "$name" overlap: $sorted');
    return Track._(
      id: id,
      kind: kind,
      name: name,
      clips: List.unmodifiable(sorted),
      muted: muted,
      locked: locked,
      hidden: hidden,
    );
  }

  final String id;
  final TrackKind kind;
  final String name;

  /// Sorted by start, non-overlapping, unmodifiable.
  final List<Clip> clips;

  final bool muted;
  final bool locked;
  final bool hidden;

  bool get isMagnetic => kind.isMagnetic;
  bool get isEmpty => clips.isEmpty;

  /// End of the last clip, or zero for an empty track.
  Tick get duration =>
      clips.isEmpty ? Tick.zero : clips.map((c) => c.end).reduce(Tick.larger);

  Clip? clipById(String clipId) {
    for (final c in clips) {
      if (c.id == clipId) return c;
    }
    return null;
  }

  int indexOfClip(String clipId) =>
      clips.indexWhere((c) => c.id == clipId);

  /// The clip covering [t], or null if [t] falls in a gap.
  Clip? clipAt(Tick t) {
    // Binary search: clips are sorted and disjoint.
    var lo = 0;
    var hi = clips.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final c = clips[mid];
      if (t < c.start) {
        hi = mid - 1;
      } else if (t >= c.end) {
        lo = mid + 1;
      } else {
        return c;
      }
    }
    return null;
  }

  Track withClips(List<Clip> newClips) => Track.of(
        id: id,
        kind: kind,
        name: name,
        clips: newClips,
        muted: muted,
        locked: locked,
        hidden: hidden,
      );

  Track copyWith({
    String? name,
    bool? muted,
    bool? locked,
    bool? hidden,
  }) =>
      Track._(
        id: id,
        kind: kind,
        name: name ?? this.name,
        clips: clips,
        muted: muted ?? this.muted,
        locked: locked ?? this.locked,
        hidden: hidden ?? this.hidden,
      );

  /// Repacks clips end to end from zero. Only meaningful on a magnetic track;
  /// this is what makes a delete ripple closed.
  Track repacked() => isMagnetic ? repackedFrom(clips) : this;

  /// Rebuilds a magnetic track from [source], which is *allowed to overlap*.
  ///
  /// This is the commit step of a magnetic drag: the dragged clip is placed
  /// freely during the gesture, and on release the lane is ordered and packed
  /// closed around it. Ordering is by centre point, so a clip has to be
  /// dragged past the middle of a neighbour before they swap — which is what
  /// makes a reorder feel deliberate rather than twitchy.
  Track repackedFrom(List<Clip> source) {
    assert(isMagnetic, 'only a magnetic track packs');
    final ordered = List<Clip>.of(source)..sort(_byCentre);

    var cursor = Tick.zero;
    final packed = <Clip>[];
    var changed = ordered.length != clips.length;
    for (var i = 0; i < ordered.length; i++) {
      final c = ordered[i];
      if (!changed && !identical(c, clips[i])) changed = true;
      packed.add(c.start == cursor ? c : c.movedTo(cursor));
      if (packed[i].start != c.start) changed = true;
      cursor += c.duration;
    }
    // Packing removed any overlap, so the invariant holds by construction.
    return changed ? withClips(packed) : this;
  }

  /// Orders by centre point, breaking ties deterministically so a repack is a
  /// pure function of its input.
  static int _byCentre(Clip a, Clip b) {
    // Doubled centres keep the comparison in integers.
    final ca = a.start.raw * 2 + a.duration.raw;
    final cb = b.start.raw * 2 + b.duration.raw;
    if (ca != cb) return ca.compareTo(cb);
    final byStart = a.start.compareTo(b.start);
    return byStart != 0 ? byStart : a.id.compareTo(b.id);
  }

  static bool _noOverlaps(List<Clip> sorted) {
    for (var i = 1; i < sorted.length; i++) {
      if (sorted[i].start < sorted[i - 1].end) return false;
    }
    return true;
  }

  @override
  String toString() => 'Track($id, $kind, ${clips.length} clips)';
}
