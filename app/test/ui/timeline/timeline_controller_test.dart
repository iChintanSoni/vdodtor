import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/commands/document_store.dart';
import 'package:vdodtor/commands/edits.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor/ui/timeline/timeline_controller.dart';
import 'package:vdodtor/ui/timeline/timeline_geometry.dart';

import '../../fixtures.dart';

/// A playhead with no engine under it. Records every seek, because the point
/// of scrubbing is that it drives something, and how often it does is as much
/// the behaviour as where it lands.
class FakeTransport extends ChangeNotifier implements TimelineTransport {
  FakeTransport({this.durationTicks = 0});

  @override
  int positionTicks = 0;

  @override
  int durationTicks;

  @override
  bool isPlaying = false;

  final List<int> seeks = [];

  @override
  void seek(int ticks) {
    seeks.add(ticks);
    positionTicks = ticks;
    notifyListeners();
  }

  void playTo(int ticks) {
    positionTicks = ticks;
    notifyListeners();
  }
}

void main() {
  late DocumentStore store;
  late FakeTransport transport;
  late TimelineController controller;

  const h = TimelineGeometry.headerWidth;
  const ruler = TimelineGeometry.rulerHeight;

  setUp(() {
    store = DocumentStore(projectWithThreeClips());
    transport = FakeTransport(durationTicks: secs(6).raw);
    controller = TimelineController(store: store, transport: transport);
  });
  tearDown(() {
    controller.dispose();
    store.dispose();
  });

  /// A point on the ruler at [x] pixels past the lane headers.
  Offset onRuler(double x) => Offset(h + x, ruler / 2);

  /// A point inside lane [track], [x] pixels past the lane headers.
  Offset inLane(double x, int track) => Offset(
      h + x, controller.geometry.topOfTrack(track) + 10);

  group('the playhead is the transport, not a copy of it', () {
    test('reads through to the transport', () {
      transport.playTo(secs(2).raw);
      expect(controller.playhead, secs(2));
    });

    test('a transport that moves repaints the timeline', () {
      var notifications = 0;
      controller.addListener(() => notifications++);
      transport.playTo(secs(1).raw);
      expect(notifications, 1);
    });

    test('a document edit repaints the timeline', () {
      var notifications = 0;
      controller.addListener(() => notifications++);
      store.run(const DeleteClips({'a'}));
      expect(notifications, greaterThanOrEqualTo(1));
    });
  });

  group('seeking', () {
    test('snaps to a frame, because that is what the engine can show', () {
      final perFrame = Timebase.project.ticksPerFrame(FrameRates.fps30);
      controller.seekTo(Tick(perFrame * 3 + 17));
      expect(transport.seeks.single, perFrame * 3);
    });

    test('clamps to the timeline at both ends', () {
      controller.seekTo(Tick(-500000));
      expect(transport.positionTicks, 0);

      controller.seekTo(Tick(secs(600).raw));
      expect(transport.positionTicks, secs(6).raw);
    });

    test('a seek that would not move the playhead is not sent', () {
      controller.seekTo(secs(1));
      expect(transport.seeks, hasLength(1));
      controller.seekTo(secs(1));
      expect(transport.seeks, hasLength(1),
          reason: 'a scrub that jitters within one frame must not re-seek — '
              'every one of those costs a decode');
    });

    test('nudge steps exactly one frame', () {
      final perFrame = Timebase.project.ticksPerFrame(FrameRates.fps30);
      transport.playTo(perFrame * 10);
      controller.nudge(1);
      expect(transport.positionTicks, perFrame * 11);
      controller.nudge(-1);
      expect(transport.positionTicks, perFrame * 10);
    });

    test('nudging back from zero stays at zero', () {
      controller.nudge(-1);
      expect(transport.positionTicks, 0);
    });
  });

  group('scrubbing', () {
    test('a press on the ruler moves the playhead there', () {
      controller.pointerDown(onRuler(160));
      // 160 px at the default 80 px/s is two seconds in.
      expect(transport.positionTicks, secs(2).raw);
      expect(controller.isScrubbing, isTrue);
    });

    test('dragging keeps seeking, and releasing stops', () {
      controller.pointerDown(onRuler(80));
      controller.pointerMove(onRuler(160));
      controller.pointerMove(onRuler(240));
      expect(transport.seeks,
          [secs(1).raw, secs(2).raw, secs(3).raw]);

      controller.pointerUp();
      expect(controller.isScrubbing, isFalse);
      controller.pointerMove(onRuler(400));
      expect(transport.seeks, hasLength(3),
          reason: 'a move with no button down is not a scrub');
    });

    test('a press in a lane does not move the playhead', () {
      controller.pointerDown(inLane(160, 0));
      expect(transport.seeks, isEmpty);
    });

    test('a press on the lane headers does nothing at all', () {
      controller.pointerDown(const Offset(20, ruler + 10));
      expect(transport.seeks, isEmpty);
      expect(controller.selectedClipId, isNull);
    });

    test('dragging off the left end pins to zero rather than going negative',
        () {
      controller.pointerDown(onRuler(200));
      controller.pointerMove(Offset(h - 400, ruler / 2));
      expect(transport.positionTicks, 0);
    });
  });

  group('selection', () {
    test('a press picks the clip under it', () {
      // a is 0-2s, b is 2-5s, c is 5-6s on the main track.
      controller.pointerDown(inLane(40, 0));
      expect(controller.selectedClipId, 'a');

      controller.pointerDown(inLane(240, 0));
      expect(controller.selectedClipId, 'b');
      expect(controller.selectedClip?.duration, secs(3));
    });

    test('a press on empty lane space clears it', () {
      controller.pointerDown(inLane(40, 0));
      controller.pointerDown(inLane(900, 0));
      expect(controller.selectedClipId, isNull);
    });

    test('survives an edit elsewhere, and reads through to the document', () {
      controller.pointerDown(inLane(240, 0));
      store.run(MoveClip('b', secs(0)));
      expect(controller.selectedClipId, 'b');
      expect(controller.selectedClip, isNotNull);
    });

    test('a clip deleted out from under the selection reads as gone', () {
      controller.pointerDown(inLane(40, 0));
      store.run(const DeleteClips({'a'}));
      expect(controller.selectedClip, isNull);
    });
  });

  group('following the playhead', () {
    const width = 900.0;

    setUp(() => controller.viewportWidth = width);

    test('is on by default and keeps the playhead visible', () {
      transport.isPlaying = true;
      transport.playTo(secs(40).raw);
      controller.pump();

      final x = controller.geometry.xOfTick(controller.playhead);
      expect(x, greaterThan(h));
      expect(x, lessThan(width));
    });

    test('a deliberate pan turns it off', () {
      controller.panBy(300);
      expect(controller.isFollowingPlayhead, isFalse);

      final before = controller.geometry;
      transport.playTo(secs(40).raw);
      controller.pump();
      expect(controller.geometry, before,
          reason: 'someone who scrolled somewhere meant to look at it');
    });

    test('scrubbing turns it back on', () {
      controller.panBy(300);
      controller.pointerDown(onRuler(100));
      expect(controller.isFollowingPlayhead, isTrue);
    });

    test('fit shows the whole timeline and follows again', () {
      controller.panBy(500);
      controller.zoomToFit();

      expect(controller.isFollowingPlayhead, isTrue);
      expect(controller.geometry.scrollPx, 0);
      final end = controller.geometry.xOfTick(controller.duration);
      expect(end, lessThanOrEqualTo(width));
      expect(end, greaterThan(width * 0.5));
    });

    test('fit on an empty timeline changes nothing', () {
      final empty = DocumentStore(emptyProject());
      final quiet = FakeTransport();
      final c = TimelineController(store: empty, transport: quiet);
      addTearDown(() {
        c.dispose();
        empty.dispose();
      });

      c.viewportWidth = width;
      final before = c.geometry;
      c.zoomToFit();
      expect(c.geometry, before);
    });

    test('fit before the view has been laid out changes nothing', () {
      // The controller learns its width at layout, so there is a moment
      // before the first frame when it does not have one. Fitting to a width
      // of zero would collapse the zoom to its floor and read as the timeline
      // having thrown itself away.
      final quiet = FakeTransport();
      final store = DocumentStore(projectWithThreeClips());
      final c = TimelineController(store: store, transport: quiet);
      addTearDown(() {
        c.dispose();
        store.dispose();
      });

      final before = c.geometry;
      c.zoomToFit();
      expect(c.geometry, before);
    });
  });

  group('moving the playhead by key', () {
    // projectWithThreeClips cuts at 0, 2, 5 and 6 seconds.
    test('a frame at a time, and a second at a time', () {
      controller.seekTo(secs(2));
      controller.nudge(1);
      expect(controller.playhead, secs(2) + Tick(4000));  // 30 fps
      controller.skip(1);
      expect(controller.playhead, secs(3) + Tick(4000));
      controller.skip(-1);
      expect(controller.playhead, secs(2) + Tick(4000));
    });

    test('to the next cut, and the one after that', () {
      controller.seekTo(Tick.zero);
      controller.jumpToCut(1);
      expect(controller.playhead, secs(2));
      controller.jumpToCut(1);
      expect(controller.playhead, secs(5));
      controller.jumpToCut(1);
      expect(controller.playhead, secs(6), reason: 'the end is a cut too');
    });

    test('past the last cut it stays where it is', () {
      // Not wrapping round to the start, which would move the playhead a long
      // way for a key someone pressed expecting it to do nothing.
      controller.seekTo(secs(6));
      controller.jumpToCut(1);
      expect(controller.playhead, secs(6));

      controller.seekTo(Tick.zero);
      controller.jumpToCut(-1);
      expect(controller.playhead, Tick.zero);
    });

    test('backwards lands on the cut before, not the one it is on', () {
      controller.seekTo(secs(5));
      controller.jumpToCut(-1);
      expect(controller.playhead, secs(2),
          reason: 'a cut the playhead is already on is not one to jump to');
    });

    test('a cut on any lane counts', () {
      final overlay = withOverlayTrack(store.project).updateTrack(
        overlayTrackId,
        (t) => t.withClips([
          clipOf('o', 'm1', start: secs(1), duration: secs(1)),
        ]),
      );
      final other = DocumentStore(overlay);
      final quiet = FakeTransport(durationTicks: secs(6).raw);
      final c = TimelineController(store: other, transport: quiet);
      addTearDown(() {
        c.dispose();
        other.dispose();
      });

      c.seekTo(Tick.zero);
      c.jumpToCut(1);
      expect(c.playhead, secs(1),
          reason: 'an overlay edge is an edit point like any other');
    });
  });

  group('zooming with no pointer', () {
    const width = 900.0;

    setUp(() => controller.viewportWidth = width);

    test('keeps the playhead where it is on screen', () {
      controller.seekTo(secs(3));
      final before = controller.geometry.xOfTick(controller.playhead);

      controller.zoomBy(1.4);

      // A pointer zoom holds still whatever is under the pointer; without one
      // the equivalent is the playhead, and holding the left edge instead
      // walks the thing being worked on off the screen.
      expect(controller.geometry.pxPerSecond, closeTo(80 * 1.4, 0.001));
      expect(controller.geometry.xOfTick(controller.playhead),
          closeTo(before, 0.5));
    });

    test('brings the playhead back on screen when it was off it', () {
      controller.seekTo(secs(3));
      controller.panBy(4000);
      expect(controller.geometry.xOfTick(controller.playhead),
          lessThan(TimelineGeometry.headerWidth));

      controller.zoomBy(1.4);

      final x = controller.geometry.xOfTick(controller.playhead);
      expect(x, greaterThanOrEqualTo(TimelineGeometry.headerWidth));
      expect(x, lessThanOrEqualTo(width));
    });

    test('stops at the zoom bounds rather than running away', () {
      for (var i = 0; i < 60; i++) {
        controller.zoomBy(1.4);
      }
      expect(controller.geometry.pxPerSecond,
          TimelineGeometry.maxPxPerSecond);

      for (var i = 0; i < 120; i++) {
        controller.zoomBy(1 / 1.4);
      }
      expect(controller.geometry.pxPerSecond,
          TimelineGeometry.minPxPerSecond);
    });
  });

  group('duration', () {
    test('is the longer of the document and the engine', () {
      // The engine lags a document edit by a frame or two; a timeline that
      // trusted only the engine would clip its own last clip off.
      transport.durationTicks = 0;
      expect(controller.duration, secs(6));

      transport.durationTicks = secs(9).raw;
      expect(controller.duration, secs(9));
    });
  });

  group('unreachable media', () {
    test('is settable and repaints only when it changes', () {
      var notifications = 0;
      controller.addListener(() => notifications++);

      controller.unreachableMediaIds = {'m1'};
      expect(notifications, 1);
      controller.unreachableMediaIds = {'m1'};
      expect(notifications, 1);
      controller.unreachableMediaIds = {'m1', 'm2'};
      expect(notifications, 2);
    });
  });
}
