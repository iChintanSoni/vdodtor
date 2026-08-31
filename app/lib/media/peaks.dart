import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../model/time.dart';

/// What a file looked like when its peaks were taken.
///
/// Length and modification time rather than a hash: hashing a two-gigabyte
/// camera file to find out whether a cached waveform is still good costs more
/// than reading the audio again, which is the thing the cache exists to avoid.
/// The pair is what every build system in the world uses for the same reason,
/// and the failure it admits — a file replaced with another of exactly the
/// same length in the same millisecond — is not one anybody meets.
@immutable
final class MediaStamp {
  const MediaStamp({required this.bytes, required this.modifiedMs});

  final int bytes;
  final int modifiedMs;

  static const unknown = MediaStamp(bytes: -1, modifiedMs: -1);

  /// The stamp of [path], or [unknown] when it cannot be reached.
  static Future<MediaStamp> of(String path) async {
    try {
      final stat = await File(path).stat();
      if (stat.type == FileSystemEntityType.notFound) return unknown;
      return MediaStamp(
        bytes: stat.size,
        modifiedMs: stat.modified.millisecondsSinceEpoch,
      );
    } on FileSystemException {
      return unknown;
    }
  }

  bool get isKnown => bytes >= 0;

  /// Whether cached peaks stamped [other] are still peaks of this file.
  ///
  /// An unknown stamp matches nothing, including another unknown one: a file
  /// the app cannot currently see is a file whose waveform it cannot vouch
  /// for, and re-reading is cheap compared with drawing the wrong one.
  bool matches(MediaStamp other) => isKnown && this == other;

  @override
  bool operator ==(Object other) =>
      other is MediaStamp &&
      other.bytes == bytes &&
      other.modifiedMs == modifiedMs;

  @override
  int get hashCode => Object.hash(bytes, modifiedMs);

  @override
  String toString() => 'MediaStamp($bytes bytes, $modifiedMs ms)';
}

/// A peak file that is not one, or is one from a version that no longer
/// exists. Always recoverable by analysing the media again.
final class PeakFormatException implements Exception {
  const PeakFormatException(this.message);

  final String message;

  @override
  String toString() => 'PeakFormatException: $message';
}

/// The envelope of a file's audio, at every resolution a timeline draws it.
///
/// Level 0 holds a minimum and a maximum per [framesPerBucket] audio frames;
/// each level above folds pairs of the one below, keeping the minimum of the
/// minima and the maximum of the maxima. So a drum hit is exactly as tall at
/// the top of the pyramid as at the bottom, and a waveform zoomed out shows
/// the same peaks as one zoomed in. Averaging instead would smooth transients
/// away as the view widens, which reads as a calmer recording rather than as
/// a bug.
///
/// Reading a span costs the same at any zoom: [envelopeInto] picks the level
/// whose bucket is closest to a pixel and reads two or three buckets for each
/// one. That is the whole reason for the pyramid — a half-hour interview drawn
/// from level 0 alone would scan five million values to paint a thousand
/// pixels, on every repaint, on every lane.
@immutable
final class PeakPyramid {
  PeakPyramid({
    required this.framesPerBucket,
    required this.sampleRate,
    required this.channels,
    required this.frameCount,
    required this.duration,
    required List<int> bucketCounts,
    required this.buckets,
    this.stamp = MediaStamp.unknown,
  })  : bucketCounts = List.unmodifiable(bucketCounts),
        _levelOffsets = _offsetsOf(bucketCounts) {
    if (bucketCounts.isEmpty) {
      throw const PeakFormatException('a pyramid with no levels');
    }
    final expected = bucketCounts.reduce((a, b) => a + b) * 2;
    if (buckets.length != expected) {
      throw PeakFormatException(
          'expected $expected values, got ${buckets.length}');
    }
  }

  /// Adopts what the engine produced. The bucket data is taken as it stands —
  /// the engine's layout and this one are the same layout, which is what keeps
  /// analysing a file and reading it back from the cache indistinguishable.
  factory PeakPyramid.fromNative(NativePeaks native, {MediaStamp? stamp}) =>
      PeakPyramid(
        framesPerBucket: native.framesPerBucket,
        sampleRate: native.sampleRate,
        channels: native.channels,
        frameCount: native.frameCount,
        duration: Tick(native.durationTicks),
        bucketCounts: native.bucketCounts,
        buckets: native.buckets,
        stamp: stamp ?? MediaStamp.unknown,
      );

  /// Level 0's bucket size, in audio frames. Level n's is this `<< n`.
  final int framesPerBucket;

  final int sampleRate;

