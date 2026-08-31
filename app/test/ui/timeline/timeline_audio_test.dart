import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/commands/document_store.dart';
import 'package:vdodtor/commands/edits.dart';
import 'package:vdodtor/model/clip.dart';
import 'package:vdodtor/model/ids.dart';
import 'package:vdodtor/model/project.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor/model/track.dart';
import 'package:vdodtor/ui/timeline/timeline_controller.dart';

import '../../fixtures.dart';
import 'timeline_controller_test.dart' show FakeTransport;

/// Audio lanes, and lifting a clip's sound onto one.
void main() {
  late DocumentStore store;
  late TimelineController controller;

  void build(Project project) {
    store = DocumentStore(project);
    controller = TimelineController(
      store: store,
      transport: FakeTransport(durationTicks: secs(30).raw),
      ids: IdGen.seeded(7),
    );
  }

  setUp(() => build(projectWithThreeClips()));
  tearDown(() {
    controller.dispose();
    store.dispose();
  });

  group('lanes', () {
    test('a project may hold six audio lanes and then no more', () {
      // One comes with the project, so five more.
      for (var i = 0; i < 5; i++) {
        expect(controller.canAddAudioTrack, isTrue, reason: 'lane ${i + 2}');
        expect(controller.addAudioTrack(), isTrue);
      }
      expect(controller.project.trackCountOfKind(TrackKind.audio), 6);
      expect(controller.canAddAudioTrack, isFalse);
      expect(controller.addAudioTrack(), isFalse);
    });

    test('a new lane is named after the ones already there', () {
      controller.addAudioTrack();
      final names = controller.project.tracks
          .where((t) => t.kind == TrackKind.audio)
          .map((t) => t.name);
      expect(names, ['Audio 1', 'Audio 2']);
    });
  });

  group('detaching', () {
    test('nothing selected means nothing to detach', () {
      expect(controller.canDetachAudio, isFalse);
      expect(controller.detachAudio(), isFalse);
    });

    test('one clip goes onto the audio lane and the original goes quiet', () {
      controller.select('b');
      expect(controller.canDetachAudio, isTrue);
      expect(controller.detachAudio(), isTrue);

      final audio = controller.project.trackById(audioTrackId)!;
      expect(audio.clips, hasLength(1));
      expect(audio.clips.single.start, secs(2), reason: 'it stays in sync');
      expect(audio.clips.single.duration, secs(3));
      expect(controller.project.clipById('b')!.audio.muted, isTrue);
      expect(store.undoLabels, ['Detach audio']);
    });

    test('a clip with no sound in its file is not offered', () {
      var p = emptyProject().addMedia(videoAsset('silent', audio: false));
      p = p.updateTrack(
        mainTrackId,
        (t) => t.withClips(
            [clipOf('q', 'silent', start: Tick.zero, duration: secs(2))]),
      );
      build(p);
      controller.select('q');
      expect(controller.canDetachAudio, isFalse);
    });

    test('an already-muted clip has nothing left to lift', () {
      controller.select('b');
      controller.detachAudio();
      controller.select('b');
      expect(controller.canDetachAudio, isFalse,
          reason: 'detaching twice would make a second silent copy');
    });

    test('clips that overlap in time land on lanes of their own', () {
      // a is 0–2s and b is 2–5s on the main track, so they do not overlap;
      // put two overlapping clips on lanes that do.
      var p = withOverlayTrack(projectWithThreeClips());
      p = p.updateTrack(
        overlayTrackId,
        (t) => t.withClips(
            [clipOf('o', 'm1', start: Tick.zero, duration: secs(4))]),
      );
      build(p);
      controller.select('a');
      controller.toggleSelection('o');
      expect(controller.detachAudio(), isTrue);

      final lanes = controller.project.tracks
          .where((t) => t.kind == TrackKind.audio)
          .toList();
      expect(lanes, hasLength(2), reason: 'one lane cannot hold both');
      expect(lanes.every((l) => l.clips.length == 1), isTrue);
      expect(store.undoLabels, hasLength(1),
          reason: 'making the lane was part of the detach, not a second edit');
    });

    test('undo puts the sound back where it was, lane and all', () {
      controller.select('a');
      controller.toggleSelection('b');
      controller.detachAudio();

      store.undo();
      expect(controller.project.trackById(audioTrackId)!.clips, isEmpty);
      expect(controller.project.clipById('a')!.audio.muted, isFalse);
      expect(controller.project.clipById('b')!.audio.muted, isFalse);
    });

    test('the detached clip keeps the level the original was playing at', () {
      store.run(const SetClipAudio('b', ClipAudio(volume: 0.25)));
      store.endGesture();
      controller.select('b');
      controller.detachAudio();

      final moved = controller.project.trackById(audioTrackId)!.clips.single;
      expect(moved.audio.volume, 0.25);
    });
  });
}
