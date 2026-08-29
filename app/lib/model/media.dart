import 'time.dart';

/// What a media file can contribute to the timeline.
enum MediaKind { video, audio, image }

/// What probing a file told us about it. Filled by the engine's media probe;
/// cached in the project so opening a file does not re-probe every launch.
final class MediaProbe {
  const MediaProbe({
    required this.kind,
    required this.duration,
    this.width = 0,
    this.height = 0,
    this.frameRate = Rational.one,
    this.variableFrameRate = false,
    this.rotationDegrees = 0,
    this.hasVideo = false,
    this.hasAudio = false,
    this.audioChannels = 0,
    this.audioSampleRate = 0,
    this.videoCodec,
    this.audioCodec,
  });

  final MediaKind kind;

  /// Source duration in project ticks.
  final Tick duration;

  /// Coded dimensions, before [rotationDegrees] is applied.
  final int width;
  final int height;

  /// Nominal rate. Meaningless on its own when [variableFrameRate] is set —
  /// VFR sources are normalised to the project timebase at decode time.
  final Rational frameRate;
  final bool variableFrameRate;

  /// Display rotation from container metadata: 0, 90, 180 or 270.
  final int rotationDegrees;

  final bool hasVideo;
  final bool hasAudio;
  final int audioChannels;
  final int audioSampleRate;
  final String? videoCodec;
  final String? audioCodec;

  /// Dimensions as the viewer sees them, with rotation applied.
  int get displayWidth => rotationDegrees % 180 == 0 ? width : height;
  int get displayHeight => rotationDegrees % 180 == 0 ? height : width;

  MediaProbe copyWith({
    MediaKind? kind,
    Tick? duration,
    int? width,
    int? height,
    Rational? frameRate,
    bool? variableFrameRate,
    int? rotationDegrees,
    bool? hasVideo,
    bool? hasAudio,
    int? audioChannels,
    int? audioSampleRate,
    String? videoCodec,
    String? audioCodec,
  }) =>
      MediaProbe(
        kind: kind ?? this.kind,
        duration: duration ?? this.duration,
        width: width ?? this.width,
        height: height ?? this.height,
        frameRate: frameRate ?? this.frameRate,
        variableFrameRate: variableFrameRate ?? this.variableFrameRate,
        rotationDegrees: rotationDegrees ?? this.rotationDegrees,
        hasVideo: hasVideo ?? this.hasVideo,
        hasAudio: hasAudio ?? this.hasAudio,
        audioChannels: audioChannels ?? this.audioChannels,
        audioSampleRate: audioSampleRate ?? this.audioSampleRate,
        videoCodec: videoCodec ?? this.videoCodec,
        audioCodec: audioCodec ?? this.audioCodec,
      );

  @override
  bool operator ==(Object other) =>
      other is MediaProbe &&
      other.kind == kind &&
      other.duration == duration &&
      other.width == width &&
      other.height == height &&
      other.frameRate == frameRate &&
      other.variableFrameRate == variableFrameRate &&
      other.rotationDegrees == rotationDegrees &&
      other.hasVideo == hasVideo &&
      other.hasAudio == hasAudio &&
      other.audioChannels == audioChannels &&
      other.audioSampleRate == audioSampleRate &&
      other.videoCodec == videoCodec &&
      other.audioCodec == audioCodec;

  @override
  int get hashCode => Object.hash(kind, duration.raw, width, height, frameRate,
      variableFrameRate, rotationDegrees, hasVideo, hasAudio, audioChannels,
      audioSampleRate, videoCodec, audioCodec);
}

/// A file the project refers to. The project never copies media; it points at
/// it, and remembers enough to find it again after the app is sandboxed.
final class MediaAsset {
  const MediaAsset({
    required this.id,
    required this.path,
    required this.displayName,
    required this.probe,
    this.bookmark,
  });

  final String id;

  /// Absolute path as last resolved. Advisory: under the App Sandbox the
  /// [bookmark] is what actually grants access, and it can resolve to a moved
  /// file whose path no longer matches.
  final String path;

  final String displayName;
  final MediaProbe probe;

  /// Base64 security-scoped bookmark. Null until the user has granted access
  /// through a picker or a drop, which is the only way to obtain one.
  final String? bookmark;

  MediaAsset copyWith({
    String? id,
    String? path,
    String? displayName,
    MediaProbe? probe,
    String? bookmark,
  }) =>
      MediaAsset(
        id: id ?? this.id,
        path: path ?? this.path,
        displayName: displayName ?? this.displayName,
        probe: probe ?? this.probe,
        bookmark: bookmark ?? this.bookmark,
      );

  @override
  bool operator ==(Object other) =>
      other is MediaAsset &&
      other.id == id &&
      other.path == path &&
      other.displayName == displayName &&
      other.probe == probe &&
      other.bookmark == bookmark;

  @override
  int get hashCode => Object.hash(id, path, displayName, probe, bookmark);

  @override
  String toString() => 'MediaAsset($id, $displayName)';
}
