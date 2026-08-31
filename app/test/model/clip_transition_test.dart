import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/commands/command.dart';
import 'package:vdodtor/commands/document_store.dart';
import 'package:vdodtor/commands/edits.dart';
import 'package:vdodtor/engine/timeline_sync.dart';
import 'package:vdodtor/model/clip.dart';
import 'package:vdodtor/model/project.dart';
import 'package:vdodtor/model/serialization.dart';
import 'package:vdodtor/model/time.dart';
// The generated bindings, on purpose: they are the C header in Dart form, and
// checking the hand-written enum against them is what makes this a check on
// vd_transition.h rather than on the file next to it.
// ignore: implementation_imports
import 'package:vdodtor_engine/src/bindings.g.dart' show VdTransitionPreset;
import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../fixtures.dart';

/// Two clips meeting at a cut five seconds in, with [transition] on the
/// second one — which is where a transition is written down.
Project projectWithCut([ClipTransition transition = ClipTransition.none]) {
  final project = emptyProject()
      .addMedia(videoAsset('m1'))
      .addMedia(videoAsset('m2'));
  return project.updateTrack(
    project.mainTrack.id,
    (t) => t.withClips([
      clipOf('a', 'm1', start: Tick.zero, duration: secs(5)),
      clipOf('b', 'm2', start: secs(5), duration: secs(5))
          .copyWith(transition: transition),
    ]),
  );
}

