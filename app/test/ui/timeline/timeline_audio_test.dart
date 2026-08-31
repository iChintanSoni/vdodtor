import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/commands/document_store.dart';
import 'package:vdodtor/commands/edits.dart';
import 'package:vdodtor/model/clip.dart';
import 'package:vdodtor/model/ids.dart';
import 'package:vdodtor/model/project.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor/model/track.dart';
import 'package:vdodtor/ui/timeline/timeline_controller.dart';
import 'package:vdodtor/ui/timeline/timeline_geometry.dart';

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

  /// Ducking, as the pointer does it. Everything here goes through the
  /// controller's own geometry, so a press at a place the eye would call "on
  /// the point" is a press the code calls that too.
  group('the volume line', () {
    /// A four-second music bed() on the audio lane(), selected.
    void withBed({ClipAudio audio = ClipAudio.unity}) {
      var p = emptyProject().addMedia(audioAsset('song'));
      p = p.updateTrack(
        audioTrackId,
        (t) => t.withClips([
          clipOf('bed', 'song', start: Tick.zero, duration: secs(4))
              .copyWith(audio: audio),
        ]),
      );
      build(p);
      controller.select('bed');
    }

    Clip bed() => controller.project.clipById('bed')!;
    Track lane() => controller.project.trackById(audioTrackId)!;

    /// Where the handle for point [index] is on screen.
    Offset handleOf(int index) => controller
        .volumeLine(bed(), lane())
        .firstWhere((h) => h.index == index)
        .at;

    /// A point somewhere along the clip, at a given level.
    Offset spotAt(Tick sourceTime, double level) {
      final band = controller.audioBandOf(bed(), lane())!;
      return Offset(
        controller.geometry.xOfTick(bed().start + (sourceTime - bed().sourceIn)),
        TimelineGeometry.yOfLevel(band, level, ClipAudio.maxVolume),
      );
    }

    test('a clip nobody has ducked shows no line until it is selected', () {
      withBed();
      controller.clearSelection();
      expect(controller.showsVolumeLine(bed(), lane()), isFalse);
      controller.select('bed');
      expect(controller.showsVolumeLine(bed(), lane()), isTrue);
    });

    test('a clip that carries a curve shows it whether selected or not', () {
      withBed(audio: const ClipAudio(points: [VolumePoint(Tick(0), 0.5)]));
      controller.clearSelection();
      expect(controller.showsVolumeLine(bed(), lane()), isTrue);
    });

    test('the line of an untouched clip is two anchors at unity', () {
      withBed();
      final line = controller.volumeLine(bed(), lane());
      expect(line, hasLength(2));
      expect(line.every((h) => h.index == null), isTrue,
          reason: 'the ends are where the curve meets the clip, not points');
      expect(line.first.at.dy, closeTo(line.last.at.dy, 0.001));
    });

    test('⌥-click puts a point where it was clicked', () {
      withBed();
      controller.pointerDown(spotAt(secs(2), 0.5), alt: true);
      controller.pointerUp();

      expect(bed().audio.points, hasLength(1));
      final point = bed().audio.points.single;
      expect(point.sourceTime.raw, closeTo(secs(2).raw, secs(0.05).raw));
      expect(point.value, closeTo(0.5, 0.05));
      expect(store.undoLabels, ['Adjust audio']);
    });

    test('⌥-click on a point takes it away again', () {
      withBed(audio: const ClipAudio(points: [VolumePoint(Tick(0), 0.5)]));
      controller.pointerDown(handleOf(0), alt: true);
      controller.pointerUp();
      expect(bed().audio.points, isEmpty);
    });

    test('placing a point and pulling it down is one undo entry', () {
      // One decision to the person making it: the point exists to be dragged.
      withBed();
      final start = spotAt(secs(2), 1);
      controller.pointerDown(start, alt: true);
      controller.pointerMove(start + const Offset(0, 8));
      controller.pointerMove(start + const Offset(0, 14));
      controller.pointerUp();

      expect(bed().audio.points.single.value, lessThan(1));
      expect(store.undoLabels, ['Adjust audio']);
      store.undo();
      expect(bed().audio.points, isEmpty);
    });

    test('a plain drag on a point moves it and does not move the clip', () {
      withBed(audio: ClipAudio(points: [VolumePoint(secs(2), 1)]));
      final at = handleOf(0);
      controller.pointerDown(at);
      expect(controller.drag, TimelineDrag.volumePoint);
      controller.pointerMove(at + const Offset(20, 10));
      controller.pointerUp();

      expect(bed().start, Tick.zero, reason: 'the clip stayed put');
      expect(bed().duration, secs(4));
      final point = bed().audio.points.single;
      expect(point.sourceTime.raw, greaterThan(secs(2).raw));
      expect(point.value, lessThan(1));
    });

    test('a plain drag away from any point still moves the clip', () {
      withBed(audio: ClipAudio(points: [VolumePoint(secs(2), 0.25)]));
      // The same time as the point, but at the top of the band rather than a
      // quarter of the way up it.
      controller.pointerDown(spotAt(secs(2), ClipAudio.maxVolume));
      expect(controller.drag, TimelineDrag.move);
      controller.pointerUp();
    });

    test('a point cannot be dragged off the clip that carries it', () {
      withBed(audio: ClipAudio(points: [VolumePoint(secs(2), 1)]));
      final at = handleOf(0);
      controller.pointerDown(at);
      controller.pointerMove(at + const Offset(-5000, 0));
      controller.pointerUp();
      expect(bed().audio.points.single.sourceTime, bed().sourceIn);

      controller.pointerDown(handleOf(0));
      controller.pointerMove(handleOf(0) + const Offset(5000, 0));
      controller.pointerUp();
      expect(bed().audio.points.single.sourceTime, bed().sourceOut);
    });

    test('a drag measures from where the gesture began, not from itself', () {
      // The same rule the clip drags follow: each move re-applies to the
      // document as it stood when the pointer went down, so dragging back the
      // way you came puts the point back where it started.
      withBed(audio: ClipAudio(points: [VolumePoint(secs(2), 1)]));
      final at = handleOf(0);
      controller.pointerDown(at);
      for (final dx in [10.0, 25.0, 40.0, 0.0]) {
        controller.pointerMove(at + Offset(dx, 0));
      }
      controller.pointerUp();
      expect(bed().audio.points.single.sourceTime, secs(2));
    });

    test('the inspector\'s button adds a point that changes nothing yet', () {
      withBed(audio: ClipAudio(
          points: [VolumePoint(Tick.zero, 1), VolumePoint(secs(4), 0)]));
      final before = bed().gainAt(secs(1));
      expect(controller.addVolumePoint('bed', secs(1)), isTrue);
      expect(bed().audio.points, hasLength(3));
      expect(bed().gainAt(secs(1)), closeTo(before, 1e-9));
    });

    test('a locked lane() takes no points', () {
      withBed();
      store.run(SetTrackProperties(audioTrackId, locked: true));
      expect(controller.addVolumePoint('bed', secs(1)), isFalse);
      controller.pointerDown(spotAt(secs(2), 0.5), alt: true);
      controller.pointerUp();
      expect(bed().audio.points, isEmpty);
    });

    test('a clip whose file is silent gets no line at all', () {
      var p = emptyProject().addMedia(videoAsset('silent', audio: false));
      p = p.updateTrack(
        mainTrackId,
        (t) => t.withClips(
            [clipOf('q', 'silent', start: Tick.zero, duration: secs(2))]),
      );
      build(p);
      controller.select('q');
      final clip = controller.project.clipById('q')!;
      final track = controller.project.mainTrack;
      expect(controller.showsVolumeLine(clip, track), isFalse);
      controller.pointerDown(const Offset(200, 40), alt: true);
      controller.pointerUp();
      expect(controller.project.clipById('q')!.audio.hasAutomation, isFalse);
    });
  });
}
