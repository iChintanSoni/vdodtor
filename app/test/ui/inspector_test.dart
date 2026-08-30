import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/commands/document_store.dart';
import 'package:vdodtor/commands/edits.dart';
import 'package:vdodtor/model/clip.dart';
import 'package:vdodtor/model/ids.dart';
import 'package:vdodtor/ui/inspector.dart';
import 'package:vdodtor/ui/timeline/timeline_controller.dart';

import '../fixtures.dart';
import 'timeline/timeline_controller_test.dart' show FakeTransport;

void main() {
  late DocumentStore store;
  late TimelineController controller;

  setUp(() {
    store = DocumentStore(projectWithThreeClips());
    controller = TimelineController(
      store: store,
      transport: FakeTransport(durationTicks: secs(6).raw),
      ids: IdGen.seeded(2),
    );
  });
  tearDown(() {
    controller.dispose();
    store.dispose();
  });

  Future<void> pumpInspector(WidgetTester tester) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimatedBuilder(
              animation: controller,
              builder: (context, _) => Inspector(timeline: controller),
            ),
          ),
        ),
      );

  testWidgets('says what to do when nothing is selected', (tester) async {
    await pumpInspector(tester);

    expect(find.textContaining('Select one clip'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets('says the same for a multi-selection', (tester) async {
    controller.selectAll();
    await pumpInspector(tester);

    // Averaging four clips' rotations into one slider is a lie that is hard
    // to notice and harder to undo.
    expect(find.textContaining('Select one clip'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets('offers the four ways of filling the frame', (tester) async {
    controller.select('b');
    await pumpInspector(tester);

    for (final label in ['Blur', 'Fit', 'Fill', 'Stretch']) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('blur fill is what a clip starts on', (tester) async {
    // Black bars make a clip look like a mistake; this makes it look
    // deliberate, so it is the default rather than an option to find.
    expect(const ClipTransform().fit, ClipFit.blurFill);

    controller.select('b');
    await pumpInspector(tester);
    await tester.tap(find.text('Fit'));
    await tester.pump();

    expect(store.project.clipById('b')!.transform.fit, ClipFit.contain);
    expect(store.undoLabels, ['Adjust clip']);
  });

  testWidgets('shows the selected clip and its controls', (tester) async {
    controller.select('b');
    await pumpInspector(tester);

    expect(find.text('b'), findsOneWidget);
    expect(find.text('Scale'), findsOneWidget);
    expect(find.text('Rotation'), findsOneWidget);
    expect(find.text('Opacity'), findsOneWidget);
    expect(find.text('Left'), findsOneWidget);
  });

  testWidgets('reads the values off the clip', (tester) async {
    store.run(const SetClipTransform('b',
        ClipTransform(scale: 2, rotationDegrees: 90, opacity: 0.5)));
    controller.select('b');
    await pumpInspector(tester);

    expect(find.text('200%'), findsOneWidget);
    expect(find.text('90°'), findsOneWidget);
    expect(find.text('50%'), findsWidgets);
  });

  testWidgets('dragging a slider edits the document', (tester) async {
    controller.select('b');
    await pumpInspector(tester);

    final scale = find.byType(Slider).first;
    await tester.drag(scale, const Offset(30, 0));
    await tester.pump();

    expect(store.project.clipById('b')!.transform.scale, greaterThan(1));
  });

  testWidgets('a slider drag is one undo entry', (tester) async {
    controller.select('b');
    await pumpInspector(tester);

    final scale = find.byType(Slider).first;
    final centre = tester.getCenter(scale);
    final gesture = await tester.startGesture(centre);
    for (var i = 1; i <= 8; i++) {
      await gesture.moveTo(centre + Offset(i * 4.0, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();

    expect(store.undoLabels, ['Adjust clip']);
    store.undo();
    expect(store.project.clipById('b')!.transform, ClipTransform.identity);
  });

  testWidgets('two drags are two undo entries', (tester) async {
    controller.select('b');
    await pumpInspector(tester);

    // Two *different* drags: repeating the same gesture from the same place
    // lands on the same value, and an edit that changes nothing is correctly
    // no edit at all.
    await tester.drag(find.byType(Slider).first, const Offset(20, 0));
    await tester.pump();
    final afterFirst = store.project.clipById('b')!.transform.scale;

    await tester.drag(find.byType(Slider).first, const Offset(-40, 0));
    await tester.pump();

    expect(store.project.clipById('b')!.transform.scale,
        isNot(closeTo(afterFirst, 1e-9)));
    expect(store.undoLabels, hasLength(2),
        reason: 'letting go of the slider ends the gesture');
  });

  testWidgets('flip is a button, and it toggles', (tester) async {
    controller.select('b');
    await pumpInspector(tester);

    // The panel scrolls; the flip buttons live below the crop sliders.
    await tester.ensureVisible(find.text('Flip H'));
    await tester.pump();
    await tester.tap(find.text('Flip H'));
    await tester.pump();
    expect(store.project.clipById('b')!.transform.flipHorizontal, isTrue);

    await tester.ensureVisible(find.text('Flip H'));
    await tester.pump();
    await tester.tap(find.text('Flip H'));
    await tester.pump();
    expect(store.project.clipById('b')!.transform.flipHorizontal, isFalse);
    expect(store.undoLabels, hasLength(2));
  });

  testWidgets('reset appears only once there is something to reset',
      (tester) async {
    controller.select('b');
    await pumpInspector(tester);
    expect(find.text('Reset'), findsNothing);

    await tester.drag(find.byType(Slider).first, const Offset(30, 0));
    await tester.pump();
    expect(find.text('Reset'), findsOneWidget);

    await tester.tap(find.text('Reset'));
    await tester.pump();
    expect(store.project.clipById('b')!.transform, ClipTransform.identity);
    expect(find.text('Reset'), findsNothing);
  });
}
