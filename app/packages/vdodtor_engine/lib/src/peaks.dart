/// The shape of a file's sound, at every resolution a timeline draws it.
library;

import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.g.dart';
import 'native.dart';

/// A pyramid of min/max pairs, straight out of the engine.
///
/// Level 0 holds one pair per [framesPerBucket] audio frames; each level above
/// folds pairs of the one below, so level n's bucket spans
/// `framesPerBucket << n`. [buckets] is every level concatenated finest-first,
/// two `int16` per bucket — the minimum then the maximum sample in it, scaled
/// by 32767.
///
/// Plain data, deliberately: what to do with it, where to keep it and how to
/// draw it are all the app's business, and this package holds no opinion about
/// any of them.
final class NativePeaks {
  const NativePeaks({
    required this.framesPerBucket,
    required this.sampleRate,
    required this.channels,
    required this.frameCount,
    required this.durationTicks,
    required this.bucketCounts,
    required this.buckets,
  });

  final int framesPerBucket;
  final int sampleRate;
  final int channels;
  final int frameCount;
  final int durationTicks;

  /// Buckets in each level, finest first. Never empty for a successful
  /// analysis.
  final List<int> bucketCounts;

  /// `2 * sum(bucketCounts)` values: min, max, min, max…
  final Int16List buckets;

  int get levelCount => bucketCounts.length;

  @override
  String toString() => 'NativePeaks(${bucketCounts.length} levels, '
      '${buckets.length ~/ 2} buckets)';
}

/// The file has no audio. Silent video lands here, and it is not a failure.
const int _noAudioStream = -2; // VD_ERR_NO_STREAMS

/// Reading the envelope of a file's audio.
abstract final class Peaks {
  /// Analyses [path] on a background isolate.
  ///
  /// This decodes the file's audio end to end, so it costs about what playing
  /// it through at full speed costs a CPU — seconds for a long recording. The
  /// UI isolate must never wait on it.
  ///
  /// Returns null for a file with no sound. Throws [EngineException] when the
  /// file will not open or its audio will not decode.
  static Future<NativePeaks?> analyze(String path) =>
      Isolate.run(() => analyzeSync(path));

  /// [analyze], on the calling isolate. For tests and command-line tools.
  static NativePeaks? analyzeSync(String path) {
    if (path.isEmpty) throw const EngineException('empty media path');

    return using((arena) {
      final out = arena<VdPeaks>();
      final nativePath = path.toNativeUtf8(allocator: arena);
      final result = bindings.vd_peaks_analyze(nativePath.cast<Char>(), out);

      if (result == _noAudioStream) return null;
      if (result != 0) {
        throw EngineException(_resultString(result), code: result, path: path);
      }

      try {
        final peaks = out.ref;
        final counts = [
          for (var i = 0; i < peaks.level_count; i++) peaks.bucket_counts[i],
        ];
        return NativePeaks(
          framesPerBucket: peaks.frames_per_bucket,
          sampleRate: peaks.sample_rate,
          channels: peaks.channels,
          frameCount: peaks.frame_count,
          durationTicks: peaks.duration,
          bucketCounts: counts,
          // Copied out before the native buffer is freed, and copied whole:
          // the levels are contiguous in the engine's allocation and stay
          // contiguous here, so a level is a range rather than a list of
          // lists.
          buckets: Int16List.fromList(
              peaks.buckets.asTypedList(peaks.bucket_total * 2)),
        );
      } finally {
        bindings.vd_peaks_free(out);
      }
    });
  }

  static String _resultString(int code) {
    final ptr = bindings.vd_result_string(code);
    return ptr == nullptr
        ? 'unknown engine error'
        : ptr.cast<Utf8>().toDartString();
  }
}
