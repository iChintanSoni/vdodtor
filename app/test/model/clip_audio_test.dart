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
// checking the hand-written enums against them is what makes this a check on
// vd_engine.h and vd_eq.h rather than on the file next to it.
// ignore: implementation_imports
import 'package:vdodtor_engine/src/bindings.g.dart'
    show VdEqPreset, VdFadeCurve;
import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../fixtures.dart';

/// The fade envelope, as a table.
///
/// The engine computes this same shape in C — `vd_audio_fade_gain` — and
/// `engine/tests/vd_audio_test.c` asserts on the identical numbers. A fade the
/// timeline draws and a fade the speakers play being the same shape is not
/// something to leave to two people reading the same prose, so it is left to
/// two people reading the same table.
/// One row per offset, one entry per curve, in the order [FadeCurve] declares
/// them — so a curve inserted in the middle of the enum reads the wrong column
/// and this table says so, which is a second reason for it beyond the numbers.
const _fadeTable = <({int offset, List<double> gains})>[
  // linear, smooth, equal power, exponential
  (offset: -1, gains: [0, 0, 0, 0]), // before the clip
  (offset: 0, gains: [0, 0, 0, 0]), // the very start of a fade in
  (offset: 50, gains: [0.25, 0.146447, 0.382683, 0.0625]), // a quarter up
  (offset: 100, gains: [0.5, 0.5, 0.707107, 0.25]), // halfway up
  (offset: 200, gains: [1, 1, 1, 1]), // fade in is over
  (offset: 500, gains: [1, 1, 1, 1]), // the middle is untouched
  (offset: 600, gains: [1, 1, 1, 1]), // where the fade out begins
  (offset: 700, gains: [0.75, 0.853553, 0.923880, 0.5625]), // 300 of 400
  (offset: 900, gains: [0.25, 0.146447, 0.382683, 0.0625]), // 100 of 400
  // One tick from the end of a 400 fade: every curve is on the floor, and the
  // point of the row is that none of them reached it early.
  (offset: 999, gains: [0.0025, 0.0000154, 0.003927, 0.00000625]),
  (offset: 1000, gains: [0, 0, 0, 0]), // past the end
];

const _fadeDuration = 1000;
const _fadeIn = 200;
const _fadeOut = 400;

/// A duck, as a table: full level, down to a quarter over 200 ticks, held for
/// 400, and back up.
///
/// The engine computes this same shape in C — `vd_audio_automation_gain` — and
/// `engine/tests/vd_audio_test.c` asserts on the identical numbers, for the
/// reason the fade table exists and by the same mechanism.
const _duck = <VolumePoint>[
  VolumePoint(Tick(1000), 1),
  VolumePoint(Tick(1200), 0.25),
  VolumePoint(Tick(1600), 0.25),
  VolumePoint(Tick(1800), 1),
];

const _automationTable = <({int at, double gain})>[
  (at: 0, gain: 1), // before the first point, held flat at its value
  (at: 1000, gain: 1), // on it
  (at: 1100, gain: 0.625), // halfway down the ramp
  (at: 1200, gain: 0.25), // the bottom
  (at: 1400, gain: 0.25), // the floor of the duck
  (at: 1600, gain: 0.25), // the last tick of the floor
  (at: 1700, gain: 0.625), // halfway back up
  (at: 1800, gain: 1), // on the last point
  (at: 9999, gain: 1), // after them all, held flat — not ramped to unity
];

/// An empty project with a music file in the bin, ready for a clip on the
/// audio lane.
Project projectWithSound() =>
    emptyProject().addMedia(audioAsset('song', seconds: 30));

