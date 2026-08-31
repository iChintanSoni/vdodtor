import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/model/clip.dart';
import 'package:vdodtor/model/media.dart';
import 'package:vdodtor/model/project.dart';
import 'package:vdodtor/model/serialization.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor/model/track.dart';

import '../fixtures.dart';

/// Compares two documents by their canonical serialised form. Cheaper to read
/// in a failure than a field-by-field walk, and it is exactly the equality that
/// matters for save/load.
void expectSameDocument(Project actual, Project expected) =>
    expect(encodeProject(actual), encodeProject(expected));

void main() {
  group('round trip', () {
    test('a full project survives encode/decode unchanged', () {
      var p = withOverlayTrack(projectWithThreeClips());
      p = p.updateTrack(
          overlayTrackId,
          (t) => t.withClips(
              [clipOf('ov', 'm2', start: secs(3), duration: secs(2))]));
      p = p.updateTrack(audioTrackId, (t) => t.copyWith(muted: true));

      expectSameDocument(decodeProject(encodeProject(p)), p);
    });

    test('every field survives, not just the ones that happen to match', () {
      final p = projectWithThreeClips();
      final back = decodeProject(encodeProject(p));

      expect(back.id, p.id);
      expect(back.name, p.name);
      expect(back.format, p.format);
      expect(back.timebase, p.timebase);
      expect(back.media.keys.toSet(), p.media.keys.toSet());
      expect(back.media['m2'], p.media['m2']);
      expect(back.tracks.map((t) => t.id), p.tracks.map((t) => t.id));

      final clip = back.clipById('b')!;
      expect(clip.start, secs(2));
      expect(clip.duration, secs(3));
      expect(clip.mediaId, 'm1');
      expect(clip.label, 'b');
      expect(clip.enabled, isTrue);
    });

    test('NTSC rates survive as exact rationals', () {
      final p = Project.empty(
        id: 'p',
        name: 'ntsc',
        format: ProjectFormat(
            width: 1920, height: 1080, frameRate: FrameRates.fps29_97),
        mainTrackId: 'm',
        audioTrackId: 'a',
      );
      final json = projectToJson(p);
      expect((json['format']! as Map)['frameRate'], '30000/1001');
      expect(decodeProject(encodeProject(p)).format.frameRate,
          FrameRates.fps29_97);
    });

    test('times are written as tick integers, never seconds', () {
      final json = projectToJson(projectWithThreeClips());
      final tracks = json['tracks']! as List;
      final clips = (tracks.first as Map)['clips']! as List;
      final first = clips.first as Map;
      expect(first['start'], isA<int>());
      expect(first['duration'], 2 * 120000);
      // No key anywhere should carry a floating-point time.
      final flat = jsonEncode(json);
      expect(RegExp(r'"(start|duration|sourceIn)":\s*-?\d+\.\d')
          .hasMatch(flat), isFalse);
    });

    test('a disabled clip and a bookmark round-trip', () {
      var p = emptyProject();
      p = p.addMedia(p.media['m1']!.copyWith(bookmark: 'Ym9va21hcms='));
      p = p.updateTrack(
          mainTrackId,
          (t) => t.withClips([
                clipOf('a', 'm1', start: Tick.zero, duration: secs(2))
                    .copyWith(enabled: false),
              ]));
      final back = decodeProject(encodeProject(p));
      expect(back.clipById('a')!.enabled, isFalse);
      expect(back.media['m1']!.bookmark, 'Ym9va21hcms=');
    });

    test('a caption round-trips, styling and all', () {
      const styled = ClipText(
        text: 'Two\nlines',
        font: 'Anton',
        size: 0.15,
        color: 0xFFFF0000,
        strokeColor: 0xFF00FF00,
        strokeWidth: 0.05,
        shadowColor: 0x80000000,
        shadowOffsetX: 0.01,
        shadowOffsetY: 0.02,
        shadowBlur: 0.03,
        boxColor: 0x99101010,
        boxPadding: 0.4,
        boxRadius: 0.2,
        letterSpacing: 0.06,
        lineSpacing: 1.4,
        maxWidth: 0.7,
        alignment: TextAlignment.right,
      );
      final p = emptyProject().addTrack(Track.of(
        id: 'tr-text',
        kind: TrackKind.text,
        name: 'Text 1',
        clips: [
          Clip.caption(
              id: 't1', start: secs(1), duration: secs(3), text: styled),
        ],
      ));

      final back = decodeProject(encodeProject(p));
      expectSameDocument(back, p);
      // And field by field, because the comparison above would also pass if
      // both sides lost the same thing.
      final clip = back.trackById('tr-text')!.clips.single;
      expect(clip.mediaId, isNull);
      expect(clip.text, styled);
    });

    test('a caption is written whole, with its colours readable', () {
      final p = emptyProject().addTrack(Track.of(
        id: 'tr-text',
        kind: TrackKind.text,
        name: 'Text 1',
        clips: [
          Clip.caption(
              id: 't1',
              start: Tick.zero,
              duration: secs(2),
              text: const ClipText(text: 'Hi', color: 0xFF3366CC)),
        ],
      ));

      final json = encodeProject(p);
      // Hex, because a project file is read by people and 4281216204 is not a
      // colour anybody recognises.
      expect(json, contains('#FF3366CC'));
      expect(json, contains('"text": "Hi"'));
    });

    test('a caption whose colour will not parse is an error, not a guess', () {
      final json = jsonDecode(encodeProject(
        emptyProject().addTrack(Track.of(
          id: 'tr-text',
          kind: TrackKind.text,
          name: 'Text 1',
          clips: [
            Clip.caption(
                id: 't1',
                start: Tick.zero,
                duration: secs(2),
                text: const ClipText(text: 'Hi')),
          ],
        )),
      )) as Map<String, Object?>;
      final tracks = json['tracks']! as List<Object?>;
      final track = tracks.last! as Map<String, Object?>;
      final clips = track['clips']! as List<Object?>;
      final text = (clips.single! as Map<String, Object?>)['text']!
          as Map<String, Object?>;
      text['color'] = 'not a colour';

      // Guessing black would silently rewrite the caption; guessing white
      // would do it just as silently the other way.
      expect(
        () => decodeProject(jsonEncode(json)),
        throwsA(isA<ProjectDecodeException>().having(
            (e) => e.path, 'path', contains('color'))),
      );
    });

    test('a caption from a wider future opens as one this build can edit', () {
      final json = jsonDecode(encodeProject(
        emptyProject().addTrack(Track.of(
          id: 'tr-text',
          kind: TrackKind.text,
          name: 'Text 1',
          clips: [
            Clip.caption(
                id: 't1',
                start: Tick.zero,
                duration: secs(2),
                text: const ClipText(text: 'Hi')),
          ],
        )),
      )) as Map<String, Object?>;
      final tracks = json['tracks']! as List<Object?>;
      final track = tracks.last! as Map<String, Object?>;
      final clips = track['clips']! as List<Object?>;
      final text = (clips.single! as Map<String, Object?>)['text']!
          as Map<String, Object?>;
      text['size'] = 9.0;

      final back = decodeProject(jsonEncode(json));
      expect(back.trackById('tr-text')!.clips.single.text!.size,
          ClipText.maxSize);
    });

    test('an animation round-trips', () {
      var p = projectWithThreeClips();
      p = p.updateTrack(
        mainTrackId,
        (t) => t.withClips([
          for (final c in t.clips)
            c.id == 'b'
                ? c.copyWith(
                    animation: ClipAnimation(
                      inPreset: AnimationPreset.spin,
                      inDuration: secs(0.5),
                      outPreset: AnimationPreset.typewriter,
                      outDuration: secs(0.25),
                    ),
                  )
                : c,
        ]),
      );

      final back = decodeProject(encodeProject(p));
      expectSameDocument(back, p);
      expect(back.clipById('b')!.animation.inPreset, AnimationPreset.spin);
      expect(back.clipById('b')!.animation.outDuration, secs(0.25));
    });

    test('a half that would not run is not written down', () {
      // A preset with no length does nothing, so recording one would be
      // recording a decision nobody made.
      var p = projectWithThreeClips();
      p = p.updateTrack(
        mainTrackId,
        (t) => t.withClips([
          for (final c in t.clips)
            c.id == 'b'
                ? c.copyWith(
                    animation:
                        const ClipAnimation(inPreset: AnimationPreset.pop),
                  )
                : c,
        ]),
      );
      expect(encodeProject(p), isNot(contains('"animation"')));
    });

    test('a preset this build has never heard of opens without it', () {
      // A project made by a newer version has to open. Unlike a colour there
      // is nothing here to guess wrongly — the clip is on screen for the same
      // length of time either way — so a missing entrance is a far smaller
      // loss than a project that will not load.
      var p = projectWithThreeClips();
      p = p.updateTrack(
        mainTrackId,
        (t) => t.withClips([
          for (final c in t.clips)
            c.id == 'b'
                ? c.copyWith(
                    animation: ClipAnimation(
                      inPreset: AnimationPreset.pop,
                      inDuration: secs(0.5),
                      outPreset: AnimationPreset.fade,
                      outDuration: secs(0.5),
                    ),
                  )
                : c,
        ]),
      );

      final json = jsonDecode(encodeProject(p)) as Map<String, Object?>;
      final tracks = json['tracks']! as List<Object?>;
      final main = tracks.first! as Map<String, Object?>;
      final clips = main['clips']! as List<Object?>;
      for (final entry in clips) {
        final clip = entry! as Map<String, Object?>;
        final animation = clip['animation'] as Map<String, Object?>?;
        if (animation != null) animation['in'] = 'kaleidoscope';
      }

      final back = decodeProject(jsonEncode(json));
      expect(back.clipById('b')!.animation.inPreset, AnimationPreset.none);
      // And the half it does understand is untouched.
      expect(back.clipById('b')!.animation.outPreset, AnimationPreset.fade);
    });

    test('an empty project round-trips', () {
      final p = Project.empty(
        id: 'p',
        name: '',
        format: ProjectFormat.fromAspect(ProjectAspect.square1x1,
            frameRate: FrameRates.fps24),
        mainTrackId: 'm',
        audioTrackId: 'a',
      );
      expectSameDocument(decodeProject(encodeProject(p)), p);
    });

    test('encoding is stable across repeated calls', () {
      final p = projectWithThreeClips();
      expect(encodeProject(p), encodeProject(p));
      expect(encodeProject(decodeProject(encodeProject(p))), encodeProject(p));
    });
  });

  group('rejects bad input', () {
    Map<String, Object?> good() => projectToJson(projectWithThreeClips());

    test('not JSON at all', () {
      expect(() => decodeProject('{nope'),
          throwsA(isA<ProjectDecodeException>()));
    });

    test('a newer schema, by name', () {
      final json = good()..['schema'] = kProjectSchemaVersion + 1;
      expect(
        () => projectFromJson(json),
        throwsA(isA<ProjectDecodeException>().having((e) => e.message,
            'message', contains('newer version'))),
      );
    });

    test('a missing field, naming its path', () {
      final json = good();
      (json['format']! as Map).remove('width');
      expect(
        () => projectFromJson(json),
        throwsA(isA<ProjectDecodeException>()
            .having((e) => e.path, 'path', 'format.width')),
      );
    });

    test('a frame rate the timebase cannot represent', () {
      final json = good();
      (json['format']! as Map)['frameRate'] = '7';
      expect(
        () => projectFromJson(json),
        throwsA(isA<ProjectDecodeException>()
            .having((e) => e.path, 'path', 'format.frameRate')),
      );
    });

    test('a malformed rational', () {
      final json = good();
      (json['format']! as Map)['frameRate'] = 'thirty';
      expect(() => projectFromJson(json),
          throwsA(isA<ProjectDecodeException>()));
    });

    test('an unknown track kind, listing the valid ones', () {
      final json = good();
      ((json['tracks']! as List).first as Map)['kind'] = 'subtitle';
      expect(
        () => projectFromJson(json),
        throwsA(isA<ProjectDecodeException>()
            .having((e) => e.message, 'message', contains('overlay'))),
      );
    });

    test('overlapping clips, rather than silently dropping one', () {
      final json = good();
      final clips = ((json['tracks']! as List).first as Map)['clips']! as List;
      (clips[1] as Map)['start'] = 0;
      expect(
        () => projectFromJson(json),
        throwsA(isA<ProjectDecodeException>()
            .having((e) => e.message, 'message', contains('overlap'))),
      );
    });

    test('a zero-length clip', () {
      final json = good();
      final clips = ((json['tracks']! as List).first as Map)['clips']! as List;
      (clips[0] as Map)['duration'] = 0;
      expect(
        () => projectFromJson(json),
        throwsA(isA<ProjectDecodeException>()
            .having((e) => e.message, 'message', contains('positive'))),
      );
    });

    test('a time written as a float', () {
      final json = good();
      final clips = ((json['tracks']! as List).first as Map)['clips']! as List;
      (clips[0] as Map)['start'] = 1.5;
      expect(
        () => projectFromJson(json),
        throwsA(isA<ProjectDecodeException>()
            .having((e) => e.message, 'message', contains('integer'))),
      );
    });

    test('an older schema is still accepted', () {
      final json = good()..['schema'] = 1;
      expect(projectFromJson(json).id, 'pr-1');
    });
  });

  group('probe serialisation', () {
    test('carries codec, rotation, sample aspect and VFR through', () {
      final asset = MediaAsset(
        id: 'vfr',
        path: '/media/phone.mov',
        displayName: 'phone.mov',
        probe: MediaProbe(
          kind: MediaKind.video,
          duration: secs(12.5),
          width: 1920,
          height: 1080,
          frameRate: FrameRates.fps59_94,
          variableFrameRate: true,
          rotationDegrees: 90,
          pixelAspect: Rational(4, 3),
          hasVideo: true,
          hasAudio: true,
          audioChannels: 1,
          audioSampleRate: 44100,
          videoCodec: 'hevc',
          audioCodec: 'aac',
        ),
      );
      final back =
          decodeProject(encodeProject(emptyProject().addMedia(asset)));
      expect(back.media['vfr'], asset);
      expect(back.media['vfr']!.probe.variableFrameRate, isTrue);
      expect(back.media['vfr']!.probe.rotationDegrees, 90);
      expect(back.media['vfr']!.probe.pixelAspect, Rational(4, 3));
      expect(back.media['vfr']!.probe.frameRate, FrameRates.fps59_94);
    });

    test('a project written before sample aspect reads as square', () {
      final json = jsonDecode(encodeProject(emptyProject().addMedia(MediaAsset(
        id: 'a',
        path: '/media/a.mp4',
        displayName: 'a.mp4',
        probe: MediaProbe(
          kind: MediaKind.video,
          duration: secs(1),
          width: 640,
          height: 480,
          hasVideo: true,
          pixelAspect: Rational(2, 1),
        ),
      )))) as Map<String, Object?>;
      // Take the field back out, which is exactly what an older file is.
      final asset = (json['media'] as List)
          .cast<Map<String, Object?>>()
          .firstWhere((m) => m['id'] == 'a');
      (asset['probe'] as Map<String, Object?>).remove('pixelAspect');

      final back = decodeProject(jsonEncode(json));
      expect(back.media['a']!.probe.pixelAspect, Rational.one);
      expect(back.media['a']!.probe.displayWidth, 640);
    });

    test('an audio-only asset needs no video fields', () {
      final asset = MediaAsset(
        id: 'song',
        path: '/media/song.m4a',
        displayName: 'song.m4a',
        probe: MediaProbe(
          kind: MediaKind.audio,
          duration: secs(180),
          hasAudio: true,
          audioChannels: 2,
          audioSampleRate: 48000,
          audioCodec: 'aac',
        ),
      );
      final back =
          decodeProject(encodeProject(emptyProject().addMedia(asset)));
      expect(back.media['song'], asset);
      expect(back.media['song']!.probe.videoCodec, isNull);
    });
  });

  test('track flags survive', () {
    var p = emptyProject();
    p = p.updateTrack(audioTrackId,
        (t) => t.copyWith(muted: true, locked: true, hidden: true));
    final back = decodeProject(encodeProject(p));
    final t = back.trackById(audioTrackId)!;
    expect([t.muted, t.locked, t.hidden], [true, true, true]);
    expect(t.kind, TrackKind.audio);
  });
}
