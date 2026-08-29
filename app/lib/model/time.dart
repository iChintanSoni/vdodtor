/// Exact time for a video editor.
///
/// Two rules hold the whole document model together:
///
///  * Instants and durations on the timeline are **integer [Tick]s** on a fixed
///    project [Timebase]. Floating-point seconds never enter the document; they
///    exist only at the edges, for display and for UI hit-testing.
///  * Rates are exact [Rational]s, so the NTSC rates (30000/1001) survive
///    arithmetic without drift.
///
/// The project timebase is 120000 ticks per second because it divides exactly
/// by every rate the product supports:
///
/// | fps       | 24   | 25   | 30   | 60   | 23.976 | 29.97 | 59.94 |
/// |-----------|------|------|------|------|--------|-------|-------|
/// | ticks     | 5000 | 4800 | 4000 | 2000 | 5005   | 4004  | 2002  |
library;

import 'dart:math' as math;

/// An exact fraction, normalised so that [denominator] > 0 and
/// gcd(|numerator|, denominator) == 1.
///
/// Used for frame rates and for any conversion that must not lose precision.
final class Rational implements Comparable<Rational> {
  factory Rational(int numerator, int denominator) {
    if (denominator == 0) {
      throw ArgumentError.value(denominator, 'denominator', 'must not be zero');
    }
    if (denominator < 0) {
      numerator = -numerator;
      denominator = -denominator;
    }
    final g = _gcd(numerator.abs(), denominator);
    return Rational._(numerator ~/ g, denominator ~/ g);
  }

  const Rational._(this.numerator, this.denominator);

  /// An integer as a rational.
  const Rational.whole(int value)
      : numerator = value,
        denominator = 1;

  final int numerator;
  final int denominator;

  static const zero = Rational.whole(0);
  static const one = Rational.whole(1);

  bool get isZero => numerator == 0;
  bool get isInteger => denominator == 1;
  bool get isNegative => numerator < 0;

  Rational operator +(Rational o) => Rational(
      numerator * o.denominator + o.numerator * denominator,
      denominator * o.denominator);

  Rational operator -(Rational o) => Rational(
      numerator * o.denominator - o.numerator * denominator,
      denominator * o.denominator);

  Rational operator *(Rational o) =>
      Rational(numerator * o.numerator, denominator * o.denominator);

  Rational operator /(Rational o) {
    if (o.isZero) throw ArgumentError('division by zero');
    return Rational(numerator * o.denominator, denominator * o.numerator);
  }

  Rational operator -() => Rational._(-numerator, denominator);

  Rational get inverse {
    if (isZero) throw StateError('zero has no inverse');
    return Rational(denominator, numerator);
  }

  bool operator <(Rational o) => compareTo(o) < 0;
  bool operator <=(Rational o) => compareTo(o) <= 0;
  bool operator >(Rational o) => compareTo(o) > 0;
  bool operator >=(Rational o) => compareTo(o) >= 0;

  @override
  int compareTo(Rational o) =>
      (numerator * o.denominator).compareTo(o.numerator * denominator);

  /// Lossy. For display and for laying out pixels — never for document state.
  double toDouble() => numerator / denominator;

  @override
  bool operator ==(Object other) =>
      other is Rational &&
      other.numerator == numerator &&
      other.denominator == denominator;

  @override
  int get hashCode => Object.hash(numerator, denominator);

  /// `"30000/1001"`, or `"30"` when integral. Round-trips through [parse].
  @override
  String toString() =>
      denominator == 1 ? '$numerator' : '$numerator/$denominator';

  static Rational parse(String s) {
    final slash = s.indexOf('/');
    if (slash < 0) return Rational(int.parse(s), 1);
    return Rational(
        int.parse(s.substring(0, slash)), int.parse(s.substring(slash + 1)));
  }
}

/// The frame rates a project may be created at, plus their NTSC variants.
abstract final class FrameRates {
  static const fps24 = Rational.whole(24);
  static const fps25 = Rational.whole(25);
  static const fps30 = Rational.whole(30);
  static const fps60 = Rational.whole(60);
  static const fps23_976 = Rational._(24000, 1001);
  static const fps29_97 = Rational._(30000, 1001);
  static const fps59_94 = Rational._(60000, 1001);

  /// Offered at project creation (see the product brief).
  static const offered = [fps24, fps25, fps30, fps60];

  /// Every rate the timebase is required to represent exactly.
  static const all = [
    fps24,
    fps25,
    fps30,
    fps60,
    fps23_976,
    fps29_97,
    fps59_94,
  ];
}

/// An instant or a duration, in ticks of the project [Timebase].
///
/// This is an extension type: at runtime a `Tick` *is* an `int`, so it costs
/// nothing to pass around, but the compiler will not let a frame number, a
/// millisecond count, or a pixel offset be used where ticks are expected.
extension type const Tick(int raw) implements Object {
  static const zero = Tick(0);

  Tick operator +(Tick other) => Tick(raw + other.raw);
  Tick operator -(Tick other) => Tick(raw - other.raw);
  Tick operator -() => Tick(-raw);
  Tick operator *(int factor) => Tick(raw * factor);

  bool operator <(Tick other) => raw < other.raw;
  bool operator <=(Tick other) => raw <= other.raw;
  bool operator >(Tick other) => raw > other.raw;
  bool operator >=(Tick other) => raw >= other.raw;

  int compareTo(Tick other) => raw.compareTo(other.raw);

