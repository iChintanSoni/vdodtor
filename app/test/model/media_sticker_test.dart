import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/engine/timeline_sync.dart';
import 'package:vdodtor/model/clip.dart';
import 'package:vdodtor/model/media.dart';
import 'package:vdodtor/model/project.dart';
import 'package:vdodtor/model/serialization.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor/model/track.dart';

import '../fixtures.dart';

/// The same table `test_the_codecs_that_are_stickers` asserts in
/// `engine/tests/vd_sticker_test.c`.
///
/// The list is written twice — in `MediaProbe.stickerCodecs` and in
/// `vd_sticker_is_sticker_codec` — because the engine has to classify a file
/// without Dart and the app has to classify one without the engine: a project
/// is read back with no native library alive, and a widget test has none. So
/// it follows the rule `vd_time.c` and `time.dart` follow, which is that two
/// copies are allowed only when one table is asserted against both.
const _codecs = <String, bool>{
  'gif': true,
  'apng': true,
  'webp': true,
  'webp_anim': true,
  'h264': false,
  'hevc': false,
  'png': false,
  'mjpeg': false,
  '': false,
};

void main() {
  group('telling a sticker from a video', () {
    test('the codec table is the one the engine has', () {
      for (final entry in _codecs.entries) {
        expect(MediaProbe.stickerCodecs.contains(entry.key), entry.value,
            reason: '${entry.key} — and engine/tests/vd_sticker_test.c '
                'asserts the same row');
      }
    });

    test('a still PNG is not an APNG', () {
      // The two differ by one letter in the codec name and by everything in
      // how they are opened, and getting it wrong is silent: an APNG down the
      // video path is a blank clip.
      expect(
          MediaProbe.kindFor(
              hasVideo: true, duration: Tick.zero, videoCodec: 'png'),
          MediaKind.image);
      expect(
          MediaProbe.kindFor(
              hasVideo: true, duration: secs(1), videoCodec: 'apng'),
          MediaKind.sticker);
    });

    test('a sticker with no duration is still a sticker', () {
      // An APNG's container reports no duration at all, so a rule that looked
      // at the length first would call it a still image.
      expect(
          MediaProbe.kindFor(
              hasVideo: true, duration: Tick.zero, videoCodec: 'gif'),
          MediaKind.sticker);
    });

    test('everything else is decided the way it always was', () {
      expect(
          MediaProbe.kindFor(
              hasVideo: false, duration: secs(10), videoCodec: null),
          MediaKind.audio);
      expect(
          MediaProbe.kindFor(
              hasVideo: true, duration: secs(10), videoCodec: 'h264'),
          MediaKind.video);
      expect(
          MediaProbe.kindFor(
              hasVideo: true, duration: Tick.zero, videoCodec: 'mjpeg'),
          MediaKind.image);
    });

    test('a sticker is visual and endless', () {
      expect(MediaKind.sticker.isVisual, isTrue);
      expect(MediaKind.sticker.isEndless, isTrue);
      expect(MediaKind.image.isEndless, isTrue);
      expect(MediaKind.video.isEndless, isFalse);
      expect(MediaKind.audio.isVisual, isFalse);
    });
  });

  group('how long one may be', () {
    test('nothing bounds it, because it loops', () {
      // A one-second GIF on a ten-second clip is the ordinary case, so the
      // loop length must not be a trim limit the way a video's length is.
      final asset = stickerAsset('m1', seconds: 1);
      final clip =
          clipOf('c1', 'm1', start: Tick.zero, duration: secs(10));
      expect(maxDurationFor(clip, asset), Tick.zero);
    });

    test('a video is still bounded by its source', () {
      final asset = videoAsset('m1', seconds: 10);
      final clip = clipOf('c1', 'm1', start: Tick.zero, duration: secs(2));
      expect(maxDurationFor(clip, asset), secs(10));
    });
  });

  group('crossing to the engine', () {
    Project projectWithSticker() {
      final project = emptyProject().addMedia(stickerAsset('sticker'));
      return project.addTrack(Track.of(
        id: 'tr-overlay',
        kind: TrackKind.overlay,
        name: 'Overlay 1',
        clips: [
          clipOf('s1', 'sticker', start: Tick.zero, duration: secs(5)),
        ],
      ));
    }

    test('it goes across as a path with the sticker flag set', () {
      final clip = engineTimelineFor(projectWithSticker()).clips.single;
      // A file, so it has a path — what differs is how the engine opens it.
      expect(clip.path, '/media/sticker.gif');
      expect(clip.sticker, isTrue);
      expect(clip.text, isNull);
      expect(clip.shape, isNull);
      expect(clip.hasVideo, isTrue);
    });

    test('an ordinary video clip does not have it set', () {
      final clip = engineTimelineFor(projectWithThreeClips()).clips.first;
      expect(clip.sticker, isFalse);
    });

    test('a hidden lane keeps its stickers off the screen', () {
      final project = projectWithSticker();
      final hidden = project.trackById('tr-overlay')!.copyWith(hidden: true);
      final clip = engineTimelineFor(project.replaceTrack(hidden)).clips.single;
      expect(clip.hasVideo, isFalse);
    });
  });

  group('on disk', () {
    test('a sticker round-trips as one', () {
      final project = emptyProject().addMedia(stickerAsset('m1'));
      final decoded = projectFromJson(projectToJson(project));
      expect(decoded.media['m1']!.probe.kind, MediaKind.sticker);
    });

    // The reason the kind is recomputed on the way in rather than believed. A
    // project written before stickers existed calls a GIF a video, and opening
    // it that way is a clip that renders as a gap — the video decoder cannot
    // export a BGRA frame at all.
    test('a GIF written down as video opens as a sticker', () {
      final json = projectToJson(emptyProject().addMedia(stickerAsset('m1')));
      final asset = (json['media']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .firstWhere((a) => a['id'] == 'm1');
      (asset['probe']! as Map<String, Object?>)['kind'] = 'video';

      expect(projectFromJson(json).media['m1']!.probe.kind, MediaKind.sticker);
    });

    test('and a video written down as video stays one', () {
      final json = projectToJson(emptyProject().addMedia(videoAsset('m1')));
      expect(projectFromJson(json).media['m1']!.probe.kind, MediaKind.video);
    });

    // Only upwards. A file this version would call a still and an older one
    // called something else keeps what it was called: the codec can promote a
    // clip to a sticker, and nothing else about the stored kind is second
    // guessed.
    test('an image stays an image', () {
      final json = projectToJson(emptyProject().addMedia(MediaAsset(
        id: 'm1',
        path: '/media/still.png',
        displayName: 'still.png',
        probe: const MediaProbe(
          kind: MediaKind.image,
          duration: Tick.zero,
          width: 100,
          height: 100,
          hasVideo: true,
          videoCodec: 'png',
        ),
      )));
      expect(projectFromJson(json).media['m1']!.probe.kind, MediaKind.image);
    });
  });
}
