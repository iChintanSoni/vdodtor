import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'bindings.g.dart';
import 'native.dart';

/// What the engine is doing right now. Mirrors `VdPlaybackState`.
enum PlaybackState { idle, playing, paused, ended }

/// How a clip is placed when its aspect does not match the project's.
///
/// Order matches `VdFitMode` in vd_compositor.h — the index crosses the FFI
/// boundary as an integer, so these may be appended to and never reordered.
enum FitMode { contain, cover, stretch, blurFill }

/// Where a clip sits inside the frame, and how much of it shows.
///
/// Plain numbers, like everything else that crosses this boundary. The
/// defaults are the identity, and they match what the engine does with a
/// transform nobody set.
@immutable
class EngineTransform {
  const EngineTransform({
    this.offsetX = 0,
    this.offsetY = 0,
    this.scale = 1,
    this.rotationDegrees = 0,
    this.cropX = 0,
    this.cropY = 0,
    this.cropWidth = 1,
    this.cropHeight = 1,
    this.flipHorizontal = false,
    this.flipVertical = false,
  });

  static const identity = EngineTransform();

  /// Offset from the centre of the output, as a fraction of its own width and
  /// height.
  final double offsetX;
  final double offsetY;

  /// Multiplier on the fitted size.
  final double scale;

  /// Extra clockwise rotation, on top of the source's own orientation.
  final double rotationDegrees;

  /// The part of the display-oriented source to show, normalised.
  final double cropX;
  final double cropY;
  final double cropWidth;
  final double cropHeight;

  final bool flipHorizontal;
  final bool flipVertical;
}

/// One point on a clip's volume line.
///
/// [sourceTicks] is in the source's own time, the same coordinate as
/// [EngineClip.sourceInTicks] — so trimming a clip slides its window over the
/// curve rather than dragging the curve along with it.
@immutable
class EngineVolumePoint {
  const EngineVolumePoint(this.sourceTicks, this.value);

  final int sourceTicks;

  /// Linear gain, multiplied with [EngineClip.gain].
  final double value;
}

/// How a clip arrives and how it leaves. Order matches `VdAnimPreset` in
/// vd_anim.h — the index crosses the FFI boundary as an integer, so these may
/// be appended to and never reordered.
///
/// A preset names the direction the clip *travels*: `slideUp` rises into place
/// on the way in and carries on upwards on the way out.
enum EngineAnimPreset {
  none,
  fade,
  slideUp,
  slideDown,
  slideLeft,
  slideRight,
  pop,
  zoom,
  spin,
  typewriter,
}

/// The entrance and exit on one clip.
///
/// Evaluated by the engine per frame and composed with the clip's own
/// transform rather than replacing it, so a clip that was placed somewhere
/// animates from where it was placed.
@immutable
class EngineAnimation {
  const EngineAnimation({
    this.inPreset = EngineAnimPreset.none,
    this.inTicks = 0,
    this.outPreset = EngineAnimPreset.none,
    this.outTicks = 0,
  });

  static const none = EngineAnimation();

  final EngineAnimPreset inPreset;
  final int inTicks;
  final EngineAnimPreset outPreset;
  final int outTicks;
}

/// Where each line sits inside a caption. Order matches `VdTextAlign` in
/// vd_text.h — the index crosses the FFI boundary as an integer.
enum EngineTextAlign { left, center, right }

/// A caption, described to the engine.
///
/// Nothing here is measured in pixels: sizes, offsets, padding and spacing are
/// fractions of the output height or of the font size they hang off, so a
/// project cut at 1080p and exported at 4K puts the same words in the same
/// place at the same size.
///
/// Colours are 0xAARRGGBB. Alpha 0 switches the two optional parts off — a
/// shadow colour with no alpha casts no shadow, a box colour with no alpha
/// draws no box — which is one rule rather than two booleans that could
/// disagree with the colours beside them.
@immutable
class EngineText {
  const EngineText({
    required this.text,
    this.font = '',
    this.size = 0.08,
    this.color = 0xFFFFFFFF,
    this.strokeColor = 0xFF000000,
    this.strokeWidth = 0,
    this.shadowColor = 0,
    this.shadowDx = 0,
    this.shadowDy = 0.04,
    this.shadowBlur = 0.06,
    this.boxColor = 0,
    this.boxPadding = 0.25,
    this.boxRadius = 0.15,
    this.letterSpacing = 0,
    this.lineSpacing = 1,
    this.maxWidth = 0.9,
    this.alignment = EngineTextAlign.center,
  });

  final String text;

