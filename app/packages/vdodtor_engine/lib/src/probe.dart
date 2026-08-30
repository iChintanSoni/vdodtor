/// Reading what is in a media file, without decoding it.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'bindings.g.dart';
import 'native.dart';

export 'bindings.g.dart' show VdProbeInfo, VdRational;

/// What the engine found in a media file. Plain data; the app turns this into
/// its own `MediaProbe`.
final class NativeProbe {
  const NativeProbe({
    required this.hasVideo,
    required this.hasAudio,
    required this.durationTicks,
    required this.width,
    required this.height,
    required this.rotationDegrees,
    required this.frameRateNumerator,
    required this.frameRateDenominator,
    required this.variableFrameRate,
    required this.audioChannels,
    required this.audioSampleRate,
    required this.pixelAspectNumerator,
    required this.pixelAspectDenominator,
    required this.videoCodec,
    required this.audioCodec,
    required this.formatName,
  });

  final bool hasVideo;
  final bool hasAudio;

  /// Duration in project ticks (120000/s), matching the document model.
  final int durationTicks;

  final int width;
  final int height;

  /// Clockwise degrees to rotate the decoded frame for correct display.
  final int rotationDegrees;

  final int frameRateNumerator;
  final int frameRateDenominator;
  final bool variableFrameRate;

  final int audioChannels;
  final int audioSampleRate;
  final int pixelAspectNumerator;
  final int pixelAspectDenominator;

  final String videoCodec;
  final String audioCodec;
  final String formatName;

  @override
  String toString() => 'NativeProbe($formatName, ${width}x$height, '
      '$frameRateNumerator/$frameRateDenominator fps, '
      '${durationTicks / 120000}s)';
}

/// Entry point to the native engine.
class VdodtorEngine {
  VdodtorEngine._();

  /// True when the native library is present and callable. Checked once at
  /// startup so a broken build fails with a clear message rather than a
  /// mid-edit crash.
  static bool get isAvailable {
    try {
      // vd_ticks_per_frame(30/1) is 4000 by definition of the timebase.
      return _ticksPerFrame(30, 1) == 4000;
    } on ArgumentError {
      return false;
    }
  }

  static int _ticksPerFrame(int num, int den) => using((arena) {
        final r = arena<VdRational>();
        r.ref.num = num;
        r.ref.den = den;
        return bindings.vd_ticks_per_frame(r.ref);
      });

  /// Ticks per frame at `numerator/denominator` fps, or 0 if the project
  /// timebase cannot represent that rate exactly.
  static int ticksPerFrame(int numerator, int denominator) =>
      _ticksPerFrame(numerator, denominator);

  /// Reads what is in the file at [path].
  ///
  /// Synchronous and fast — it reads container headers, it does not decode —
  /// but it does touch the disk, so callers importing many files at once
  /// should run it off the UI isolate.
  static NativeProbe probeFile(String path) {
    if (path.isEmpty) {
      throw const EngineException('empty media path');
    }
    return using((arena) {
      final info = arena<VdProbeInfo>();
      final nativePath = path.toNativeUtf8(allocator: arena);
      final result =
          bindings.vd_probe_file(nativePath.cast<Char>(), info);

      if (result != 0) {
        throw EngineException(_resultString(result), code: result, path: path);
      }

      final probe = info.ref;
      return NativeProbe(
        hasVideo: probe.has_video,
        hasAudio: probe.has_audio,
        durationTicks: probe.duration,
        width: probe.width,
        height: probe.height,
        rotationDegrees: probe.rotation_degrees,
        frameRateNumerator: probe.frame_rate.num,
        frameRateDenominator: probe.frame_rate.den,
        variableFrameRate: probe.variable_frame_rate,
        audioChannels: probe.audio_channels,
        audioSampleRate: probe.audio_sample_rate,
        pixelAspectNumerator: probe.pixel_aspect.num,
        pixelAspectDenominator: probe.pixel_aspect.den,
        videoCodec: _readString(probe.video_codec, 32),
        audioCodec: _readString(probe.audio_codec, 32),
        formatName: _readString(probe.format_name, 64),
      );
    });
  }

  static String _resultString(int code) {
    final ptr = bindings.vd_result_string(code);
    return ptr == nullptr ? 'unknown engine error' : ptr.cast<Utf8>().toDartString();
  }

  static String _readString(Array<Char> chars, int capacity) {
    final bytes = <int>[];
    for (var i = 0; i < capacity; i++) {
      final c = chars[i];
      if (c == 0) break;
      bytes.add(c);
    }
    return String.fromCharCodes(bytes);
  }

  /// True on the platforms the engine is built for today.
  static bool get isSupportedPlatform => Platform.isMacOS;
}