  /// Channels the peaks were taken across — the extremes are over every
  /// sample of every channel, not over a downmix.
  final int channels;

  final int frameCount;
  final Tick duration;

  /// Buckets in each level, finest first.
  final List<int> bucketCounts;

  /// Every level concatenated finest-first, two values per bucket: the
  /// minimum then the maximum, scaled by [_fullScale].
  final Int16List buckets;

  /// What the media file looked like when this was taken.
  final MediaStamp stamp;

  final List<int> _levelOffsets;

  static const int _fullScale = 32767;

  int get levelCount => bucketCounts.length;

  static List<int> _offsetsOf(List<int> counts) {
    final offsets = <int>[];
    var total = 0;
    for (final count in counts) {
      offsets.add(total);
      total += count;
    }
    return offsets;
  }

  /// Audio frames in [ticks] of source time.
  double framesIn(double ticks) =>
      ticks * sampleRate / Timebase.project.ticksPerSecond;

  /// The level to draw a pixel [framesPerPixel] wide from: the coarsest one
  /// whose bucket still fits inside a pixel.
  ///
  /// Coarsest rather than finest, because a finer level costs proportionally
  /// more reads and cannot show anything more — a pixel is one column either
  /// way. Zoomed in past level 0 there is nothing finer to pick, and the
  /// waveform simply stretches, which is the truth: 2.7 ms is as fine as the
  /// file was measured.
  int levelFor(double framesPerPixel) {
    var level = 0;
    while (level + 1 < levelCount &&
        (framesPerBucket << (level + 1)) <= framesPerPixel) {
      level++;
    }
    return level;
  }

  /// Fills [out] with `2 * pixels` values — a minimum then a maximum in
  /// -1..1 per pixel — for the span starting at source time [from] and
  /// running [ticksPerPixel] per pixel.
  ///
  /// Every bucket a pixel touches is folded into it, never sampled from.
  /// Point-sampling one bucket per pixel is the obvious implementation and it
  /// makes transients flicker in and out as the view scrolls, because whether
  /// a peak is visible then depends on where the pixel grid happens to land.
  ///
  /// Fills with silence outside the file rather than refusing: a clip trimmed
  /// past the end of its source is a thing the timeline can hold, and it draws
  /// as a flat line.
  ///
  /// Takes the buffer rather than returning one because this runs per lane per
  /// repaint, and a timeline that allocates a few thousand floats every frame
  /// is a timeline that stutters while it plays.
  void envelopeInto(
    Float32List out, {
    required Tick from,
    required double ticksPerPixel,
    required int pixels,
  }) {
    assert(out.length >= pixels * 2, 'buffer too small for $pixels pixels');

    final perPixel = framesIn(ticksPerPixel);
    final level = levelFor(perPixel);
    final bucketFrames = (framesPerBucket << level).toDouble();
    final offset = _levelOffsets[level];
    final count = bucketCounts[level];
    final startFrame = framesIn(from.raw.toDouble());

    for (var i = 0; i < pixels; i++) {
      final left = startFrame + i * perPixel;
      var first = (left / bucketFrames).floor();
      var last = ((left + perPixel) / bucketFrames).ceil();
      // A pixel narrower than a bucket still covers one of them.
      if (last <= first) last = first + 1;

      if (last <= 0 || first >= count) {
        out[i * 2] = 0;
        out[i * 2 + 1] = 0;
        continue;
      }
      if (first < 0) first = 0;
      if (last > count) last = count;

      var low = _fullScale;
      var high = -_fullScale;
      for (var bucket = first; bucket < last; bucket++) {
        final at = (offset + bucket) * 2;
        if (buckets[at] < low) low = buckets[at];
        if (buckets[at + 1] > high) high = buckets[at + 1];
      }
      out[i * 2] = low / _fullScale;
      out[i * 2 + 1] = high / _fullScale;
    }
  }

  /// [envelopeInto] with a buffer of its own. For tests and one-off callers.
  Float32List envelope({
    required Tick from,
    required double ticksPerPixel,
    required int pixels,
  }) {
    final out = Float32List(pixels * 2);
    envelopeInto(out, from: from, ticksPerPixel: ticksPerPixel, pixels: pixels);
    return out;
  }

  @override
  bool operator ==(Object other) =>
      other is PeakPyramid &&
      other.framesPerBucket == framesPerBucket &&
      other.sampleRate == sampleRate &&
      other.channels == channels &&
      other.frameCount == frameCount &&
      other.duration == duration &&
      other.stamp == stamp &&
      listEquals(other.bucketCounts, bucketCounts) &&
      _sameBuckets(other.buckets, buckets);

