import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/commands/document_store.dart';
import 'package:vdodtor/ui/timeline/timeline_controller.dart';
import 'package:vdodtor/ui/timeline/timeline_geometry.dart';
import 'package:vdodtor/ui/timeline/timeline_view.dart';

import '../../fixtures.dart';
import 'timeline_controller_test.dart' show FakeTransport;

void main() {
  late DocumentStore store;
  late FakeTransport transport;
  late TimelineController controller;

  const size = Size(900, 200);

  setUp(() {
    store = DocumentStore(projectWithThreeClips());
    transport = FakeTransport(durationTicks: secs(6).raw);
    controller = TimelineController(store: store, transport: transport);
  });
  tearDown(() {
    controller.dispose();
    store.dispose();
  });

  Future<void> pumpTimeline(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: TimelineView(controller: controller),
          ),
        ),
      ),
    ));
  }

  /// Screen coordinates for a point [x] px past the lane headers, at [y]
  /// within the timeline.
  Offset at(WidgetTester tester, double x, double y) {
    final origin = tester.getTopLeft(find.byType(TimelineView));
    return origin + Offset(TimelineGeometry.headerWidth + x, y);
  }

  /// A timeline whose film is far longer than its window.
  ///
  /// Scrolling is bounded at the end of the film, so the six-second fixture
  /// above cannot be scrolled at all in a 784 px track — which is correct, and
  /// makes it useless for testing anything that pans. Anything about the view
  /// moving uses this.
  Future<TimelineController> pumpLong(WidgetTester tester) async {
    final store = DocumentStore(projectWithThreeClips());
    final transport = FakeTransport(durationTicks: secs(120).raw);
    final long = TimelineController(store: store, transport: transport);
    addTearDown(() {
      long.dispose();
      store.dispose();
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: TimelineView(controller: long),
          ),
        ),
      ),
    ));
    return long;
  }

  testWidgets('draws a document without complaint', (tester) async {
    await pumpTimeline(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('draws an empty project without complaint', (tester) async {
    final empty = DocumentStore(emptyProject());
    final quiet = FakeTransport();
    final c = TimelineController(store: empty, transport: quiet);
    addTearDown(() {
      c.dispose();
      empty.dispose();
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox.fromSize(
          size: size, child: TimelineView(controller: c))),
    ));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a drag on the ruler scrubs', (tester) async {
    await pumpTimeline(tester);

    final gesture =
        await tester.startGesture(at(tester, 80, TimelineGeometry.rulerHeight / 2));
    await tester.pump();
    await gesture.moveTo(at(tester, 240, TimelineGeometry.rulerHeight / 2));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(transport.seeks.first, secs(1).raw);
    expect(transport.positionTicks, secs(3).raw);
    expect(controller.isScrubbing, isFalse);
  });

  testWidgets('a tap in a lane selects the clip under it', (tester) async {
    await pumpTimeline(tester);

    await tester.tapAt(
        at(tester, 40, controller.geometry.topOfTrack(0) + 10));
    await tester.pump();

    expect(controller.selectedClipId, 'a');
    expect(transport.seeks, isEmpty);
  });

  testWidgets('the wheel pans, and with a modifier it zooms', (tester) async {
    final long = await pumpLong(tester);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    final where = at(tester, 200, 60);

    await tester.sendEventToBinding(pointer.hover(where));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 60)));
    await tester.pump();
    expect(long.geometry.scrollPx, 60);
    expect(long.isFollowingPlayhead, isFalse);

    final zoomBefore = long.geometry.pxPerSecond;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -10)));
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);

    expect(long.geometry.pxPerSecond, greaterThan(zoomBefore));
  });

  testWidgets('the trackpad pans, and the axis is decided once', (tester) async {
    // The wheel test above passed all along and the timeline still could not
    // be scrolled on a laptop: macOS reports a two-finger swipe as a pan/zoom
    // sequence, not as a scroll signal, and only a mouse produces the event
    // that test synthesises. So this one uses a trackpad, which is what the
    // machine the app is written on actually has.
    final long = await pumpLong(tester);
    final pointer = TestPointer(1, PointerDeviceKind.trackpad);
    final where = at(tester, 200, 60);

    await tester.sendEventToBinding(pointer.panZoomStart(where));

    // Swiping the fingers left reveals what is to the right, the way dragging
    // the film under the playhead would. `panDelta` follows the fingers where
    // a wheel's delta opposes them, so this is the sign that has to flip.
    await tester.sendEventToBinding(
        pointer.panZoomUpdate(where, pan: const Offset(-60, 0)));
    await tester.pump();
    expect(long.geometry.scrollPx, 60);
    expect(long.isFollowingPlayhead, isFalse);

    // The rest of the swipe stays on the axis it started along, however much
    // the hand drifts off it. Reading the larger axis per event instead makes
    // a diagonal swipe flip between them frame to frame — and since a vertical
    // swipe pans too, the timeline stutters under a hand moving smoothly.
    // Here the drift is ten times the intended movement and contributes
    // nothing.
    await tester.sendEventToBinding(
        pointer.panZoomUpdate(where, pan: const Offset(-64, -40)));
    await tester.pump();
    expect(long.geometry.scrollPx, 64);

    await tester.sendEventToBinding(pointer.panZoomEnd());
    await tester.pumpAndSettle();
  });

  testWidgets('a vertical swipe does not pan', (tester) async {
    // Time runs across the screen. Swiping down and having the film run
    // forwards is a gesture pointing one way and a result going another; the
    // wheel does it only because a wheel has no other axis to offer.
    final long = await pumpLong(tester);
    final pointer = TestPointer(1, PointerDeviceKind.trackpad);
    final where = at(tester, 200, 60);

    await tester.sendEventToBinding(pointer.panZoomStart(where));
    await tester.sendEventToBinding(
        pointer.panZoomUpdate(where, pan: const Offset(0, -30)));
    await tester.pump();
    expect(long.geometry.scrollPx, 0);

    // Nor does it coast afterwards: there is nothing for it to coast along.
    await tester.sendEventToBinding(pointer.panZoomEnd());
    await tester.pump(const Duration(milliseconds: 300));
    expect(long.geometry.scrollPx, 0);
  });

  testWidgets('a vertical swipe with a modifier still zooms', (tester) async {
    await pumpTimeline(tester);
    final pointer = TestPointer(1, PointerDeviceKind.trackpad);
    final where = at(tester, 200, 60);
    final before = controller.geometry.pxPerSecond;

    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendEventToBinding(pointer.panZoomStart(where));
    await tester.sendEventToBinding(
        pointer.panZoomUpdate(where, pan: const Offset(0, 30)));
    await tester.pump();
    await tester.sendEventToBinding(pointer.panZoomEnd());
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pumpAndSettle();

    expect(controller.geometry.pxPerSecond, greaterThan(before));
  });

  testWidgets('a flick keeps going after the fingers lift', (tester) async {
    // macOS sends *nothing* once contact ends — the embedder drops the inertia
    // events on the grounds that the framework generates the momentum, which
    // Scrollable does and a bare Listener does not. So the timeline stopped
    // dead on an operating system where every other window coasts, and the
    // whole of the bug was in events that never arrive. Nothing but a test
    // that lifts the fingers and then waits can see it.
    final long = await pumpLong(tester);
    final pointer = TestPointer(1, PointerDeviceKind.trackpad);
    final where = at(tester, 200, 60);

    await tester.sendEventToBinding(pointer.panZoomStart(where));
    for (var i = 1; i <= 5; i++) {
      await tester.sendEventToBinding(pointer.panZoomUpdate(
        where,
        pan: Offset(-40.0 * i, 0),
        timeStamp: Duration(milliseconds: 16 * i),
      ));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final atRelease = long.geometry.scrollPx;
    expect(atRelease, 200);

    await tester.sendEventToBinding(
        pointer.panZoomEnd(timeStamp: const Duration(milliseconds: 96)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    final coasted = long.geometry.scrollPx;
    expect(coasted, greaterThan(atRelease),
        reason: 'the swipe stopped the instant the fingers left');

    // And it stops by itself rather than running for ever.
    await tester.pumpAndSettle();
    expect(long.geometry.scrollPx, greaterThan(coasted));
  });

  testWidgets('touching the timeline stops a glide', (tester) async {
    // A coast that cannot be interrupted is worse than no coast: the next
    // thing anybody does after flinging a timeline is grab it.
    final long = await pumpLong(tester);
    final pointer = TestPointer(1, PointerDeviceKind.trackpad);
    final where = at(tester, 200, 60);

    await tester.sendEventToBinding(pointer.panZoomStart(where));
    for (var i = 1; i <= 5; i++) {
      await tester.sendEventToBinding(pointer.panZoomUpdate(
        where,
        pan: Offset(-40.0 * i, 0),
        timeStamp: Duration(milliseconds: 16 * i),
      ));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.sendEventToBinding(
        pointer.panZoomEnd(timeStamp: const Duration(milliseconds: 96)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));

    await tester.tapAt(at(tester, 300, 60));
    await tester.pump();
    final stopped = long.geometry.scrollPx;

    await tester.pump(const Duration(milliseconds: 300));
    expect(long.geometry.scrollPx, stopped);
  });

  testWidgets('scrolling stops at the end of the film', (tester) async {
    // There is nothing past the last frame, so a view that can be taken there
    // is a view that can be lost: the film goes off the left-hand edge and
    // every gesture that would bring it back looks like the one that did not
    // work. Bounded at the end, the last frame sits against the right edge and
    // swiping harder does nothing, which is what a wall is for.
    final long = await pumpLong(tester);
    // The real laid-out width, not `size`: the test window is narrower than
    // the box asks for, so the box gets what there is.
    final track = tester.getSize(find.byType(TimelineView)).width -
        TimelineGeometry.headerWidth;
    final film = secs(120).raw * long.geometry.pxPerTick;

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(at(tester, 200, 60)));
    for (var i = 0; i < 40; i++) {
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 600)));
    }
    await tester.pump();

    expect(long.geometry.scrollPx, closeTo(film - track, 0.5),
        reason: 'scrolling should stop with the last frame at the right edge');
  });

  testWidgets('a shorter film pulls the view back', (tester) async {
    // The bound moves when the document does. Deleting the last clip leaves
    // the view looking at where the film used to end, which is off the end of
    // the one that is left.
    final long = await pumpLong(tester);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(at(tester, 200, 60)));
    for (var i = 0; i < 40; i++) {
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 600)));
    }
    await tester.pump();
    final atEnd = long.geometry.scrollPx;
    expect(atEnd, greaterThan(0));

    (long.transport as FakeTransport).setDuration(secs(30).raw);
    await tester.pump();

    final track = tester.getSize(find.byType(TimelineView)).width -
        TimelineGeometry.headerWidth;
    expect(long.geometry.scrollPx, lessThan(atEnd));
    expect(long.geometry.scrollPx,
        closeTo(secs(30).raw * long.geometry.pxPerTick - track, 0.5));
  });

  testWidgets('pinching zooms, and its scale is cumulative', (tester) async {
    await pumpTimeline(tester);
    final pointer = TestPointer(1, PointerDeviceKind.trackpad);
    final where = at(tester, 200, 60);

    final zoomBefore = controller.geometry.pxPerSecond;
    await tester.sendEventToBinding(pointer.panZoomStart(where));
    await tester.sendEventToBinding(
        pointer.panZoomUpdate(where, pan: Offset.zero, scale: 1.5));
    await tester.pump();
    final zoomed = controller.geometry.pxPerSecond;
    expect(zoomed, closeTo(zoomBefore * 1.5, 0.001));

    // Reporting 1.5 again is the same pinch, not a second one.
    await tester.sendEventToBinding(
        pointer.panZoomUpdate(where, pan: Offset.zero, scale: 1.5));
    await tester.pump();
    expect(controller.geometry.pxPerSecond, zoomed);

    await tester.sendEventToBinding(pointer.panZoomEnd());
    await tester.pumpAndSettle();
  });

  group('the scrollbar', () {
    testWidgets('is there only when there is film off screen', (tester) async {
      // The one that matters. The timeline pans freely and has no edge to
      // bump into, so without a bar a two-minute edit under a twenty-second
      // window looks exactly like a twenty-second edit.
      await pumpTimeline(tester);
      expect(controller.scrollbarThumb, isNull,
          reason: 'six seconds in a 784 px window is nothing to say');

      final long = await pumpLong(tester);
      expect(long.scrollbarThumb, isNotNull);
    });

    testWidgets('dragging it pans the timeline', (tester) async {
      final long = await pumpLong(tester);
      final thumb = long.scrollbarThumb!;
      final origin = tester.getTopLeft(find.byType(TimelineView));
      final onThumb = origin +
          Offset(TimelineGeometry.headerWidth + thumb.left + thumb.width / 2,
              size.height - TimelineGeometry.scrollbarHeight / 2);

      final gesture = await tester.startGesture(onThumb);
      await tester.pump();
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(long.geometry.scrollPx, closeTo(40 * thumb.scale, 1));
    });

    testWidgets('grabbing it does not clear the selection', (tester) async {
      // The bar is a widget laid over the bottom of the same box the timeline
      // listens to, and that Listener sees every press in the box whoever
      // handles it. Below the last lane is empty space, and pressing empty
      // space means "nothing is selected" — so without a guard, reaching for
      // the scrollbar would throw away what you were working on.
      final long = await pumpLong(tester);
      long.select('a');
      await tester.pump();

      final thumb = long.scrollbarThumb!;
      final origin = tester.getTopLeft(find.byType(TimelineView));
      final gesture = await tester.startGesture(origin +
          Offset(TimelineGeometry.headerWidth + thumb.left + thumb.width / 2,
              size.height - TimelineGeometry.scrollbarHeight / 2));
      await tester.pump();
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(long.selectedClipId, 'a');
      expect(long.geometry.scrollPx, greaterThan(0));
    });

    testWidgets('pressing the track takes you there', (tester) async {
      // A press that did nothing until you moved would read as a dead bar.
      final long = await pumpLong(tester);
      final origin = tester.getTopLeft(find.byType(TimelineView));
      final track = size.width - TimelineGeometry.headerWidth;

      await tester.tapAt(origin +
          Offset(TimelineGeometry.headerWidth + track * 0.75,
              size.height - TimelineGeometry.scrollbarHeight / 2));
      await tester.pump();

      expect(long.geometry.scrollPx, greaterThan(0));
    });
  });

  group('the ticker', () {
    testWidgets('runs only while playing', (tester) async {
      await pumpTimeline(tester);

      var repaints = 0;
      controller.addListener(() => repaints++);

      // Paused: nothing per vsync. A still playhead costs nothing.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(repaints, 0);

      transport.isPlaying = true;
      transport.notifyListeners(); // one, for the state change
      final baseline = repaints;

      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(repaints, greaterThan(baseline),
          reason: 'the playhead has to move between transport notifications, '
              'and the transport does not send one per frame');

      transport.isPlaying = false;
      transport.notifyListeners();
      await tester.pump();
      final settled = repaints;
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(repaints, settled);
    });

    testWidgets('disposing while playing does not leave one running',
        (tester) async {
      transport.isPlaying = true;
      await pumpTimeline(tester);
      await tester.pump(const Duration(milliseconds: 16));

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      expect(tester.takeException(), isNull);
    });
  });
}
