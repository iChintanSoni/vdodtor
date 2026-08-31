import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/media/peaks.dart';
import 'package:vdodtor/model/time.dart';

import 'peak_fixtures.dart';

/// Ticks per pixel at a zoom of [pxPerSecond].
double zoom(double pxPerSecond) =>
    Timebase.project.ticksPerSecond / pxPerSecond;

/// The loudest sample anywhere in an envelope.
double loudest(Float32List envelope) {
  var peak = 0.0;
  for (final value in envelope) {
    if (value.abs() > peak) peak = value.abs();
  }
  return peak;
}

void main() {
  group('the pyramid', () {
    test('every level is the folded extremes of the one below', () {
      // The fixture builds it; this is the reader agreeing about what it holds.
      final peaks = pyramid(steadyWithSpike(64, at: 17));

      expect(peaks.bucketCounts, [64, 32, 16, 8, 4, 2, 1]);
      expect(peaks.buckets.length, 127 * 2);
      expect(peaks.levelCount, 7);
    });

    test('a bucket array that does not match the counts is refused', () {
      expect(
        () => PeakPyramid(
          framesPerBucket: 128,
          sampleRate: 48000,
          channels: 2,
          frameCount: 256,
          duration: const Tick(640),
          bucketCounts: const [2, 1],
          buckets: Int16List(4), // three buckets' worth is six values
        ),
        throwsA(isA<PeakFormatException>()),
      );
    });

    test('the level picked is the coarsest that still fits in a pixel', () {
      final peaks = pyramid(steadyWithSpike(1024, at: 3));

      // Zoomed in past the finest measurement there is nothing finer to pick.
      expect(peaks.levelFor(1), 0);
      expect(peaks.levelFor(127), 0);
      expect(peaks.levelFor(128), 0);
      expect(peaks.levelFor(255), 0);
      expect(peaks.levelFor(256), 1);
      expect(peaks.levelFor(1024), 3);
      // Past the top of the pyramid it stays at the top rather than running
      // off the end of the level table.
      expect(peaks.levelFor(1e9), peaks.levelCount - 1);
    });
  });

  group('the envelope', () {
    // The claim the whole pyramid exists to make. A drum hit two thirds of the
    // way through a file has to be visible when the file is one bar wide, and
    // an averaging pyramid — or a reader that point-samples one bucket per
    // pixel — loses it at exactly the zoom where someone is looking for it.
    test('a single loud bucket survives every zoom', () {
      final peaks = pyramid(steadyWithSpike(4096, level: 0.08, at: 2731));
      final span = peaks.duration;

      for (final pxPerSecond in [2.0, 8.0, 40.0, 80.0, 300.0, 1200.0]) {
        final ticksPerPixel = zoom(pxPerSecond);
        final pixels = (span.raw / ticksPerPixel).ceil();
        final envelope = peaks.envelope(
          from: Tick.zero,
          ticksPerPixel: ticksPerPixel,
          pixels: pixels,
        );
        expect(loudest(envelope), closeTo(1, 0.001),
            reason: 'the spike vanished at $pxPerSecond px/s');
      }
    });

    test('a pixel folds every bucket it covers, rather than sampling one', () {
      // Four level-0 buckets per pixel, with the loud one third in the pixel.
      final peaks = pyramid(steadyWithSpike(64, level: 0.1, spike: 0.9, at: 6));
      final ticksPerPixel =
          4 * 128 * Timebase.project.ticksPerSecond / 48000;

      final envelope = peaks.envelope(
        from: Tick.zero,
        ticksPerPixel: ticksPerPixel,
        pixels: 4,
      );

      // Pixel 1 covers buckets 4..7, which is where the spike is.
      expect(envelope[2], closeTo(-0.9, 0.001));
      expect(envelope[3], closeTo(0.9, 0.001));
      // Its neighbours are the quiet level, so the spike did not leak.
      expect(envelope[1], closeTo(0.1, 0.001));
      expect(envelope[5], closeTo(0.1, 0.001));
    });

    test('a pixel narrower than a bucket still reads that bucket', () {
      final peaks = pyramid(steadyWithSpike(32, level: 0.2, spike: 0.7, at: 9));
      // A tenth of a bucket per pixel: far past the resolution the file was
      // measured at, which is a zoom the timeline can reach.
      final ticksPerPixel =
          0.1 * 128 * Timebase.project.ticksPerSecond / 48000;

      final envelope = peaks.envelope(
        from: Tick.zero,
        ticksPerPixel: ticksPerPixel,
        pixels: 200,
      );

      expect(loudest(envelope), closeTo(0.7, 0.001));
      // Ten pixels wide, because that is what a bucket is at this zoom, and
      // stretching is the honest answer: 2.7 ms is as fine as the file was
      // measured.
      var wide = 0;
      for (var i = 0; i < 200; i++) {
        if (envelope[i * 2 + 1] > 0.5) wide++;
      }
      expect(wide, inInclusiveRange(9, 11));
    });

    test('outside the file is silence, not an error', () {
      final peaks = pyramid(steadyWithSpike(16, level: 0.5, at: 0));
      final ticksPerPixel = 128 * Timebase.project.ticksPerSecond / 48000;

      // Starting a clip's worth of pixels before the file begins.
      final before = peaks.envelope(
        from: Tick(-8 * ticksPerPixel.round()),
        ticksPerPixel: ticksPerPixel,
        pixels: 8,
      );
      expect(loudest(before), 0);

      // And running off the end of it.
      final after = peaks.envelope(
        from: peaks.duration,
        ticksPerPixel: ticksPerPixel,
        pixels: 8,
      );
      expect(loudest(after), 0);
    });

    test('a buffer can be reused across calls', () {
      final peaks = pyramid(steadyWithSpike(64, level: 0.3, at: 5));
      final buffer = Float32List(256);

      peaks.envelopeInto(buffer,
          from: Tick.zero, ticksPerPixel: zoom(80), pixels: 32);
      final first = buffer.sublist(0, 64);
      peaks.envelopeInto(buffer,
          from: Tick.zero, ticksPerPixel: zoom(80), pixels: 32);

      expect(buffer.sublist(0, 64), first);
    });
  });

  group('the peak file', () {
    test('survives a round trip, stamp and all', () {
      final original = pyramid(
        steadyWithSpike(300, level: 0.42, at: 130),
        stamp: const MediaStamp(bytes: 991, modifiedMs: 1724000000000),
      );

      final decoded = PeakFile.decode(PeakFile.encode(original));

      expect(decoded, original);
      expect(decoded.stamp.bytes, 991);
      expect(decoded.stamp.modifiedMs, 1724000000000);
      expect(decoded.buckets, original.buckets);
    });

    test('is exactly as long as its contents', () {
      final peaks = pyramid(steadyWithSpike(8, at: 1));
      // 8 + 4 + 2 + 1 buckets, four bytes each, after the header and the
      // level table.
      expect(PeakFile.encode(peaks).length,
          PeakFile.headerBytes + 4 * 4 + 15 * 4);
    });

    test('anything that is not a peak file is refused, not misread', () {
      final good = PeakFile.encode(pyramid(steadyWithSpike(8, at: 1)));

      Uint8List broken(void Function(ByteData) damage) {
        final copy = Uint8List.fromList(good);
        damage(ByteData.sublistView(copy));
        return copy;
      }

      expect(() => PeakFile.decode(Uint8List(4)),
          throwsA(isA<PeakFormatException>()));
      expect(
          () => PeakFile.decode(
              broken((view) => view.setUint32(0, 0xDEADBEEF, Endian.host))),
          throwsA(isA<PeakFormatException>()));
      // A file from a future version is refused rather than read as this one:
      // that is the entire migration story a cache needs.
      expect(
          () => PeakFile.decode(broken(
              (view) => view.setUint32(4, PeakFile.version + 1, Endian.host))),
          throwsA(isA<PeakFormatException>()));
      expect(
          () => PeakFile.decode(
              broken((view) => view.setUint32(20, 0, Endian.host))),
          throwsA(isA<PeakFormatException>()));
      // A write cut short by a crash is short, and reads as short rather than
      // as a file that ends early.
      expect(() => PeakFile.decode(good.sublist(0, good.length - 6)),
          throwsA(isA<PeakFormatException>()));
    });
  });

  group('the stamp', () {
    test('an unknown stamp matches nothing, including another unknown one', () {
      const known = MediaStamp(bytes: 10, modifiedMs: 20);

      expect(known.matches(known), isTrue);
      expect(known.matches(const MediaStamp(bytes: 10, modifiedMs: 21)),
          isFalse);
      // A file the app cannot currently see is a file whose waveform it cannot
      // vouch for.
      expect(MediaStamp.unknown.matches(MediaStamp.unknown), isFalse);
      expect(MediaStamp.unknown.matches(known), isFalse);
      expect(known.matches(MediaStamp.unknown), isFalse);
    });
  });
}
