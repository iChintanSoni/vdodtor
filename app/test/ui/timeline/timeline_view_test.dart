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
    await pumpTimeline(tester);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    final where = at(tester, 200, 60);

    await tester.sendEventToBinding(pointer.hover(where));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 60)));
    await tester.pump();
    expect(controller.geometry.scrollPx, 60);
    expect(controller.isFollowingPlayhead, isFalse);

    final zoomBefore = controller.geometry.pxPerSecond;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -10)));
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);

    expect(controller.geometry.pxPerSecond, greaterThan(zoomBefore));
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
