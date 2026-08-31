import 'clip.dart';
import 'media.dart';
import 'time.dart';
import 'track.dart';

/// The aspect ratios offered at project creation (product brief §4).
enum ProjectAspect {
  portrait9x16(9, 16, '9:16'),
  landscape16x9(16, 9, '16:9'),
  square1x1(1, 1, '1:1'),
  portrait4x5(4, 5, '4:5');

  const ProjectAspect(this.wide, this.tall, this.label);

  final int wide;
  final int tall;
  final String label;
}

/// Output geometry and rate. Fixed at creation; changing it is a document edit,
/// not a render setting, because every layout decision depends on it.
final class ProjectFormat {
  const ProjectFormat({
    required this.width,
    required this.height,
    required this.frameRate,
  })  : assert(width > 0 && height > 0),
        assert(width % 2 == 0 && height % 2 == 0,
            'odd dimensions break 4:2:0 chroma subsampling');

  /// Builds a format from an aspect, sizing the *short* side to [shortSide].
  /// 1080 gives 1920x1080, 1080x1920, 1080x1080 and 1080x1350 respectively.
  factory ProjectFormat.fromAspect(
    ProjectAspect aspect, {
    int shortSide = 1080,
    required Rational frameRate,
  }) {
    final short = aspect.wide <= aspect.tall ? aspect.wide : aspect.tall;
    final scale = shortSide / short;
    int even(int v) => v.isEven ? v : v + 1;
    return ProjectFormat(
      width: even((aspect.wide * scale).round()),
      height: even((aspect.tall * scale).round()),
      frameRate: frameRate,
    );
  }

  final int width;
  final int height;
  final Rational frameRate;

  int get shortSide => width < height ? width : height;

  /// The offered aspect this format matches, or null for a custom size.
  ProjectAspect? get aspect {
    for (final a in ProjectAspect.values) {
      if (width * a.tall == height * a.wide) return a;
    }
    return null;
  }

  /// Whether export at this size needs Pro (product brief §5: 1080p is free).
  bool get isAboveFreeTier => shortSide > 1080;

  ProjectFormat copyWith({int? width, int? height, Rational? frameRate}) =>
      ProjectFormat(
        width: width ?? this.width,
        height: height ?? this.height,
        frameRate: frameRate ?? this.frameRate,
      );

  @override
  bool operator ==(Object other) =>
      other is ProjectFormat &&
      other.width == width &&
      other.height == height &&
      other.frameRate == frameRate;

  @override
  int get hashCode => Object.hash(width, height, frameRate);

  @override
  String toString() => 'ProjectFormat(${width}x$height @ $frameRate)';
}

/// The document.
///
/// Immutable, with structural sharing: every mutator returns a new [Project]
/// that reuses the untouched [Track] and [MediaAsset] instances. That is what
/// makes snapshot undo cheap and makes `identical()` a correct, O(1) test for
/// "did this track change?" in the UI.
final class Project {
  const Project._({
    required this.id,
    required this.name,
    required this.format,
    required this.timebase,
    required this.tracks,
    required this.media,
  });

  factory Project({
    required String id,
    required String name,
    required ProjectFormat format,
    Timebase timebase = Timebase.project,
    List<Track> tracks = const [],
    Map<String, MediaAsset> media = const {},
  }) {
    assert(timebase.divides(format.frameRate),
        'timebase $timebase cannot represent ${format.frameRate} exactly');
    return Project._(
      id: id,
      name: name,
      format: format,
      timebase: timebase,
      tracks: List.unmodifiable(tracks),
      media: Map.unmodifiable(media),
    );
  }

  /// A new project: one magnetic main video track and one audio track, which
  /// is the least a user can drop a clip onto and hear it.
  factory Project.empty({
    required String id,
    required String name,
    required ProjectFormat format,
    required String mainTrackId,
    required String audioTrackId,
  }) =>
      Project(
        id: id,
        name: name,
        format: format,
        tracks: [
          Track.of(id: mainTrackId, kind: TrackKind.main, name: 'Video'),
          Track.of(id: audioTrackId, kind: TrackKind.audio, name: 'Audio 1'),
        ],
      );

  final String id;
  final String name;
  final ProjectFormat format;
  final Timebase timebase;

  /// Ordered bottom-to-top for the visual kinds; that order is the compositor's
  /// z-order. Unmodifiable.
  final List<Track> tracks;

  /// Media assets by id. Unmodifiable.
  final Map<String, MediaAsset> media;

  int get ticksPerFrame => timebase.ticksPerFrame(format.frameRate);

  /// End of the last clip on any track.
  Tick get duration => tracks.isEmpty
      ? Tick.zero
      : tracks.map((t) => t.duration).reduce(Tick.larger);

