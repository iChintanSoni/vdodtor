import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/commands/document_store.dart';
import 'package:vdodtor/commands/edits.dart';
import 'package:vdodtor/model/clip.dart';
import 'package:vdodtor/model/ids.dart';
import 'package:vdodtor/commands/command.dart';
import 'package:vdodtor/model/project.dart';
import 'package:vdodtor/model/track.dart';
import 'package:vdodtor/ui/timeline/timeline_controller.dart';

import '../../fixtures.dart';
import 'timeline_controller_test.dart' show FakeTransport;

void main() {
  late DocumentStore store;
  late FakeTransport transport;
  late TimelineController controller;

  TimelineController controllerFor(Project project) {
    store = DocumentStore(project);
    transport = FakeTransport();
    return TimelineController(
      store: store,
      transport: transport,
      ids: IdGen.seeded(7),
    );
  }

  setUp(() => controller = controllerFor(projectWithThreeClips()));
  tearDown(() {
    controller.dispose();
    store.dispose();
  });

  List<Track> textLanes() =>
      controller.project.tracks.where((t) => t.kind == TrackKind.text).toList();

  group('adding a caption', () {
    test('makes the lane it needs and puts one on it at the playhead', () {
      // A new project has no text lane, so the first caption has to bring one.
      expect(textLanes(), isEmpty);
      transport.positionTicks = secs(2).raw;

      expect(controller.addTextClip(), isTrue);

      expect(textLanes(), hasLength(1));
      final clip = textLanes().single.clips.single;
      expect(clip.isText, isTrue);
      expect(clip.start, secs(2));
      expect(clip.duration, TimelineController.defaultCaptionDuration);
      expect(clip.text!.text, 'Text');
    });

    test('and selects it, so the inspector is already on it', () {
      controller.addTextClip();
      expect(controller.selectedClipId,
          textLanes().single.clips.single.id);
    });

    test('lane and caption are one undo entry', () {
      // Two would mean pressing ⌘Z twice to take back one button, and the
      // first press would leave an empty lane behind.
      controller.addTextClip();
      expect(store.canUndo, isTrue);

      store.undo();
      expect(textLanes(), isEmpty);
      expect(store.project.tracks.map((t) => t.id),
          projectWithThreeClips().tracks.map((t) => t.id));
    });

    test('a second caption elsewhere shares the lane', () {
      controller.addTextClip();
      transport.positionTicks = secs(20).raw;
      controller.addTextClip();

      expect(textLanes(), hasLength(1));
      expect(textLanes().single.clips, hasLength(2));
    });

    test('a second caption at the same time gets a lane of its own', () {
      // Lanes hold no overlaps, so two captions on screen together cannot
      // share one — and refusing would be a button that stops working exactly
      // when somebody wants a title and a subtitle at once.
      transport.positionTicks = secs(1).raw;
      controller.addTextClip();
      controller.addTextClip();

      expect(textLanes(), hasLength(2));
      for (final lane in textLanes()) {
        expect(lane.clips, hasLength(1));
        expect(lane.clips.single.start, secs(1));
      }
    });

    test('captions composite above the video lanes', () {
      controller.addTextClip();
      final tracks = controller.project.tracks;
      final text = tracks.indexWhere((t) => t.kind == TrackKind.text);
      final main = tracks.indexWhere((t) => t.kind == TrackKind.main);
      expect(text, greaterThan(main));
    });

    test('stops at the lane limit rather than making a ninth', () {
      transport.positionTicks = 0;
      for (var i = 0; i < Project.maxTracksOfKind(TrackKind.text); i++) {
        expect(controller.addTextClip(), isTrue, reason: 'caption $i');
      }
      expect(textLanes(), hasLength(Project.maxTracksOfKind(TrackKind.text)));

      expect(controller.canAddTextClip, isFalse);
      expect(controller.addTextClip(), isFalse);
      expect(textLanes(), hasLength(Project.maxTracksOfKind(TrackKind.text)));
    });

    test('but there is still room somewhere else on the timeline', () {
      transport.positionTicks = 0;
      for (var i = 0; i < Project.maxTracksOfKind(TrackKind.text); i++) {
        controller.addTextClip();
      }
      // Full at zero, empty a minute later. The button is about the playhead,
      // not about the project.
      transport.positionTicks = secs(60).raw;
      expect(controller.canAddTextClip, isTrue);
      expect(controller.addTextClip(), isTrue);
    });

    test('a locked lane is not somewhere to put one', () {
      controller.addTextClip();
      final lane = textLanes().single;
      store.run(SetTrackProperties(lane.id, locked: true));
      transport.positionTicks = secs(30).raw;

      controller.addTextClip();
      // It went on a new lane rather than onto the locked one.
      expect(textLanes(), hasLength(2));
      expect(controller.project.trackById(lane.id)!.clips, hasLength(1));
    });
  });

  group('editing a caption', () {
    test('SetClipText changes the words and merges while typing', () {
      controller.addTextClip();
      final id = controller.selectedClipId!;

      store.run(SetClipText(id, const ClipText(text: 'H')));
      store.run(SetClipText(id, const ClipText(text: 'He')));
      store.run(SetClipText(id, const ClipText(text: 'Hello')));

      expect(store.project.clipById(id)!.text!.text, 'Hello');

      // One entry for the sentence: an undo per keystroke makes ⌘Z useless
      // exactly where it is needed most.
      store.undo();
      expect(store.project.clipById(id)!.text!.text, 'Text');
    });

    test('and clamps what it is given', () {
      controller.addTextClip();
      final id = controller.selectedClipId!;
      store.run(SetClipText(id, const ClipText(text: 'x', size: 99)));
      expect(store.project.clipById(id)!.text!.size, ClipText.maxSize);
    });

    test('refuses a clip that is not a caption', () {
      expect(
        () => store.run(const SetClipText('a', ClipText(text: 'no'))),
        throwsA(isA<EditException>()),
      );
    });

    test('a caption survives being split', () {
      controller.addTextClip();
      final id = controller.selectedClipId!;
      transport.positionTicks =
          (TimelineController.defaultCaptionDuration.raw ~/ 2);
      controller.splitAtPlayhead();

      final lane = textLanes().single;
      expect(lane.clips, hasLength(2));
      for (final clip in lane.clips) {
        expect(clip.isText, isTrue);
        expect(clip.text!.text, 'Text');
      }
      expect(lane.clips.first.id, id);
    });

    test('and being copied', () {
      controller.addTextClip();
      controller.copySelection();
      transport.positionTicks = secs(30).raw;
      expect(controller.paste(), isTrue);

      final pasted = controller.project.clipById(controller.selectedClipId!)!;
      expect(pasted.isText, isTrue);
      expect(pasted.text!.text, 'Text');
    });
  });

  group('adding a shape', () {
    test('makes the lane it needs and puts one on it at the playhead', () {
      // The same lanes a caption uses. A shape is the other thing the app
      // draws, and a second family of lanes would be a second cap to keep in
      // step with VD_MAX_LAYERS for no difference anybody could see.
      expect(textLanes(), isEmpty);
      transport.positionTicks = secs(2).raw;

      expect(controller.addShapeClip(), isTrue);

      expect(textLanes(), hasLength(1));
      final clip = textLanes().single.clips.single;
      expect(clip.isShape, isTrue);
      expect(clip.start, secs(2));
      expect(clip.duration, TimelineController.defaultCaptionDuration);
      expect(clip.shape!.kind, ShapeKind.rectangle);
    });

    test('any of the four kinds, and each one visible', () {
      for (final kind in ShapeKind.values) {
        transport.positionTicks = secs(10 * (kind.index + 1)).raw;
        expect(controller.addShapeClip(kind: kind), isTrue);
        final clip = controller.project.clipById(controller.selectedClipId!)!;
        expect(clip.shape!.kind, kind);
        expect(clip.shape!.isBlank, isFalse, reason: '$kind draws nothing');
      }
    });

    test('and selects it, so the inspector is already on it', () {
      controller.addShapeClip();
      expect(controller.selectedClipId, textLanes().single.clips.single.id);
    });

    test('lane and shape are one undo entry', () {
      controller.addShapeClip();
      store.undo();
      expect(textLanes(), isEmpty);
      expect(store.project.tracks.map((t) => t.id),
          projectWithThreeClips().tracks.map((t) => t.id));
    });

    test('a shape and a caption share a lane when there is room', () {
      controller.addTextClip();
      transport.positionTicks = secs(20).raw;
      controller.addShapeClip();

      expect(textLanes(), hasLength(1));
      expect(textLanes().single.clips, hasLength(2));
    });

    test('a shape under a caption at the same moment gets its own lane', () {
      // Which is what stacking them means: the shape on the lower lane
      // composites first, so the caption lands on top of it.
      transport.positionTicks = secs(1).raw;
      controller.addShapeClip();
      controller.addTextClip();

      expect(textLanes(), hasLength(2));
      expect(textLanes().first.clips.single.isShape, isTrue);
      expect(textLanes().last.clips.single.isText, isTrue);
    });

    test('it stops at the same lane limit a caption does', () {
      transport.positionTicks = 0;
      for (var i = 0; i < Project.maxTracksOfKind(TrackKind.text); i++) {
        expect(controller.addShapeClip(), isTrue, reason: 'shape $i');
      }
      expect(controller.canAddShapeClip, isFalse);
      expect(controller.addShapeClip(), isFalse);
      expect(controller.canAddTextClip, isFalse,
          reason: 'one pool of lanes, one answer');
    });

    test('a shape survives being split and copied', () {
      controller.addShapeClip(kind: ShapeKind.ellipse);
      final id = controller.selectedClipId!;
      transport.positionTicks =
          TimelineController.defaultCaptionDuration.raw ~/ 2;
      controller.splitAtPlayhead();

      final lane = textLanes().single;
      expect(lane.clips, hasLength(2));
      for (final clip in lane.clips) {
        expect(clip.shape!.kind, ShapeKind.ellipse);
      }
      expect(lane.clips.first.id, id);

      controller.copySelection();
      transport.positionTicks = secs(30).raw;
      expect(controller.paste(), isTrue);
      expect(controller.project.clipById(controller.selectedClipId!)!.isShape,
          isTrue);
    });
  });

  group('a caption stays on a text lane', () {
    test('it cannot be dragged onto a video or audio lane', () {
      controller.addTextClip();
      final caption =
          controller.project.clipById(controller.selectedClipId!)!;
      for (final track in controller.project.tracks) {
        if (track.kind == TrackKind.text) continue;
        expect(
          MoveClip.accepts(track, null, from: TrackKind.text, isGenerated: true),
          isFalse,
          reason: 'a caption on ${track.kind.name} would repack the lane and '
              'then composite underneath it',
        );
      }
      expect(caption.isText, isTrue);
    });

    test('and nothing else can be dragged onto one', () {
      controller.addTextClip();
      final lane = textLanes().single;
      final asset = controller.project.media.values.first;
      expect(MoveClip.accepts(lane, asset), isFalse);
      expect(MoveClip.accepts(lane, null), isFalse);
      // But a caption may move between text lanes like anything else.
      expect(MoveClip.accepts(lane, null, from: TrackKind.text, isGenerated: true),
          isTrue);
    });

    test('a shape is bound by the same rule', () {
      controller.addShapeClip();
      final shape =
          controller.project.clipById(controller.selectedClipId!)!;
      expect(shape.isGenerated, isTrue);
      for (final track in controller.project.tracks) {
        expect(
          MoveClip.accepts(track, null,
              from: TrackKind.text, isGenerated: true),
          track.kind == TrackKind.text,
          reason: 'a shape belongs on a text lane and nowhere else',
        );
      }
    });

    test('a locked text lane takes nothing either', () {
      controller.addTextClip();
      final lane = textLanes().single;
      store.run(SetTrackProperties(lane.id, locked: true));
      expect(
        MoveClip.accepts(controller.project.trackById(lane.id)!, null,
            from: TrackKind.text, isGenerated: true),
        isFalse,
      );
    });
  });
}
