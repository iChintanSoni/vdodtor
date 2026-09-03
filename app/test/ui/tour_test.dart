import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/ui/tour.dart';

/// The tour is tested away from the editor on purpose.
///
/// [EditorScreen] cannot be pumped in a widget test — it makes a real
/// [PreviewEngine], which needs the native library — so a tour that could only
/// be exercised inside it would be a first-run experience with no test at all.
/// Everything here is about the mechanism: what it points at, how it advances,
/// and that it stops once.
void main() {
  late TourAnchors anchors;

  setUp(() => anchors = makeTourAnchors());

  /// A stand-in editor: five boxes in the places the real panels are, each
  /// carrying the key the real panel carries.
  Widget harness({
    required List<TourStop> stops,
    required VoidCallback onFinished,
    double binWidth = 160,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Column(
                children: [
                  Row(children: [
                    SizedBox(
                        key: anchors.export, width: 90, height: 30),
                  ]),
                  Expanded(
                    child: Row(
                      children: [
                        SizedBox(key: anchors.bin, width: binWidth),
                        Expanded(child: SizedBox(key: anchors.preview)),
                        SizedBox(key: anchors.inspector, width: 200),
                      ],
                    ),
                  ),
                  SizedBox(key: anchors.timeline, height: 120),
                ],
              ),
              TourOverlay(stops: stops, onFinished: onFinished),
            ],
          ),
        ),
      );

  testWidgets('shows the first stop, and counts them', (tester) async {
    await tester.pumpWidget(
        harness(stops: editorTour(anchors), onFinished: () {}));
    await tester.pump();

    expect(find.text('This is your film'), findsOneWidget);
    expect(find.text('1 of 6'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
    expect(find.text('Skip tour'), findsOneWidget);
  });

  testWidgets('Next walks all the way to the end', (tester) async {
    var finished = 0;
    final stops = editorTour(anchors);
    await tester
        .pumpWidget(harness(stops: stops, onFinished: () => finished++));
    await tester.pump();

    for (var i = 0; i < stops.length - 1; i++) {
      expect(find.text(stops[i].title), findsOneWidget);
      expect(find.text('${i + 1} of ${stops.length}'), findsOneWidget);
      await tester.tap(find.text('Next'));
      await tester.pump();
    }

    // The last card has no Skip on it: there is nothing left to skip, and an
    // offer to abandon a tour that has already finished is a second button
    // doing the first one's job.
    expect(find.text(stops.last.title), findsOneWidget);
    expect(find.text('Skip tour'), findsNothing);
    expect(find.text('Start editing'), findsOneWidget);
    expect(finished, 0);

    await tester.tap(find.text('Start editing'));
    await tester.pump();
    expect(finished, 1);
  });

  testWidgets('Skip finishes it, and finishing is finishing', (tester) async {
    // Skipped and completed are the same outcome: both mean "do not show this
    // again", and a product that treats Skip as unfinished business shows the
    // tour twice.
    var finished = 0;
    await tester.pumpWidget(harness(
        stops: editorTour(anchors), onFinished: () => finished++));
    await tester.pump();

    await tester.tap(find.text('Skip tour'));
    await tester.pump();
    expect(finished, 1);
  });

  testWidgets('Escape skips it and Enter advances it', (tester) async {
    var finished = 0;
    final stops = editorTour(anchors);
    await tester
        .pumpWidget(harness(stops: stops, onFinished: () => finished++));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text(stops[1].title), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(finished, 1);
  });

  testWidgets('the hole lands on the panel the stop names', (tester) async {
    await tester.pumpWidget(
        harness(stops: editorTour(anchors), onFinished: () {}));
    // Two pumps: the rect is measured after the frame that laid the panels
    // out, and applied in the one after that.
    await tester.pump();
    await tester.pump();

    expect(_hole(tester), _around(tester.getRect(find.byKey(anchors.preview))));

    // The third stop points at the bin, which is somewhere else entirely.
    await tester.tap(find.text('Next'));
    await tester.pump();
    await tester.tap(find.text('Next'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Your footage'), findsOneWidget);
    expect(_hole(tester), _around(tester.getRect(find.byKey(anchors.bin))));
  });

  testWidgets('the hole follows a panel that moves', (tester) async {
    // The things being pointed at move for reasons the tour cannot see: a
    // resized window, an engine that finishes starting and replacing a
    // spinner with a preview, a lane that appears. Measuring once would leave
    // the highlight behind the thing it is highlighting.
    final stops = editorTour(anchors);
    await tester.pumpWidget(harness(stops: stops, onFinished: () {}));
    await tester.pump();
    await tester.pump();
    final before = _hole(tester);

    await tester.pumpWidget(
        harness(stops: stops, onFinished: () {}, binWidth: 320));
    await tester.pump();
    await tester.pump();

    expect(_hole(tester), isNot(before));
    expect(_hole(tester), _around(tester.getRect(find.byKey(anchors.preview))));
  });

  testWidgets('the last stop dims everything and cuts nothing out',
      (tester) async {
    // It is about the app rather than about a panel, so there is nothing to
    // point at — and a hole left over from the stop before would be pointing
    // at the wrong thing while the card talked about something else.
    const stop = TourStop(title: 'Only', body: 'No target here.');
    await tester
        .pumpWidget(harness(stops: const [stop], onFinished: () {}));
    await tester.pump();
    await tester.pump();

    expect(_holeOrNull(tester), isNull);
    expect(find.text('Start editing'), findsOneWidget);
  });

  testWidgets('a click on the scrim does not reach what is under it',
      (tester) async {
    // The hole is a highlight, not a door. A tour whose fourth stop can be
    // dismissed by clicking the panel it is describing ends by accident.
    var tapsUnderneath = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => tapsUnderneath++,
                child: SizedBox(key: anchors.preview),
              ),
            ),
            TourOverlay(
              stops: const [TourStop(title: 'One', body: 'Two')],
              onFinished: () {},
            ),
          ],
        ),
      ),
    ));
    await tester.pump();

    await tester.tapAt(const Offset(20, 20));
    await tester.pump();
    expect(tapsUnderneath, 0);
  });

  test('every anchor the tour names is attached in the editor', () {
    // The record makes a stop naming an anchor nobody declared a compile
    // error; it cannot make one naming an anchor nobody *attached*. EditorScreen
    // is not pumpable in a widget test — it builds a real PreviewEngine — so
    // this reads the source instead, which is the arrangement about_test.dart
    // already uses for the things a sandbox hides from a test.
    final source = File('lib/ui/editor_screen.dart').readAsStringSync();
    for (final field in [
      'preview',
      'timeline',
      'bin',
      'inspector',
      'export',
    ]) {
      expect(source, contains('_anchors.$field'),
          reason: 'the tour points at $field and nothing carries its key');
    }
  });

  testWidgets('every stop says something', (tester) async {
    // Cheap, and it is the thing that goes wrong when a stop is added in a
    // hurry: an anchor with no words, or words with a title nobody wrote.
    for (final stop in editorTour(anchors)) {
      expect(stop.title.trim(), isNotEmpty);
      expect(stop.body.trim().length, greaterThan(40));
    }
  });
}

/// Where the tour is currently pointing, read off the scrim it paints.
Rect _hole(WidgetTester tester) => _holeOrNull(tester)!;

Rect? _holeOrNull(WidgetTester tester) =>
    (tester.widget<CustomPaint>(find.byKey(scrimKey)).painter!
            as TourScrimPainter)
        .hole;

/// The hole is inflated a little past the widget so it reads as a highlight
/// rather than as a crop; this is "the same rect, give or take that".
Matcher _around(Rect target) => predicate<Rect>(
      (r) =>
          (r.center - target.center).distance < 1 &&
          (r.width - target.width).abs() <= 16 &&
          (r.height - target.height).abs() <= 16,
      'a rect sitting on $target',
    );
