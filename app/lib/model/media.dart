import 'time.dart';

/// What a media file can contribute to the timeline.
///
/// Serialised by name, so these may be added to but not renamed.
enum MediaKind {
  video,
  audio,
  image,

  /// An animated overlay: a GIF, an animated WebP, an APNG. A file with a
  /// picture, like [video], and with no length of its own, like [image] —
  /// because it loops, so a one-second sticker fits a ten-second clip and the
  /// only thing bounding it is the clip.
  ///
  /// Its own kind rather than a flavour of [video] because the engine opens it
  /// differently: decoded whole and looped instead of seeked in, and handed to
  /// the compositor as premultiplied BGRA instead of YCbCr. See vd_sticker.h.
  sticker;

  /// True for the kinds that put something on screen.
  bool get isVisual => this != MediaKind.audio;

  /// True for the kinds with no length of their own, which the timeline may
  /// therefore stretch as far as anybody drags them.
  bool get isEndless => this == MediaKind.image || this == MediaKind.sticker;
}

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
    this.pixelAspect = Rational.one,
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

  /// Sample aspect: how much wider one coded pixel is than it is tall. 1 for
  /// the square pixels almost everything shot this century has, 2 for the
  /// anamorphic footage that is the reason this is not assumed.
  final Rational pixelAspect;

  final bool hasVideo;
  final bool hasAudio;
  final int audioChannels;
  final int audioSampleRate;
  final String? videoCodec;
  final String? audioCodec;

  /// Dimensions as the viewer sees them: coded pixels widened by
  /// [pixelAspect], then turned by [rotationDegrees]. Rotation comes second
  /// because a quarter turn puts the stretch on the other axis.
  ///
  /// This is the size the engine lays the clip out at, so it is the size to
  /// put next to the thumbnail — a bin that labels a clip with its coded size
  /// and draws it at its display size is telling two stories about one file.
  int get displayWidth => rotationDegrees % 180 == 0 ? _widened : height;
  int get displayHeight => rotationDegrees % 180 == 0 ? height : _widened;

  int get _widened =>
      (width * pixelAspect.numerator / pixelAspect.denominator).round();

  /// The codecs that mean "animated overlay" rather than "video".
  ///
  /// **This list is written twice** — here and in `vd_sticker_is_sticker_codec`
  /// in `engine/src/vd_sticker.c` — and the same table is asserted in both test
  /// suites, exactly as `vd_time.c` and `time.dart` are. The engine needs it
  /// because a second frontend would have to classify a file without Dart; the
  /// app needs it because a project loaded from disk is classified with no
  /// engine alive, and a widget test has none.
  ///
  /// The *codec* rather than the extension, because a `.webp` may hold either
  /// a still or an animation and the container is the thing that knows.
  /// `webp` covers both, deliberately: a still WebP is a one-frame animation,
  /// and going down the sticker path is how it keeps its alpha.
  static const stickerCodecs = {'gif', 'apng', 'webp', 'webp_anim'};

  /// What kind of thing a file with these facts is.
  ///
  /// One rule in one place, called both by the probe that first reads a file
  /// and by the decoder that reads a project back — so a GIF imported by a
  /// version that had never heard of stickers opens as one, with no migration
  /// step and nothing to remember to run.
  static MediaKind kindFor({
    required bool hasVideo,
    required Tick duration,
    String? videoCodec,
  }) {
    if (!hasVideo) return MediaKind.audio;
    if (videoCodec != null && stickerCodecs.contains(videoCodec)) {
      return MediaKind.sticker;
    }
    // No duration and a picture is a still: one frame, and nothing to seek.
    return duration.raw == 0 ? MediaKind.image : MediaKind.video;
  }

  MediaProbe copyWith({
    MediaKind? kind,
    Tick? duration,
    int? width,
    int? height,
    Rational? frameRate,
    bool? variableFrameRate,
    int? rotationDegrees,
    Rational? pixelAspect,
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
        pixelAspect: pixelAspect ?? this.pixelAspect,
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
      other.pixelAspect == pixelAspect &&
      other.hasVideo == hasVideo &&
      other.hasAudio == hasAudio &&
      other.audioChannels == audioChannels &&
      other.audioSampleRate == audioSampleRate &&
      other.videoCodec == videoCodec &&
      other.audioCodec == audioCodec;

  @override
  int get hashCode => Object.hash(kind, duration.raw, width, height, frameRate,
      variableFrameRate, rotationDegrees, pixelAspect, hasVideo, hasAudio,
      audioChannels, audioSampleRate, videoCodec, audioCodec);
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
