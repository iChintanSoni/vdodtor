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

/// One five-second clip at the head of a ten-second file, on the main lane.
Project projectWithOneClip() {
  final project = emptyProject();
  return project.updateTrack(
    project.mainTrack.id,
    (t) => t.withClips([
      clipOf('a', 'm1', start: Tick.zero, duration: secs(5)),
    ]),
  );
}

void main() {
  group('what a speed is', () {
    test('a clip nobody retimed plays at its own speed', () {
      expect(ClipSpeed.normal.rate, 1);
      expect(ClipSpeed.normal.pitchShift, isFalse);
      expect(ClipSpeed.normal.isNormal, isTrue);
      expect(ClipSpeed.normal.isRetimed, isFalse);
      expect(clipOf('a', 'm1', start: Tick.zero, duration: secs(5)).speed,
          ClipSpeed.normal);
    });

    test('the pitch toggle alone is not a retime', () {
      // It means nothing at 1x, where stretching time and resampling agree —
      // which is why the inspector only offers it once there is a rate.
      const toggled = ClipSpeed(pitchShift: true);
      expect(toggled.isRetimed, isFalse);
      expect(toggled.isNormal, isFalse);
    });

    test('a rate past either end is pulled back into range', () {
      expect(const ClipSpeed(rate: 100).clamped().rate, ClipSpeed.maxRate);
      expect(const ClipSpeed(rate: 0.001).clamped().rate, ClipSpeed.minRate);
      // Zero, negative and NaN are all "somebody edited the file": the clip
      // plays, at the speed it was shot.
      expect(const ClipSpeed(rate: 0).clamped().rate, 1);
      expect(const ClipSpeed(rate: -2).clamped().rate, 1);
      expect(const ClipSpeed(rate: double.nan).clamped().rate, 1);
      expect(const ClipSpeed(rate: double.infinity).clamped().rate, 1);
    });

    test('clamping keeps the toggle while there is a speed to shift', () {
      final tamed = const ClipSpeed(rate: 50, pitchShift: true).clamped();
      expect(tamed.rate, ClipSpeed.maxRate);
      expect(tamed.pitchShift, isTrue);
    });

    test('a clip back at its own speed loses the toggle with it', () {
      // The two answers agree at 1x, so a remembered toggle would be a
      // decision recorded in the file that changes nothing — and a Reset
      // button on a clip nobody retimed.
      expect(const ClipSpeed(pitchShift: true).clamped(), ClipSpeed.normal);
      expect(const ClipSpeed(rate: 0, pitchShift: true).clamped(),
          ClipSpeed.normal);

      final store = DocumentStore(projectWithOneClip());
      store.run(const SetClipSpeed('a', ClipSpeed(rate: 2, pitchShift: true)));
      store.endGesture();
      store.run(const SetClipSpeed('a', ClipSpeed(rate: 1, pitchShift: true)));
      expect(store.project.clipById('a')!.speed, ClipSpeed.normal);
    });

    test('a rate is spelled the same wherever it is written', () {
      // The inspector's slider, its preset buttons and the clip on the
      // timeline all read this, and three spellings of one rate would be three
      // things to keep in step.
      expect(ClipSpeed.labelFor(1), '1.0×');
      expect(ClipSpeed.labelFor(2), '2.0×');
      expect(ClipSpeed.labelFor(0.25), '0.25×');
      expect(const ClipSpeed(rate: 0.5).label, '0.50×');
    });

    test('the range is the engine\'s', () {
      // VD_SPEED_MIN and VD_SPEED_MAX in engine/include/vdodtor/vd_stretch.h.
      // Where the overlap search stops having anything to correlate against,
      // not a number picked here.
      expect(ClipSpeed.minRate, 0.1);
      expect(ClipSpeed.maxRate, 10);
    });
  });

  group('a speed is a window over the source', () {
    final clip = clipOf('a', 'm1',
        start: secs(2), duration: secs(4), sourceIn: secs(1));

    test('the timeline length is the clip\'s length, whatever the speed', () {
      // The whole reason speed is a rate and not a length: hit testing,
      // packing and splitting all ask a clip how long it is, and none of them
      // should have to learn a second way of asking.
      final fast = clip.copyWith(speed: const ClipSpeed(rate: 2));
      expect(fast.duration, secs(4));
      expect(fast.start, secs(2));
      expect(fast.end, secs(6));
    });

    test('the source window is the length times the rate', () {
      expect(clip.sourceDuration, secs(4));
      expect(clip.copyWith(speed: const ClipSpeed(rate: 2)).sourceDuration,
          secs(8));
      expect(clip.copyWith(speed: const ClipSpeed(rate: 0.5)).sourceDuration,
          secs(2));
      expect(clip.copyWith(speed: const ClipSpeed(rate: 2)).sourceOut,
          secs(9));
    });

    test('source time runs at the rate', () {
      // The same multiply as `source_time_at` in engine/src/vd_engine.c and
      // in engine/src/vd_audio_renderer.c. A frame and the sound under it
      // disagreeing about where in the file they are is the one bug in a video
      // editor everybody can hear.
      final fast = clip.copyWith(speed: const ClipSpeed(rate: 2));
      expect(fast.sourceTimeAt(secs(2)), secs(1));
      expect(fast.sourceTimeAt(secs(3)), secs(3));
      expect(fast.sourceTimeAt(secs(6)), secs(9));

      final slow = clip.copyWith(speed: const ClipSpeed(rate: 0.25));
      expect(slow.sourceTimeAt(secs(2)), secs(1));
      expect(slow.sourceTimeAt(secs(6)), secs(2));
    });

    test('trimming the head opens the window at the rate', () {
      // Half a second off the front of a 2x clip is a second of the file.
      final fast = clip.copyWith(speed: const ClipSpeed(rate: 2));
      final trimmed = fast.trimHeadBy(secs(0.5));
      expect(trimmed.start, secs(2.5));
      expect(trimmed.duration, secs(3.5));
      expect(trimmed.sourceIn, secs(2));
    });

    test('how long a clip may be depends on how fast it plays', () {
      // Ten seconds of file, opened one second in: nine left, and a clip at
      // 2x gets through them in four and a half.
      final asset = videoAsset('m1');
      expect(maxDurationFor(clip, asset), secs(9));
      expect(maxDurationFor(clip.copyWith(speed: const ClipSpeed(rate: 2)),
          asset), secs(4.5));
      expect(maxDurationFor(clip.copyWith(speed: const ClipSpeed(rate: 0.5)),
          asset), secs(18));
      // A still and a sticker have no length to run out of, at any speed.
      expect(maxDurationFor(clip, stickerAsset('s1')), Tick.zero);
    });
  });

  group('a speed and a volume line', () {
    test('the window crosses the curve at the rate', () {
      // A volume point is measured in the *source*, so retiming the clip
      // slides its window over the curve faster. The duck stays on the word.
      final clip = clipOf('a', 'm1', start: Tick.zero, duration: secs(8))
          .copyWith(
        audio: ClipAudio(points: [
          VolumePoint(secs(4), 1),
          VolumePoint(secs(4), 0.25),
        ]),
      );
      expect(clip.gainAt(secs(3)), closeTo(1, 1e-9));
      expect(clip.gainAt(secs(5)), closeTo(0.25, 1e-9));

      final fast = clip.copyWith(speed: const ClipSpeed(rate: 2));
      expect(fast.gainAt(secs(1)), closeTo(1, 1e-9),
          reason: 'one second in at 2x is two seconds of source');
      expect(fast.gainAt(secs(3)), closeTo(0.25, 1e-9),
          reason: 'the duck arrives twice as soon on the timeline');
    });

    test('a fade is measured on the timeline and does not move', () {
      // The other half of the same rule: a fade is a length the user drew on
      // the clip, so it stays the length they drew.
      final clip = clipOf('a', 'm1', start: Tick.zero, duration: secs(4))
          .copyWith(audio: ClipAudio(fadeIn: secs(2)))
          .copyWith(speed: const ClipSpeed(rate: 4));
      expect(clip.gainAt(secs(1)), closeTo(0.5, 1e-9));
      expect(clip.gainAt(secs(2)), closeTo(1, 1e-9));
    });
  });

  group('retiming a clip', () {
    test('SetClipSpeed keeps the window and changes the length', () {
      final store = DocumentStore(projectWithOneClip());
      store.run(const SetClipSpeed('a', ClipSpeed(rate: 2)));

      final clip = store.project.clipById('a')!;
      expect(clip.speed.rate, 2);
      expect(clip.duration, secs(2.5), reason: 'twice as fast is half as long');
      expect(clip.sourceDuration, secs(5), reason: 'the same frames');
      expect(clip.sourceIn, Tick.zero);
    });

    test('slowing a clip down makes it longer', () {
      final store = DocumentStore(projectWithOneClip());
      store.run(const SetClipSpeed('a', ClipSpeed(rate: 0.5)));

      final clip = store.project.clipById('a')!;
      expect(clip.duration, secs(10));
      expect(clip.sourceDuration, secs(5));
    });

    test('there and back again is where it started', () {
      // What survives a retime is the window on the source, so a clip taken to
      // 4x and back to 1x is the clip it was rather than a sixteenth of it.
      final store = DocumentStore(projectWithOneClip());
      store.run(const SetClipSpeed('a', ClipSpeed(rate: 4)));
      store.endGesture();
      store.run(const SetClipSpeed('a', ClipSpeed(rate: 1)));

      final clip = store.project.clipById('a')!;
      expect(clip.duration, secs(5));
      expect(clip.speed, ClipSpeed.normal);
    });

    test('the magnetic lane repacks around it', () {
      final store = DocumentStore(projectWithThreeClips());
      store.run(const SetClipSpeed('a', ClipSpeed(rate: 2)));

      // a was 0–2s and is now 0–1s, so everything after it slides back.
      expect(store.project.clipById('a')!.duration, secs(1));
      expect(store.project.clipById('b')!.start, secs(1));
      expect(store.project.clipById('c')!.start, secs(4));
    });

    test('on a free-form lane the neighbour is a wall', () {
      // Nothing repacks there, so a clip that grew into the next one would
      // break the no-overlap invariant every lane rests on.
      var project = withOverlayTrack(projectWithThreeClips());
      project = project.updateTrack(
        overlayTrackId,
        (t) => t.withClips([
          clipOf('x', 'm1', start: Tick.zero, duration: secs(2)),
          clipOf('y', 'm1', start: secs(3), duration: secs(1)),
        ]),
      );
      final store = DocumentStore(project);
      store.run(const SetClipSpeed('x', ClipSpeed(rate: 0.25)));

      final x = store.project.clipById('x')!;
      expect(x.duration, secs(3), reason: 'it stops where y starts');
      expect(x.speed.rate, 0.25);
      expect(store.project.clipById('y')!.start, secs(3));
    });

    test('a clip cannot be retimed past the end of its file', () {
      // Retiming never asks for more source than the clip already had, so this
      // is the hand-edited case: a window that already overran the file. It is
      // bounded the same way a trim's tail is, because it is the same bound.
      var project = emptyProject();
      project = project.updateTrack(
        project.mainTrack.id,
        (t) => t.withClips([
          // Ten seconds of file, opened eight seconds in and claiming five.
          clipOf('a', 'm1',
              start: Tick.zero, duration: secs(5), sourceIn: secs(8)),
        ]),
      );
      final store = DocumentStore(project);
      store.run(const SetClipSpeed('a', ClipSpeed(rate: 0.5)));
      // Ten seconds is what the window asks for; four is what is left.
      expect(store.project.clipById('a')!.duration, secs(4));
    });

    test('a trim runs out of source at the clip\'s rate', () {
      // The head takes `sourceIn` with it at the rate, so a 2x clip opened one
      // second into its file has only half a second of timeline to give back.
      // On an overlay lane, where nothing repacks and the clip stays where the
      // trim leaves it.
      final project = withOverlayTrack(emptyProject()).updateTrack(
        overlayTrackId,
        (t) => t.withClips([
          clipOf('a', 'm1',
                  start: secs(2), duration: secs(2), sourceIn: secs(1))
              .copyWith(speed: const ClipSpeed(rate: 2)),
        ]),
      );
      final store = DocumentStore(project);
      // Asked for a whole second back; a half is all there is.
      store.run(TrimClip('a', start: secs(1)));

      final clip = store.project.clipById('a')!;
      expect(clip.sourceIn, Tick.zero);
      expect(clip.start, secs(1.5));
      expect(clip.duration, secs(2.5));
    });

    test('at one frame the rate gives way, not the window', () {
      // Two frames asked to play ten times faster would be a fifth of a frame.
      // The length cannot go below one, and the tempting fix — keep the rate
      // and grow the length back — widens the *window*: the clip would start
      // showing frames it never had, a clip at the end of its file would run
      // past it, and 10x and back would not land where it started. So the
      // rate is what bends.
      final store = DocumentStore(projectWithOneClip());
      final frame = store.project.ticksPerFrame;
      store.run(TrimClip('a', end: Tick(2 * frame)));
      store.endGesture();

      store.run(const SetClipSpeed('a', ClipSpeed(rate: 10)));
      final clip = store.project.clipById('a')!;
      expect(clip.duration.raw, frame);
      expect(clip.speed.rate, 2, reason: 'two frames of source in one');
      expect(clip.sourceDuration.raw, 2 * frame,
          reason: 'the window is exactly what it was');
    });

    test('a clip with one frame in it has nothing to play faster', () {
      final store = DocumentStore(projectWithOneClip());
      final frame = store.project.ticksPerFrame;
      store.run(TrimClip('a', end: Tick(frame)));
      store.endGesture();

      // A rate of 1 is the only one that fits, so this changes nothing at all
      // — and an edit that changes nothing is correctly no edit.
      store.run(const SetClipSpeed('a', ClipSpeed(rate: 10)));
      expect(store.project.clipById('a')!.duration.raw, frame);
      expect(store.project.clipById('a')!.speed, ClipSpeed.normal);
      expect(store.undoLabels, ['Trim clip']);
    });

    test('a sticker is retimed without changing how long it is on for', () {
      // Its own length is one loop rather than a limit, so there is no window
      // to hold still: what a rate changes is how fast the loop runs. A three
      // second overlay becoming thirty because somebody slowed it down would
      // be an edit nobody asked for.
      var project = withOverlayTrack(emptyProject())
          .addMedia(stickerAsset('gif', seconds: 1));
      project = project.updateTrack(
        overlayTrackId,
        (t) => t.withClips([
          clipOf('s', 'gif', start: secs(1), duration: secs(3)),
        ]),
      );
      final store = DocumentStore(project);
      store.run(const SetClipSpeed('s', ClipSpeed(rate: 0.1)));

      final clip = store.project.clipById('s')!;
      expect(clip.duration, secs(3));
      expect(clip.start, secs(1));
      expect(clip.speed.rate, 0.1);
      // And the engine is told the rate, which is what makes the loop slow.
      expect(engineTimelineFor(store.project)
              .clips
              .firstWhere((c) => c.sticker)
              .speed,
          0.1);
    });

    test('a caption has no source to retime', () {
      final store = DocumentStore(projectWithThreeClips().updateTrack(
        mainTrackId,
        (t) => t.withClips([
          Clip.caption(
              id: 't1',
              start: Tick.zero,
              duration: secs(2),
              text: const ClipText(text: 'hello')),
        ]),
      ));
      expect(() => store.run(const SetClipSpeed('t1', ClipSpeed(rate: 2))),
          throwsA(isA<EditException>()));
    });

    test('the whole drag is one undo entry', () {
      final store = DocumentStore(projectWithOneClip());
      for (final rate in [1.5, 2.0, 2.5, 3.0]) {
        store.run(SetClipSpeed('a', ClipSpeed(rate: rate)),
            fromGestureStart: true);
      }
      expect(store.undoLabels, ['Change speed']);

      // And undoing it puts the clip back at the length it had, not at the
      // length the middle of the drag left it.
      store.undo();
      expect(store.project.clipById('a')!.duration, secs(5));
      expect(store.project.clipById('a')!.speed, ClipSpeed.normal);
    });

    test('a drag applies from where the gesture began', () {
      // Which is what stops a rate compounding: each step of the drag retimes
      // the clip as it was before the drag, not as the last step left it.
      final store = DocumentStore(projectWithOneClip());
      store.run(const SetClipSpeed('a', ClipSpeed(rate: 2)),
          fromGestureStart: true);
      store.run(const SetClipSpeed('a', ClipSpeed(rate: 4)),
          fromGestureStart: true);
      expect(store.project.clipById('a')!.duration, secs(1.25));
      expect(store.project.clipById('a')!.sourceDuration, secs(5));
    });

    test('a split gives both halves the speed and the right frames', () {
      final store = DocumentStore(projectWithOneClip());
      store.run(const SetClipSpeed('a', ClipSpeed(rate: 2)));
      store.endGesture();
      // The clip is now 0–2.5s on the timeline and 0–5s in the file.
      store.run(const SplitClip('a', Tick(120000), newClipId: 'a2'));

      final head = store.project.clipById('a')!;
      final tail = store.project.clipById('a2')!;
      expect(head.speed.rate, 2);
      expect(tail.speed.rate, 2);
      expect(head.duration, secs(1));
      expect(tail.duration, secs(1.5));
      expect(tail.sourceIn, secs(2), reason: 'one second in at 2x is two');
      expect(tail.sourceDuration, secs(3));
    });
  });

  group('a speed crosses to the engine and to disk', () {
    test('the rate goes across, not the window it implies', () {
      final store = DocumentStore(projectWithOneClip());
      store.run(const SetClipSpeed('a', ClipSpeed(rate: 2, pitchShift: true)));

      final sent = engineTimelineFor(store.project).clips.single;
      expect(sent.speed, 2);
      expect(sent.pitchShift, isTrue);
      expect(sent.durationTicks, secs(2.5).raw,
          reason: 'the engine is told the timeline length, as always');
      expect(sent.sourceInTicks, 0);
    });

    test('a clip nobody retimed says so', () {
      final sent =
          engineTimelineFor(projectWithOneClip()).clips.single;
      expect(sent.speed, 1);
      expect(sent.pitchShift, isFalse);
    });

    test('a retimed clip round-trips', () {
      final store = DocumentStore(projectWithOneClip());
      store.run(const SetClipSpeed('a', ClipSpeed(rate: 0.5, pitchShift: true)));

      final json = encodeProject(store.project);
      final back = decodeProject(json);
      final clip = back.clipById('a')!;
      expect(clip.speed.rate, 0.5);
      expect(clip.speed.pitchShift, isTrue);
      expect(clip.duration, secs(10));
    });

    test('a clip at its own speed writes nothing at all', () {
      // A project file should read like the edit that made it, and almost
      // every clip in it was never retimed.
      final json = encodeProject(projectWithOneClip());
      expect(json, isNot(contains('speed')));
      expect(decodeProject(json).clipById('a')!.speed, ClipSpeed.normal);
    });

    test('a file claiming an impossible rate opens at the nearest one', () {
      final store = DocumentStore(projectWithOneClip());
      store.run(const SetClipSpeed('a', ClipSpeed(rate: 2)));
      final tampered = encodeProject(store.project)
          .replaceAll('"rate": 2.0', '"rate": 400.0');
      expect(decodeProject(tampered).clipById('a')!.speed.rate,
          ClipSpeed.maxRate);
    });
  });
}
