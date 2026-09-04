import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor/ui/timeline/timeline_geometry.dart';

import '../../fixtures.dart';

/// The geometry is the whole of the timeline's arithmetic, and every bug it
/// can have is one the eye would forgive and the hand would not: a playhead
/// that lands a frame off, a zoom that walks away from the cursor, a clip
/// culled while still on screen.
void main() {
  const geometry = TimelineGeometry(pxPerSecond: 80);
  const h = TimelineGeometry.headerWidth;

  Tick seconds(num s) =>
      Timebase.project.fromSeconds(Rational((s * 1000).round(), 1000));

  group('ticks and pixels', () {
    test('time zero sits at the right edge of the lane headers', () {
      expect(geometry.xOfTick(Tick.zero), h);
    });

    test('a second is pxPerSecond wide', () {
      expect(geometry.xOfTick(seconds(1)) - geometry.xOfTick(Tick.zero), 80);
      expect(
        const TimelineGeometry(pxPerSecond: 250).xOfTick(seconds(2)) - h,
        500,
      );
    });

    test('scrolling moves content left, not the headers', () {
      const scrolled = TimelineGeometry(pxPerSecond: 80, scrollPx: 40);
      expect(scrolled.xOfTick(Tick.zero), h - 40);
      expect(scrolled.xOfTick(seconds(1)), h + 40);
    });

    test('x and tick are inverses', () {
      for (final g in [
        geometry,
        const TimelineGeometry(pxPerSecond: 4, scrollPx: 900),
        const TimelineGeometry(pxPerSecond: 900, scrollPx: 17.5),
      ]) {
        for (final t in [Tick.zero, seconds(1), seconds(37), seconds(600)]) {
          expect(g.tickAtX(g.xOfTick(t)).raw, closeTo(t.raw, 1),
              reason: 'round trip at $g for ${t.raw}');
        }
      }
    });

    test('a point left of the headers reads as a time before zero', () {
      // Unclamped on purpose: the caller decides whether that means zero, and
      // clamping here would hide a drag that ran off the left.
      expect(geometry.tickAtX(h - 80).raw, -Timebase.project.ticksPerSecond);
    });
  });

  group('zoom', () {
    test('keeps the time under the cursor under the cursor', () {
      // Scrolled in, so there is room on the left for zooming out to use.
      const scrolled = TimelineGeometry(pxPerSecond: 80, scrollPx: 2000);
      const focus = h + 300;
      final before = scrolled.tickAtX(focus);
      for (final factor in [1.1, 0.9, 4.0, 0.25]) {
        final zoomed = scrolled.zoomedAround(focus, factor);
        expect(zoomed.tickAtX(focus).raw, closeTo(before.raw, 60),
            reason: 'factor $factor');
      }
    });

    test('gives up the anchor rather than scrolling before zero', () {
      // Zooming out near the start cannot hold the cursor's time in place —
      // doing so would need timeline to the left of zero, and there is none.
      // Pinning to the start is the right answer; pretending otherwise would
      // mean a negative scroll and a ruler counting backwards.
      const focus = h + 300;
      final zoomed = geometry.zoomedAround(focus, 0.5);
      expect(zoomed.scrollPx, 0);
      expect(zoomed.xOfTick(Tick.zero), h);
    });

    test('holds the anchor across a run of small steps', () {
      // A wheel produces dozens of these; drift that is invisible in one is
      // obvious after thirty.
      const focus = h + 420;
      var g = const TimelineGeometry(pxPerSecond: 80, scrollPx: 2000);
      final anchor = g.tickAtX(focus);
      for (var i = 0; i < 30; i++) {
        g = g.zoomedAround(focus, 1.1);
      }
      expect(g.tickAtX(focus).raw, closeTo(anchor.raw, 60));
      expect(g.pxPerSecond, greaterThan(geometry.pxPerSecond));
    });

    test('clamps rather than running away', () {
      var g = geometry;
      for (var i = 0; i < 200; i++) {
        g = g.zoomedAround(h, 1.5);
      }
      expect(g.pxPerSecond, TimelineGeometry.maxPxPerSecond);

      for (var i = 0; i < 400; i++) {
        g = g.zoomedAround(h, 0.5);
      }
      expect(g.pxPerSecond, TimelineGeometry.minPxPerSecond);
    });

    test('never scrolls before zero', () {
      final g = geometry.zoomedAround(h + 900, 0.05);
      expect(g.scrollPx, greaterThanOrEqualTo(0));
    });
  });

  group('panning', () {
    test('moves by the delta and stops at zero', () {
      expect(geometry.pannedBy(120).scrollPx, 120);
      expect(geometry.pannedBy(-120).scrollPx, 0);
      expect(
        const TimelineGeometry(scrollPx: 100).pannedBy(-40).scrollPx,
        60,
      );
    });
  });

  group('following the playhead', () {
    const width = 1000.0;

    test('does nothing while the playhead is comfortably on screen', () {
      final g = geometry.scrolledToShow(seconds(4), width);
      expect(identical(g, geometry), isTrue,
          reason: 'an unchanged geometry must be the same instance, or the '
              'painter repaints every frame of playback for nothing');
    });

    test('brings the playhead back when it runs off the right', () {
      final g = geometry.scrolledToShow(seconds(30), width);
      final x = g.xOfTick(seconds(30));
      expect(x, greaterThan(TimelineGeometry.headerWidth));
      expect(x, lessThan(width));
    });

    test('lands the playhead well inside, not on the edge it just left', () {
      // Otherwise the next frame pushes it off again and the view lurches
      // once per frame for the rest of the clip.
      final g = geometry.scrolledToShow(seconds(30), width);
      final x = g.xOfTick(seconds(30));
      expect(x, lessThan(width * 0.7));
    });

    test('catches up when the playhead is behind the view', () {
      const scrolled = TimelineGeometry(pxPerSecond: 80, scrollPx: 4000);
      final g = scrolled.scrolledToShow(seconds(2), width);
      final x = g.xOfTick(seconds(2));
      expect(x, greaterThanOrEqualTo(TimelineGeometry.headerWidth));
      expect(x, lessThan(width));
    });
  });

  group('lanes', () {
    test('finds the lane under a point', () {
      final top = geometry.topOfTrack(1);
      expect(geometry.trackIndexAt(top + 4, 3), 1);
      expect(geometry.trackIndexAt(geometry.topOfTrack(0) + 4, 3), 0);
    });

    test('the ruler is not a lane', () {
      expect(geometry.trackIndexAt(TimelineGeometry.rulerHeight - 1, 3), isNull);
    });

    test('the gap between lanes is not a lane', () {
      final justPastFirst =
          TimelineGeometry.rulerHeight + TimelineGeometry.trackHeight + 1;
      expect(geometry.trackIndexAt(justPastFirst, 3), isNull);
    });

    test('empty space below the last lane is not a lane', () {
      expect(geometry.trackIndexAt(geometry.topOfTrack(3) + 4, 3), isNull);
      expect(geometry.trackIndexAt(9000, 3), isNull);
    });

    test('height covers every lane it claims to', () {
      final height = TimelineGeometry.heightFor(4);
      expect(geometry.topOfTrack(3) + TimelineGeometry.trackHeight,
          lessThanOrEqualTo(height));
    });
  });

  group('ruler steps', () {
    test('are whole seconds at ordinary zoom', () {
      final step = geometry.rulerStep(FrameRates.fps30);
      expect(step.raw, Timebase.project.ticksPerSecond);
    });

    test('become whole frames once a frame is wide enough to label', () {
      final step = const TimelineGeometry(pxPerSecond: 1200)
          .rulerStep(FrameRates.fps30);
      final perFrame = Timebase.project.ticksPerFrame(FrameRates.fps30);
      expect(step.raw % perFrame, 0);
      expect(step.raw, lessThan(Timebase.project.ticksPerSecond));
    });

    test('become minutes when zoomed all the way out', () {
      final step =
          const TimelineGeometry(pxPerSecond: 2).rulerStep(FrameRates.fps30);
      expect(step.raw, greaterThanOrEqualTo(Timebase.project.ticksPerSecond * 30));
    });

    test('always leave room for the label', () {
      for (final px in [2.0, 8.0, 30.0, 80.0, 200.0, 600.0, 1200.0]) {
        final g = TimelineGeometry(pxPerSecond: px);
        for (final fps in [FrameRates.fps24, FrameRates.fps30, FrameRates.fps60]) {
          final step = g.rulerStep(fps);
          expect(step.raw * g.pxPerTick, greaterThanOrEqualTo(60),
              reason: 'at $px px/s, $fps');
        }
      }
    });

    test('land on a real frame boundary, whatever the rate', () {
      // A gridline at 0.37 s is a gridline nobody can read a time off.
      for (final fps in [FrameRates.fps24, FrameRates.fps25, FrameRates.fps30]) {
        final perFrame = Timebase.project.ticksPerFrame(fps);
        for (final px in [5.0, 50.0, 300.0, 1200.0]) {
          final step = TimelineGeometry(pxPerSecond: px).rulerStep(fps);
          expect(step.raw % perFrame, 0, reason: '$fps at $px px/s');
        }
      }
    });
  });

  group('the scrollbar', () {
    // 900 px wide, so 784 px of track past the lane headers.
    const width = 900.0;

    test('says nothing when the whole project fits', () {
      const g = TimelineGeometry(pxPerSecond: 80);
      expect(g.scrollbarThumb(secs(6), width), isNull);
      // Exactly filling the view is still nothing to say.
      expect(g.scrollbarThumb(Tick((784 / g.pxPerTick).floor()), width),
          isNull);
    });

    test('the thumb is the fraction of the film that is on screen', () {
      const g = TimelineGeometry(pxPerSecond: 80);
      // Two minutes at 80 px/s is 9600 px of film behind 784 px of window.
      final thumb = g.scrollbarThumb(secs(120), width)!;
      expect(thumb.width, closeTo(784 * 784 / 9600, 0.5));
      expect(thumb.left, 0);
    });

    test('the thumb moves with the view, and reaches the end', () {
      const g = TimelineGeometry(pxPerSecond: 80);
      final content = secs(120);
      final track = width - TimelineGeometry.headerWidth;
      final full = g.copyWith(scrollPx: 9600 - track);

      final thumb = full.scrollbarThumb(content, width)!;
      expect(thumb.left + thumb.width, closeTo(track, 0.5),
          reason: 'the far end of the film should put the thumb at the far '
              'end of its track');
    });

    test('a drag of the thumb is worth `scale` pixels of film', () {
      const g = TimelineGeometry(pxPerSecond: 80);
      final content = secs(120);
      final thumb = g.scrollbarThumb(content, width)!;
      final track = width - TimelineGeometry.headerWidth;

      // Dragging the thumb the length of its travel is scrolling the film the
      // length of its reach: the two ends have to meet.
      final travel = track - thumb.width;
      expect(travel * thumb.scale, closeTo(9600 - track, 1));
    });

    test('a thumb never gets too small to grab', () {
      // Ten hours at full zoom is the shape that would leave a sliver.
      const g = TimelineGeometry(pxPerSecond: 1200);
      final thumb = g.scrollbarThumb(secs(36000), width)!;
      expect(thumb.width, TimelineGeometry.minThumbWidth);
      expect(thumb.scale, greaterThan(0));
    });

    test('panning past the end grows the bar rather than leaving it', () {
      // Nothing clamps a pan at the end of the film, so the reachable extent
      // is the longer of the film and wherever the view actually is. A thumb
      // drawn outside its own track would be a bar lying about where you are.
      final g = const TimelineGeometry(pxPerSecond: 80)
          .copyWith(scrollPx: 20000);
      final thumb = g.scrollbarThumb(secs(120), width)!;
      final track = width - TimelineGeometry.headerWidth;
      expect(thumb.left, greaterThanOrEqualTo(0));
      expect(thumb.left + thumb.width, lessThanOrEqualTo(track + 0.5));
    });

    test('the band is pinned to the bottom, whatever the height', () {
      // heightFor is clamped by the editor, so a project with many lanes gets
      // less room than it asked for; the bar has to be findable anyway.
      for (final height in [120.0, 200.0, 320.0]) {
        final band = TimelineGeometry.scrollbarBand(width, height);
        expect(band.bottom, height);
        expect(band.height, TimelineGeometry.scrollbarHeight);
        expect(band.left, TimelineGeometry.headerWidth);
      }
    });

    test('the lanes make room for it', () {
      final withBar = TimelineGeometry.heightFor(3);
      final lanes = TimelineGeometry.rulerHeight +
          3 * (TimelineGeometry.trackHeight + TimelineGeometry.trackGap) +
          TimelineGeometry.trackGap;
      expect(withBar - lanes, TimelineGeometry.scrollbarHeight,
          reason: 'a bar drawn over the last lane is a bar in the way');
    });
  });
}