void main() {
  group('the preset list', () {
    test('is the same list in the document, the plugin and the engine', () {
      // Three enums, one order, and the index is what crosses the boundary —
      // so a preset inserted in the middle of one would silently rename every
      // transition in every project on disk.
      expect(
        TransitionPreset.values.map((p) => p.name).toList(),
        EngineTransitionPreset.values.map((p) => p.name).toList(),
      );
      expect(TransitionPreset.values.length, VdTransitionPreset.values.length);
      for (var i = 0; i < TransitionPreset.values.length; i++) {
        expect(VdTransitionPreset.values[i].value, i,
            reason: 'the C enum is not densely numbered from zero, so an '
                'index is not a value');
      }
    });

    test('every preset has something to call itself', () {
      for (final preset in TransitionPreset.values) {
        expect(preset.label, isNotEmpty);
      }
    });
  });

  group('what a transition is', () {
    test('a preset and a length, and it needs both', () {
      expect(ClipTransition.none.isActive, isFalse);
      expect(
          const ClipTransition(preset: TransitionPreset.dissolve).isActive,
          isFalse,
          reason: 'a preset with no length does nothing');
      expect(ClipTransition(duration: secs(1)).isActive, isFalse,
          reason: 'a length with no preset does nothing');
      expect(
          ClipTransition(
                  preset: TransitionPreset.dissolve, duration: secs(1))
              .isActive,
          isTrue);
    });

    test('clamping pulls a length inside what the slider offers', () {
      final huge = ClipTransition(
          preset: TransitionPreset.wipe, duration: secs(60));
      expect(huge.clamped().duration, ClipTransition.maxDuration);

      final tiny =
          ClipTransition(preset: TransitionPreset.wipe, duration: Tick(1));
      expect(tiny.clamped().duration, ClipTransition.minDuration);

      // And something that does nothing clamps to nothing at all rather than
      // to a length with no preset on it.
      expect(ClipTransition(duration: secs(1)).clamped(), ClipTransition.none);
    });

    test('it is bounded by twice the shorter clip it joins', () {
      // Half the window sits on each side, so a one-second neighbour can carry
      // half a second of transition — and therefore a whole window of two.
      final t = ClipTransition(
          preset: TransitionPreset.dissolve, duration: secs(4));
      expect(t.clampedBetween(secs(1), secs(10)).duration, secs(2));
      expect(t.clampedBetween(secs(10), secs(1)).duration, secs(2));
      expect(t.clampedBetween(secs(10), secs(10)).duration, secs(4),
          reason: 'room on both sides leaves it alone');
      expect(t.clampedBetween(Tick.zero, secs(10)), ClipTransition.none,
          reason: 'a clip with no length has no half to give');
    });
  });

  group('a clip carries the transition at its head', () {
    test('and a plain cut is the default', () {
      final clip = clipOf('a', 'm1', start: Tick.zero, duration: secs(5));
      expect(clip.transition, ClipTransition.none);
      expect(clip.transition.isActive, isFalse);
    });

    test('trimming shortens a transition it can no longer hold', () {
      // The same rule the fades and the animations follow: a window longer
      // than twice the clip would reach past its far end.
      final clip = clipOf('a', 'm1', start: Tick.zero, duration: secs(5))
          .copyWith(
              transition: ClipTransition(
                  preset: TransitionPreset.dissolve, duration: secs(4)));
      final trimmed = clip.trimTailBy(-secs(4));
      expect(trimmed.duration, secs(1));
      expect(trimmed.transition.duration, secs(2));
      expect(trimmed.transition.preset, TransitionPreset.dissolve);
    });
  });

  group('editing one', () {
    test('SetClipTransition lands and merges into one undo entry', () {
      final store = DocumentStore(projectWithCut());
      store.run(
          SetClipTransition('b',
              ClipTransition(preset: TransitionPreset.wipe, duration: secs(1))),
          fromGestureStart: true);
      store.run(SetClipTransition('b',
          ClipTransition(preset: TransitionPreset.wipe, duration: secs(2))));

      expect(store.project.clipById('b')!.transition.duration, secs(2));
      store.undo();
      expect(store.project.clipById('b')!.transition, ClipTransition.none);
    });

    test('it is bounded by the clip before it', () {
      final project = emptyProject().addMedia(videoAsset('m1'));
      final store = DocumentStore(project.updateTrack(
        project.mainTrack.id,
        (t) => t.withClips([
          // A short clip first, so it is what bounds the window.
          clipOf('a', 'm1', start: Tick.zero, duration: secs(1)),
          clipOf('b', 'm1', start: secs(1), duration: secs(20)),
        ]),
      ));

      store.run(SetClipTransition('b',
          ClipTransition(preset: TransitionPreset.dissolve, duration: secs(3))));
      expect(store.project.clipById('b')!.transition.duration, secs(2));
    });

    test('a clip with nothing before it keeps the setting anyway', () {
      // A transition with no cut under it does nothing, and refusing to store
      // one would mean re-picking it every time a clip was dragged away from
      // its neighbour and back.
      final store = DocumentStore(projectWithCut());
      store.run(SetClipTransition('a',
          ClipTransition(preset: TransitionPreset.dissolve, duration: secs(1))));
      expect(store.project.clipById('a')!.transition.isActive, isTrue);
    });

    test('setting the same transition is not an edit', () {
      final store = DocumentStore(projectWithCut(
          ClipTransition(preset: TransitionPreset.push, duration: secs(1))));
      final before = store.project;
      store.run(SetClipTransition('b',
          ClipTransition(preset: TransitionPreset.push, duration: secs(1))));
      expect(identical(store.project, before), isTrue);
    });

    test('a clip that is not there is refused', () {
      final store = DocumentStore(projectWithCut());
      expect(
          () => store.run(
              const SetClipTransition('nope', ClipTransition.none)),
          throwsA(isA<EditException>()));
    });
  });

  group('the document never overlaps', () {
    test('a transition moves nothing at all', () {
      // The whole design decision: the overlap a transition needs is made by
      // the engine, not by the document — because Track.clipAt binary-searches
      // on clips being disjoint, and the magnetic lane would repack every clip
      // downstream if a cut could shorten the sequence.
      final plain = projectWithCut();
      final joined = projectWithCut(
          ClipTransition(preset: TransitionPreset.dissolve, duration: secs(2)));

      expect(joined.duration, plain.duration);
      for (final id in ['a', 'b']) {
        expect(joined.clipById(id)!.start, plain.clipById(id)!.start);
        expect(joined.clipById(id)!.duration, plain.clipById(id)!.duration);
      }
      // And the clips still meet exactly, with nothing between them.
      expect(joined.clipById('a')!.end, joined.clipById('b')!.start);
    });
  });

  group('crossing to the engine', () {
    EngineClip incoming(Project project) =>
        engineTimelineFor(project).clips.firstWhere((c) => c.durationTicks > 0 &&
            c.transition.preset != EngineTransitionPreset.none);

    test('the preset and the window go across', () {
      final clip = incoming(projectWithCut(
          ClipTransition(preset: TransitionPreset.wipe, duration: secs(1))));
      expect(clip.transition.preset, EngineTransitionPreset.wipe);
      expect(clip.transition.ticks, secs(1).raw);
    });

    test('a plain cut crosses as nothing', () {
      for (final clip in engineTimelineFor(projectWithCut()).clips) {
        expect(clip.transition.preset, EngineTransitionPreset.none);
        expect(clip.transition.ticks, 0);
      }
    });

    test('a preset with no length crosses as nothing', () {
      // Resolved here so the engine does not have to work it out twice.
      final project = projectWithCut(
          const ClipTransition(preset: TransitionPreset.dissolve));
      for (final clip in engineTimelineFor(project).clips) {
        expect(clip.transition.preset, EngineTransitionPreset.none);
      }
    });
  });

  group('on disk', () {
    test('a transition round-trips', () {
      final project = projectWithCut(
          ClipTransition(preset: TransitionPreset.fadeWhite, duration: secs(1)));
      final decoded = projectFromJson(projectToJson(project));
      expect(decoded.clipById('b')!.transition.preset,
          TransitionPreset.fadeWhite);
      expect(decoded.clipById('b')!.transition.duration, secs(1));
    });

    test('a plain cut writes nothing at all', () {
      final json = projectToJson(projectWithCut());
      for (final track in json['tracks']! as List<Object?>) {
        for (final clip in (track! as Map)['clips'] as List<Object?>) {
          expect((clip! as Map).containsKey('transition'), isFalse);
        }
      }
    });

    test('a preset this version has never heard of opens as a plain cut', () {
      // The same bargain an animation gets: the clips are on screen for the
      // same length of time either way, so there is nothing to guess wrongly
      // and a project that will not load is the larger loss.
      final json = projectToJson(projectWithCut(
          ClipTransition(preset: TransitionPreset.wipe, duration: secs(1))));
      final track = (json['tracks']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .firstWhere((t) => (t['clips']! as List<Object?>).length == 2);
      final clip =
          (track['clips']! as List<Object?>)[1]! as Map<String, Object?>;
      (clip['transition']! as Map<String, Object?>)['preset'] = 'kaleidoscope';

      expect(projectFromJson(json).clipById('b')!.transition,
          ClipTransition.none);
    });

    test('a length from a wider version opens as something editable', () {
      final json = projectToJson(projectWithCut(
          ClipTransition(preset: TransitionPreset.wipe, duration: secs(1))));
      final track = (json['tracks']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .firstWhere((t) => (t['clips']! as List<Object?>).length == 2);
      final clip =
          (track['clips']! as List<Object?>)[1]! as Map<String, Object?>;
      (clip['transition']! as Map<String, Object?>)['duration'] =
          secs(600).raw;

      expect(projectFromJson(json).clipById('b')!.transition.duration,
          ClipTransition.maxDuration);
    });
  });
}
