import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/model/time.dart';

void main() {
  group('Rational', () {
    test('normalises sign and magnitude', () {
      expect(Rational(2, 4), Rational(1, 2));
      expect(Rational(1, -2), Rational(-1, 2));
      expect(Rational(-2, -4).numerator, 1);
      expect(Rational(-2, -4).denominator, 2);
      expect(Rational(0, 5), Rational.zero);
    });

    test('rejects a zero denominator', () {
      expect(() => Rational(1, 0), throwsArgumentError);
    });

    test('arithmetic is exact for NTSC rates', () {
      // The whole point: 30000/1001 must not become 29.97.
      final ntsc = FrameRates.fps29_97;
      expect(ntsc * Rational.whole(1001), Rational.whole(30000));
      expect(ntsc.inverse, Rational(1001, 30000));
      expect(ntsc - ntsc, Rational.zero);
      expect(ntsc / ntsc, Rational.one);
      // 1001 frames of 29.97 is exactly 1001/29.97 = 100.1s, not 100.1000333…
      expect(ntsc.inverse * Rational.whole(1001), Rational(1001 * 1001, 30000));
    });

    test('addition of thirds is exact where doubles are not', () {
      final third = Rational(1, 3);
      expect(third + third + third, Rational.one);
      expect(0.1 + 0.2 == 0.3, isFalse); // the failure mode being avoided
      expect(Rational(1, 10) + Rational(2, 10), Rational(3, 10));
    });

    test('orders correctly across denominators', () {
      expect(Rational(2, 3) > Rational(3, 5), isTrue);
      expect(Rational(-1, 3) < Rational.zero, isTrue);
      final sorted = [Rational(3, 4), Rational(1, 2), Rational(2, 3)]..sort();
      expect(sorted, [Rational(1, 2), Rational(2, 3), Rational(3, 4)]);
    });

    test('round-trips through its string form', () {
      for (final r in FrameRates.all) {
        expect(Rational.parse(r.toString()), r);
      }
      expect(FrameRates.fps30.toString(), '30');
      expect(FrameRates.fps29_97.toString(), '30000/1001');
    });

    test('zero has no inverse', () {
      expect(() => Rational.zero.inverse, throwsStateError);
      expect(() => Rational.one / Rational.zero, throwsArgumentError);
    });
  });

  group('Timebase', () {
    const tb = Timebase.project;

    test('divides every supported rate exactly', () {
      // If this ever fails, the 120000 constant is wrong for the product's
      // rate list and the document model has silent drift.
      for (final fps in FrameRates.all) {
        expect(tb.divides(fps), isTrue, reason: 'timebase must divide $fps');
      }
    });

    test('ticks per frame match the documented table', () {
      expect(tb.ticksPerFrame(FrameRates.fps24), 5000);
      expect(tb.ticksPerFrame(FrameRates.fps25), 4800);
      expect(tb.ticksPerFrame(FrameRates.fps30), 4000);
      expect(tb.ticksPerFrame(FrameRates.fps60), 2000);
      expect(tb.ticksPerFrame(FrameRates.fps23_976), 5005);
      expect(tb.ticksPerFrame(FrameRates.fps29_97), 4004);
      expect(tb.ticksPerFrame(FrameRates.fps59_94), 2002);
    });

    test('refuses a rate it cannot represent exactly', () {
      expect(() => tb.ticksPerFrame(Rational(7, 1)), throwsArgumentError);
      expect(() => tb.ticksPerFrame(Rational.zero), throwsArgumentError);
      expect(() => tb.ticksPerFrame(Rational(-30, 1)), throwsArgumentError);
    });

    test('an hour of NTSC frames lands on an exact tick, with no drift', () {
      const fps = FrameRates.fps29_97;
      const frames = 107892; // one hour of 29.97
      final t = tb.tickOfFrame(frames, fps);
      expect(t.raw, frames * 4004);
      expect(tb.frameOfTick(t, fps), frames);
      // Walking frame by frame must agree with multiplying.
      var walk = Tick.zero;
      final per = Tick(tb.ticksPerFrame(fps));
      for (var i = 0; i < 1000; i++) {
        walk += per;
      }
      expect(walk, tb.tickOfFrame(1000, fps));
    });

    test('frameOfTick floors within a frame and handles negatives', () {
      const fps = FrameRates.fps30; // 4000 ticks per frame
      expect(tb.frameOfTick(const Tick(0), fps), 0);
      expect(tb.frameOfTick(const Tick(3999), fps), 0);
      expect(tb.frameOfTick(const Tick(4000), fps), 1);
      expect(tb.frameOfTick(const Tick(-1), fps), -1);
      expect(tb.frameOfTick(const Tick(-4000), fps), -1);
      expect(tb.frameOfTick(const Tick(-4001), fps), -2);
    });

    test('snapToFrame lands on frame starts', () {
      const fps = FrameRates.fps30;
      expect(tb.snapToFrame(const Tick(4123), fps), const Tick(4000));
      expect(tb.snapToFrame(const Tick(4000), fps), const Tick(4000));
      expect(tb.snapToFrame(Tick.zero, fps), Tick.zero);
    });

    test('converts seconds and nanoseconds', () {
      expect(tb.fromSeconds(Rational.whole(1)), const Tick(120000));
      expect(tb.fromSeconds(Rational(1, 2)), const Tick(60000));
      expect(tb.fromNanos(1000000000), const Tick(120000));
      expect(tb.toNanos(const Tick(120000)), 1000000000);
      expect(tb.fromNanos(0), Tick.zero);
    });

    test('nanosecond conversion survives a ten-hour timeline', () {
      const tenHoursNs = 36000 * 1000000000;
      final t = tb.fromNanos(tenHoursNs);
      expect(t.raw, 36000 * 120000);
      expect(tb.toNanos(t), tenHoursNs); // no overflow, no drift
    });

    test('converts stream timestamps on their own timebase', () {
      // FFmpeg commonly reports MP4 video on 1/90000 or 1/15360.
      final t = tb.fromStreamTime(90000, Rational(1, 90000));
      expect(t, const Tick(120000));
      expect(tb.fromStreamTime(0, Rational(1, 90000)), Tick.zero);
      expect(tb.fromStreamTime(45000, Rational(1, 90000)), const Tick(60000));
    });
  });

  group('Tick', () {
    test('arithmetic and ordering', () {
      const a = Tick(100);
      const b = Tick(30);
      expect((a + b).raw, 130);
      expect((a - b).raw, 70);
      expect((-a).raw, -100);
      expect((b * 3).raw, 90);
      expect(a > b, isTrue);
      expect(b <= b, isTrue);
      expect(a.compareTo(b), greaterThan(0));
      expect(Tick.smaller(a, b), b);
      expect(Tick.larger(a, b), a);
      expect(const Tick(-5).abs, const Tick(5));
    });

    test('clamps into range', () {
      expect(const Tick(50).clampTo(const Tick(0), const Tick(10)),
          const Tick(10));
      expect(const Tick(-50).clampTo(const Tick(0), const Tick(10)), Tick.zero);
      expect(const Tick(5).clampTo(const Tick(0), const Tick(10)),
          const Tick(5));
    });

    test('sorts as a list', () {
      final ticks = [const Tick(5), const Tick(1), const Tick(3)]
        ..sort((x, y) => x.compareTo(y));
      expect(ticks.map((t) => t.raw), [1, 3, 5]);
    });
  });

  group('TimeSpan', () {
    test('bounds and emptiness', () {
      final s = TimeSpan(const Tick(100), const Tick(50));
      expect(s.end, const Tick(150));
      expect(s.isEmpty, isFalse);
      expect(TimeSpan(const Tick(10), Tick.zero).isEmpty, isTrue);
    });

    test('fromBounds never produces a negative duration', () {
      final s = TimeSpan.fromBounds(const Tick(100), const Tick(40));
      expect(s.duration, Tick.zero);
      expect(s.start, const Tick(100));
    });

    test('contains is half-open', () {
      final s = TimeSpan(const Tick(100), const Tick(50));
      expect(s.contains(const Tick(100)), isTrue);
      expect(s.contains(const Tick(149)), isTrue);
      expect(s.contains(const Tick(150)), isFalse); // end is exclusive
      expect(s.contains(const Tick(99)), isFalse);
    });

    test('abutting spans do not overlap', () {
      final a = TimeSpan(const Tick(0), const Tick(100));
      final b = TimeSpan(const Tick(100), const Tick(100));
      expect(a.overlaps(b), isFalse);
      expect(a.intersect(b), isNull);
      final c = TimeSpan(const Tick(99), const Tick(100));
      expect(a.overlaps(c), isTrue);
      expect(a.intersect(c), TimeSpan(const Tick(99), const Tick(1)));
    });

    test('empty spans never overlap', () {
      final empty = TimeSpan(const Tick(50), Tick.zero);
      final s = TimeSpan(const Tick(0), const Tick(100));
      expect(s.overlaps(empty), isFalse);
      expect(empty.overlaps(s), isFalse);
    });

    test('shifting preserves duration', () {
      final s = TimeSpan(const Tick(100), const Tick(50));
      final moved = s.shiftedBy(const Tick(-30));
      expect(moved.start, const Tick(70));
      expect(moved.duration, s.duration);
    });
  });
}
