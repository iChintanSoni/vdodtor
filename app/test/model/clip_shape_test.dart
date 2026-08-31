import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/commands/command.dart';
import 'package:vdodtor/commands/document_store.dart';
import 'package:vdodtor/commands/edits.dart';
import 'package:vdodtor/engine/timeline_sync.dart';
import 'package:vdodtor/model/clip.dart';
import 'package:vdodtor/model/project.dart';
import 'package:vdodtor/model/serialization.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor/model/track.dart';
// The generated bindings, on purpose: they are the C header in Dart form, and
// checking the hand-written enum against them is what makes this a check on
// vd_shape.h rather than on the file next to it.
// ignore: implementation_imports
import 'package:vdodtor_engine/src/bindings.g.dart' show VdShapeKind;
import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../fixtures.dart';

const textTrackId = 'tr-text';

Clip shapeOf(
  String id, {
  required Tick start,
  required Tick duration,
  ClipShape shape = ClipShape.plain,
}) =>
    Clip.drawing(id: id, start: start, duration: duration, shape: shape);

Project projectWithShape([ClipShape shape = ClipShape.plain]) =>
    emptyProject().addTrack(Track.of(
      id: textTrackId,
      kind: TrackKind.text,
      name: 'Text 1',
      clips: [shapeOf('s1', start: Tick.zero, duration: secs(3), shape: shape)],
    ));

