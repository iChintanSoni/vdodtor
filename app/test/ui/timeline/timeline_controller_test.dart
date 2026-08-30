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

    test('is on by default and keeps the playhead visible', () {
      transport.isPlaying = true;
      transport.playTo(secs(40).raw);
      controller.pump(width);

      final x = controller.geometry.xOfTick(controller.playhead);
      expect(x, greaterThan(h));
      expect(x, lessThan(width));
    });

    test('a deliberate pan turns it off', () {
      controller.panBy(300);
      expect(controller.isFollowingPlayhead, isFalse);

      final before = controller.geometry;
      transport.playTo(secs(40).raw);
      controller.pump(width);
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
      controller.zoomToFit(width);

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

      final before = c.geometry;
      c.zoomToFit(width);
      expect(c.geometry, before);
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
