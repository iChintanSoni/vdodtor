import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/commands/document_store.dart';
import 'package:vdodtor/commands/edits.dart';
import 'package:vdodtor/media/looks.dart';
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

  Future<void> pumpInspector(WidgetTester tester,
          {Future<String?> Function()? onLoadLook,
          Future<int?> Function()? onPickKeyColour,
          bool matteView = false,
          ValueChanged<bool>? onMatteView}) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimatedBuilder(
              animation: controller,
              builder: (context, _) => Inspector(
                timeline: controller,
                onLoadLook: onLoadLook,
                onPickKeyColour: onPickKeyColour,
                matteView: matteView,
                onMatteView: onMatteView,
              ),
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

    /// Scrolls until [finder] itself is on screen, which is what a test that
    /// *taps* something needs: the section heading being visible says nothing
    /// about a control further down it, and a section added above pushes it
    /// off the bottom.
    Future<void> scrollToControl(WidgetTester tester, Finder finder) async {
      await tester.scrollUntilVisible(finder, 60,
          scrollable: find.byType(Scrollable).first);
      // scrollUntilVisible stops as soon as the widget is *built*, and a
      // ListView builds a little past the edge of what it shows — so the thing
      // it just found can still be off screen and untappable.
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
    }

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

    testWidgets('a clip with sound gets an EQ picker, and it sets one',
        (tester) async {
      controller.select('b');
      await pumpInspector(tester);
      await scrollToControl(tester, find.text('EQ'));

      // Inside the EQ dropdown specifically: "None" is also what an animation
      // preset with nothing chosen calls itself, and there are two of those.
      expect(
        find.descendant(
          of: find.byType(DropdownButtonFormField<EqPreset>),
          matching: find.text(EqPreset.none.label),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byType(DropdownButtonFormField<EqPreset>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(EqPreset.voice.label).last);
      await tester.pumpAndSettle();

      expect(store.project.clipById('b')!.audio.eq, EqPreset.voice);
      expect(store.undoLabels, ['Adjust audio']);
    });

    testWidgets('the fade shape appears only once there is a fade',
        (tester) async {
      // A curve on a clip with no fades is a control that silently does
      // nothing, which is the one kind that teaches people not to trust the
      // panel.
      controller.select('b');
      await pumpInspector(tester);
      await scrollToSound(tester);
      expect(find.text('Shape'), findsNothing);

      store.run(SetClipAudio('b', ClipAudio(fadeIn: secs(1))));
      store.endGesture();
      await tester.pumpAndSettle();
      await scrollToControl(tester, find.text('Shape'));

      expect(
        find.descendant(
          of: find.byType(DropdownButtonFormField<FadeCurve>),
          matching: find.text(FadeCurve.linear.label),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byType(DropdownButtonFormField<FadeCurve>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(FadeCurve.equalPower.label).last);
      await tester.pumpAndSettle();

      expect(store.project.clipById('b')!.audio.fadeCurve,
          FadeCurve.equalPower);
      // And the fade it shapes is untouched: a shape is not a length.
      expect(store.project.clipById('b')!.audio.fadeIn, secs(1));
    });

    testWidgets('Reset takes the EQ and the shape with it', (tester) async {
      controller.select('b');
      store.run(SetClipAudio(
          'b',
          ClipAudio(
              fadeIn: secs(1),
              fadeCurve: FadeCurve.smooth,
              eq: EqPreset.telephone)));
      store.endGesture();
      await pumpInspector(tester);
      await scrollToSound(tester);

      await tester.tap(find.descendant(
        of: find.ancestor(
          of: find.text('SOUND'),
          matching: find.byType(Row),
        ).first,
        matching: find.text('Reset'),
      ));
      await tester.pump();

      expect(store.project.clipById('b')!.audio, ClipAudio.unity);
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
      await scrollToControl(tester, find.text('Mute'));
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

  group('a caption', () {
    /// Adds one at the playhead and selects it, which is what the toolbar
    /// button does.
    String addCaption() {
      controller.addTextClip();
      return controller.selectedClipId!;
    }

    Future<void> scrollTo(WidgetTester tester, Finder finder) async {
      await tester.scrollUntilVisible(finder, 120,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
    }

    testWidgets('gets a field with its words in it', (tester) async {
      addCaption();
      await pumpInspector(tester);

      expect(find.byType(TextField), findsOneWidget);
      expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'Text');
    });

    testWidgets('typing into the field reaches the document', (tester) async {
      final id = addCaption();
      await pumpInspector(tester);

      await tester.enterText(find.byType(TextField), 'Hello there');
      await tester.pump();

      expect(store.project.clipById(id)!.text!.text, 'Hello there');
    });

    testWidgets('an ordinary clip gets no text field', (tester) async {
      controller.select('b');
      await pumpInspector(tester);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('and a caption gets no fit or crop', (tester) async {
      // Its raster is made at the size of the frame, so a fit mode would do
      // nothing and a crop would cut the words off.
      addCaption();
      await pumpInspector(tester);
      await scrollTo(tester, find.text('PLACE'));

      expect(find.text('FILL'), findsNothing);
      expect(find.text('CROP'), findsNothing);
      expect(find.text('Flip H'), findsNothing);
      expect(find.text('PLACE'), findsOneWidget);
    });

    testWidgets('the shadow controls appear only once there is a shadow',
        (tester) async {
      final id = addCaption();
      await pumpInspector(tester);
      await scrollTo(tester, find.text('SHADOW'));
      expect(find.text('Blur'), findsNothing);

      store.run(SetClipText(
          id, const ClipText(text: 'Text', shadowColor: 0xB3000000)));
      store.endGesture();
      await tester.pumpAndSettle();
      await scrollTo(tester, find.text('Blur'));
      expect(find.text('Blur'), findsOneWidget);
    });

    testWidgets('the box controls appear only once there is a box',
        (tester) async {
      final id = addCaption();
      await pumpInspector(tester);
      await scrollTo(tester, find.text('BOX'));
      expect(find.text('Padding'), findsNothing);

      store.run(SetClipText(
          id, const ClipText(text: 'Text', boxColor: 0x99000000)));
      store.endGesture();
      await tester.pumpAndSettle();
      await scrollTo(tester, find.text('Padding'));
      expect(find.text('Padding'), findsOneWidget);
    });

    testWidgets('alignment is three buttons, and pressing one lands',
        (tester) async {
      final id = addCaption();
      await pumpInspector(tester);

      await tester.tap(find.byIcon(Icons.format_align_left));
      await tester.pump();

      expect(store.project.clipById(id)!.text!.alignment, TextAlignment.left);
    });

    testWidgets('undo puts the old words back in the field', (tester) async {
      // The field owns the caret, so it is not rebuilt from the document on
      // every keystroke — which means an edit from outside has to be pushed
      // into it deliberately.
      final id = addCaption();
      await pumpInspector(tester);

      await tester.enterText(find.byType(TextField), 'Changed');
      await tester.pump();
      expect(store.project.clipById(id)!.text!.text, 'Changed');

      store.undo();
      await tester.pumpAndSettle();

      expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'Text');
    });
  });

  group('a shape', () {
    /// Adds one at the playhead and selects it, which is what the toolbar
    /// button does.
    String addShape([ShapeKind kind = ShapeKind.rectangle]) {
      controller.addShapeClip(kind: kind);
      return controller.selectedClipId!;
    }

    Future<void> scrollTo(WidgetTester tester, Finder finder) async {
      await tester.scrollUntilVisible(finder, 120,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
    }

    testWidgets('gets the four kinds and no text field', (tester) async {
      addShape();
      await pumpInspector(tester);

      expect(find.text('SHAPE'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      for (final icon in [
        Icons.crop_square,
        Icons.circle_outlined,
        Icons.remove,
        Icons.arrow_right_alt,
      ]) {
        expect(find.byIcon(icon), findsOneWidget);
      }
    });

    testWidgets('an ordinary clip gets no shape controls', (tester) async {
      controller.select('b');
      await pumpInspector(tester);
      expect(find.text('SHAPE'), findsNothing);
    });

    testWidgets('a caption gets no shape controls either', (tester) async {
      controller.addTextClip();
      await pumpInspector(tester);
      expect(find.text('SHAPE'), findsNothing);
    });

    testWidgets('picking a kind lands, and keeps the shape visible',
        (tester) async {
      // Switching a filled rectangle to a line has to carry its colour into
      // the stroke and give the stroke a width, or the clip vanishes.
      final id = addShape();
      await pumpInspector(tester);

      await tester.tap(find.byIcon(Icons.remove));
      await tester.pump();

      final shape = store.project.clipById(id)!.shape!;
      expect(shape.kind, ShapeKind.line);
      expect(shape.isBlank, isFalse);
    });

    testWidgets('a line is measured by its length, not its height',
        (tester) async {
      // A line runs across the middle of its box, so the box's height changes
      // nothing about it — and a slider that moves nothing is a slider that
      // teaches people not to trust the panel.
      addShape(ShapeKind.line);
      await pumpInspector(tester);

      expect(find.text('Length'), findsOneWidget);
      expect(find.text('Height'), findsNothing);
      expect(find.text('LINE'), findsOneWidget);
      expect(find.text('OUTLINE'), findsNothing);
    });

    testWidgets('only a rectangle gets a corner and only an arrow a head',
        (tester) async {
      addShape();
      await pumpInspector(tester);
      expect(find.text('Corner'), findsOneWidget);
      expect(find.text('Head'), findsNothing);

      await tester.tap(find.byIcon(Icons.arrow_right_alt));
      await tester.pumpAndSettle();
      expect(find.text('Corner'), findsNothing);
      expect(find.text('Head'), findsOneWidget);
    });

    testWidgets('a line gets no fill, because it has no interior',
        (tester) async {
      addShape();
      await pumpInspector(tester);
      expect(find.text('Fill'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.remove));
      await tester.pumpAndSettle();
      expect(find.text('Fill'), findsNothing);
    });

    testWidgets('the shadow controls appear only once there is a shadow',
        (tester) async {
      final id = addShape();
      await pumpInspector(tester);
      await scrollTo(tester, find.text('SHADOW'));
      expect(find.text('Blur'), findsNothing);

      store.run(SetClipShape(id, const ClipShape(shadowColor: 0xB3000000)));
      store.endGesture();
      await tester.pumpAndSettle();
      await scrollTo(tester, find.text('Blur'));
      expect(find.text('Blur'), findsOneWidget);
    });

    testWidgets('a shape gets no fit or crop', (tester) async {
      // Its raster is made at the size of the frame, so a fit mode would do
      // nothing and a crop would cut the corner off the rectangle.
      addShape();
      await pumpInspector(tester);
      await scrollTo(tester, find.text('PLACE'));

      expect(find.text('FILL'), findsNothing);
      expect(find.text('CROP'), findsNothing);
      expect(find.text('PLACE'), findsOneWidget);
    });

    testWidgets('and it can still be animated', (tester) async {
      // An animation is the transform the clip already has, over time. A shape
      // that could not pop in would be the odd one out for no reason.
      addShape();
      await pumpInspector(tester);
      await scrollTo(tester, find.text('ANIMATE'));
      expect(find.text('ANIMATE'), findsOneWidget);
    });
  });

  group('a join', () {
    Future<void> scrollToJoin(WidgetTester tester) async {
      await tester.scrollUntilVisible(find.text('JOIN'), 120,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
    }

    testWidgets('every clip with a picture gets the picker', (tester) async {
      controller.select('b');
      await pumpInspector(tester);
      await scrollToJoin(tester);
      expect(find.text('JOIN'), findsOneWidget);
      // No length to drag until there is something to give one to.
      expect(find.text('Length'), findsNothing);
    });

    testWidgets('a clip with nothing before it says so', (tester) async {
      // The control still appears — a transition with no cut under it does
      // nothing, and hiding it would mean re-picking one every time a clip was
      // dragged away from its neighbour and back.
      controller.select('a');
      await pumpInspector(tester);
      await scrollToJoin(tester);
      expect(find.text('Nothing before it on this lane'), findsOneWidget);
    });

    testWidgets('a clip that meets another does not', (tester) async {
      controller.select('b');
      await pumpInspector(tester);
      await scrollToJoin(tester);
      expect(find.text('Nothing before it on this lane'), findsNothing);
    });

    testWidgets('picking a preset gives it a length', (tester) async {
      // Otherwise the first thing anybody does after choosing one is discover
      // that it did nothing.
      controller.select('b');
      await pumpInspector(tester);
      await scrollToJoin(tester);

      await tester.tap(find.byType(DropdownButtonFormField<TransitionPreset>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dissolve').last);
      await tester.pumpAndSettle();

      final transition = store.project.clipById('b')!.transition;
      expect(transition.preset, TransitionPreset.dissolve);
      expect(transition.duration, ClipTransition.defaultDuration);
      expect(transition.isActive, isTrue);
    });

    testWidgets('the length only appears once there is a transition',
        (tester) async {
      final id = controller.project.mainTrack.clips[1].id;
      controller.select(id);
      await pumpInspector(tester);
      await scrollToJoin(tester);
      expect(find.text('Length'), findsNothing);

      store.run(SetClipTransition(
          id,
          ClipTransition(
              preset: TransitionPreset.wipe, duration: secs(1))));
      store.endGesture();
      await tester.pumpAndSettle();
      await scrollToJoin(tester);
      expect(find.text('Length'), findsOneWidget);
    });

    testWidgets('resetting it back to a plain cut', (tester) async {
      final id = controller.project.mainTrack.clips[1].id;
      controller.select(id);
      store.run(SetClipTransition(
          id,
          ClipTransition(
              preset: TransitionPreset.push, duration: secs(1))));
      store.endGesture();
      await pumpInspector(tester);
      await scrollToJoin(tester);

      await tester.tap(find.text('Cut'));
      await tester.pumpAndSettle();
      expect(store.project.clipById(id)!.transition, ClipTransition.none);
    });
  });

  group('colour', () {
    Future<void> scrollToColour(WidgetTester tester) async {
      await tester.scrollUntilVisible(find.text('COLOUR'), 120,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
    }

    /// The readout beside one named slider. Scoped to its own row, because
    /// "0%" is what most of the transform's sliders say too.
    String readout(WidgetTester tester, String label) => tester
        .widgetList<Text>(find.descendant(
          of: find.ancestor(
              of: find.text(label), matching: find.byType(Row)).first,
          matching: find.byType(Text),
        ))
        .last
        .data!;

    testWidgets('a clip with a picture gets all five sliders', (tester) async {
      controller.select('b');
      await pumpInspector(tester);
      await scrollToColour(tester);

      for (final label in [
        'Temperature',
        'Tint',
        'Brightness',
        'Contrast',
        'Saturation',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
    });

    testWidgets('they are offered in the order they are applied',
        (tester) async {
      // Fix the light, set the level, set the contrast, and judge the colour
      // last — the order anybody grades in, and the order the engine composes
      // them in. A panel in some other order teaches the wrong habit.
      controller.select('b');
      await pumpInspector(tester);
      await scrollToColour(tester);

      double top(String label) =>
          tester.getTopLeft(find.text(label)).dy;
      expect(top('Temperature'), lessThan(top('Tint')));
      expect(top('Tint'), lessThan(top('Brightness')));
      expect(top('Brightness'), lessThan(top('Contrast')));
      expect(top('Contrast'), lessThan(top('Saturation')));
    });

    testWidgets('a caption does not get them', (tester) async {
      // A caption is drawn from colours the sections above already offer, and
      // a saturation slider fighting a colour picker is two controls for one
      // decision.
      controller.addTextClip();
      await pumpInspector(tester);
      expect(find.text('COLOUR'), findsNothing);
    });

    testWidgets('dragging one grades the clip', (tester) async {
      controller.select('b');
      await pumpInspector(tester);
      await scrollToColour(tester);

      final slider = find.ancestor(
        of: find.text('Saturation'),
        matching: find.byType(Column),
      );
      await tester.drag(
          find.descendant(of: slider.first, matching: find.byType(Slider)),
          const Offset(-40, 0));
      await tester.pumpAndSettle();

      expect(store.project.clipById('b')!.color.saturation, lessThan(0));
      expect(store.project.clipById('b')!.color.isNeutral, isFalse);
    });

    testWidgets('a neutral grade reads as nothing changed', (tester) async {
      // "0%" rather than "100%": a grade is a change, and the number should be
      // the size of the change.
      controller.select('b');
      await pumpInspector(tester);
      await scrollToColour(tester);

      for (final label in ['Temperature', 'Brightness', 'Saturation']) {
        expect(readout(tester, label), '0%');
      }
    });

    testWidgets('an off-centre slider says which way', (tester) async {
      store.run(const SetClipColor(
          'b', ClipColor(temperature: 0.5, saturation: -0.25)));
      store.endGesture();
      controller.select('b');
      await pumpInspector(tester);
      await scrollToColour(tester);

      expect(readout(tester, 'Temperature'), '+50%');
      expect(readout(tester, 'Saturation'), '-25%');
    });

    testWidgets('the reset only appears once there is a grade', (tester) async {
      controller.select('b');
      await pumpInspector(tester);
      await scrollToColour(tester);
      // The transform's own Reset is the other one, and it is not showing
      // either: an untouched clip has nothing to put back.
      expect(find.text('Reset'), findsNothing);

      store.run(const SetClipColor('b', ClipColor(contrast: 0.4)));
      store.endGesture();
      await tester.pumpAndSettle();
      await scrollToColour(tester);
      expect(find.text('Reset'), findsOneWidget);

      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();
      expect(store.project.clipById('b')!.color, ClipColor.neutral);
    });

    testWidgets('the reset appears for a look with no slider moved',
        (tester) async {
      // A look is a grade too, and it is one somebody may well want off in one
      // press rather than by hunting back through the picker.
      store.run(const SetClipColor('b', ClipColor(look: 'Noir')));
      store.endGesture();
      controller.select('b');
      await pumpInspector(tester);
      await scrollToColour(tester);
      expect(find.text('Reset'), findsOneWidget);
    });

    testWidgets('the look is offered under the five sliders', (tester) async {
      // Because that is where it runs: correct the shot, then style it. A
      // panel that put the look first would be teaching the wrong habit, the
      // same reason temperature sits above saturation.
      controller.select('b');
      await pumpInspector(tester);
      await scrollToColour(tester);

      expect(find.text('Look'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Saturation')).dy,
          lessThan(tester.getTopLeft(find.text('Look')).dy));
    });

    testWidgets('every bundled look is on offer, and None with them',
        (tester) async {
      controller.select('b');
      await pumpInspector(tester);
      await scrollToColour(tester);

      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      expect(find.text('None'), findsWidgets);
      for (final name in BundledLooks.names) {
        expect(find.text(name), findsWidgets, reason: name);
      }
    });

    testWidgets('picking one puts it on the clip', (tester) async {
      controller.select('b');
      await pumpInspector(tester);
      await scrollToColour(tester);

      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Noir').last);
      await tester.pumpAndSettle();

      expect(store.project.clipById('b')!.color.look, 'Noir');
      expect(store.project.clipById('b')!.color.lookStrength, 1);
    });

    testWidgets('the strength only appears once there is a look',
        (tester) async {
      // A slider under "None" is a control that does nothing, and one that
      // stayed put would invite a drag and a puzzled look at the picture.
      controller.select('b');
      await pumpInspector(tester);
      await scrollToColour(tester);
      expect(find.text('Strength'), findsNothing);

      store.run(const SetClipColor('b', ClipColor(look: 'Faded')));
      store.endGesture();
      await tester.pumpAndSettle();
      await scrollToColour(tester);
      expect(find.text('Strength'), findsOneWidget);
      expect(readout(tester, 'Strength'), '100%');
    });

    testWidgets('the strength reads as a proportion, not as a change',
        (tester) async {
      // Unsigned, unlike the five above it: a strength is how much of a look
      // there is rather than how far from neutral the shot has moved, so
      // there is no centre for it to be off.
      store.run(const SetClipColor(
          'b', ClipColor(look: 'Faded', lookStrength: 0.4)));
      store.endGesture();
      controller.select('b');
      await pumpInspector(tester);
      await scrollToColour(tester);
      expect(readout(tester, 'Strength'), '40%');
    });

    testWidgets('a look this build does not have still shows its name',
        (tester) async {
      // Otherwise changing anything else about the clip would silently drop a
      // look the project is asking for, and there would be no way to see that
      // it had been.
      store.run(const SetClipColor('b', ClipColor(look: 'Somebody Elses')));
      store.endGesture();
      controller.select('b');
      await pumpInspector(tester);
      await scrollToColour(tester);
      expect(find.text('Somebody Elses'), findsOneWidget);
    });

    testWidgets('Load… is hidden when there is nowhere to load from',
        (tester) async {
      controller.select('b');
      await pumpInspector(tester);
      await scrollToColour(tester);
      expect(find.text('Load…'), findsNothing);
    });

    testWidgets('loading a cube puts it on the clip in one step',
        (tester) async {
      controller.select('b');
      await pumpInspector(tester, onLoadLook: () async => 'Kodak 2383');
      await scrollToColour(tester);

      await tester.tap(find.text('Load…'));
      await tester.pumpAndSettle();

      expect(store.project.clipById('b')!.color.look, 'Kodak 2383');
      // One undo step, not two: loading it is how the user chose it.
      store.undo();
      expect(store.project.clipById('b')!.color.look, isEmpty);
    });

    testWidgets('cancelling the panel changes nothing', (tester) async {
      controller.select('b');
      await pumpInspector(tester, onLoadLook: () async => null);
      await scrollToColour(tester);

      await tester.tap(find.text('Load…'));
      await tester.pumpAndSettle();
      expect(store.project.clipById('b')!.color, ClipColor.neutral);
    });
  });

  group('animation', () {
    Future<void> scrollToAnimate(WidgetTester tester) async {
      await tester.scrollUntilVisible(find.text('ANIMATE'), 120,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
    }

    testWidgets('every clip with a picture gets the two pickers',
        (tester) async {
      // An animation is the transform a clip already has, over time, so there
      // is nothing about it only a caption can do.
      controller.select('b');
      await pumpInspector(tester);
      await scrollToAnimate(tester);

      expect(find.text('ANIMATE'), findsOneWidget);
      expect(find.text('In'), findsOneWidget);
      expect(find.text('Out'), findsOneWidget);
      // Nothing chosen, so no lengths to drag.
      expect(find.text('In length'), findsNothing);
      expect(find.text('Out length'), findsNothing);
    });

    testWidgets('choosing a preset gives it a length to run in',
        (tester) async {
      controller.select('b');
      await pumpInspector(tester);
      await scrollToAnimate(tester);

      await tester.tap(find.byType(DropdownButtonFormField<AnimationPreset>)
          .first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(AnimationPreset.pop.label).last);
      await tester.pumpAndSettle();

      final animation = store.project.clipById('b')!.animation;
      expect(animation.inPreset, AnimationPreset.pop);
      expect(animation.inDuration.raw, greaterThan(0),
          reason: 'a picker whose entries do nothing is a picker nobody '
              'trusts');

      await scrollToAnimate(tester);
      expect(find.text('In length'), findsOneWidget);
    });

    testWidgets('the typewriter is offered only where it would do something',
        (tester) async {
      controller.select('b');
      await pumpInspector(tester);
      await scrollToAnimate(tester);
      await tester.tap(find.byType(DropdownButtonFormField<AnimationPreset>)
          .first);
      await tester.pumpAndSettle();
      expect(find.text(AnimationPreset.typewriter.label), findsNothing);
      await tester.tapAt(const Offset(5, 5));  // dismiss
      await tester.pumpAndSettle();

      controller.addTextClip();
      await tester.pumpAndSettle();
      await scrollToAnimate(tester);
      await tester.tap(find.byType(DropdownButtonFormField<AnimationPreset>)
          .first);
      await tester.pumpAndSettle();
      expect(find.text(AnimationPreset.typewriter.label), findsWidgets);
    });

    testWidgets('Reset takes both halves away in one press', (tester) async {
      controller.select('b');
      store.run(SetClipAnimation(
        'b',
        ClipAnimation(
          inPreset: AnimationPreset.fade,
          inDuration: secs(0.4),
          outPreset: AnimationPreset.zoom,
          outDuration: secs(0.4),
        ),
      ));
      store.endGesture();
      await pumpInspector(tester);
      await scrollToAnimate(tester);

      // Two Resets on screen — the transform's and this one — so it is the
      // one inside the animation section that has to be pressed.
      await tester.tap(find.descendant(
        of: find.ancestor(
          of: find.text('ANIMATE'),
          matching: find.byType(Row),
        ).first,
        matching: find.text('Reset'),
      ));
      await tester.pump();

      expect(store.project.clipById('b')!.animation, ClipAnimation.still);
    });
  });

  group('speed', () {
    Future<void> scrollToSpeed(WidgetTester tester) async {
      await tester.scrollUntilVisible(find.text('SPEED'), 120,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
    }

    testWidgets('a clip whose source runs gets the section', (tester) async {
      controller.select('b');
      await pumpInspector(tester);
      await scrollToSpeed(tester);

      expect(find.text('SPEED'), findsOneWidget);
      expect(find.text('Rate'), findsOneWidget);
      expect(find.text('1.0×'), findsWidgets);
      // Nothing to shift the pitch of yet: at its own speed the two answers
      // agree, and a toggle that changes nothing is one nobody trusts.
      expect(find.text('Pitch kept'), findsNothing);
    });

    testWidgets('a caption has no source to run', (tester) async {
      controller.addTextClip();
      await pumpInspector(tester);
      await tester.pumpAndSettle();

      expect(find.text('SPEED'), findsNothing);
    });

    testWidgets('a preset retimes the clip and repacks the lane',
        (tester) async {
      controller.select('a');  // 0–2s, with b and c behind it
      await pumpInspector(tester);
      await scrollToSpeed(tester);

      await tester.tap(find.text('2.0×'));
      await tester.pump();

      expect(store.project.clipById('a')!.speed.rate, 2);
      expect(store.project.clipById('a')!.duration, secs(1));
      expect(store.project.clipById('b')!.start, secs(1),
          reason: 'the magnetic lane closes up behind it');
      expect(store.undoLabels, ['Change speed']);
    });

    testWidgets('the pitch toggle appears once there is a speed',
        (tester) async {
      controller.select('b');
      await pumpInspector(tester);
      await scrollToSpeed(tester);
      await tester.tap(find.text('0.50×'));
      await tester.pumpAndSettle();
      await scrollToSpeed(tester);

      expect(find.text('Pitch kept'), findsOneWidget);
      await tester.tap(find.text('Pitch kept'));
      await tester.pump();

      expect(store.project.clipById('b')!.speed.pitchShift, isTrue);
      await scrollToSpeed(tester);
      expect(find.text('Pitch shifts'), findsOneWidget);
    });

    testWidgets('the rate slider runs slow on the left and fast on the right',
        (tester) async {
      // A log scale, so 1x sits in the middle rather than a tenth of the way
      // along — and a scale that came out inverted would still look like a
      // working slider.
      final rate = find.descendant(
        of: find
            .ancestor(of: find.text('Rate'), matching: find.byType(Column))
            .first,
        matching: find.byType(Slider),
      );

      controller.select('b');  // 2–5s on the magnetic lane
      await pumpInspector(tester);
      await scrollToSpeed(tester);
      await tester.drag(rate, const Offset(30, 0));
      await tester.pumpAndSettle();

      final fast = store.project.clipById('b')!;
      expect(fast.speed.rate, greaterThan(1));
      expect(fast.duration.raw, lessThan(secs(3).raw));
      // The same frames, to within the tick a retime rounds to: the length is
      // whole ticks and the rate is not, so the window comes back a tick short
      // of the three seconds it went in as. Eight microseconds.
      expect(fast.sourceDuration.raw, closeTo(secs(3).raw, 2),
          reason: 'the same frames');

      store.endGesture();
      await scrollToSpeed(tester);
      await tester.drag(rate, const Offset(-60, 0));
      await tester.pumpAndSettle();

      final slow = store.project.clipById('b')!;
      expect(slow.speed.rate, lessThan(1));
      expect(slow.duration.raw, greaterThan(secs(3).raw));
    });

    testWidgets('Reset puts the clip back at the length it had',
        (tester) async {
      controller.select('b');
      store.run(const SetClipSpeed('b', ClipSpeed(rate: 4)));
      store.endGesture();
      await pumpInspector(tester);
      await scrollToSpeed(tester);

      // Two Resets on screen — the transform's and this one — so it is the
      // one inside the speed section that has to be pressed.
      await tester.tap(find.descendant(
        of: find.ancestor(
          of: find.text('SPEED'),
          matching: find.byType(Row),
        ).first,
        matching: find.text('Reset'),
      ));
      await tester.pump();

      expect(store.project.clipById('b')!.speed, ClipSpeed.normal);
      expect(store.project.clipById('b')!.duration, secs(3));
    });
  });

  group('the chroma key', () {
    Future<void> scrollToKey(WidgetTester tester) async {
      await tester.scrollUntilVisible(find.text('CHROMA KEY'), 120,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
    }

    testWidgets('a clip with a picture gets the panel', (tester) async {
      controller.select('b');
      await pumpInspector(tester);
      await scrollToKey(tester);
      expect(find.text('Screen'), findsOneWidget);
    });

    testWidgets('a caption does not', (tester) async {
      // The same condition COLOUR is offered under: a shape is drawn from a
      // colour somebody chose, so there is nothing in it to key out.
      controller.addTextClip();
      await pumpInspector(tester);
      expect(find.text('CHROMA KEY'), findsNothing);
    });

    testWidgets('it sits under the grade, because that is where it runs',
        (tester) async {
      // A key is measured on the shot as it was shot, before every slider
      // above it — so a panel offering it first would describe an order the
      // engine does not run in.
      //
      // Measured as how far the rail has to be scrolled to reach each, rather
      // than by comparing two coordinates: the rail is lazy, so the section
      // above is no longer built by the time the one below is on screen.
      double scrolled() =>
          tester.state<ScrollableState>(find.byType(Scrollable).first)
              .position
              .pixels;

      controller.select('b');
      await pumpInspector(tester);
      await tester.scrollUntilVisible(find.text('Look'), 120,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      final toLook = scrolled();

      await scrollToKey(tester);
      expect(scrolled(), greaterThan(toLook));
    });

    testWidgets('the sliders only appear once there is a colour',
        (tester) async {
      controller.select('b');
      await pumpInspector(tester);
      await scrollToKey(tester);
      expect(find.text('Tolerance'), findsNothing);

      store.run(const SetClipKey(
          'b', ClipKey(color: 0x00B140, tolerance: 0.2)));
      store.endGesture();
      await tester.pumpAndSettle();
      await scrollToKey(tester);
      for (final label in ['Tolerance', 'Softness', 'Spill']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('a swatch keys the clip on that colour', (tester) async {
      controller.select('b');
      await pumpInspector(tester);
      await scrollToKey(tester);

      // The first swatch under "Screen" is chroma green.
      await tester.tap(find
          .descendant(
              of: find.ancestor(
                  of: find.text('Screen'), matching: find.byType(Column)).first,
              matching: find.byType(GestureDetector))
          .first);
      await tester.pumpAndSettle();

      final key = store.project.clipById('b')!.key;
      expect(key.color, 0x00B140);
      // And it arrived keying, rather than as a colour at no tolerance that
      // appears to do nothing.
      expect(key.isKeying, isTrue);
      expect(key.tolerance, ClipKey.defaultTolerance);
    });

    testWidgets('the eyedropper puts what it picked on the clip',
        (tester) async {
      controller.select('b');
      await pumpInspector(tester,
          onPickKeyColour: () async => 0xFF33CC33);
      await scrollToKey(tester);

      await tester.tap(find.text('Pick from preview'));
      await tester.pumpAndSettle();

      final key = store.project.clipById('b')!.key;
      expect(key.color, 0x33CC33);  // the alpha is dropped
      expect(key.isKeying, isTrue);
    });

    testWidgets('a cancelled pick changes nothing', (tester) async {
      controller.select('b');
      await pumpInspector(tester, onPickKeyColour: () async => null);
      await scrollToKey(tester);

      await tester.tap(find.text('Pick from preview'));
      await tester.pumpAndSettle();
      expect(store.project.clipById('b')!.key, ClipKey.none);
    });

    testWidgets('and a pick is one undo step', (tester) async {
      // Pointing at the screen is how the user *chose* the colour. An undo
      // that put back a key nobody had picked yet would be a step nobody took.
      final before = store.project;
      controller.select('b');
      await pumpInspector(tester, onPickKeyColour: () async => 0xFF33CC33);
      await scrollToKey(tester);

      await tester.tap(find.text('Pick from preview'));
      await tester.pumpAndSettle();
      store.undo();
      expect(store.project, same(before));
    });

    testWidgets('no eyedropper without somewhere to pick from',
        (tester) async {
      controller.select('b');
      await pumpInspector(tester);
      await scrollToKey(tester);
      expect(find.text('Pick from preview'), findsNothing);
      // The swatches are still there, which is the point of having them.
      expect(find.text('Screen'), findsOneWidget);
    });

    testWidgets('Reset takes the whole key off', (tester) async {
      store.run(const SetClipKey(
          'b', ClipKey(color: 0x00B140, tolerance: 0.4, spill: 0.2)));
      store.endGesture();
      controller.select('b');
      await pumpInspector(tester);
      await scrollToKey(tester);

      await tester.tap(find.descendant(
          of: find.ancestor(
              of: find.text('CHROMA KEY'), matching: find.byType(Row)).first,
          matching: find.text('Reset')));
      await tester.pumpAndSettle();
      expect(store.project.clipById('b')!.key, ClipKey.none);
    });

    testWidgets('the matte view is only offered under a key that is doing '
        'something', (tester) async {
      // The matte of a clip nobody keyed is a white rectangle, which teaches
      // nothing and looks broken.
      var asked = false;
      controller.select('b');
      await pumpInspector(tester, onMatteView: (_) => asked = true);
      await scrollToKey(tester);
      expect(find.text('View matte'), findsNothing);

      store.run(const SetClipKey(
          'b', ClipKey(color: 0x00B140, tolerance: 0.2)));
      store.endGesture();
      await tester.pumpAndSettle();
      await scrollToKey(tester);

      await tester.tap(find.text('View matte'));
      await tester.pumpAndSettle();
      expect(asked, isTrue);
      // And it is not written down anywhere: a view mode is a property of the
      // person looking, and nothing about it reaches the document.
      expect(store.project.clipById('b')!.key.tolerance, 0.2);
    });

    test('the editor attaches both of the view-side controls', () {
      // EditorScreen is not pumpable in a widget test — it builds a real
      // PreviewEngine — so this reads the source, which is the arrangement
      // tour_test.dart and about_test.dart already use for the parts of the
      // app a test cannot construct.
      //
      // Both controls above take a callback and hide themselves when it is
      // null, which makes "the panel is right" and "the editor wired it up"
      // two different questions. This is the second one.
      final source = File('lib/ui/editor_screen.dart').readAsStringSync();
      for (final wiring in [
        'onPickKeyColour:',
        'onMatteView:',
        // Escape has to reach the pick before it reaches the selection: the
        // eyedropper is the more recent thing the user started, and clearing
        // the selection would take away the panel they started it from.
        '_cancelPick()',
      ]) {
        expect(source, contains(wiring), reason: wiring);
      }
    });

    testWidgets('and it says when it is on', (tester) async {
      store.run(const SetClipKey(
          'b', ClipKey(color: 0x00B140, tolerance: 0.2)));
      store.endGesture();
      controller.select('b');
      await pumpInspector(tester, matteView: true, onMatteView: (_) {});
      await scrollToKey(tester);
      expect(find.text('Showing matte'), findsOneWidget);
    });
  });
}