  static bool _sameBuckets(Int16List a, Int16List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(framesPerBucket, frameCount, duration, stamp, buckets.length);

  @override
  String toString() => 'PeakPyramid($levelCount levels, '
      '${buckets.length ~/ 2} buckets, ${duration.raw} ticks)';
}

/// The peak file: a [PeakPyramid] as bytes, and back.
///
/// **Host byte order, on purpose.** These are cache files sitting beside the
/// machine that wrote them, never documents and never shared, and reading a
/// few million samples one `getInt16` at a time to be portable about it would
/// cost more than the analysis the cache exists to skip. The magic and version
/// at the front are what make a file from anywhere else fail cleanly instead
/// of drawing nonsense.
abstract final class PeakFile {
  /// 'VDPK'.
  static const int magic = 0x4b504456;

  /// Bumped whenever the layout or the meaning of anything in it changes.
  /// Every cache file with a different number is thrown away unread, which is
  /// the whole migration story a cache needs.
  static const int version = 1;

  /// Bytes before the per-level bucket counts.
  static const int headerBytes = 56;

  static Uint8List encode(PeakPyramid peaks) {
    final counts = peaks.bucketCounts;
    final bytes = Uint8List(
        headerBytes + counts.length * 4 + peaks.buckets.length * 2);
    final view = ByteData.sublistView(bytes);

    view.setUint32(0, magic, Endian.host);
    view.setUint32(4, version, Endian.host);
    view.setUint32(8, peaks.framesPerBucket, Endian.host);
    view.setUint32(12, peaks.sampleRate, Endian.host);
    view.setUint32(16, peaks.channels, Endian.host);
    view.setUint32(20, counts.length, Endian.host);
    view.setInt64(24, peaks.frameCount, Endian.host);
    view.setInt64(32, peaks.duration.raw, Endian.host);
    view.setInt64(40, peaks.stamp.bytes, Endian.host);
    view.setInt64(48, peaks.stamp.modifiedMs, Endian.host);
    for (var i = 0; i < counts.length; i++) {
      view.setUint32(headerBytes + i * 4, counts[i], Endian.host);
    }

    bytes.setRange(
      headerBytes + counts.length * 4,
      bytes.length,
      Uint8List.sublistView(peaks.buckets),
    );
    return bytes;
  }

  /// Throws [PeakFormatException] for anything that is not a peak file this
  /// version wrote. Every such failure is recoverable by analysing again, so
  /// callers catch it rather than surfacing it.
  static PeakPyramid decode(Uint8List bytes) {
    if (bytes.length < headerBytes) {
      throw PeakFormatException('too short: ${bytes.length} bytes');
    }
    final view = ByteData.sublistView(bytes);
    if (view.getUint32(0, Endian.host) != magic) {
      throw const PeakFormatException('not a peak file');
    }
    final fileVersion = view.getUint32(4, Endian.host);
    if (fileVersion != version) {
      throw PeakFormatException('version $fileVersion, expected $version');
    }

    final levelCount = view.getUint32(20, Endian.host);
    if (levelCount == 0 || levelCount > 64) {
      throw PeakFormatException('$levelCount levels');
    }
    if (bytes.length < headerBytes + levelCount * 4) {
      throw const PeakFormatException('truncated level table');
    }

    final counts = <int>[];
    var total = 0;
    for (var i = 0; i < levelCount; i++) {
      final count = view.getUint32(headerBytes + i * 4, Endian.host);
      counts.add(count);
      total += count;
    }

    final start = headerBytes + levelCount * 4;
    if (bytes.length - start != total * 4) {
      throw PeakFormatException(
          'expected ${total * 4} bytes of buckets, got ${bytes.length - start}');
    }

    // Copied rather than viewed. A view would have to be two-byte aligned
    // inside whatever buffer the file was read into, and a copy of a cache
    // file we are about to keep for the session is not the expensive part.
    final buckets = Int16List(total * 2);
    Uint8List.sublistView(buckets).setRange(0, total * 4, bytes, start);

    return PeakPyramid(
      framesPerBucket: view.getUint32(8, Endian.host),
      sampleRate: view.getUint32(12, Endian.host),
      channels: view.getUint32(16, Endian.host),
      frameCount: view.getInt64(24, Endian.host),
      duration: Tick(view.getInt64(32, Endian.host)),
      bucketCounts: counts,
      buckets: buckets,
      stamp: MediaStamp(
        bytes: view.getInt64(40, Endian.host),
        modifiedMs: view.getInt64(48, Endian.host),
      ),
    );
  }
}
