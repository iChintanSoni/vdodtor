import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/model/clip.dart';
import 'package:vdodtor/model/media.dart';
import 'package:vdodtor/model/project.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor/model/track.dart';

import '../fixtures.dart';

void main() {
  group('ProjectFormat', () {
    test('derives dimensions from each offered aspect', () {
      ProjectFormat f(ProjectAspect a) =>
          ProjectFormat.fromAspect(a, frameRate: FrameRates.fps30);
      expect([f(ProjectAspect.landscape16x9).width,
              f(ProjectAspect.landscape16x9).height], [1920, 1080]);
      expect([f(ProjectAspect.portrait9x16).width,
              f(ProjectAspect.portrait9x16).height], [1080, 1920]);
      expect([f(ProjectAspect.square1x1).width,
              f(ProjectAspect.square1x1).height], [1080, 1080]);
      expect([f(ProjectAspect.portrait4x5).width,
              f(ProjectAspect.portrait4x5).height], [1080, 1350]);
    });

    test('round-trips back to its aspect', () {
      for (final a in ProjectAspect.values) {
        final f = ProjectFormat.fromAspect(a, frameRate: FrameRates.fps30);
        expect(f.aspect, a);
      }
    });

    test('4K is above the free tier, 1080p is not', () {
      expect(
          ProjectFormat.fromAspect(ProjectAspect.landscape16x9,
                  frameRate: FrameRates.fps30)
              .isAboveFreeTier,
          isFalse);
      expect(
          ProjectFormat.fromAspect(ProjectAspect.landscape16x9,
                  shortSide: 2160, frameRate: FrameRates.fps30)
              .isAboveFreeTier,
          isTrue);
    });

    test('dimensions stay even for 4:2:0', () {
      for (final a in ProjectAspect.values) {
        for (final side in [720, 1080, 1440, 2160]) {
          final f = ProjectFormat.fromAspect(a,
              shortSide: side, frameRate: FrameRates.fps30);
          expect(f.width.isEven, isTrue, reason: '$a @$side width');
          expect(f.height.isEven, isTrue, reason: '$a @$side height');
        }
      }
    });
  });

  group('Track', () {
    test('sorts clips on construction', () {
      final t = Track.of(id: 't', kind: TrackKind.overlay, name: 'o', clips: [
        clipOf('b', 'm1', start: secs(5), duration: secs(1)),
        clipOf('a', 'm1', start: secs(1), duration: secs(1)),
      ]);
      expect(t.clips.map((c) => c.id), ['a', 'b']);
    });

    test('rejects overlapping clips', () {
      expect(
        () => Track.of(id: 't', kind: TrackKind.overlay, name: 'o', clips: [
          clipOf('a', 'm1', start: Tick.zero, duration: secs(3)),
          clipOf('b', 'm1', start: secs(2), duration: secs(1)),
        ]),
        throwsA(isA<AssertionError>()),
      );
    });

    test('clip list is unmodifiable', () {
      final t = projectWithThreeClips().mainTrack;
      expect(() => t.clips.add(t.clips.first), throwsUnsupportedError);
    });

    test('clipAt finds by binary search and respects gaps', () {
      final t = Track.of(id: 't', kind: TrackKind.overlay, name: 'o', clips: [
        clipOf('a', 'm1', start: Tick.zero, duration: secs(2)),
        clipOf('b', 'm1', start: secs(4), duration: secs(2)),
      ]);
      expect(t.clipAt(Tick.zero)?.id, 'a');
      expect(t.clipAt(secs(1.9))?.id, 'a');
      expect(t.clipAt(secs(2)), isNull); // end is exclusive
      expect(t.clipAt(secs(3)), isNull); // the gap
      expect(t.clipAt(secs(4))?.id, 'b');
      expect(t.clipAt(secs(6)), isNull);
    });

    test('duration is the end of the last clip', () {
      expect(projectWithThreeClips().mainTrack.duration, secs(6));
      expect(
          Track.of(id: 't', kind: TrackKind.audio, name: 'a').duration,
          Tick.zero);
    });

    test('repacked closes gaps on a magnetic track only', () {
      final gappy = [
        clipOf('a', 'm1', start: Tick.zero, duration: secs(2)),
        clipOf('b', 'm1', start: secs(5), duration: secs(1)),
      ];
      final main = Track.of(
          id: 't', kind: TrackKind.main, name: 'v', clips: gappy).repacked();
      expect(main.clips.map((c) => c.start.raw), [0, secs(2).raw]);

      final overlay = Track.of(
          id: 't', kind: TrackKind.overlay, name: 'o', clips: gappy).repacked();
      expect(overlay.clips.map((c) => c.start.raw), [0, secs(5).raw]);
    });

    test('repacked returns the same instance when nothing moves', () {
      final t = projectWithThreeClips().mainTrack;
      expect(identical(t.repacked(), t), isTrue);
    });
  });

  group('Clip', () {
    test('maps timeline time into source time', () {
      final c = clipOf('a', 'm1',
          start: secs(10), duration: secs(5), sourceIn: secs(2));
      expect(c.sourceTimeAt(secs(10)), secs(2));
      expect(c.sourceTimeAt(secs(12)), secs(4));
      expect(c.sourceOut, secs(7));
    });

    test('trimming the head moves start and source together', () {
      final c = clipOf('a', 'm1', start: secs(10), duration: secs(5));
      final trimmed = c.trimHeadBy(secs(1));
      expect(trimmed.start, secs(11));
      expect(trimmed.sourceIn, secs(1));
      expect(trimmed.duration, secs(4));
      expect(trimmed.end, c.end, reason: 'the tail must not move');
    });

    test('trimming the tail changes only duration', () {
      final c = clipOf('a', 'm1', start: secs(10), duration: secs(5));
      final trimmed = c.trimTailBy(secs(2));
      expect(trimmed.start, c.start);
      expect(trimmed.sourceIn, c.sourceIn);
      expect(trimmed.duration, secs(7));
    });

    test('max duration is what is left of the source', () {
      final asset = videoAsset('m1', seconds: 10);
      final c = clipOf('a', 'm1',
          start: Tick.zero, duration: secs(2), sourceIn: secs(3));
      expect(maxDurationFor(c, asset), secs(7));
    });
  });

  group('Project', () {
    test('duration spans every track', () {
      var p = withOverlayTrack(projectWithThreeClips());
      p = p.updateTrack(
          overlayTrackId,
          (t) => t.withClips(
              [clipOf('ov', 'm2', start: secs(9), duration: secs(2))]));
      expect(p.mainTrack.duration, secs(6));
      expect(p.duration, secs(11));
    });

    test('replaceTrack shares every untouched track', () {
      final p = withOverlayTrack(projectWithThreeClips());
      final before = p.trackById(audioTrackId)!;
      final after = p.updateTrack(
          overlayTrackId, (t) => t.copyWith(name: 'Renamed'));
      expect(identical(after.trackById(audioTrackId), before), isTrue,
          reason: 'structural sharing keeps unrelated tracks identical');
      expect(identical(after.mainTrack, p.mainTrack), isTrue);
      expect(after.trackById(overlayTrackId)!.name, 'Renamed');
      expect(p.trackById(overlayTrackId)!.name, 'Overlay 1',
          reason: 'the original document must be untouched');
    });

    test('replaceTrack with an identical track returns the same project', () {
      final p = projectWithThreeClips();
      expect(identical(p.replaceTrack(p.mainTrack), p), isTrue);
    });

    test('lookups find clips across tracks', () {
      final p = projectWithThreeClips();
      expect(p.clipById('b')?.start, secs(2));
      expect(p.trackOfClip('c')?.id, mainTrackId);
      expect(p.clipById('nope'), isNull);
      expect(p.trackOfClip('nope'), isNull);
    });

    test('assetFor resolves a clip to its media', () {
      final p = projectWithThreeClips();
      expect(p.assetFor(p.clipById('c')!)?.id, 'm2');
      expect(
          p.assetFor(const Clip(
              id: 'x', mediaId: null, start: Tick.zero, duration: Tick(1))),
          isNull);
    });

    test('orphaned media are the ones no clip uses', () {
      final p = projectWithThreeClips().addMedia(videoAsset('unused'));
      expect(p.orphanedMediaIds, {'unused'});
      expect(p.removeMedia('unused').orphanedMediaIds, isEmpty);
    });

    test('tracks and media are unmodifiable', () {
      final p = projectWithThreeClips();
      expect(() => p.tracks.add(p.mainTrack), throwsUnsupportedError);
      expect(() => p.media['x'] = videoAsset('x'), throwsUnsupportedError);
    });

    test('rejects a frame rate the timebase cannot represent', () {
      expect(
        () => Project(
          id: 'p',
          name: 'n',
          format: ProjectFormat(
              width: 1920, height: 1080, frameRate: Rational(7, 1)),
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('ticksPerFrame follows the project rate', () {
      expect(projectWithThreeClips().ticksPerFrame, 4000);
    });

    test('an empty project has a main and an audio track', () {
      final p = emptyProject();
      expect(p.tracks.map((t) => t.kind),
          [TrackKind.main, TrackKind.audio]);
      expect(p.duration, Tick.zero);
      expect(p.mainTrack.isMagnetic, isTrue);
    });
  });

  group('MediaProbe', () {
    test('rotation swaps display dimensions', () {
      const p = MediaProbe(
          kind: MediaKind.video,
          duration: Tick(0),
          width: 1920,
          height: 1080,
          rotationDegrees: 90);
      expect(p.displayWidth, 1080);
      expect(p.displayHeight, 1920);
      expect(p.copyWith(rotationDegrees: 180).displayWidth, 1920);
    });
  });
}
