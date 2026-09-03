import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/media/sample_project.dart';
import 'package:vdodtor/model/clip.dart';
import 'package:vdodtor/model/ids.dart';
import 'package:vdodtor/model/project.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor/model/track.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory library;

  setUp(() => library = Directory.systemTemp.createTempSync('vdodtor_sample_'));
  tearDown(() => library.deleteSync(recursive: true));

  ProjectFormat format() => ProjectFormat.fromAspect(
        ProjectAspect.landscape16x9,
        frameRate: FrameRates.fps30,
      );

  /// The sample built over files that are staged for real but probed from a
  /// table: the arrangement is the thing under test, and the decoder is not.
  Future<Project> buildSample() async {
    final media = await SampleProject.stage(library);
    final byPath = {
      for (final file in media)
        file.path: file.path.endsWith('.m4a')
            ? audioProbe(seconds: 15)
            : videoProbe(seconds: 5, audio: false),
    };
    return SampleProject.build(
      media: media,
      format: format(),
      ids: IdGen.seeded(7),
      prober: FakeProber(byPath),
      access: FakeFileAccess(),
    );
  }

  group('the footage it ships', () {
    test('is in the bundle, under the names the builder asks for', () async {
      for (final key in SampleProject.assetKeys) {
        final data = await rootBundle.load(key);
        expect(data.lengthInBytes, greaterThan(1024),
            reason: '$key is in the manifest but is empty or a stub');
      }
    });

    test('names a look and faces the app actually ships', () {
      // A look nobody registered draws ungraded and a face nobody registered
      // falls back to the system's — both silently, both looking like a
      // decision rather than a missing file. This is the whole reason the
      // sample's content is listed rather than only used.
      expect(SampleProject.contentIsBundled(), isTrue);
    });

    test('is copied into the library, once', () async {
      final first = await SampleProject.stage(library);
      expect(first, hasLength(SampleProject.assetKeys.length));
      for (final file in first) {
        expect(file.existsSync(), isTrue);
        expect(file.path, contains(SampleProject.mediaFolderName));
      }

      // Staged again — because somebody opened the sample a second time —
      // and what is on disk is left alone. A user who graded this footage in
      // another project must not have it replaced under them.
      await File(first.first.path).writeAsString('edited by the user');
      final again = await SampleProject.stage(library);
      expect(again.first.path, first.first.path);
      expect(File(first.first.path).readAsStringSync(), 'edited by the user');
    });

    test('lands beside the projects rather than inside the app', () async {
      final staged = await SampleProject.stage(library);
      // Under the library, which the sandbox grants whole by entitlement, so
      // the importer can mint a bookmark for it exactly as it would for the
      // user's own footage. A path inside the bundle could never be
      // bookmarked at all.
      expect(staged.first.parent.parent.path, library.path);
    });
  });

  group('the edit', () {
    test('is three shots in a row with a bed under them', () async {
      final project = await buildSample();

      expect(project.name, SampleProject.name);
      expect(project.mainTrack.clips, hasLength(3));

      final audio = project.tracks.firstWhere((t) => t.kind == TrackKind.audio);
      expect(audio.clips, hasLength(1));

      // Butt-joined, which is what the transitions below rest on: the overlap
      // a transition needs is made by the engine, never by the document.
      final clips = project.mainTrack.clips;
      expect(clips[0].end, clips[1].start);
      expect(clips[1].end, clips[2].start);
    });

    test('joins the cuts two different ways', () async {
      final clips = (await buildSample()).mainTrack.clips;

      expect(clips[0].transition.preset, TransitionPreset.none,
          reason: 'the first clip has no cut above it to join');
      expect(clips[1].transition.preset, TransitionPreset.dissolve);
      expect(clips[2].transition.preset, TransitionPreset.wipe);
      for (final clip in clips.skip(1)) {
        expect(clip.transition.isActive, isTrue);
      }
    });

    test('opens out of black and closes back into it', () async {
      final clips = (await buildSample()).mainTrack.clips;

      expect(clips.first.animation.hasIn, isTrue);
      expect(clips.first.animation.inPreset, AnimationPreset.fade);
      expect(clips.last.animation.hasOut, isTrue);
      expect(clips.last.animation.outPreset, AnimationPreset.fade);
    });

    test('grades one shot and leaves its neighbours alone', () async {
      final clips = (await buildSample()).mainTrack.clips;

      // The first thing the sample teaches about grading is that it belongs
      // to a clip, which only reads if the shots either side are ungraded.
      expect(clips[0].color, ClipColor.neutral);
      expect(clips[2].color, ClipColor.neutral);
      expect(clips[1].color.look, SampleProject.look);
      expect(clips[1].color.lookStrength, lessThan(1));
    });

    test('puts a title, a rule and a strapline on three lanes', () async {
      final project = await buildSample();
      final text =
          project.tracks.where((t) => t.kind == TrackKind.text).toList();
      expect(text, hasLength(3));

      final drawn = [for (final t in text) ...t.clips];
      expect(drawn.where((c) => c.isText), hasLength(3));
      expect(drawn.where((c) => c.isShape), hasLength(1));

      // Every caption is set in a face the app ships — the thing
      // contentIsBundled promises, checked against what actually got built.
      for (final clip in drawn.where((c) => c.isText)) {
        expect(SampleProject.fonts, contains(clip.text!.font));
      }
    });

    test('overlaps nothing on any one lane', () async {
      // The rule the whole caption arrangement rests on, and the one that
      // decides how many lanes there are: a lane holds no overlaps, so three
      // things on screen together is three lanes.
      for (final track in (await buildSample()).tracks) {
        for (var i = 1; i < track.clips.length; i++) {
          expect(track.clips[i - 1].end.raw,
              lessThanOrEqualTo(track.clips[i].start.raw),
              reason: 'lane ${track.name} overlaps itself');
        }
      }
    });

    test('fades the bed in and out on a curve', () async {
      final project = await buildSample();
      final bed = project.tracks
          .firstWhere((t) => t.kind == TrackKind.audio)
          .clips
          .single;

      expect(bed.audio.fadeIn.raw, greaterThan(0));
      expect(bed.audio.fadeOut.raw, greaterThan(0));
      expect(bed.audio.fadeCurve, FadeCurve.equalPower);
      expect(bed.audio.volume, lessThan(1));
    });

    test('is a 1080p project, which is under the free tier', () async {
      // A first launch that ended at the resolution gate would be an editor
      // that cannot export its own sample.
      final project = await buildSample();
      expect(project.format.width, 1920);
      expect(project.format.height, 1080);
    });

    test('every clip that draws is one the inspector could have made',
        () async {
      // Nothing in the sample may use a value the panels cannot reach: a
      // sample project teaches by being a project, and one built out of
      // unreachable state teaches something untrue about the editor.
      for (final track in (await buildSample()).tracks) {
        for (final clip in track.clips) {
          expect(clip.duration.raw, greaterThan(0));
          expect(clip.transition, clip.transition.clamped());
          expect(clip.color, clip.color.clamped());
          expect(clip.animation, clip.animation.clampedTo(clip.duration));
          if (clip.text case final text?) expect(text, text.clamped());
          if (clip.shape case final shape?) expect(shape, shape.clamped());
        }
      }
    });
  });
}
