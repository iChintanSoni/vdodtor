import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/commands/command.dart';
import 'package:vdodtor/commands/document_store.dart';
import 'package:vdodtor/commands/edits.dart';
import 'package:vdodtor/engine/timeline_sync.dart';
import 'package:vdodtor/model/clip.dart';
import 'package:vdodtor/model/project.dart';
import 'package:vdodtor/model/serialization.dart';
import 'package:vdodtor/model/time.dart';

import '../fixtures.dart';

/// A grade with every slider somewhere different, so a field that is dropped
/// or crossed with its neighbour on the way through cannot land on the right
/// number by accident.
const _graded = ClipColor(
  brightness: 0.1,
  contrast: 0.2,
  saturation: -0.3,
  temperature: 0.4,
  tint: -0.5,
);

Project projectWithClip() {
  final project = emptyProject().addMedia(videoAsset('m1'));
  return project.updateTrack(
    project.mainTrack.id,
    (t) => t.withClips([
      clipOf('a', 'm1', start: Tick.zero, duration: secs(5)),
    ]),
  );
}

void main() {
  group('what a grade is', () {
    test('five sliders, all neutral at zero', () {
      expect(ClipColor.neutral.brightness, 0);
      expect(ClipColor.neutral.contrast, 0);
      expect(ClipColor.neutral.saturation, 0);
      expect(ClipColor.neutral.temperature, 0);
      expect(ClipColor.neutral.tint, 0);
      expect(ClipColor.neutral.isNeutral, isTrue);
    });

    test('any slider off zero is a grade', () {
      // The property the engine's fast path rests on: neutral means every one
      // of them, and "nearly neutral" is not neutral.
      expect(const ClipColor(brightness: 0.001).isNeutral, isFalse);
      expect(const ClipColor(contrast: -0.001).isNeutral, isFalse);
      expect(const ClipColor(saturation: 0.001).isNeutral, isFalse);
      expect(const ClipColor(temperature: 0.001).isNeutral, isFalse);
      expect(const ClipColor(tint: -0.001).isNeutral, isFalse);
    });

    test('copyWith changes one slider and leaves the others', () {
      final warmed = _graded.copyWith(temperature: 0.9);
      expect(warmed.temperature, 0.9);
      expect(warmed.brightness, _graded.brightness);
      expect(warmed.contrast, _graded.contrast);
      expect(warmed.saturation, _graded.saturation);
      expect(warmed.tint, _graded.tint);
    });

    test('two grades with the same five numbers are the same grade', () {
      expect(_graded, equals(_graded.copyWith()));
      expect(_graded.hashCode, _graded.copyWith().hashCode);
      expect(_graded, isNot(equals(_graded.copyWith(tint: 0))));
    });

    test('a slider past its end is pulled back into range', () {
      const wild = ClipColor(
        brightness: 5,
        contrast: -9,
        saturation: 40,
        temperature: -2,
        tint: 1.5,
      );
      final tamed = wild.clamped();
      expect(tamed.brightness, 1);
      expect(tamed.contrast, -1);
      expect(tamed.saturation, 1);
      expect(tamed.temperature, -1);
      expect(tamed.tint, 1);
    });
  });

  group('a clip carries one', () {
    test('a clip nobody has graded is neutral', () {
      final clip = clipOf('a', 'm1', start: Tick.zero, duration: secs(5));
      expect(clip.color, ClipColor.neutral);
    });

    test('the grade is part of what a clip is', () {
      final clip = clipOf('a', 'm1', start: Tick.zero, duration: secs(5));
      final graded = clip.copyWith(color: _graded);
      expect(graded, isNot(equals(clip)));
      expect(graded.hashCode, isNot(clip.hashCode));
      expect(graded.copyWith(), equals(graded));
    });

    test('a trim leaves the grade alone', () {
      // Unlike a fade or an entrance, a grade has no length to outlive the
      // clip carrying it — there is nothing for a trim to clamp.
      final clip = clipOf('a', 'm1', start: Tick.zero, duration: secs(5))
          .copyWith(color: _graded);
      expect(clip.trimHeadBy(secs(1)).color, _graded);
      expect(clip.trimTailBy(secs(-3)).color, _graded);
      expect(clip.movedTo(secs(9)).color, _graded);
    });
  });

  group('grading a clip', () {
    test('SetClipColor writes it to the clip named', () {
      final store = DocumentStore(projectWithClip());
      store.run(const SetClipColor('a', _graded));
      expect(store.project.clipById('a')!.color, _graded);
    });

    test('the whole drag is one undo entry', () {
      // Five sliders are one decision about how a shot should look, and an
      // undo stack with a step per pixel of a drag is one nobody can walk back
      // through.
      final store = DocumentStore(projectWithClip());
      for (var i = 1; i <= 10; i++) {
        store.run(SetClipColor('a', ClipColor(brightness: i / 10)),
            fromGestureStart: true);
      }
      expect(store.project.clipById('a')!.color.brightness, 1);

      store.undo();
      expect(store.project.clipById('a')!.color, ClipColor.neutral);
      expect(store.canUndo, isFalse);
    });

    test('a drag that ends and one that starts again are two entries', () {
      final store = DocumentStore(projectWithClip());
      store.run(const SetClipColor('a', ClipColor(brightness: 0.5)),
          fromGestureStart: true);
      store.endGesture();
      store.run(const SetClipColor('a', ClipColor(brightness: 0.5, tint: 0.2)),
          fromGestureStart: true);
      store.endGesture();

      store.undo();
      expect(store.project.clipById('a')!.color,
          const ClipColor(brightness: 0.5));
      store.undo();
      expect(store.project.clipById('a')!.color, ClipColor.neutral);
    });

    test('setting the grade it already has changes nothing', () {
      final store = DocumentStore(projectWithClip());
      store.run(const SetClipColor('a', _graded));
      final before = store.project;
      store.run(const SetClipColor('a', _graded));
      expect(identical(store.project, before), isTrue);
    });

    test('a value past the slider cannot reach the document', () {
      final store = DocumentStore(projectWithClip());
      store.run(const SetClipColor('a', ClipColor(saturation: 12)));
      expect(store.project.clipById('a')!.color.saturation, 1);
    });

    test('grading a clip that is not there is an error', () {
      final store = DocumentStore(projectWithClip());
      expect(() => store.run(const SetClipColor('nope', _graded)),
          throwsA(isA<EditException>()));
    });
  });

  group('through the file', () {
    test('a neutral grade is not written down at all', () {
      final json = projectToJson(projectWithClip());
      final clip = _firstClipJson(json);
      expect(clip.containsKey('color'), isFalse,
          reason: 'a project file should read like the edit that made it');
    });

    test('only the sliders that moved are written', () {
      final project = projectWithClip().updateTrack(
        mainTrackId,
        (t) => t.withClips([
          t.clips.first.copyWith(color: const ClipColor(temperature: 0.4)),
        ]),
      );
      final clip = _firstClipJson(projectToJson(project));
      expect(clip['color'], {'temperature': 0.4});
    });

    test('a grade survives the round trip', () {
      final project = projectWithClip().updateTrack(
        mainTrackId,
        (t) => t.withClips([t.clips.first.copyWith(color: _graded)]),
      );
      final back = decodeProject(encodeProject(project));
      expect(back.clipById('a')!.color, _graded);
    });

    test('a file with a slider past the end opens clamped', () {
      final project = projectWithClip();
      final json = projectToJson(project);
      _firstClipJson(json)['color'] = {'saturation': 8.0, 'brightness': -3.0};
      final back = projectFromJson(json);
      expect(back.clipById('a')!.color.saturation, 1);
      expect(back.clipById('a')!.color.brightness, -1);
    });

    test('a slider this version has never heard of is ignored', () {
      // The bargain a grade gets, and it is the right one: the sliders this
      // version does know still apply, and the picture is wrong in a way the
      // user can see and put right rather than a file that will not open.
      final json = projectToJson(projectWithClip());
      _firstClipJson(json)['color'] = {'contrast': 0.5, 'vibrance': 0.9};
      final back = projectFromJson(json);
      expect(back.clipById('a')!.color, const ClipColor(contrast: 0.5));
    });
  });

  group('through to the engine', () {
    test('every slider arrives, and on the same scale', () {
      final project = projectWithClip().updateTrack(
        mainTrackId,
        (t) => t.withClips([t.clips.first.copyWith(color: _graded)]),
      );
      final clip = engineTimelineFor(project).clips.single;
      expect(clip.color.brightness, _graded.brightness);
      expect(clip.color.contrast, _graded.contrast);
      expect(clip.color.saturation, _graded.saturation);
      expect(clip.color.temperature, _graded.temperature);
      expect(clip.color.tint, _graded.tint);
    });

    test('an ungraded clip crosses as the neutral grade', () {
      final clip = engineTimelineFor(projectWithClip()).clips.single;
      expect(clip.color.brightness, 0);
      expect(clip.color.contrast, 0);
      expect(clip.color.saturation, 0);
      expect(clip.color.temperature, 0);
      expect(clip.color.tint, 0);
    });
  });
}

Map<String, Object?> _firstClipJson(Map<String, Object?> json) {
  final tracks = json['tracks']! as List<Object?>;
  final track = tracks.first! as Map<String, Object?>;
  final clips = track['clips']! as List<Object?>;
  return clips.first! as Map<String, Object?>;
}