  /// Family name as the engine knows it, from `TextFonts.families`. Empty
  /// falls back to the system's own face.
  final String font;

  /// Cap height as a fraction of the output height.
  final double size;

  final int color;

  final int strokeColor;

  /// Fraction of the font size. 0 for no outline.
  final double strokeWidth;

  final int shadowColor;
  final double shadowDx;
  final double shadowDy;
  final double shadowBlur;

  final int boxColor;
  final double boxPadding;
  final double boxRadius;

  /// Fraction of the font size; negative tightens.
  final double letterSpacing;

  /// Multiple of the font's own line height.
  final double lineSpacing;

  /// How much of the output's width the block may fill before it wraps.
  final double maxWidth;

  final EngineTextAlign alignment;
}

/// What a shape is. Order matches `VdShapeKind` in vd_shape.h — the index
/// crosses the FFI boundary as an integer.
enum EngineShapeKind { rectangle, ellipse, line, arrow }

/// A shape, described to the engine.
///
/// **Every length here is a fraction of the output height** — not of the
/// width, and not one of each, so a square stays square and a circle stays
/// round whatever shape the project's frame is. That differs from
/// [EngineText], where everything hangs off the font size, because a caption
/// has one size to hang things off and a shape has two.
///
/// Colours are 0xAARRGGBB and alpha 0 means off, exactly as for a caption: no
/// fill, no outline, no shadow.
@immutable
class EngineShape {
  const EngineShape({
    this.kind = EngineShapeKind.rectangle,
    this.width = 0.5,
    this.height = 0.28,
    this.corner = 0,
    this.fillColor = 0xFFFFFFFF,
    this.strokeColor = 0xFF000000,
    this.strokeWidth = 0,
    this.shadowColor = 0,
    this.shadowDx = 0,
    this.shadowDy = 0,
    this.shadowBlur = 0,
    this.headSize = 0.25,
  });

  final EngineShapeKind kind;

  /// The box the shape is drawn in, as fractions of the output height.
  final double width;
  final double height;

  /// 0 square, 1 as round as the box allows. Rectangles only.
  final double corner;

  /// Ignored by [EngineShapeKind.line] and [EngineShapeKind.arrow], which have
  /// no interior — for those the stroke *is* the shape.
  final int fillColor;

  final int strokeColor;
  final double strokeWidth;

  final int shadowColor;
  final double shadowDx;
  final double shadowDy;
  final double shadowBlur;

  /// How much of an arrow is head, as a fraction of its length.
  final double headSize;
}

/// One clip on the render list the engine composites from.
///
/// This is deliberately not the document model: the engine gets flat clips
/// with paths and times, and knows nothing about undo, media bins or track
/// names. That is what lets a different backend implement the same contract.
@immutable
class EngineClip {
  const EngineClip({
    this.path,
    this.text,
    this.shape,
    this.sticker = false,
    required this.startTicks,
    required this.durationTicks,
    this.sourceInTicks = 0,
    this.track = 0,
    this.opacity = 1.0,
    this.fit = FitMode.contain,
    this.transform = EngineTransform.identity,
    this.animation = EngineAnimation.none,
    this.hasVideo = true,
    this.gain = 1.0,
    this.fadeInTicks = 0,
    this.fadeOutTicks = 0,
    this.volumePoints = const [],
  }) : assert(
            (path == null ? 0 : 1) +
                    (text == null ? 0 : 1) +
                    (shape == null ? 0 : 1) ==
                1,
            'a clip is a window onto a file or one of the things the engine '
            'draws, never two of them and never none');

  /// The source file, or null for a clip the engine generates.
  final String? path;

  /// A caption instead of a file. Null for every clip that has a [path].
  final EngineText? text;

  /// A shape instead of a file. Null for every clip that has a [path] or a
  /// [text] — the three are exclusive.
  final EngineShape? shape;

  /// True when [path] is an animated overlay — a GIF, an animated WebP, an
  /// APNG — rather than video. The engine decodes it whole and loops it
  /// instead of seeking in it.
  ///
  /// A flag beside the path rather than a fourth exclusive field, because a
  /// sticker *is* a file: it has a path, it can be missing, and everything
  /// about how it is addressed on the timeline is a video clip's. What differs
  /// is how the engine opens it.
  final bool sticker;

  final int startTicks;
  final int durationTicks;
  final int sourceInTicks;

  /// Compositing order: lower renders first, so 0 is the main track.
  final int track;

  final double opacity;
  final FitMode fit;
  final EngineTransform transform;

  /// How it arrives and how it leaves.
  final EngineAnimation animation;

