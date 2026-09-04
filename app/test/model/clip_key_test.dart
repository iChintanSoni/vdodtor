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

/// A key with every field somewhere different, so a value dropped or crossed
/// with its neighbour on the way through cannot land on the right number by
/// accident.
const _keyed = ClipKey(
  color: 0x33CC33,
  tolerance: 0.3,
  softness: 0.4,
  spill: 0.5,
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
  group('what a key is', () {
    test('nothing at all, for a clip nobody keyed', () {
      expect(ClipKey.none.color, 0);
      expect(ClipKey.none.tolerance, 0);
      expect(ClipKey.none.isNone, isTrue);
      expect(ClipKey.none.isKeying, isFalse);
    });

    test('the two shaping sliders open somewhere useful', () {
      // Not zero: a key with no softness is cut out with scissors and one with
      // no despill leaves the green on the subject's shoulder, so a key that
      // opened on zeros would be wrong in the two ways somebody would then
      // have to go and find the controls for.
      expect(ClipKey.none.softness, greaterThan(0));
      expect(ClipKey.none.spill, greaterThan(0));
    });

    test('tolerance is the on switch as well as the amount', () {
      const picked = ClipKey(color: 0x00FF00, tolerance: 0.2);
      expect(picked.isKeying, isTrue);
      // Turned all the way down, the document still remembers the colour —
      // exactly what a look at no strength does — and the frame shows all of
      // itself again.
      expect(picked.copyWith(tolerance: 0).isKeying, isFalse);
      expect(picked.copyWith(tolerance: 0).color, 0x00FF00);
    });

    test('a grey colour keys nothing, whatever the tolerance', () {
      // There is no hue to be near and nothing to measure a fraction of. The
      // engine refuses these on its own terms; this is the inspector agreeing,
      // so a swatch cannot be lit while nothing is being removed.
      for (final grey in [0x000000, 0x808080, 0xFFFFFF, 0x424344]) {
        expect(ClipKey(color: grey, tolerance: 1).isKeying, isFalse,
            reason: 'grey ${grey.toRadixString(16)}');
      }
      expect(const ClipKey(color: 0x424840, tolerance: 1).isKeying, isTrue);
    });

    test('picking a colour brings the tolerance back up', () {
      // Otherwise a colour chosen after the slider was dragged to nothing
      // arrives at nothing and appears to do nothing at all. The rule
      // ClipColor.withLook already has, because it is the same mistake.
      const off = ClipKey(color: 0x00FF00, tolerance: 0);
      expect(off.withColor(0x33CC33).tolerance, ClipKey.defaultTolerance);
      expect(off.withColor(0x33CC33).color, 0x33CC33);
    });

    test('and leaves a tolerance somebody chose alone', () {
      const tuned = ClipKey(color: 0x00FF00, tolerance: 0.65);
      expect(tuned.withColor(0x33CC33).tolerance, 0.65);
    });

    test('picking a grey does not turn a key on', () {
      expect(ClipKey.none.withColor(0x808080).isKeying, isFalse);
      expect(ClipKey.none.withColor(0x808080).tolerance, 0);
    });

    test('the alpha of a picked colour is dropped', () {
      // A key colour is a point in the picture, not ink: what comes back from
      // the eyedropper is opaque, and carrying that into the document would
      // make two keys on the same green compare unequal.
      expect(ClipKey.none.withColor(0xFF33CC33).color, 0x33CC33);
    });

    test('everything is clamped on the way in', () {
      const wild = ClipKey(
          color: 0xFF00FF00, tolerance: 4, softness: -1, spill: 9);
      final safe = wild.clamped();
      expect(safe.color, 0x00FF00);
      expect(safe.tolerance, 1);
      expect(safe.softness, 0);
      expect(safe.spill, 1);
    });
  });

  group('on a clip', () {
    test('a clip carries one, and it survives a copy', () {
      final clip = clipOf('a', 'm1', start: Tick.zero, duration: secs(2));
      expect(clip.key, ClipKey.none);
      expect(clip.copyWith(key: _keyed).key, _keyed);
    });

    test('two clips differing only in the key are different clips', () {
      final clip = clipOf('a', 'm1', start: Tick.zero, duration: secs(2));
      expect(clip.copyWith(key: _keyed), isNot(clip));
      expect(clip.copyWith(key: _keyed), clip.copyWith(key: _keyed));
    });

    test('a trim leaves the key exactly as it was', () {
      // A key is not measured in time at all — unlike a fade, which is — so
      // nothing about a length can reach it.
      final clip =
          clipOf('a', 'm1', start: Tick.zero, duration: secs(5))
              .copyWith(key: _keyed);
      expect(clip.trimHeadBy(secs(1)).key, _keyed);
      expect(clip.trimTailBy(-secs(1)).key, _keyed);
    });
  });

  group('the command', () {
    late DocumentStore store;
    setUp(() => store = DocumentStore(projectWithClip()));
    tearDown(() => store.dispose());

    test('sets the key on the clip it names', () {
      store.run(const SetClipKey('a', _keyed));
      expect(store.project.clipById('a')!.key, _keyed);
    });

    test('clamps, so the document cannot hold what no slider can show', () {
      store.run(const SetClipKey('a', ClipKey(color: 0x00FF00, tolerance: 3)));
      expect(store.project.clipById('a')!.key.tolerance, 1);
    });

    test('a drag is one undo step, not one per value', () {
      final before = store.project;
      for (var i = 1; i <= 6; i++) {
        store.run(SetClipKey('a', ClipKey(color: 0x00FF00, tolerance: i / 10)),
            fromGestureStart: i == 1);
      }
      store.endGesture();
      expect(store.project.clipById('a')!.key.tolerance, closeTo(0.6, 1e-9));
      store.undo();
      expect(store.project, same(before));
    });

    test('setting the key it already has changes nothing at all', () {
      store.run(const SetClipKey('a', _keyed));
      final after = store.project;
      store.run(const SetClipKey('a', _keyed));
      expect(store.project, same(after));
    });

    test('a clip that is not there is an error', () {
      expect(() => store.run(const SetClipKey('nope', _keyed)),
          throwsA(isA<EditException>()));
    });
  });

  group('in the file', () {
    test('a clip nobody keyed writes nothing about a key', () {
      final json = projectToJson(projectWithClip());
      expect(_firstClipJson(json).containsKey('key'), isFalse);
    });

    test('a colour at no tolerance writes nothing either', () {
      // A file records what happens rather than what was clicked on the way
      // there — the rule an animation and a transition already take.
      final project = projectWithClip().updateTrack(
        mainTrackId,
        (t) => t.withClips([
          t.clips.first.copyWith(key: const ClipKey(color: 0x00FF00)),
        ]),
      );
      expect(_firstClipJson(projectToJson(project)).containsKey('key'), isFalse);
    });

    test('a key round-trips', () {
      final project = projectWithClip().updateTrack(
        mainTrackId,
        (t) => t.withClips([t.clips.first.copyWith(key: _keyed)]),
      );
      final back = projectFromJson(projectToJson(project));
      expect(back.clipById('a')!.key, _keyed);
    });

    test('the sliders left at their defaults are left out', () {
      final project = projectWithClip().updateTrack(
        mainTrackId,
        (t) => t.withClips([
          t.clips.first
              .copyWith(key: const ClipKey(color: 0x33CC33, tolerance: 0.2)),
        ]),
      );
      final written =
          _firstClipJson(projectToJson(project))['key']! as Map<String, Object?>;
      expect(written.keys, containsAll(<String>['color', 'tolerance']));
      expect(written.containsKey('softness'), isFalse);
      expect(written.containsKey('spill'), isFalse);

      // And they come back as the defaults rather than as zero.
      final back = projectFromJson(projectToJson(project));
      expect(back.clipById('a')!.key.softness, ClipKey.defaultSoftness);
      expect(back.clipById('a')!.key.spill, ClipKey.defaultSpill);
    });

    test('a key object with no colour opens as no key', () {
      // The safe reading of a hand edit: the clip is whole rather than gone.
      final json = projectToJson(projectWithClip());
      _firstClipJson(json)['key'] = {'tolerance': 0.5};
      final back = projectFromJson(json);
      expect(back.clipById('a')!.key.isKeying, isFalse);
    });

    test('a field this version has never heard of is ignored', () {
      final json = projectToJson(projectWithClip());
      _firstClipJson(json)['key'] = {
        'color': 0x33CC33,
        'tolerance': 0.4,
        'edgeShrink': 0.7,
      };
      final back = projectFromJson(json);
      expect(back.clipById('a')!.key.color, 0x33CC33);
      expect(back.clipById('a')!.key.tolerance, 0.4);
    });
  });

  group('through to the engine', () {
    test('every field arrives, and on the same scale', () {
      final project = projectWithClip().updateTrack(
        mainTrackId,
        (t) => t.withClips([t.clips.first.copyWith(key: _keyed)]),
      );
      final clip = engineTimelineFor(project).clips.single;
      expect(clip.key.color, _keyed.color);
      expect(clip.key.tolerance, _keyed.tolerance);
      expect(clip.key.softness, _keyed.softness);
      expect(clip.key.spill, _keyed.spill);
    });

    test('an unkeyed clip crosses as no tolerance, which is no key', () {
      final clip = engineTimelineFor(projectWithClip()).clips.single;
      expect(clip.key.tolerance, 0);
    });
  });
}

Map<String, Object?> _firstClipJson(Map<String, Object?> json) {
  final tracks = json['tracks']! as List<Object?>;
  final track = tracks.first! as Map<String, Object?>;
  final clips = track['clips']! as List<Object?>;
  return clips.first! as Map<String, Object?>;
}
