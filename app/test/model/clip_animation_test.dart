import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/commands/document_store.dart';
import 'package:vdodtor/commands/edits.dart';
import 'package:vdodtor/engine/timeline_sync.dart';
import 'package:vdodtor/model/clip.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor/model/project.dart';
import 'package:vdodtor/model/track.dart';
// The generated bindings, on purpose: they are the C header in Dart form, and
// checking the hand-written enum against them is what makes this a check on
// vd_anim.h rather than on the file next to it.
// ignore: implementation_imports
import 'package:vdodtor_engine/src/bindings.g.dart' show VdAnimPreset;
import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../fixtures.dart';

void main() {
  group('the preset list', () {
    test('is the same list in the document, the plugin and the engine', () {
      // Three enums, one order, and the index is what crosses the boundary —
      // so a preset inserted in the middle of one of them would silently
      // rename every animation in every project on disk. The generated
      // bindings come straight from vd_anim.h, which makes this a check on
      // the C header and not only on the Dart beside it.
      expect(
        AnimationPreset.values.map((p) => p.name).toList(),
        EngineAnimPreset.values.map((p) => p.name).toList(),
      );
      expect(AnimationPreset.values.length, VdAnimPreset.values.length);
      for (var i = 0; i < AnimationPreset.values.length; i++) {
        expect(VdAnimPreset.values[i].value, i,
            reason: 'the C enum is not densely numbered from zero, so an '
                'index is not a value');
      }
    });

    test('every preset has something to call itself', () {
      for (final preset in AnimationPreset.values) {
        expect(preset.label, isNotEmpty);
      }
      expect(AnimationPreset.none.isNone, isTrue);
      expect(AnimationPreset.fade.isNone, isFalse);
    });
  });

  group('ClipAnimation', () {
    test('a clip nobody animated is still', () {
      const a = ClipAnimation.still;
      expect(a.isStill, isTrue);
      expect(a.isAnimated, isFalse);
      expect(a.hasIn, isFalse);
      expect(a.hasOut, isFalse);
    });

    test('a preset without a length is not an animation', () {
      // Both halves of the rule, because both can happen: a preset chosen and
      // then dragged to nothing, and a length left behind by a preset set
      // back to none.
      const noLength = ClipAnimation(inPreset: AnimationPreset.pop);
      expect(noLength.hasIn, isFalse);
      expect(noLength.isAnimated, isFalse);

      const noPreset = ClipAnimation(inDuration: Tick(60000));
      expect(noPreset.hasIn, isFalse);
    });

    test('choosing a preset gives it time to run in', () {
      // A picker whose entries do nothing is a picker nobody trusts.
      final a = ClipAnimation.still.withInPreset(AnimationPreset.slideUp);
      expect(a.inPreset, AnimationPreset.slideUp);
      expect(a.inDuration, ClipAnimation.defaultDuration);
      expect(a.hasIn, isTrue);
      // And the exit is untouched.
      expect(a.hasOut, isFalse);
    });

    test('and choosing none takes it away again', () {
      final a = ClipAnimation.still
          .withInPreset(AnimationPreset.pop)
          .withInPreset(AnimationPreset.none);
      expect(a.inPreset, AnimationPreset.none);
      expect(a.inDuration, Tick.zero,
          reason: 'a file should not carry a length for an animation that is '
              'not there');
      expect(a, ClipAnimation.still);
    });

    test('a length already set is kept when the preset changes', () {
      final a = ClipAnimation.still
          .withInPreset(AnimationPreset.fade)
          .copyWith(inDuration: secs(1))
          .withInPreset(AnimationPreset.spin);
      expect(a.inDuration, secs(1));
    });

    test('clamping shares a short clip between the two halves', () {
      // The same rule the audio fades follow, for the same reason: trimming a
      // clip shorter than its own entrance is the ordinary way to get here.
      final a = ClipAnimation(
        inPreset: AnimationPreset.fade,
        inDuration: secs(1),
        outPreset: AnimationPreset.fade,
        outDuration: secs(3),
      ).clampedTo(secs(2));

      expect(a.inDuration.raw + a.outDuration.raw, secs(2).raw);
      // In the proportion asked for — 1:3 stays 1:3, rather than each being
      // clamped to the whole clip and the ratio becoming something else.
      expect(a.inDuration, secs(0.5));
      expect(a.outDuration, secs(1.5));
    });

    test('and caps either half on its own', () {
      final a = ClipAnimation(
        inPreset: AnimationPreset.fade,
        inDuration: secs(30),
      ).clampedTo(secs(60));
      expect(a.inDuration, ClipAnimation.maxDuration);
    });

    test('a clip with no length has no animation', () {
      final a = ClipAnimation(
        inPreset: AnimationPreset.fade,
        inDuration: secs(1),
      ).clampedTo(Tick.zero);
      expect(a.hasIn, isFalse);
    });

    test('clamping leaves an animation that fits alone', () {
      final a = ClipAnimation(
        inPreset: AnimationPreset.fade,
        inDuration: secs(0.4),
        outPreset: AnimationPreset.zoom,
        outDuration: secs(0.4),
      );
      expect(a.clampedTo(secs(5)), a);
    });

    test('equality is by value', () {
      const a = ClipAnimation(
          inPreset: AnimationPreset.pop, inDuration: Tick(1000));
      const b = ClipAnimation(
          inPreset: AnimationPreset.pop, inDuration: Tick(1000));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.copyWith(inDuration: const Tick(2000)), isNot(b));
      expect(a.copyWith(inPreset: AnimationPreset.zoom), isNot(b));
    });
  });

  group('on a clip', () {
    test('trimming a clip shortens the animation with it', () {
      // Otherwise trimming would leave an entrance the clip never finishes
      // arriving from.
      final clip = clipOf('a', 'm1', start: Tick.zero, duration: secs(4))
          .copyWith(
        animation: ClipAnimation(
          inPreset: AnimationPreset.fade,
          inDuration: secs(2),
        ),
      );
      final trimmed = clip.trimTailBy(secs(-3));  // now one second long
      expect(trimmed.duration, secs(1));
      expect(trimmed.animation.inDuration, secs(1));
    });

    test('splitting gives each half the end it still has', () {
      // The same division the fades get: an entrance on the tail would be the
      // clip arriving in the middle of itself.
      final store = DocumentStore(projectWithThreeClips());
      store.run(SetClipAnimation(
        'b',
        ClipAnimation(
          inPreset: AnimationPreset.slideUp,
          inDuration: secs(0.5),
          outPreset: AnimationPreset.fade,
          outDuration: secs(0.5),
        ),
      ));
      store.endGesture();
      final before = store.project.clipById('b')!;
      store.run(SplitClip('b', before.start + secs(1), newClipId: 'b2'));

      final head = store.project.clipById('b')!;
      final tail = store.project.clipById('b2')!;
      expect(head.animation.inPreset, AnimationPreset.slideUp);
      expect(head.animation.hasOut, isFalse);
      expect(tail.animation.hasIn, isFalse);
      expect(tail.animation.outPreset, AnimationPreset.fade);
    });

    test('SetClipAnimation clamps and merges', () {
      final store = DocumentStore(projectWithThreeClips());
      final length = store.project.clipById('b')!.duration;

      store.run(SetClipAnimation(
        'b',
        ClipAnimation(
            inPreset: AnimationPreset.fade, inDuration: secs(30)),
      ));
      expect(store.project.clipById('b')!.animation.inDuration.raw,
          lessThanOrEqualTo(length.raw));

      // A run of drags on the same clip is one undo entry.
      store.run(SetClipAnimation(
        'b',
        ClipAnimation(
            inPreset: AnimationPreset.fade, inDuration: secs(0.2)),
      ));
      store.undo();
      expect(store.project.clipById('b')!.animation, ClipAnimation.still);
    });

    test('it applies to any clip, not only to a caption', () {
      // An animation is the transform a clip already has, over time, so there
      // is nothing about it only a caption can do.
      final store = DocumentStore(projectWithThreeClips());
      store.run(SetClipAnimation('a',
          ClipAnimation(inPreset: AnimationPreset.pop, inDuration: secs(0.4))));
      expect(store.project.clipById('a')!.animation.hasIn, isTrue);
    });
  });

  group('reaching the engine', () {
    Project animated(ClipAnimation animation) {
      final project = projectWithThreeClips();
      return project.updateTrack(
        mainTrackId,
        (t) => t.withClips([
          for (final c in t.clips)
            c.id == 'a' ? c.copyWith(animation: animation) : c,
        ]),
      );
    }

    EngineClip firstClip(Project project) =>
        engineTimelineFor(project).clips.first;

    test('an animation crosses as a preset and a length', () {
      final clip = firstClip(animated(ClipAnimation(
        inPreset: AnimationPreset.spin,
        inDuration: secs(0.5),
        outPreset: AnimationPreset.slideLeft,
        outDuration: secs(0.25),
      )));

      expect(clip.animation.inPreset, EngineAnimPreset.spin);
      expect(clip.animation.inTicks, secs(0.5).raw);
      expect(clip.animation.outPreset, EngineAnimPreset.slideLeft);
      expect(clip.animation.outTicks, secs(0.25).raw);
    });

    test('a half that would not run crosses as nothing at all', () {
      // A preset with no length and a length with no preset both mean the
      // same thing, and the engine should not have to work that out twice.
      final noLength = firstClip(
          animated(const ClipAnimation(inPreset: AnimationPreset.pop)));
      expect(noLength.animation.inPreset, EngineAnimPreset.none);
      expect(noLength.animation.inTicks, 0);

      final noPreset =
          firstClip(animated(ClipAnimation(inDuration: secs(1))));
      expect(noPreset.animation.inPreset, EngineAnimPreset.none);
      expect(noPreset.animation.inTicks, 0);
    });

    test('an unanimated clip crosses as still', () {
      final clip = firstClip(projectWithThreeClips());
      expect(clip.animation.inPreset, EngineAnimPreset.none);
      expect(clip.animation.outPreset, EngineAnimPreset.none);
    });

    test('a caption carries one too', () {
      final project = emptyProject().addTrack(Track.of(
        id: 'tr-text',
        kind: TrackKind.text,
        name: 'Text 1',
        clips: [
          Clip.caption(
            id: 't1',
            start: Tick.zero,
            duration: secs(3),
            text: const ClipText(text: 'Hello'),
            animation: ClipAnimation(
              inPreset: AnimationPreset.typewriter,
              inDuration: secs(1),
            ),
          ),
        ],
      ));

      final clip = engineTimelineFor(project).clips.single;
      expect(clip.text, isNotNull);
      expect(clip.animation.inPreset, EngineAnimPreset.typewriter);
      expect(clip.animation.inTicks, secs(1).raw);
    });
  });
}