  /// False for a clip that only makes a sound. The compositor skips it rather
  /// than opening a decoder for a picture that is not there.
  final bool hasVideo;

  /// Linear gain, 0 for silent. Mute has already been folded in by the time a
  /// clip gets here — the engine is told a number, not a state.
  final double gain;

  final int fadeInTicks;
  final int fadeOutTicks;

  /// The volume line, sorted by [EngineVolumePoint.sourceTicks] and empty for
  /// a clip nobody has automated. Copied into native memory on set_timeline,
  /// like [path] is.
  final List<EngineVolumePoint> volumePoints;
}

/// The render list plus the output format.
@immutable
class EngineTimeline {
  const EngineTimeline({
    required this.width,
    required this.height,
    required this.frameRateNumerator,
    required this.frameRateDenominator,
    this.clips = const [],
  });

  final int width;
  final int height;
  final int frameRateNumerator;
  final int frameRateDenominator;
  final List<EngineClip> clips;
}

/// A snapshot of what the engine is doing. Read cheaply, as often as wanted.
@immutable
class EngineStats {
  const EngineStats({
    required this.framesPresented,
    required this.framesLate,
    required this.compositeMsAvg,
    required this.presentFps,
    required this.positionTicks,
    required this.durationTicks,
    required this.state,
    required this.openDecoders,
    required this.activeLayers,
    required this.lastSeekMs,
    required this.audioAvailable,
    required this.audioUnderruns,
    required this.audioBufferedFrames,
    required this.forcedRenders,
    required this.clockRegressions,
    required this.textRasters,
    required this.shapeRasters,
    required this.stickerFrames,
    required this.stickerOpens,
    required this.stickerBytes,
  });

  final int framesPresented;

  /// Frames whose deadline had already passed when they were ready. The
  /// honest measure of whether playback is keeping up.
  final int framesLate;

  final double compositeMsAvg;
  final double presentFps;
  final int positionTicks;
  final int durationTicks;
  final PlaybackState state;
  final int openDecoders;
  final int activeLayers;
  final double lastSeekMs;

  /// True when the timeline has audio, and therefore when the audio clock is
  /// what playback is following.
  final bool audioAvailable;

  /// Times the device asked for audio that had not been decoded yet. Unlike a
  /// late video frame, every one of these is audible.
  final int audioUnderruns;

  final int audioBufferedFrames;

  /// Renders that something asked for rather than the playhead reaching a new
  /// frame. A steady stream during playback means spurious repainting.
  final int forcedRenders;

  /// Times the playhead was seen to move backwards during playback.
  final int clockRegressions;

  /// Captions laid out since the engine started. It should tick once per
  /// caption per edit that changed one, and never during playback.
  final int textRasters;

  /// Shapes drawn, read the same way and counted apart from captions: laying
  /// out text is the expensive one, and folding a rectangle into that number
  /// would blunt the measurement.
  final int shapeRasters;

  /// Times a sticker put a *different* frame on screen. It should tick at the
  /// sticker's own rate rather than the project's — that is what says an
  /// animated overlay is being retimed instead of resampled.
  final int stickerFrames;

  /// Animated overlays decoded whole since the engine started, and how much
  /// decoded RGBA they are holding.
  final int stickerOpens;
  final int stickerBytes;
}

/// Drives the native preview engine and owns its Flutter texture.
///
/// Transport goes over `dart:ffi`, which is a direct call. The single method
/// channel hop is texture registration, because only the plugin registrar can
/// mint a texture id.
class PreviewEngine extends ChangeNotifier {
  PreviewEngine._(this._handle, this._textureId);

  static const MethodChannel _channel = MethodChannel('vdodtor/engine');

  Pointer<Void> _handle;
  int? _textureId;
  bool _disposed = false;

  /// Feed this to a [Texture] widget. Null once disposed.
  int? get textureId => _textureId;

  /// Creates the engine and registers its preview texture.
  static Future<PreviewEngine> create() async {
    final resultPtr = calloc<Int32>();
    try {
      final handle = bindings.vd_engine_create(resultPtr).cast<Void>();
      if (handle == nullptr) {
        throw EngineException('the native engine could not start',
            code: resultPtr.value);
      }
      final textureId = await _channel.invokeMethod<int>('registerTexture', {
        'engine': handle.address,
      });
      if (textureId == null) {
        bindings.vd_engine_destroy(handle.cast());
        throw const EngineException('the preview texture could not be registered');
      }
      return PreviewEngine._(handle, textureId);
    } finally {
      calloc.free(resultPtr);
    }
  }

  void _checkAlive() {
    if (_disposed) {
      throw StateError('this PreviewEngine has been disposed');
    }
  }

