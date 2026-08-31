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

/// One clip on the render list the engine composites from.
///
/// This is deliberately not the document model: the engine gets flat clips
/// with paths and times, and knows nothing about undo, media bins or track
/// names. That is what lets a different backend implement the same contract.
@immutable
class EngineClip {
  const EngineClip({
    required this.path,
    required this.startTicks,
    required this.durationTicks,
    this.sourceInTicks = 0,
    this.track = 0,
    this.opacity = 1.0,
    this.fit = FitMode.contain,
    this.transform = EngineTransform.identity,
    this.hasVideo = true,
    this.gain = 1.0,
    this.fadeInTicks = 0,
    this.fadeOutTicks = 0,
  });

  final String path;
  final int startTicks;
  final int durationTicks;
  final int sourceInTicks;

  /// Compositing order: lower renders first, so 0 is the main track.
  final int track;

  final double opacity;
  final FitMode fit;
  final EngineTransform transform;

  /// False for a clip that only makes a sound. The compositor skips it rather
  /// than opening a decoder for a picture that is not there.
  final bool hasVideo;

  /// Linear gain, 0 for silent. Mute has already been folded in by the time a
  /// clip gets here — the engine is told a number, not a state.
  final double gain;

  final int fadeInTicks;
  final int fadeOutTicks;
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

  /// Replaces the render list. Safe while playing; the playhead is kept.
  void setTimeline(EngineTimeline timeline) {
    _checkAlive();
    final arena = Arena();
    try {
      final clips = arena<VdTimelineClip>(timeline.clips.length.clamp(1, 1 << 20));
      for (var i = 0; i < timeline.clips.length; i++) {
        final clip = timeline.clips[i];
        final entry = clips[i];
        entry.path = clip.path.toNativeUtf8(allocator: arena).cast<Char>();
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