void main() {
  group('the value', () {
    test('a clip nobody touched is at unity', () {
      final clip = clipOf('a', 'm1', start: Tick.zero, duration: secs(1));
      expect(clip.audio, ClipAudio.unity);
      expect(clip.audio.isUnity, isTrue);
      expect(clip.audio.volume, 1);
      expect(clip.audio.muted, isFalse);
    });

    test('mute does not throw the level away', () {
      // The whole reason there is a mute *and* a volume: unmuting has to give
      // the level back, so mute cannot be spelled `volume = 0`.
      const loud = ClipAudio(volume: 0.4);
      final muted = loud.copyWith(muted: true);
      expect(muted.effectiveVolume, 0);
      expect(muted.volume, 0.4);
      expect(muted.copyWith(muted: false).effectiveVolume, 0.4);
    });

    test('a volume above the cap is pulled back to it', () {
      const shouted = ClipAudio(volume: 99);
      expect(shouted.effectiveVolume, ClipAudio.maxVolume);
    });

    test('the fade envelope matches the table the engine tests', () {
      for (final row in _fadeTable) {
        for (final curve in FadeCurve.values) {
          expect(
            ClipAudio.fadeShapeAt(Tick(row.offset), const Tick(_fadeDuration),
                const Tick(_fadeIn), const Tick(_fadeOut),
                curve: curve),
            closeTo(row.gains[curve.index], 0.0005),
            reason: 'a ${curve.name} fade at offset ${row.offset}',
          );
        }
      }
    });

    test('a fade with no curve named is the one every fade used to be', () {
      // Linear, and the default — so a project written before there was a
      // choice sounds exactly as it did.
      expect(ClipAudio.unity.fadeCurve, FadeCurve.linear);
      for (final row in _fadeTable) {
        expect(
          ClipAudio.fadeShapeAt(Tick(row.offset), const Tick(_fadeDuration),
              const Tick(_fadeIn), const Tick(_fadeOut)),
          closeTo(row.gains[FadeCurve.linear.index], 0.0005),
        );
      }
    });

    test('every curve starts at silence and ends at full', () {
      // Whatever a curve does in between, a fade that arrived at 0.99 would
      // click at exactly the moment it stopped.
      for (final curve in FadeCurve.values) {
        expect(
          ClipAudio.fadeShapeAt(Tick.zero, const Tick(_fadeDuration),
              const Tick(_fadeIn), Tick.zero,
              curve: curve),
          0,
          reason: curve.name,
        );
        expect(
          ClipAudio.fadeShapeAt(const Tick(_fadeIn), const Tick(_fadeDuration),
              const Tick(_fadeIn), Tick.zero,
              curve: curve),
          1,
          reason: curve.name,
        );
      }
    });

    test('the curve reaches the gain a clip actually plays at', () {
      // `gainAt` is what the timeline draws the waveform through, so a curve
      // the envelope knew about and the clip did not would be a fade that
      // looked wrong and sounded right.
      final clip = clipOf('a', 'm1', start: Tick.zero, duration: secs(4))
          .copyWith(
        audio: ClipAudio(
            fadeIn: secs(2), fadeCurve: FadeCurve.exponential),
      );
      expect(clip.gainAt(secs(1)), closeTo(0.25, 1e-9));
      expect(clip.gainAt(secs(2)), closeTo(1, 1e-9));
    });

    test('no fades means no envelope at all', () {
      for (final offset in [0, 1, 500, 999]) {
        expect(
          ClipAudio.fadeShapeAt(
              Tick(offset), const Tick(1000), Tick.zero, Tick.zero),
          1,
        );
      }
    });

    test('gainAt folds volume, mute and the fades together', () {
      const a = ClipAudio(volume: 0.5, fadeIn: Tick(_fadeIn));
      expect(a.gainAt(const Tick(100), const Tick(_fadeDuration)),
          closeTo(0.25, 1e-9));
      expect(a.copyWith(muted: true).gainAt(
          const Tick(100), const Tick(_fadeDuration)), 0);
    });

    test('fades that would overlap are shortened to share the clip', () {
      // Multiplying two overlapping ramps dips in the middle, which is nobody's
      // intent — so they get the length they asked for, in proportion.
      const greedy = ClipAudio(fadeIn: Tick(300), fadeOut: Tick(900));
      final fitted = greedy.clampedTo(const Tick(400));
      expect(fitted.fadeIn.raw + fitted.fadeOut.raw, 400);
      expect(fitted.fadeIn.raw, 100); // 300 of the 1200 asked for
      expect(fitted.fadeOut.raw, 300);
    });

    test('fades that already fit are left exactly alone', () {
      const a = ClipAudio(fadeIn: Tick(100), fadeOut: Tick(200));
      expect(identical(a.clampedTo(const Tick(1000)), a), isTrue);
    });

    test('trimming a clip shorter than its fades takes them with it', () {
      final clip = Clip(
        id: 'a',
        mediaId: 'm1',
        start: Tick.zero,
        duration: secs(4),
        audio: ClipAudio(fadeIn: secs(1), fadeOut: secs(1)),
      );
      final trimmed = clip.trimTailBy(-secs(3)); // down to one second
      expect(trimmed.duration, secs(1));
      expect(trimmed.audio.fadeIn.raw + trimmed.audio.fadeOut.raw,
          lessThanOrEqualTo(secs(1).raw));
    });
  });

  group('curves and presets', () {
    test('the fade curves are the same list on both sides of the boundary',
        () {
      // Three enums, one order, and the index is what crosses — so a curve
      // inserted in the middle of one of them would silently reshape every
      // fade in every project on disk. The generated bindings come straight
      // from vd_engine.h, which makes this a check on the C header.
      expect(
        FadeCurve.values.map((c) => c.name).toList(),
        EngineFadeCurve.values.map((c) => c.name).toList(),
      );
      expect(FadeCurve.values.length, VdFadeCurve.values.length);
      for (var i = 0; i < FadeCurve.values.length; i++) {
        expect(VdFadeCurve.values[i].value, i,
            reason: 'the C enum is not densely numbered from zero, so an '
                'index is not a value');
      }
      // Zero is linear on all three, which is what lets a caller that memsets
      // the struct get the fade every project already had.
      expect(FadeCurve.values.first, FadeCurve.linear);
    });

    test('the EQ presets are the same list on both sides of the boundary', () {
      expect(
        EqPreset.values.map((p) => p.name).toList(),
        EngineEqPreset.values.map((p) => p.name).toList(),
      );
      expect(EqPreset.values.length, VdEqPreset.values.length);
      for (var i = 0; i < EqPreset.values.length; i++) {
        expect(VdEqPreset.values[i].value, i);
      }
      expect(EqPreset.values.first, EqPreset.none);
    });

    test('every entry has something to call itself', () {
      for (final curve in FadeCurve.values) {
        expect(curve.label, isNotEmpty);
      }
      for (final preset in EqPreset.values) {
        expect(preset.label, isNotEmpty);
      }
      expect(FadeCurve.linear.isLinear, isTrue);
      expect(FadeCurve.smooth.isLinear, isFalse);
      expect(EqPreset.none.isNone, isTrue);
      expect(EqPreset.voice.isNone, isFalse);
    });

    test('a clip nobody touched has neither', () {
      expect(ClipAudio.unity.fadeCurve, FadeCurve.linear);
      expect(ClipAudio.unity.eq, EqPreset.none);
      expect(ClipAudio.unity.isUnity, isTrue);
      // And either one on its own is enough to make a clip not-unity, which is
      // what puts the Reset button on the panel.
      expect(const ClipAudio(eq: EqPreset.voice).isUnity, isFalse);
      expect(const ClipAudio(fadeCurve: FadeCurve.smooth).isUnity, isFalse);
    });

    test('both cross to the engine as what they are', () {
      final project = projectWithSound().updateTrack(
        audioTrackId,
        (t) => t.withClips([
          clipOf('bed', 'song', start: Tick.zero, duration: secs(4)).copyWith(
            audio: ClipAudio(
              fadeIn: secs(1),
              fadeCurve: FadeCurve.equalPower,
              eq: EqPreset.telephone,
            ),
          ),
        ]),
      );

      final sent = engineTimelineFor(project).clips.single;
      expect(sent.fadeCurve, EngineFadeCurve.equalPower);
      expect(sent.eq, EngineEqPreset.telephone);
      // The shape and the name, not the shaped values: the mixer evaluates the
      // fade per audio frame and owns what a preset means.
      expect(sent.fadeInTicks, secs(1).raw);
    });

    test('a clip with neither says so', () {
      final sent = engineTimelineFor(projectWithSound().updateTrack(
        audioTrackId,
        (t) => t.withClips(
            [clipOf('bed', 'song', start: Tick.zero, duration: secs(4))]),
      )).clips.single;
      expect(sent.fadeCurve, EngineFadeCurve.linear);
      expect(sent.eq, EngineEqPreset.none);
    });

    test('both round-trip through a project file', () {
      final project = projectWithSound().updateTrack(
        audioTrackId,
        (t) => t.withClips([
          clipOf('bed', 'song', start: Tick.zero, duration: secs(4)).copyWith(
            audio: ClipAudio(
              fadeOut: secs(1),
              fadeCurve: FadeCurve.smooth,
              eq: EqPreset.voice,
            ),
          ),
        ]),
      );

      final back = decodeProject(encodeProject(project)).clipById('bed')!;
      expect(back.audio.fadeCurve, FadeCurve.smooth);
      expect(back.audio.eq, EqPreset.voice);
    });

    test('a clip with neither writes neither', () {
      // A project file should read like the edit that made it, and almost
      // every clip in it has a plain fade and no filter.
      final json = encodeProject(projectWithSound().updateTrack(
        audioTrackId,
        (t) => t.withClips([
          clipOf('bed', 'song', start: Tick.zero, duration: secs(4))
              .copyWith(audio: ClipAudio(fadeIn: secs(1))),
        ]),
      ));
      expect(json, isNot(contains('fadeCurve')));
      expect(json, isNot(contains('"eq"')));
    });

    test('a curve outlives no fade at all', () {
      // Dragging a fade back to zero takes the shape with it, so the document
      // cannot hold a curve the panel no longer shows — which is also what
      // keeps the file and the document in step, and the Reset button honest.
      final store = DocumentStore(projectWithSound().updateTrack(
        audioTrackId,
        (t) => t.withClips(
            [clipOf('bed', 'song', start: Tick.zero, duration: secs(4))]),
      ));
      store.run(SetClipAudio('bed',
          ClipAudio(fadeIn: secs(1), fadeCurve: FadeCurve.exponential)));
      store.endGesture();
      expect(store.project.clipById('bed')!.audio.fadeCurve,
          FadeCurve.exponential);

      store.run(const SetClipAudio(
          'bed', ClipAudio(fadeCurve: FadeCurve.exponential)));
      final bare = store.project.clipById('bed')!.audio;
      expect(bare.fadeCurve, FadeCurve.linear);
      expect(bare.isUnity, isTrue,
          reason: 'nothing left to reset, so no Reset button');
      expect(encodeProject(store.project), isNot(contains('fadeCurve')));
    });

    test('a trim that takes the fades takes the shape with them', () {
      final store = DocumentStore(projectWithSound().updateTrack(
        audioTrackId,
        (t) => t.withClips(
            [clipOf('bed', 'song', start: Tick.zero, duration: secs(4))]),
      ));
      store.run(SetClipAudio('bed',
          ClipAudio(fadeIn: secs(1), fadeCurve: FadeCurve.smooth)));
      store.endGesture();

      // Every path that shortens a clip runs through `clampedTo`, and a clip
      // with no length has no fades — so it has no shape either.
      expect(
          store.project
              .clipById('bed')!
              .audio
              .clampedTo(Tick.zero)
              .fadeCurve,
          FadeCurve.linear);
    });

    test('what the document holds is what the file gets', () {
      // The round trip is exact, which a curve written only when there were
      // fades would have broken the moment somebody dragged one to zero.
      for (final audio in [
        const ClipAudio(),
        const ClipAudio(eq: EqPreset.bright),
        ClipAudio(fadeIn: secs(1), fadeCurve: FadeCurve.smooth),
        ClipAudio(
            fadeOut: secs(1),
            fadeCurve: FadeCurve.exponential,
            eq: EqPreset.telephone),
      ]) {
        final project = projectWithSound().updateTrack(
          audioTrackId,
          (t) => t.withClips([
            clipOf('bed', 'song', start: Tick.zero, duration: secs(4))
                .copyWith(audio: audio),
          ]),
        );
        expect(decodeProject(encodeProject(project)).clipById('bed')!.audio,
            audio,
            reason: '$audio');
      }
    });

    test('a curve or a preset this version never heard of opens as none', () {
      final project = projectWithSound().updateTrack(
        audioTrackId,
        (t) => t.withClips([
          clipOf('bed', 'song', start: Tick.zero, duration: secs(4)).copyWith(
            audio: ClipAudio(
                fadeIn: secs(1),
                fadeCurve: FadeCurve.smooth,
                eq: EqPreset.voice),
          ),
        ]),
      );
      final tampered = encodeProject(project)
          .replaceAll('"fadeCurve": "smooth"', '"fadeCurve": "sawtooth"')
          .replaceAll('"eq": "voice"', '"eq": "helicopter"');

      // A fade in a shape this build does not know is still a fade, and a clip
      // with a filter it cannot build is still audible — a project that will
      // not open is the larger loss either way.
      final back = decodeProject(tampered).clipById('bed')!;
      expect(back.audio.fadeCurve, FadeCurve.linear);
      expect(back.audio.eq, EqPreset.none);
      expect(back.audio.fadeIn, secs(1));
    });

    test('setting either is one undo entry with the rest of the panel', () {
      final store = DocumentStore(projectWithSound().updateTrack(
        audioTrackId,
        (t) => t.withClips(
            [clipOf('bed', 'song', start: Tick.zero, duration: secs(4))]),
      ));
      store.run(
          SetClipAudio('bed', ClipAudio(fadeIn: secs(1), eq: EqPreset.music)),
          fromGestureStart: true);
      store.run(
          SetClipAudio(
              'bed',
              ClipAudio(
                  fadeIn: secs(1),
                  eq: EqPreset.music,
                  fadeCurve: FadeCurve.smooth)),
          fromGestureStart: true);

      expect(store.project.clipById('bed')!.audio.eq, EqPreset.music);
      expect(store.project.clipById('bed')!.audio.fadeCurve, FadeCurve.smooth);
      expect(store.undoLabels, ['Adjust audio']);
    });
  });

  group('the volume line', () {
    test('matches the table the engine tests', () {
      for (final row in _automationTable) {
        expect(
          ClipAudio.automationAt(_duck, Tick(row.at)),
          closeTo(row.gain, 0.0005),
          reason: 'at ${row.at}',
        );
      }
    });

    test('no line at all is a flat one, and one point is a flat that', () {
      expect(ClipAudio.automationAt(const [], const Tick(500)), 1);
      const lone = [VolumePoint(Tick(500), 0.4)];
      expect(ClipAudio.automationAt(lone, Tick.zero), 0.4);
      expect(ClipAudio.automationAt(lone, const Tick(5000)), 0.4);
    });

    test('two points at the same tick are a step, not a division by zero', () {
      const step = [
        VolumePoint(Tick(0), 1),
        VolumePoint(Tick(500), 1),
        VolumePoint(Tick(500), 0),
      ];
      expect(ClipAudio.automationAt(step, const Tick(499)), greaterThan(0.99));
      expect(ClipAudio.automationAt(step, const Tick(500)), 0);
    });

    test('gainAt folds the line in with the fader, mute and the fades', () {
      const a = ClipAudio(volume: 0.5, points: _duck);
      final clip = Clip(
        id: 'a',
        mediaId: 'm1',
        start: secs(3),
        duration: const Tick(4000),
        audio: a,
      );
      // Half the fader, a quarter from the line.
      expect(clip.gainAt(const Tick(1400)), closeTo(0.125, 1e-9));
      expect(
          clip.copyWith(audio: a.copyWith(muted: true)).gainAt(const Tick(1400)),
          0);
    });

    test('the line is read at the source time, not the clip offset', () {
      // The whole reason points are stored in the source's own time: a clip
      // trimmed past the duck plays the level after it, not the level before.
      const a = ClipAudio(points: _duck);
      final head =
          Clip(id: 'a', mediaId: 'm1', start: Tick.zero, duration: const Tick(4000),
              audio: a);
      final trimmed = head.trimHeadBy(const Tick(1400));
      // 200 ticks into the trimmed clip is source tick 1600 — the floor.
      expect(trimmed.gainAt(const Tick(200)), closeTo(0.25, 1e-9));
      // The same offset on the untrimmed clip is still full level.
      expect(head.gainAt(const Tick(200)), closeTo(1, 1e-9));
    });

    test('trimming a clip leaves the line alone entirely', () {
      // Non-destructive, so trimming in and back out brings the duck back.
      const a = ClipAudio(points: _duck);
      final clip = Clip(
        id: 'a',
        mediaId: 'm1',
        start: Tick.zero,
        duration: const Tick(4000),
        audio: a,
      );
      final tiny = clip.trimTailBy(const Tick(-3900));
      expect(tiny.audio.points, _duck);
      expect(tiny.trimTailBy(const Tick(3900)).audio.points, _duck);
    });

    test('adding a point keeps the list sorted, and replaces at the same tick',
        () {
      var a = ClipAudio.unity.withPoint(const Tick(500), 0.5);
      a = a.withPoint(const Tick(100), 0.9);
      a = a.withPoint(const Tick(900), 0.1);
      expect(a.points.map((p) => p.sourceTime.raw), [100, 500, 900]);

      a = a.withPoint(const Tick(500), 0.2);
      expect(a.points, hasLength(3));
      expect(a.points[1].value, 0.2);
    });

    test('a point cannot be added louder than the fader goes', () {
      final a = ClipAudio.unity.withPoint(const Tick(0), 99);
      expect(a.points.single.value, ClipAudio.maxVolume);
    });

    test('a moved point is clamped between its neighbours', () {
      // Otherwise a drag reorders the list under itself and the point being
      // dragged is suddenly a different one.
      var a = ClipAudio.unity
          .withPoint(const Tick(100), 1)
          .withPoint(const Tick(500), 0.5)
          .withPoint(const Tick(900), 1);

      a = a.movePoint(1, sourceTime: const Tick(-9999));
      expect(a.points[1].sourceTime.raw, 100);
      a = a.movePoint(1, sourceTime: const Tick(9999));
      expect(a.points[1].sourceTime.raw, 900);
      expect(a.points.map((p) => p.sourceTime.raw), [100, 900, 900]);
    });

    test('moving or removing a point that is not there changes nothing', () {
      // An index is a fact about a document, and undo can change one under
      // the pointer still holding it.
      final a = ClipAudio.unity.withPoint(const Tick(100), 0.5);
      expect(identical(a.movePoint(7, value: 0.1), a), isTrue);
      expect(identical(a.withoutPoint(-1), a), isTrue);
      expect(a.withoutPoint(0).points, isEmpty);
      expect(a.withoutPoint(0).hasAutomation, isFalse);
    });

    test('two clips with the same line are equal, and differ when it moves',
        () {
      expect(const ClipAudio(points: _duck), const ClipAudio(points: _duck));
      expect(const ClipAudio(points: _duck).hashCode,
          const ClipAudio(points: _duck).hashCode);
      expect(const ClipAudio(points: _duck) == ClipAudio.unity, isFalse);
      expect(
          const ClipAudio(points: _duck) ==
              const ClipAudio(points: _duck).movePoint(0, value: 0.5),
          isFalse);
    });
  });

  group('persistence', () {
    Project projectWith(ClipAudio audio) {
      final p = emptyProject();
      return p.updateTrack(
        mainTrackId,
        (t) => t.withClips([
          clipOf('a', 'm1', start: Tick.zero, duration: secs(4))
              .copyWith(audio: audio),
        ]),
      );
    }

    test('a clip at unity writes no audio at all', () {
      final json = projectToJson(projectWith(ClipAudio.unity));
      final tracks = json['tracks']! as List<Object?>;
      final clip = ((tracks.first as Map<String, Object?>)['clips']!
          as List<Object?>).first as Map<String, Object?>;
      expect(clip.containsKey('audio'), isFalse,
          reason: 'a project file should read like the edit that made it');
    });

    test('volume, fades and mute survive a save', () {
      const audio =
          ClipAudio(volume: 0.3, fadeIn: Tick(4000), fadeOut: Tick(8000),
              muted: true);
      final back = projectFromJson(projectToJson(projectWith(audio)));
      expect(back.clipById('a')!.audio, audio);
    });

    test('a file claiming a fade longer than its clip is pulled back', () {
      // Whether it came from a hand edit or a version of this program that did
      // not clamp, the document has to end up sane.
      final json = projectToJson(projectWith(ClipAudio.unity));
      final tracks = json['tracks']! as List<Object?>;
      final clip = ((tracks.first as Map<String, Object?>)['clips']!
          as List<Object?>).first as Map<String, Object?>;
      clip['audio'] = {'fadeIn': secs(100).raw};

      final back = projectFromJson(json);
      expect(back.clipById('a')!.audio.fadeIn.raw,
          lessThanOrEqualTo(secs(4).raw));
    });

    test('the volume line survives a save, in the source\'s own time', () {
      const audio = ClipAudio(volume: 0.8, points: _duck);
      final back = projectFromJson(projectToJson(projectWith(audio)));
      expect(back.clipById('a')!.audio.points, _duck);
      expect(back.clipById('a')!.audio, audio);
    });

    test('a file whose points are out of order is sorted on the way in', () {
      // Sortedness is what every reader of the line assumes, and a hand-edited
      // file is exactly where it stops being true.
      final json = projectToJson(projectWith(ClipAudio.unity));
      final tracks = json['tracks']! as List<Object?>;
      final clip = ((tracks.first as Map<String, Object?>)['clips']!
          as List<Object?>).first as Map<String, Object?>;
      clip['audio'] = {
        'volumePoints': [
          {'t': 900, 'v': 1.0},
          {'t': 100, 'v': 0.2},
        ],
      };
      final back = projectFromJson(json);
      expect(back.clipById('a')!.audio.points.map((p) => p.sourceTime.raw),
          [100, 900]);
    });

    test('a point with no level is an error, not a point at unity', () {
      final json = projectToJson(projectWith(ClipAudio.unity));
      final tracks = json['tracks']! as List<Object?>;
      final clip = ((tracks.first as Map<String, Object?>)['clips']!
          as List<Object?>).first as Map<String, Object?>;
      clip['audio'] = {
        'volumePoints': [
          {'t': 100},
        ],
      };
      expect(() => projectFromJson(json),
          throwsA(isA<ProjectDecodeException>()));
    });

    test('a fade written as a string is an error, not a silent zero', () {
      final json = projectToJson(projectWith(ClipAudio.unity));
      final tracks = json['tracks']! as List<Object?>;
      final clip = ((tracks.first as Map<String, Object?>)['clips']!
          as List<Object?>).first as Map<String, Object?>;
      clip['audio'] = {'fadeIn': '4000'};
      expect(() => projectFromJson(json),
          throwsA(isA<ProjectDecodeException>()));
    });
  });

  group('reaching the engine', () {
    Project withMusic({bool muted = false, ClipAudio? audio}) {
      var p = emptyProject().addMedia(audioAsset('music'));
      p = p.updateTrack(
        mainTrackId,
        (t) => t.withClips(
            [clipOf('v', 'm1', start: Tick.zero, duration: secs(4))]),
      );
      return p.updateTrack(
        audioTrackId,
        (t) => Track.of(
          id: t.id,
          kind: t.kind,
          name: t.name,
          muted: muted,
          clips: [
            clipOf('bed', 'music', start: Tick.zero, duration: secs(4))
                .copyWith(audio: audio ?? ClipAudio.unity),
          ],
        ),
      );
    }

    test('a music bed on an audio lane actually reaches the engine', () {
      // It did not before: the render list was built from visual tracks only,
      // so everything on an audio lane was silent no matter what was on it.
      final timeline = engineTimelineFor(withMusic());
      final bed = timeline.clips.where((c) => c.path!.endsWith('music.m4a'));
      expect(bed, hasLength(1));
      expect(bed.single.gain, 1);
    });

    test('and it arrives carrying no picture', () {
      final timeline = engineTimelineFor(withMusic());
      final bed =
          timeline.clips.firstWhere((c) => c.path!.endsWith('music.m4a'));
      expect(bed.hasVideo, isFalse,
          reason: 'the compositor must not open a decoder for a music file');
    });

    test('a muted lane silences what is on it', () {
      final timeline = engineTimelineFor(withMusic(muted: true));
      final bed =
          timeline.clips.firstWhere((c) => c.path!.endsWith('music.m4a'));
      expect(bed.gain, 0);
    });

    test('a muted clip still goes, so the project does not get shorter', () {
      // Drop it and the playhead stops short of the end the moment someone
      // mutes the last clip.
      final timeline =
          engineTimelineFor(withMusic(audio: const ClipAudio(muted: true)));
      final bed = timeline.clips.where((c) => c.path!.endsWith('music.m4a'));
      expect(bed, hasLength(1));
      expect(bed.single.gain, 0);
    });

    test('volume and fades cross as themselves', () {
      final timeline = engineTimelineFor(withMusic(
          audio: ClipAudio(volume: 0.25, fadeIn: secs(1), fadeOut: secs(2))));
      final bed =
          timeline.clips.firstWhere((c) => c.path!.endsWith('music.m4a'));
      expect(bed.gain, 0.25);
      expect(bed.fadeInTicks, secs(1).raw);
      expect(bed.fadeOutTicks, secs(2).raw);
    });

    test('the volume line crosses as points, not as a resolved gain', () {
      // The mixer has to evaluate it per audio frame. Resolved here, once per
      // edit, it would arrive as a staircase — the same argument as the fades.
      final timeline = engineTimelineFor(
          withMusic(audio: const ClipAudio(volume: 0.5, points: _duck)));
      final bed =
          timeline.clips.firstWhere((c) => c.path!.endsWith('music.m4a'));
      expect(bed.gain, 0.5);
      expect(bed.volumePoints.map((p) => p.sourceTicks), [1000, 1200, 1600, 1800]);
      expect(bed.volumePoints.map((p) => p.value), [1, 0.25, 0.25, 1]);
    });

    test('a clip with no line sends none', () {
      final timeline = engineTimelineFor(withMusic());
      final bed =
          timeline.clips.firstWhere((c) => c.path!.endsWith('music.m4a'));
      expect(bed.volumePoints, isEmpty);
    });

    test('hiding a video lane leaves its sound playing', () {
      // Two switches, two effects. Folding them together would make each one
      // a surprise.
      var p = withMusic();
      p = p.updateTrack(mainTrackId, (t) => t.copyWith(hidden: true));
      final timeline = engineTimelineFor(p);
      final video = timeline.clips.firstWhere((c) => c.path!.endsWith('m1.mp4'));
      expect(video.hasVideo, isFalse);
      expect(video.gain, 1);
    });

    test('an audio-lane clip of a video file leaves the picture behind', () {
      // What a detached clip is: the lane decides which half of the file it
      // contributes, so the picture must not come back with it.
      var p = emptyProject();
      p = p.updateTrack(
        audioTrackId,
        (t) => t.withClips(
            [clipOf('d', 'm1', start: Tick.zero, duration: secs(2))]),
      );
      final timeline = engineTimelineFor(p);
      expect(timeline.clips, hasLength(1));
      expect(timeline.clips.single.hasVideo, isFalse);
      expect(timeline.clips.single.gain, 1);
    });
  });

  group('setting it', () {
    late DocumentStore store;

    setUp(() {
      store = DocumentStore(projectWithThreeClips());
    });

    test('a run across the faders is one undo entry', () {
      // One decision to the person making it, however many values it passed
      // through on the way.
      for (final v in [0.9, 0.7, 0.4]) {
        store.run(SetClipAudio('b', ClipAudio(volume: v)),
            fromGestureStart: true);
      }
      store.endGesture();
      expect(store.project.clipById('b')!.audio.volume, 0.4);
      expect(store.undoLabels, ['Adjust audio']);
    });

    test('a fade longer than the clip is clamped when it is set', () {
      store.run(SetClipAudio('a', ClipAudio(fadeIn: secs(50))));
      // 'a' is two seconds long.
      expect(store.project.clipById('a')!.audio.fadeIn.raw,
          lessThanOrEqualTo(secs(2).raw));
    });
  });

  group('detaching audio', () {
    late DocumentStore store;

    setUp(() {
      store = DocumentStore(projectWithThreeClips());
    });

    Clip detachedFrom(String id, {Tick? start}) {
      final source = store.project.clipById(id)!;
      return Clip(
        id: '$id-audio',
        mediaId: source.mediaId,
        start: start ?? source.start,
        duration: source.duration,
        sourceIn: source.sourceIn,
      );
    }

    test('makes a clip and silences the one it came from, in one entry', () {
      store.run(DetachAudio([
        (fromClipId: 'b', toTrackId: audioTrackId, clip: detachedFrom('b')),
      ]));

      expect(store.project.clipById('b')!.audio.muted, isTrue,
          reason: 'otherwise it plays twice');
      expect(store.project.clipById('b-audio'), isNotNull);
      expect(store.undoLabels, hasLength(1),
          reason: 'it felt like one edit, so it undoes like one');

      store.undo();
      expect(store.project.clipById('b')!.audio.muted, isFalse);
      expect(store.project.clipById('b-audio'), isNull);
    });

    test('the sound keeps the level it was already playing at', () {
      store.run(SetClipAudio('b', ClipAudio(volume: 0.5, fadeIn: secs(1))));
      store.endGesture();
      final source = store.project.clipById('b')!;
      store.run(DetachAudio([
        (
          fromClipId: 'b',
          toTrackId: audioTrackId,
          clip: detachedFrom('b').copyWith(audio: source.audio),
        ),
      ]));
      final moved = store.project.clipById('b-audio')!;
      expect(moved.audio.volume, 0.5);
      expect(moved.audio.fadeIn, secs(1));
    });

    test('refuses a clip whose source has no sound', () {
      var p = emptyProject().addMedia(videoAsset('silent', audio: false));
      p = p.updateTrack(
        mainTrackId,
        (t) => t.withClips(
            [clipOf('q', 'silent', start: Tick.zero, duration: secs(2))]),
      );
      final quiet = DocumentStore(p);
      expect(
        () => quiet.run(DetachAudio([
          (
            fromClipId: 'q',
            toTrackId: audioTrackId,
            clip: clipOf('q-audio', 'silent',
                start: Tick.zero, duration: secs(2)),
          ),
        ])),
        throwsA(isA<EditException>()),
      );
    });

    test('will not put sound on a lane that is not for it', () {
      expect(
        () => store.run(DetachAudio([
          (fromClipId: 'b', toTrackId: mainTrackId, clip: detachedFrom('b')),
        ])),
        throwsA(isA<EditException>()),
      );
    });

    test('makes the lanes it needs, still in one entry', () {
      // Two clips that overlap in time cannot share a lane, and an AddTrack the
      // user has to press ⌘Z through would make one action two.
      final extra = Track.of(
          id: 'tr-audio-2', kind: TrackKind.audio, name: 'Audio 2');
      store.run(DetachAudio(
        [
          (fromClipId: 'a', toTrackId: audioTrackId, clip: detachedFrom('a')),
          (
            fromClipId: 'b',
            toTrackId: 'tr-audio-2',
            clip: detachedFrom('b', start: Tick.zero),
          ),
        ],
        newTracks: [extra],
      ));

      expect(store.project.trackById('tr-audio-2'), isNotNull);
      expect(store.project.clipById('b-audio'), isNotNull);
      expect(store.undoLabels, hasLength(1));

      store.undo();
      expect(store.project.trackById('tr-audio-2'), isNull);
    });

    test('a detached clip may then move between audio lanes', () {
      // Its *file* still has video, so the old rule — an audio lane takes only
      // files with no picture — would have stranded it on the lane it landed
      // on, out of six.
      final extra = Track.of(
          id: 'tr-audio-2', kind: TrackKind.audio, name: 'Audio 2');
      store.run(DetachAudio(
        [(fromClipId: 'b', toTrackId: audioTrackId, clip: detachedFrom('b'))],
        newTracks: [extra],
      ));
      store.endGesture();

      store.run(MoveClip('b-audio', secs(2), toTrackId: 'tr-audio-2'));
      expect(store.project.trackOfClip('b-audio')!.id, 'tr-audio-2');
    });

    test('a video clip still cannot be dragged onto an audio lane', () {
      // Dragging one down would throw its picture away without saying so, and
      // detaching is how that gets asked for on purpose.
      store.run(MoveClip('b', secs(2), toTrackId: audioTrackId));
      expect(store.project.trackOfClip('b')!.id, mainTrackId);
    });
  });
}