  bool get isZero => raw == 0;
  bool get isNegative => raw < 0;
  bool get isPositive => raw > 0;
  Tick get abs => Tick(raw.abs());

  Tick clampTo(Tick lo, Tick hi) =>
      raw < lo.raw ? lo : (raw > hi.raw ? hi : this);

  static Tick smaller(Tick a, Tick b) => a.raw <= b.raw ? a : b;
  static Tick larger(Tick a, Tick b) => a.raw >= b.raw ? a : b;
}

/// A half-open interval `[start, start + duration)` in ticks.
final class TimeSpan {
  TimeSpan(this.start, this.duration)
      : assert(duration.raw >= 0, 'duration must not be negative');

  TimeSpan.fromBounds(Tick start, Tick end)
      : this(start, Tick(math.max(0, end.raw - start.raw)));

  final Tick start;
  final Tick duration;

  Tick get end => start + duration;
  bool get isEmpty => duration.raw == 0;

  bool contains(Tick t) => t >= start && t < end;

  bool overlaps(TimeSpan other) =>
      start < other.end && other.start < end && !isEmpty && !other.isEmpty;

  TimeSpan shiftedBy(Tick delta) => TimeSpan(start + delta, duration);

  /// The overlapping part, or `null` when the spans are disjoint.
  TimeSpan? intersect(TimeSpan other) {
    final lo = Tick.larger(start, other.start);
    final hi = Tick.smaller(end, other.end);
    return hi > lo ? TimeSpan.fromBounds(lo, hi) : null;
  }

  @override
  bool operator ==(Object other) =>
      other is TimeSpan && other.start == start && other.duration == duration;

  @override
  int get hashCode => Object.hash(start.raw, duration.raw);

  @override
  String toString() => 'TimeSpan(${start.raw}..${end.raw})';
}

/// Ticks per second for a project. There is exactly one in practice
/// ([Timebase.project]); the type exists so the constant is never assumed.
final class Timebase {
  const Timebase(this.ticksPerSecond)
      : assert(ticksPerSecond > 0, 'timebase must be positive');

  final int ticksPerSecond;

  /// The project timebase. Chosen so every supported rate divides exactly —
  /// see the table in this library's doc comment.
  static const project = Timebase(120000);

  static const nanosPerSecond = 1000000000;

  /// Exact ticks per frame at [fps].
  ///
  /// Throws if [fps] does not divide the timebase exactly, because a rounded
  /// answer here is the drift this whole type exists to prevent.
  int ticksPerFrame(Rational fps) {
    if (fps.isZero || fps.isNegative) {
      throw ArgumentError.value(fps, 'fps', 'must be positive');
    }
    final numer = ticksPerSecond * fps.denominator;
    if (numer % fps.numerator != 0) {
      throw ArgumentError.value(
          fps, 'fps', 'does not divide a $ticksPerSecond/s timebase exactly');
    }
    return numer ~/ fps.numerator;
  }

  bool divides(Rational fps) =>
      !fps.isZero &&
      !fps.isNegative &&
      (ticksPerSecond * fps.denominator) % fps.numerator == 0;

  Tick tickOfFrame(int frame, Rational fps) => Tick(frame * ticksPerFrame(fps));

  /// The index of the frame containing [t]. Floors, so it is stable across the
  /// whole frame rather than flipping at the midpoint.
  int frameOfTick(Tick t, Rational fps) {
    final per = ticksPerFrame(fps);
    return t.raw >= 0 ? t.raw ~/ per : -((-t.raw + per - 1) ~/ per);
  }

  /// Snaps [t] down to the start of the frame that contains it.
  Tick snapToFrame(Tick t, Rational fps) => tickOfFrame(frameOfTick(t, fps), fps);

  Tick fromSeconds(Rational seconds) => Tick(_scale(
      seconds.numerator, ticksPerSecond, seconds.denominator));

  Tick fromNanos(int nanos) => Tick(_scale(nanos, ticksPerSecond, nanosPerSecond));

  int toNanos(Tick t) => _scale(t.raw, nanosPerSecond, ticksPerSecond);

  /// Converts a presentation timestamp on [streamTimebase] (as FFmpeg reports
  /// it, e.g. 1/90000) into project ticks.
  Tick fromStreamTime(int pts, Rational streamTimebase) => Tick(_scale(
      pts * streamTimebase.numerator, ticksPerSecond, streamTimebase.denominator));

  /// Lossy, and deliberately named so. Display and layout only.
  double toSecondsForDisplay(Tick t) => t.raw / ticksPerSecond;

  @override
  bool operator ==(Object other) =>
      other is Timebase && other.ticksPerSecond == ticksPerSecond;

  @override
  int get hashCode => ticksPerSecond.hashCode;

  @override
  String toString() => 'Timebase($ticksPerSecond/s)';
}

/// `value * mul / div`, rounded half away from zero, reducing before
/// multiplying so long timelines cannot overflow int64.
int _scale(int value, int mul, int div) {
  final g = _gcd(mul.abs(), div.abs());
  final m = mul ~/ g;
  final d = div ~/ g;
  final n = value * m;
  if (d == 1) return n;
  final half = d ~/ 2;
  return n >= 0 ? (n + half) ~/ d : -((-n + half) ~/ d);
}

int _gcd(int a, int b) {
  while (b != 0) {
    final t = a % b;
    a = b;
    b = t;
  }
  return a == 0 ? 1 : a;
}
