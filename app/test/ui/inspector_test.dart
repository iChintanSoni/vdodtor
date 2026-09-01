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
}
