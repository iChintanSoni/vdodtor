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

/// Where a clip sits inside the frame: the value, how it survives a save, and
/// how it reaches the compositor.
void main() {
  group('the value', () {
    test('a clip nobody touched carries the identity', () {
      final clip = clipOf('a', 'm1', start: Tick.zero, duration: secs(1));
      expect(clip.transform, ClipTransform.identity);
      expect(clip.transform.isIdentity, isTrue);
    });

    test('everything is relative, so the frame size cannot matter', () {
      // A project cut at 1080p and exported at 4K has to look the same, and
      // it only can if nothing in here is measured in pixels.
      const t = ClipTransform(offsetX: 0.25, scale: 2, cropLeft: 0.1);
      expect(t.offsetX, 0.25);
      expect(t.scale, 2);
      expect(t.cropWidth, closeTo(0.9, 1e-9));
    });

    test('crop insets become a width, and opposite ones do not fight', () {
      const t = ClipTransform(cropLeft: 0.2, cropRight: 0.3);
      expect(t.cropWidth, closeTo(0.5, 1e-9));
      expect(t.cropHeight, 1);
    });

    test('a crop that would swallow the clip leaves something to see', () {
      const t = ClipTransform(cropLeft: 0.7, cropRight: 0.7);
      expect(t.cropWidth, greaterThan(0));
    });

    test('copyWith changes one field and keeps the rest', () {
      const t = ClipTransform(scale: 1.5, opacity: 0.5, flipHorizontal: true);
      final next = t.copyWith(rotationDegrees: 90);
      expect(next.scale, 1.5);
      expect(next.opacity, 0.5);
      expect(next.flipHorizontal, isTrue);
      expect(next.rotationDegrees, 90);
    });

    test('equality is by value, so an unchanged edit is droppable', () {
      const a = ClipTransform(scale: 2, offsetY: -0.1);
      const b = ClipTransform(scale: 2, offsetY: -0.1);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const ClipTransform(scale: 2)));
    });
  });

  group('saving', () {
    Project withTransform(ClipTransform transform) {
      final p = projectWithThreeClips();
      final track = p.mainTrack;
      return p.replaceTrack(track.withClips([
        for (final c in track.clips)
          c.id == 'b' ? c.copyWith(transform: transform) : c,
      ]));
    }

    test('an untouched clip writes no transform at all', () {
      final json = projectToJson(projectWithThreeClips());
      final track = (json['tracks']! as List).first as Map<String, Object?>;
      final clip = (track['clips']! as List).first as Map<String, Object?>;

      // A project file should read like the edit that made it, not like a
      // dump of every field that exists.
      expect(clip.containsKey('transform'), isFalse);
    });

    test('only the fields that differ are written', () {
      final json =
          projectToJson(withTransform(const ClipTransform(scale: 1.5)));
      final track = (json['tracks']! as List).first as Map<String, Object?>;
      final clips = (track['clips']! as List).cast<Map<String, Object?>>();
      final b = clips.firstWhere((c) => c['id'] == 'b');
      final transform = b['transform']! as Map<String, Object?>;

      expect(transform.keys, ['scale']);
    });

    test('a full transform survives the round trip', () {
      const transform = ClipTransform(
        offsetX: 0.125,
        offsetY: -0.25,
        scale: 1.75,
        rotationDegrees: 33.5,
        cropLeft: 0.1,
        cropTop: 0.05,
        cropRight: 0.2,
        cropBottom: 0.15,
        opacity: 0.4,
        flipHorizontal: true,
        flipVertical: true,
      );
      final restored = projectFromJson(projectToJson(withTransform(transform)));
      expect(restored.clipById('b')!.transform, transform);
    });

    test('a file written before transforms existed still opens', () {
      final json = projectToJson(projectWithThreeClips());
      final restored = projectFromJson(json);
      expect(restored.clipById('b')!.transform, ClipTransform.identity);
    });

    test('a transform of nonsense types falls back rather than throwing', () {
      final json = projectToJson(withTransform(const ClipTransform(scale: 2)));
      final track = (json['tracks']! as List).first as Map<String, Object?>;
      final clips = (track['clips']! as List).cast<Map<String, Object?>>();
      clips.firstWhere((c) => c['id'] == 'b')['transform'] = {
        'scale': 'quite big',
        'opacity': null,
      };

      final restored = projectFromJson(json);
      expect(restored.clipById('b')!.transform, ClipTransform.identity,
          reason: 'a project that will not open is worse than one that opens '
              'with a clip back at its defaults');
    });
  });

  group('SetClipTransform', () {
    test('changes the one clip it names', () {
      final store = DocumentStore(projectWithThreeClips());
      store.run(const SetClipTransform('b', ClipTransform(scale: 2)));

      expect(store.project.clipById('b')!.transform.scale, 2);
      expect(store.project.clipById('a')!.transform, ClipTransform.identity);
    });

    test('leaves the clip where it is on the timeline', () {
      final store = DocumentStore(projectWithThreeClips());
      final before = store.project.clipById('b')!;
      store.run(const SetClipTransform(
          'b', ClipTransform(scale: 3, offsetX: 0.4)));

      final after = store.project.clipById('b')!;
      expect(after.start, before.start);
      expect(after.duration, before.duration);
      expect(after.sourceIn, before.sourceIn);
      expect(store.project.duration, secs(6));
    });

    test('a run of adjustments is one undo entry', () {
      final store = DocumentStore(projectWithThreeClips());
      final before = encodeProject(store.project);

      for (var i = 1; i <= 20; i++) {
        store.run(SetClipTransform('b', ClipTransform(scale: 1 + i * 0.05)));
      }
      expect(store.undoLabels, ['Adjust clip']);

      store.undo();
      expect(encodeProject(store.project), before);
    });

    test('a drag across different properties still folds into one', () {
      // Someone adjusting a shot moves scale, then rotation, then position.
      // That is one decision to them, so it should be one press of ⌘Z.
      final store = DocumentStore(projectWithThreeClips());
      store.run(const SetClipTransform('b', ClipTransform(scale: 1.2)));
      store.run(const SetClipTransform(
          'b', ClipTransform(scale: 1.2, rotationDegrees: 10)));
      store.run(const SetClipTransform(
          'b', ClipTransform(scale: 1.2, rotationDegrees: 10, offsetX: 0.1)));

      expect(store.undoLabels, ['Adjust clip']);
    });

    test('a barrier between two adjustments keeps them apart', () {
      final store = DocumentStore(projectWithThreeClips());
      store.run(const SetClipTransform('b', ClipTransform(scale: 1.2)));
      store.endGesture();
      store.run(const SetClipTransform('b', ClipTransform(scale: 1.4)));

      expect(store.undoLabels, ['Adjust clip', 'Adjust clip']);
    });

    test('setting the same transform is not an edit', () {
      final store = DocumentStore(projectWithThreeClips());
      store.run(const SetClipTransform('b', ClipTransform(scale: 2)));
      final revision = store.revision;
      store.run(const SetClipTransform('b', ClipTransform(scale: 2)));
      expect(store.revision, revision);
    });

    test('an unknown clip is a programming error', () {
      final store = DocumentStore(projectWithThreeClips());
      expect(
        () => store.run(
            const SetClipTransform('ghost', ClipTransform(scale: 2))),
        throwsA(isA<EditException>()),
      );
    });
  });

  group('what the engine is handed', () {
    test('the identity reaches it as the identity', () {
      final timeline = engineTimelineFor(projectWithThreeClips());
      final clip = timeline.clips.first;
      expect(clip.transform.scale, 1);
      expect(clip.transform.cropWidth, 1);
      expect(clip.transform.cropHeight, 1);
      expect(clip.opacity, 1);
    });

    test('insets are turned into a rectangle on the way out', () {
      // The document says what the user dragged — an inset per edge — and the
      // engine wants to know where to sample. This is the one place that
      // knows both.
      final project = projectWithThreeClips();
      final withCrop = project.replaceTrack(project.mainTrack.withClips([
        for (final c in project.mainTrack.clips)
          c.id == 'a'
              ? c.copyWith(
                  transform: const ClipTransform(
                      cropLeft: 0.25, cropRight: 0.25, cropTop: 0.1))
              : c,
      ]));

      final clip = engineTimelineFor(withCrop).clips.first;
      expect(clip.transform.cropX, 0.25);
      expect(clip.transform.cropWidth, closeTo(0.5, 1e-9));
      expect(clip.transform.cropY, 0.1);
      expect(clip.transform.cropHeight, closeTo(0.9, 1e-9));
    });

    test('opacity travels on the clip, where the engine expects it', () {
      final project = projectWithThreeClips();
      final faded = project.replaceTrack(project.mainTrack.withClips([
        for (final c in project.mainTrack.clips)
          c.id == 'a'
              ? c.copyWith(transform: const ClipTransform(opacity: 0.25))
              : c,
      ]));

      expect(engineTimelineFor(faded).clips.first.opacity, 0.25);
    });

    test('the rest of the transform travels intact', () {
      final project = projectWithThreeClips();
      final moved = project.replaceTrack(project.mainTrack.withClips([
        for (final c in project.mainTrack.clips)
          c.id == 'a'
              ? c.copyWith(
                  transform: const ClipTransform(
                    offsetX: -0.3,
                    offsetY: 0.2,
                    scale: 1.5,
                    rotationDegrees: 12,
                    flipHorizontal: true,
                  ))
              : c,
      ]));

      final clip = engineTimelineFor(moved).clips.first;
      expect(clip.transform.offsetX, -0.3);
      expect(clip.transform.offsetY, 0.2);
      expect(clip.transform.scale, 1.5);
      expect(clip.transform.rotationDegrees, 12);
      expect(clip.transform.flipHorizontal, isTrue);
      expect(clip.transform.flipVertical, isFalse);
    });
  });
}