  /// One caption in native memory, borrowed from [arena] for the length of the
  /// call. Field for field with `VdTextSpec`, and deliberately not clever
  /// about it: a missing assignment here is a property that silently reverts
  /// to whatever the arena's memory happened to hold.
  static Pointer<VdTextSpec> _textSpec(Arena arena, EngineText text) {
    final spec = arena<VdTextSpec>();
    spec.ref
      ..text = text.text.toNativeUtf8(allocator: arena).cast<Char>()
      ..font = text.font.toNativeUtf8(allocator: arena).cast<Char>()
      ..size = text.size
      ..color = text.color
      ..stroke_color = text.strokeColor
      ..stroke_width = text.strokeWidth
      ..shadow_color = text.shadowColor
      ..shadow_dx = text.shadowDx
      ..shadow_dy = text.shadowDy
      ..shadow_blur = text.shadowBlur
      ..box_color = text.boxColor
      ..box_padding = text.boxPadding
      ..box_radius = text.boxRadius
      ..letter_spacing = text.letterSpacing
      ..line_spacing = text.lineSpacing
      ..max_width = text.maxWidth
      ..alignAsInt = text.alignment.index;
    return spec;
  }

  /// One shape in native memory, on the same terms and with the same warning:
  /// a field left out here reads back whatever the arena happened to hold.
  static Pointer<VdShapeSpec> _shapeSpec(Arena arena, EngineShape shape) {
    final spec = arena<VdShapeSpec>();
    spec.ref
      ..kindAsInt = shape.kind.index
      ..width = shape.width
      ..height = shape.height
      ..corner = shape.corner
      ..fill_color = shape.fillColor
      ..stroke_color = shape.strokeColor
      ..stroke_width = shape.strokeWidth
      ..shadow_color = shape.shadowColor
      ..shadow_dx = shape.shadowDx
      ..shadow_dy = shape.shadowDy
      ..shadow_blur = shape.shadowBlur
      ..head_size = shape.headSize;
    return spec;
  }

  /// Replaces the render list. Safe while playing; the playhead is kept.
  void setTimeline(EngineTimeline timeline) {
    _checkAlive();
    final arena = Arena();
    try {
      final clips = arena<VdTimelineClip>(timeline.clips.length.clamp(1, 1 << 20));
      for (var i = 0; i < timeline.clips.length; i++) {
        final clip = timeline.clips[i];
        final entry = clips[i];
        entry.path = clip.path == null
            ? nullptr
            : clip.path!.toNativeUtf8(allocator: arena).cast<Char>();
        // Allocated from the same arena as the paths, for the same reason:
        // the engine copies the spec, strings and all, before set_timeline
        // returns.
        entry.text = clip.text == null
            ? nullptr
            : _textSpec(arena, clip.text!);
        entry.shape = clip.shape == null
            ? nullptr
            : _shapeSpec(arena, clip.shape!);
        entry.sticker = clip.sticker;
        entry.start = clip.startTicks;
        entry.duration = clip.durationTicks;
        entry.source_in = clip.sourceInTicks;
        entry.track = clip.track;
        entry.opacity = clip.opacity;
        entry.fitAsInt = clip.fit.index;
        entry.has_video = clip.hasVideo;
        entry.gain = clip.gain;
        entry.fade_in = clip.fadeInTicks;
        entry.fade_out = clip.fadeOutTicks;

        // Allocated from the same arena as the paths and freed with them: the
        // engine copies the array before set_timeline returns.
        if (clip.volumePoints.isEmpty) {
          entry.volume_points = nullptr;
          entry.volume_point_count = 0;
        } else {
          final points = arena<VdVolumePoint>(clip.volumePoints.length);
          for (var p = 0; p < clip.volumePoints.length; p++) {
            points[p].source_time = clip.volumePoints[p].sourceTicks;
            points[p].value = clip.volumePoints[p].value;
          }
          entry.volume_points = points;
          entry.volume_point_count = clip.volumePoints.length;
        }

        final transform = clip.transform;
        entry.transform.offset_x = transform.offsetX;
        entry.transform.offset_y = transform.offsetY;
        entry.transform.scale = transform.scale;
        entry.transform.rotation_degrees = transform.rotationDegrees;
        entry.transform.crop_x = transform.cropX;
        entry.transform.crop_y = transform.cropY;
        entry.transform.crop_w = transform.cropWidth;
        entry.transform.crop_h = transform.cropHeight;
        entry.transform.flip_h = transform.flipHorizontal;
        entry.transform.flip_v = transform.flipVertical;

        final animation = clip.animation;
        entry.anim.in_presetAsInt = animation.inPreset.index;
        entry.anim.in_duration = animation.inTicks;
        entry.anim.out_presetAsInt = animation.outPreset.index;
        entry.anim.out_duration = animation.outTicks;
      }

      final native = arena<VdTimeline>();
      native.ref.width = timeline.width;
      native.ref.height = timeline.height;
      native.ref.frame_rate.num = timeline.frameRateNumerator;
      native.ref.frame_rate.den = timeline.frameRateDenominator;
      native.ref.clips = timeline.clips.isEmpty ? nullptr : clips;
      native.ref.clip_count = timeline.clips.length;

      final result = bindings.vd_engine_set_timeline(_handle.cast(), native);
      if (result != 0) {
        throw EngineException('the engine rejected the timeline', code: result);
      }
    } finally {
      arena.releaseAll();
    }
    notifyListeners();
  }

