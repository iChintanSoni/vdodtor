import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/commands/document_store.dart';
import 'package:vdodtor/commands/edits.dart';
import 'package:vdodtor/model/clip.dart';
import 'package:vdodtor/model/ids.dart';
import 'package:vdodtor/model/time.dart';
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

  group('sound', () {
    // The sound section is below the transform controls, and a ListView does
    // not build what it has not laid out — so it has to be scrolled to before
    // it can be found at all.
    Future<void> scrollToSound(WidgetTester tester) => tester.scrollUntilVisible(
          find.text('SOUND'),
          120,
          scrollable: find.byType(Scrollable).first,
        );

    testWidgets('a clip with sound gets a level and fades', (tester) async {
      controller.select('b');
      await pumpInspector(tester);
      await scrollToSound(tester);

      expect(find.text('SOUND'), findsOneWidget);
      expect(find.text('Volume'), findsOneWidget);
      expect(find.text('Fade in'), findsOneWidget);
      expect(find.text('Fade out'), findsOneWidget);
    });

    testWidgets('a silent file gets no level to set', (tester) async {
      // A control that cannot do anything is worse than an absent one.
      var p = emptyProject().addMedia(videoAsset('silent', audio: false));
      p = p.updateTrack(
        mainTrackId,
        (t) => t.withClips(
            [clipOf('q', 'silent', start: Tick.zero, duration: secs(2))]),
      );
      store.dispose();
      controller.dispose();
      store = DocumentStore(p);
      controller = TimelineController(
        store: store,
        transport: FakeTransport(durationTicks: secs(6).raw),
        ids: IdGen.seeded(2),
      );
      controller.select('q');
      await pumpInspector(tester);

      expect(find.text('SOUND'), findsNothing);
      expect(find.text('FILL'), findsOneWidget);
    });

    testWidgets('a clip on an audio lane has no picture to place',
        (tester) async {
      var p = emptyProject().addMedia(audioAsset('music'));
      p = p.updateTrack(
        audioTrackId,
        (t) => t.withClips(
            [clipOf('bed', 'music', start: Tick.zero, duration: secs(4))]),
      );
      store.dispose();
      controller.dispose();
      store = DocumentStore(p);
      controller = TimelineController(
        store: store,
        transport: FakeTransport(durationTicks: secs(6).raw),
        ids: IdGen.seeded(2),
      );
      controller.select('bed');
      await pumpInspector(tester);

      expect(find.text('FILL'), findsNothing);
      expect(find.text('SOUND'), findsOneWidget);
    });

    testWidgets('the fader reads in decibels, not in multipliers',
        (tester) async {
      // The ear is logarithmic; a fader marked 0.50 tells nobody anything.
      controller.select('b');
      await pumpInspector(tester);
      await scrollToSound(tester);
      expect(find.text('0.0 dB'), findsOneWidget);

      store.run(const SetClipAudio('b', ClipAudio(volume: 0.5)));
      await tester.pump();
      expect(find.text('-6.0 dB'), findsOneWidget);
    });

    testWidgets('mute reads as silent rather than as minus infinity',
        (tester) async {
      controller.select('b');
      await pumpInspector(tester);
      await scrollToSound(tester);
      await tester.tap(find.text('Mute'));
      await tester.pump();

      expect(store.project.clipById('b')!.audio.muted, isTrue);
      expect(find.text('Muted'), findsOneWidget);

      // The fader does not drop to the bottom. Mute is not "turned all the way
      // down" — the level is kept so that unmuting gives it back, and a fader
      // that moved would be saying the opposite.
      expect(find.text('0.0 dB'), findsOneWidget);
      expect(store.project.clipById('b')!.audio.volume, 1);
    });

    testWidgets('a level of nothing reads as silent, not as -inf dB',
        (tester) async {
      controller.select('b');
      await pumpInspector(tester);
      await scrollToSound(tester);

      store.run(const SetClipAudio('b', ClipAudio(volume: 0)));
      await tester.pump();
      expect(find.text('silent'), findsOneWidget);
    });
  });

  group('the volume line', () {
    /// Scrolled to the button rather than to the section label: the button is
    /// the last thing in the panel, so bringing it into view brings the whole
    /// section with it — where stopping at the label leaves the button below
    /// the fold and untappable.
    Future<void> scrollToLine(WidgetTester tester) async {
      await tester.scrollUntilVisible(
        find.text('Point at playhead'),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('says how to make one when there is none', (tester) async {
      // ⌥-click on a waveform is not a gesture anyone guesses, so the panel
      // is where it gets said.
      controller.select('b');
      await pumpInspector(tester);
      await scrollToLine(tester);

      expect(find.textContaining('⌥-click a clip to duck it'), findsOneWidget);
      expect(find.text('Clear'), findsNothing);
    });

    testWidgets('counts the points, so a curve off screen is not invisible',
        (tester) async {
      controller.select('b');
      await pumpInspector(tester);
      await scrollToLine(tester);

      store.run(SetClipAudio(
          'b',
          ClipAudio(points: [
            VolumePoint(Tick.zero, 1),
            VolumePoint(secs(1), 0.2),
          ])));
      await tester.pump();
      expect(find.textContaining('2 points'), findsOneWidget);
    });

    testWidgets('the button adds a point where the playhead is',
        (tester) async {
      // 'b' runs 2s–5s on the main track.
      controller.select('b');
      controller.seekTo(secs(3));
      await pumpInspector(tester);
      await scrollToLine(tester);

      await tester.tap(find.text('Point at playhead'));
      await tester.pump();

      final points = store.project.clipById('b')!.audio.points;
      expect(points, hasLength(1));
      expect(points.single.sourceTime, secs(1),
          reason: 'the source time, not the timeline time');
    });

    testWidgets('and does nothing when the playhead is somewhere else',
        (tester) async {
      controller.select('b');
      controller.seekTo(secs(5) + Tick(1));
      await pumpInspector(tester);
      await scrollToLine(tester);

      final button = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Point at playhead'));
      expect(button.onPressed, isNull);
    });

    testWidgets('Clear takes the whole line away in one press', (tester) async {
      controller.select('b');
      store.run(SetClipAudio('b',
          ClipAudio(volume: 0.5, points: [VolumePoint(Tick.zero, 0.2)])));
      store.endGesture();
      await pumpInspector(tester);
      await scrollToLine(tester);

      await tester.tap(find.text('Clear'));
      await tester.pump();

      final audio = store.project.clipById('b')!.audio;
      expect(audio.points, isEmpty);
      expect(audio.volume, 0.5, reason: 'the fader is not part of the line');
    });
  });
}
