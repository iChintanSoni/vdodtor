import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vdodtor/media/peaks.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor_engine/vdodtor_engine.dart';

/// Quantises a sample the way the engine does.
int quantise(double value) =>
    (value * 32767).round().clamp(-32767, 32767);

/// A pyramid built the way the engine builds one: level 0 as given, every
/// level above folding pairs of the one below and keeping the extremes.
///
/// The fold is written out here rather than shared with anything, because
/// these tests are about what a *reader* does with a well-formed pyramid. That
/// the engine's writer produces one is `vd_peaks_test.c`'s business, and a
/// helper that borrowed the reader's own idea of the shape would agree with it
/// whatever either of them did.
NativePeaks nativePyramid(
  List<(double, double)> level0, {
  int framesPerBucket = 128,
  int sampleRate = 48000,
}) {
  var level = [for (final (low, high) in level0) (quantise(low), quantise(high))];
  final counts = <int>[level.length];
  final all = <int>[];
  for (final (low, high) in level) {
    all..add(low)..add(high);
  }

  while (level.length > 1) {
    final folded = <(int, int)>[];
    for (var i = 0; i < level.length; i += 2) {
      final a = level[i];
      final b = i + 1 < level.length ? level[i + 1] : a;
      folded.add((math.min(a.$1, b.$1), math.max(a.$2, b.$2)));
    }
    level = folded;
    counts.add(level.length);
    for (final (low, high) in level) {
      all..add(low)..add(high);
    }
  }

  final frames = level0.length * framesPerBucket;
  return NativePeaks(
    framesPerBucket: framesPerBucket,
    sampleRate: sampleRate,
    channels: 2,
    frameCount: frames,
    durationTicks:
        frames * Timebase.project.ticksPerSecond ~/ sampleRate,
    bucketCounts: counts,
    buckets: Int16List.fromList(all),
  );
}

PeakPyramid pyramid(
  List<(double, double)> level0, {
  int framesPerBucket = 128,
  int sampleRate = 48000,
  MediaStamp stamp = MediaStamp.unknown,
}) =>
    PeakPyramid.fromNative(
      nativePyramid(level0,
          framesPerBucket: framesPerBucket, sampleRate: sampleRate),
      stamp: stamp,
    );

/// [count] buckets at a steady `±level`, with a single one at `±spike`.
List<(double, double)> steadyWithSpike(
  int count, {
  double level = 0.1,
  double spike = 1,
  required int at,
}) =>
    [
      for (var i = 0; i < count; i++)
        i == at ? (-spike, spike) : (-level, level),
    ];