  Track? trackById(String trackId) {
    for (final t in tracks) {
      if (t.id == trackId) return t;
    }
    return null;
  }

  Track get mainTrack =>
      tracks.firstWhere((t) => t.kind == TrackKind.main,
          orElse: () => throw StateError('project $id has no main track'));

  /// The track holding [clipId], or null.
  Track? trackOfClip(String clipId) {
    for (final t in tracks) {
      if (t.indexOfClip(clipId) >= 0) return t;
    }
    return null;
  }

  Clip? clipById(String clipId) {
    for (final t in tracks) {
      final c = t.clipById(clipId);
      if (c != null) return c;
    }
    return null;
  }

  MediaAsset? assetFor(Clip clip) =>
      clip.mediaId == null ? null : media[clip.mediaId];

  /// Replaces one track, sharing every other track instance.
  Project replaceTrack(Track track) {
    final index = tracks.indexWhere((t) => t.id == track.id);
    if (index < 0) throw ArgumentError('no track ${track.id} in project $id');
    if (identical(tracks[index], track)) return this;
    final next = List<Track>.of(tracks)..[index] = track;
    return _with(tracks: next);
  }

  /// Applies [edit] to the track with [trackId], sharing the rest.
  Project updateTrack(String trackId, Track Function(Track) edit) {
    final track = trackById(trackId);
    if (track == null) throw ArgumentError('no track $trackId in project $id');
    return replaceTrack(edit(track));
  }

  /// How many lanes of [kind] the project has.
  int trackCountOfKind(TrackKind kind) =>
      tracks.where((t) => t.kind == kind).length;

  /// The most lanes of each kind a project may hold (product brief §4):
  /// one magnetic main video track, three parallel overlays, six audio.
  ///
  /// The visual ones add up to the compositor's own bound: `VD_MAX_LAYERS` in
  /// `engine/src/vd_engine.c` is one main plus three overlays plus eight text,
  /// and the two numbers have to move together. A lane the document allows and
  /// the compositor silently drops is a caption that is on the timeline and
  /// not on the screen.
  static int maxTracksOfKind(TrackKind kind) => switch (kind) {
        TrackKind.main => 1,
        TrackKind.overlay => 3,
        TrackKind.audio => 6,
        // Not in the brief, which says nothing about how many. Eight is enough
        // for a title, a lower third and a run of captions at once, and few
        // enough that the compositor can promise to draw all of them.
        TrackKind.text => 8,
      };

  bool canAddTrackOfKind(TrackKind kind) =>
      trackCountOfKind(kind) < maxTracksOfKind(kind);

  /// Where a new lane of [kind] belongs in [tracks].
  ///
  /// List order *is* compositing order — later renders on top — so this is not
  /// a cosmetic decision. A new overlay goes above every visual lane already
  /// there and below the audio ones, which composite nothing.
  int insertIndexFor(TrackKind kind) {
    if (!kind.isVisual) return tracks.length;
    var index = 0;
    for (var i = 0; i < tracks.length; i++) {
      if (tracks[i].kind.isVisual) index = i + 1;
    }
    return index;
  }

  Project addTrack(Track track, {int? at}) {
    final next = List<Track>.of(tracks);
    next.insert(at ?? next.length, track);
    return _with(tracks: next);
  }

  Project removeTrack(String trackId) {
    final next = tracks.where((t) => t.id != trackId).toList();
    if (next.length == tracks.length) return this;
    return _with(tracks: next);
  }

  Project addMedia(MediaAsset asset) {
    if (media[asset.id] == asset) return this;
    return _with(media: {...media, asset.id: asset});
  }

  Project removeMedia(String mediaId) {
    if (!media.containsKey(mediaId)) return this;
    final next = Map<String, MediaAsset>.of(media)..remove(mediaId);
    return _with(media: next);
  }

  /// Media ids no clip refers to any more — candidates for bin cleanup.
  Set<String> get orphanedMediaIds {
    final used = <String>{};
    for (final t in tracks) {
      for (final c in t.clips) {
        if (c.mediaId != null) used.add(c.mediaId!);
      }
    }
    return media.keys.toSet().difference(used);
  }

  Project copyWith({
    String? name,
    ProjectFormat? format,
  }) =>
      _with(name: name, format: format);

  Project _with({
    String? name,
    ProjectFormat? format,
    List<Track>? tracks,
    Map<String, MediaAsset>? media,
  }) =>
      Project._(
        id: id,
        name: name ?? this.name,
        format: format ?? this.format,
        timebase: timebase,
        tracks: tracks == null ? this.tracks : List.unmodifiable(tracks),
        media: media == null ? this.media : Map.unmodifiable(media),
      );

  @override
  String toString() =>
      'Project($id, "$name", $format, ${tracks.length} tracks)';
}