void main() {
  group('the kind list', () {
    test('is the same list in the document, the plugin and the engine', () {
      // Three enums, one order, and the *index* is what crosses the boundary —
      // so a kind inserted in the middle of one of them would silently redraw
      // every shape in every project on disk as something else. Same hazard as
      // the animation presets, checked the same way.
      expect(
        ShapeKind.values.map((k) => k.name).toList(),
        EngineShapeKind.values.map((k) => k.name).toList(),
      );
      expect(ShapeKind.values.length, VdShapeKind.values.length);
      for (var i = 0; i < ShapeKind.values.length; i++) {
        expect(VdShapeKind.values[i].value, i,
            reason: 'the C enum is not densely numbered from zero, so an '
                'index is not a value');
      }
    });

    test('every kind has something to call itself', () {
      for (final kind in ShapeKind.values) {
        expect(kind.label, isNotEmpty);
      }
    });

    test('the two that are all outline say so', () {
      expect(ShapeKind.line.isStroke, isTrue);
      expect(ShapeKind.arrow.isStroke, isTrue);
      expect(ShapeKind.rectangle.isStroke, isFalse);
      expect(ShapeKind.ellipse.isStroke, isFalse);
    });
  });

  group('a shape is a clip with no file', () {
    test('and says so', () {
      final clip = shapeOf('s1', start: Tick.zero, duration: secs(3));
      expect(clip.isShape, isTrue);
      expect(clip.isGenerated, isTrue);
      expect(clip.isText, isFalse);
      expect(clip.mediaId, isNull);
    });

    test('a caption is generated too, and is not a shape', () {
      final clip = Clip.caption(
          id: 't1',
          start: Tick.zero,
          duration: secs(3),
          text: const ClipText(text: 'Hi'));
      expect(clip.isGenerated, isTrue);
      expect(clip.isShape, isFalse);
    });

    test('an ordinary clip is neither', () {
      final clip = clipOf('c1', 'm1', start: Tick.zero, duration: secs(3));
      expect(clip.isGenerated, isFalse);
      expect(clip.shape, isNull);
    });

    test('a clip is one of the three and never two', () {
      // A clip is a window onto a file or one of the things the app draws.
      // Anything else is a clip nobody can render.
      expect(
        () => Clip(
          id: 'x',
          mediaId: 'm1',
          start: Tick.zero,
          duration: secs(1),
          shape: ClipShape.plain,
        ),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => Clip(
          id: 'x',
          mediaId: null,
          start: Tick.zero,
          duration: secs(1),
          text: const ClipText(text: 'no'),
          shape: ClipShape.plain,
        ),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => Clip(
            id: 'x', mediaId: null, start: Tick.zero, duration: secs(1)),
        throwsA(isA<AssertionError>()),
      );
    });

    test('nothing bounds how long it may be', () {
      expect(maxDurationFor(shapeOf('s1', start: Tick.zero, duration: secs(3)),
              null),
          Tick.zero);
    });

    test('trimming it keeps the shape', () {
      final clip = shapeOf('s1', start: Tick.zero, duration: secs(3));
      final trimmed = clip.trimTailBy(secs(2));
      expect(trimmed.duration, secs(5));
      expect(trimmed.shape, clip.shape);
    });
  });

  group('what a shape is made of', () {
    test('a default of each kind draws something', () {
      // The point of ClipShape.of: a line takes its colour from the stroke and
      // its thickness from the stroke width, so the plain constructor's
      // unstroked rectangle would be an invisible line — and a button that
      // adds a clip nobody can see looks broken.
      for (final kind in ShapeKind.values) {
        final shape = ClipShape.of(kind);
        expect(shape.kind, kind);
        expect(shape.isBlank, isFalse, reason: '$kind draws nothing');
      }
    });

    test('an ellipse starts round', () {
      final circle = ClipShape.of(ShapeKind.ellipse);
      expect(circle.width, circle.height);
    });

    test('a fill with no alpha is no fill', () {
      const filled = ClipShape(fillColor: 0xFFFFFFFF);
      expect(filled.hasFill, isTrue);
      expect(filled.copyWith(fillColor: 0x00FFFFFF).hasFill, isFalse);
    });

    test('a stroke needs both a width and an alpha', () {
      const base = ClipShape(strokeColor: 0xFF000000);
      expect(base.hasStroke, isFalse, reason: 'no width');
      expect(base.copyWith(strokeWidth: 0.02).hasStroke, isTrue);
      expect(
          base
              .copyWith(strokeWidth: 0.02, strokeColor: 0x00000000)
              .hasStroke,
          isFalse);
    });

    test('a line has no fill however it is coloured', () {
      const line = ClipShape(kind: ShapeKind.line, fillColor: 0xFFFFFFFF);
      expect(line.hasFill, isFalse);
    });

    test('a shape nobody can see still knows what it is', () {
      const blank = ClipShape(fillColor: 0x00FFFFFF);
      expect(blank.isBlank, isTrue);
      expect(blank.label, 'Rectangle');
    });
  });

  group('changing the kind', () {
    test('carries the colour and a thickness across to a line', () {
      // A filled rectangle turned into a line has its colour in the wrong
      // field and no thickness at all, so without this it would vanish.
      const rect = ClipShape(fillColor: 0xFFE53935, strokeColor: 0x00000000);
      final line = rect.withKind(ShapeKind.line);
      expect(line.kind, ShapeKind.line);
      expect(line.strokeColor, 0xFFE53935);
      expect(line.strokeWidth, ClipShape.defaultStrokeWidth);
      expect(line.isBlank, isFalse);
    });

    test('leaves a stroke that already works alone', () {
      const outlined = ClipShape(strokeColor: 0xFF1E88E5, strokeWidth: 0.05);
      final arrow = outlined.withKind(ShapeKind.arrow);
      expect(arrow.strokeColor, 0xFF1E88E5);
      expect(arrow.strokeWidth, 0.05);
    });

    test('going back to a rectangle changes nothing but the kind', () {
      const line = ClipShape(
          kind: ShapeKind.line, strokeColor: 0xFFFFFFFF, strokeWidth: 0.02);
      final rect = line.withKind(ShapeKind.rectangle);
      expect(rect, line.copyWith(kind: ShapeKind.rectangle));
    });

    test('the same kind is the same shape', () {
      const shape = ClipShape(kind: ShapeKind.ellipse);
      expect(identical(shape.withKind(ShapeKind.ellipse), shape), isTrue);
    });
  });

  group('clamping', () {
    test('pulls every number inside what the inspector offers', () {
      const wild = ClipShape(
        width: 99,
        height: -1,
        corner: 4,
        strokeWidth: 9,
        shadowOffsetX: -9,
        shadowOffsetY: 9,
        shadowBlur: 9,
        headSize: 9,
      );
      final tame = wild.clamped();
      expect(tame.width, ClipShape.maxSize);
      expect(tame.height, ClipShape.minSize);
      expect(tame.corner, 1.0);
      expect(tame.strokeWidth, ClipShape.maxStrokeWidth);
      expect(tame.shadowOffsetX, -ClipShape.maxShadowOffset);
      expect(tame.shadowOffsetY, ClipShape.maxShadowOffset);
      expect(tame.shadowBlur, ClipShape.maxShadowBlur);
      expect(tame.headSize, ClipShape.maxHeadSize);
    });

    test('leaves an ordinary shape alone', () {
      for (final kind in ShapeKind.values) {
        final shape = ClipShape.of(kind);
        expect(shape.clamped(), shape);
      }
    });
  });

  group('editing one', () {
    test('SetClipShape changes it and merges into one undo entry', () {
      final store = DocumentStore(projectWithShape());
      store.run(const SetClipShape('s1', ClipShape(width: 0.6)),
          fromGestureStart: true);
      store.run(const SetClipShape('s1', ClipShape(width: 0.7)));
      expect(store.project.clipById('s1')!.shape!.width, 0.7);

      store.undo();
      expect(store.project.clipById('s1')!.shape, ClipShape.plain);
    });

    test('it clamps on the way into the document', () {
      final store = DocumentStore(projectWithShape());
      store.run(const SetClipShape('s1', ClipShape(corner: 5)));
      expect(store.project.clipById('s1')!.shape!.corner, 1.0);
    });

    test('a clip that is not a shape is refused', () {
      // The kinds of clip are exclusive, and a command that could turn a video
      // clip into a rectangle is a command that will.
      final store = DocumentStore(projectWithThreeClips());
      expect(() => store.run(const SetClipShape('a', ClipShape.plain)),
          throwsA(isA<EditException>()));
    });

    test('setting the same shape is not an edit', () {
      final store = DocumentStore(projectWithShape());
      final before = store.project;
      store.run(const SetClipShape('s1', ClipShape.plain));
      expect(identical(store.project, before), isTrue);
    });
  });

  group('where a shape may go', () {
    test('a text lane takes it and nothing else does', () {
      final project = projectWithShape();
      final text = project.trackById(textTrackId)!;
      expect(MoveClip.accepts(text, null, isGenerated: true), isTrue);
      expect(MoveClip.accepts(project.mainTrack, null, isGenerated: true),
          isFalse);
    });

    test('a text lane refuses a clip with a file', () {
      final project = projectWithShape();
      final text = project.trackById(textTrackId)!;
      expect(MoveClip.accepts(text, videoAsset('m1')), isFalse);
    });
  });

  group('crossing to the engine', () {
    test('a shape goes across with no path and nothing to decode', () {
      final clip = engineTimelineFor(projectWithShape()).clips.single;
      expect(clip.path, isNull);
      expect(clip.text, isNull);
      expect(clip.shape, isNotNull);
      // Silent, and stretched: the raster is made at the size of the output,
      // so there is nothing to fit.
      expect(clip.gain, 0);
      expect(clip.fit, FitMode.stretch);
    });

    test('every field crosses, field for field', () {
      const shape = ClipShape(
        kind: ShapeKind.arrow,
        width: 0.7,
        height: 0.3,
        corner: 0.4,
        fillColor: 0xFF112233,
        strokeColor: 0xFF445566,
        strokeWidth: 0.03,
        shadowColor: 0xFF778899,
        shadowOffsetX: 0.01,
        shadowOffsetY: 0.02,
        shadowBlur: 0.04,
        headSize: 0.35,
      );
      final crossed = engineTimelineFor(projectWithShape(shape)).clips.single
          .shape!;
      expect(crossed.kind, EngineShapeKind.arrow);
      expect(crossed.width, 0.7);
      expect(crossed.height, 0.3);
      expect(crossed.corner, 0.4);
      expect(crossed.fillColor, 0xFF112233);
      expect(crossed.strokeColor, 0xFF445566);
      expect(crossed.strokeWidth, 0.03);
      expect(crossed.shadowColor, 0xFF778899);
      expect(crossed.shadowDx, 0.01);
      expect(crossed.shadowDy, 0.02);
      expect(crossed.shadowBlur, 0.04);
      expect(crossed.headSize, 0.35);
    });

    test('an animation reaches it like any other clip', () {
      final project = emptyProject().addTrack(Track.of(
        id: textTrackId,
        kind: TrackKind.text,
        name: 'Text 1',
        clips: [
          Clip.drawing(
            id: 's1',
            start: Tick.zero,
            duration: secs(3),
            shape: ClipShape.plain,
            animation: ClipAnimation(
              inPreset: AnimationPreset.pop,
              inDuration: secs(1),
            ),
          ),
        ],
      ));
      final clip = engineTimelineFor(project).clips.single;
      expect(clip.animation.inPreset, EngineAnimPreset.pop);
      expect(clip.animation.inTicks, secs(1).raw);
    });

    test('a hidden lane keeps its shapes off the screen', () {
      final project = projectWithShape();
      final hidden = project.trackById(textTrackId)!.copyWith(hidden: true);
      expect(engineTimelineFor(project.replaceTrack(hidden)).clips, isEmpty);
    });
  });

  group('on disk', () {
    test('a shape round-trips whole', () {
      const shape = ClipShape(
        kind: ShapeKind.ellipse,
        width: 0.42,
        height: 0.42,
        corner: 0.3,
        fillColor: 0xFFE53935,
        strokeColor: 0xCC1E88E5,
        strokeWidth: 0.02,
        shadowColor: 0x80000000,
        shadowOffsetX: 0.01,
        shadowOffsetY: 0.02,
        shadowBlur: 0.03,
        headSize: 0.4,
      );
      final decoded =
          projectFromJson(projectToJson(projectWithShape(shape)));
      expect(decoded.clipById('s1')!.shape, shape);
    });

    test('an ordinary clip writes no shape at all', () {
      final json = projectToJson(projectWithThreeClips());
      final tracks = json['tracks']! as List<Object?>;
      for (final track in tracks) {
        for (final clip in (track! as Map)['clips'] as List<Object?>) {
          expect((clip! as Map).containsKey('shape'), isFalse);
        }
      }
    });

    test('a kind this version has never heard of is an error', () {
      // Unlike an animation preset, which opens as "no animation" because the
      // clip is still on screen for the same length of time. A shape whose
      // kind is unknown has no honest stand-in: drawing a rectangle for it
      // would silently rewrite the picture.
      final json = projectToJson(projectWithShape());
      final track = (json['tracks']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .firstWhere((t) => t['id'] == textTrackId);
      final clip =
          (track['clips']! as List<Object?>).first! as Map<String, Object?>;
      (clip['shape']! as Map<String, Object?>)['kind'] = 'hexagon';
      expect(() => projectFromJson(json),
          throwsA(isA<ProjectDecodeException>()));
    });

    test('a file from a wider version opens as something editable', () {
      final json = projectToJson(projectWithShape());
      final track = (json['tracks']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .firstWhere((t) => t['id'] == textTrackId);
      final clip =
          (track['clips']! as List<Object?>).first! as Map<String, Object?>;
      (clip['shape']! as Map<String, Object?>)['width'] = 99.0;
      expect(projectFromJson(json).clipById('s1')!.shape!.width,
          ClipShape.maxSize);
    });
  });
}