  void play() {
    _checkAlive();
    bindings.vd_engine_play(_handle.cast());
    notifyListeners();
  }

  void pause() {
    _checkAlive();
    bindings.vd_engine_pause(_handle.cast());
    notifyListeners();
  }

  /// Moves the playhead. Renders a frame even while paused, which is what
  /// makes scrubbing show anything.
  void seek(int ticks) {
    _checkAlive();
    bindings.vd_engine_seek(_handle.cast(), ticks);
    notifyListeners();
  }

  int get positionTicks =>
      _disposed ? 0 : bindings.vd_engine_position(_handle.cast());

  int get durationTicks =>
      _disposed ? 0 : bindings.vd_engine_duration(_handle.cast());

  PlaybackState get state {
    if (_disposed) return PlaybackState.idle;
    final raw = bindings.vd_engine_state(_handle.cast());
    return raw >= 0 && raw < PlaybackState.values.length
        ? PlaybackState.values[raw]
        : PlaybackState.idle;
  }

  bool get isPlaying => state == PlaybackState.playing;

  EngineStats get stats {
    if (_disposed) {
      return const EngineStats(
        framesPresented: 0,
        framesLate: 0,
        compositeMsAvg: 0,
        presentFps: 0,
        positionTicks: 0,
        durationTicks: 0,
        state: PlaybackState.idle,
        openDecoders: 0,
        activeLayers: 0,
        lastSeekMs: 0,
        audioAvailable: false,
        audioUnderruns: 0,
        audioBufferedFrames: 0,
        forcedRenders: 0,
        clockRegressions: 0,
        textRasters: 0,
        shapeRasters: 0,
        stickerFrames: 0,
        stickerOpens: 0,
        stickerBytes: 0,
      );
    }
    final out = calloc<VdEngineStats>();
    try {
      bindings.vd_engine_stats(_handle.cast(), out);
      final s = out.ref;
      return EngineStats(
        framesPresented: s.frames_presented,
        framesLate: s.frames_late,
        compositeMsAvg: s.composite_ms_avg,
        presentFps: s.present_fps,
        positionTicks: s.position,
        durationTicks: s.duration,
        state: s.state >= 0 && s.state < PlaybackState.values.length
            ? PlaybackState.values[s.state]
            : PlaybackState.idle,
        openDecoders: s.open_decoders,
        activeLayers: s.active_layers,
        lastSeekMs: s.last_seek_ms,
        audioAvailable: s.audio_available,
        audioUnderruns: s.audio_underruns,
        audioBufferedFrames: s.audio_buffered_frames,
        forcedRenders: s.forced_renders,
        clockRegressions: s.clock_regressions,
        textRasters: s.text_rasters,
        shapeRasters: s.shape_rasters,
        stickerFrames: s.sticker_frames,
        stickerOpens: s.sticker_opens,
        stickerBytes: s.sticker_bytes,
      );
    } finally {
      calloc.free(out);
    }
  }

  /// Writes the last composited frame to [path] as PNG. Verification aid.
  void dumpPng(String path) {
    _checkAlive();
    final native = path.toNativeUtf8();
    try {
      bindings.vd_engine_dump_png(_handle.cast(), native.cast<Char>());
    } finally {
      calloc.free(native);
    }
  }

  /// Tears the engine down in the one order that is safe: unregister the
  /// texture so Flutter stops asking for frames, then destroy the engine,
  /// which joins its render thread before freeing anything.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final id = _textureId;
    _textureId = null;
    if (id != null) {
      await _channel.invokeMethod<void>('unregisterTexture', {'textureId': id});
    }
    bindings.vd_engine_destroy(_handle.cast());
    _handle = nullptr;
    super.dispose();
  }
}
