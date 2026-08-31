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

import '../fixtures.dart';

/// The fade envelope, as a table.
///
/// The engine computes this same shape in C — `vd_audio_fade_gain` — and
/// `engine/tests/vd_audio_test.c` asserts on the identical numbers. A fade the
/// timeline draws and a fade the speakers play being the same shape is not
/// something to leave to two people reading the same prose, so it is left to
/// two people reading the same table.
const _fadeTable = <({int offset, double gain})>[
  (offset: -1, gain: 0), // before the clip
  (offset: 0, gain: 0), // silent at the very start of a fade in
  (offset: 100, gain: 0.5), // halfway up a 200-tick fade
  (offset: 200, gain: 1), // fade in is over
  (offset: 500, gain: 1), // the middle is untouched
  (offset: 600, gain: 1), // exactly where the fade out begins
  (offset: 700, gain: 0.75), // 300 of 400 remaining
  (offset: 900, gain: 0.25),
  (offset: 999, gain: 0.0025), // one tick from the end, of a 400 fade
  (offset: 1000, gain: 0), // past the end
];

const _fadeDuration = 1000;
const _fadeIn = 200;
const _fadeOut = 400;

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
        expect(
          ClipAudio.fadeShapeAt(Tick(row.offset), const Tick(_fadeDuration),
              const Tick(_fadeIn), const Tick(_fadeOut)),
          closeTo(row.gain, 0.0005),
          reason: 'at offset ${row.offset}',
        );
      }
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
      final bed = timeline.clips.where((c) => c.path.endsWith('music.m4a'));
      expect(bed, hasLength(1));
      expect(bed.single.gain, 1);
    });

    test('and it arrives carrying no picture', () {
      final timeline = engineTimelineFor(withMusic());
      final bed =
          timeline.clips.firstWhere((c) => c.path.endsWith('music.m4a'));
      expect(bed.hasVideo, isFalse,
          reason: 'the compositor must not open a decoder for a music file');
    });

    test('a muted lane silences what is on it', () {
      final timeline = engineTimelineFor(withMusic(muted: true));
      final bed =
          timeline.clips.firstWhere((c) => c.path.endsWith('music.m4a'));
      expect(bed.gain, 0);
    });

    test('a muted clip still goes, so the project does not get shorter', () {
      // Drop it and the playhead stops short of the end the moment someone
      // mutes the last clip.
      final timeline =
          engineTimelineFor(withMusic(audio: const ClipAudio(muted: true)));
      final bed = timeline.clips.where((c) => c.path.endsWith('music.m4a'));
      expect(bed, hasLength(1));
      expect(bed.single.gain, 0);
    });

    test('volume and fades cross as themselves', () {
      final timeline = engineTimelineFor(withMusic(
          audio: ClipAudio(volume: 0.25, fadeIn: secs(1), fadeOut: secs(2))));
      final bed =
          timeline.clips.firstWhere((c) => c.path.endsWith('music.m4a'));
      expect(bed.gain, 0.25);
      expect(bed.fadeInTicks, secs(1).raw);
      expect(bed.fadeOutTicks, secs(2).raw);
    });

    test('hiding a video lane leaves its sound playing', () {
      // Two switches, two effects. Folding them together would make each one
      // a surprise.
      var p = withMusic();
      p = p.updateTrack(mainTrackId, (t) => t.copyWith(hidden: true));
      final timeline = engineTimelineFor(p);
      final video = timeline.clips.firstWhere((c) => c.path.endsWith('m1.mp4'));
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
