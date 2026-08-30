import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/commands/command.dart';
import 'package:vdodtor/commands/document_store.dart';
import 'package:vdodtor/commands/edits.dart';
import 'package:vdodtor/model/ids.dart';
import 'package:vdodtor/model/media.dart';
import 'package:vdodtor/model/serialization.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor/model/track.dart';
import 'package:vdodtor/ui/timeline/timeline_controller.dart';

import '../../fixtures.dart';
import 'timeline_controller_test.dart' show FakeTransport;

/// Overlay lanes: where they go in the document, where they go on screen, and
/// how a clip gets onto one.
///
/// The two orders are different on purpose and that is the thing most likely
/// to be got wrong, so most of this is about which is which.
void main() {
  late DocumentStore store;
  late FakeTransport transport;
  late TimelineController controller;

  setUp(() {
    store = DocumentStore(projectWithThreeClips());
    transport = FakeTransport(durationTicks: secs(6).raw);
    controller = TimelineController(
      store: store,
      transport: transport,
      ids: IdGen.seeded(31),
    );
  });
  tearDown(() {
    controller.dispose();
    store.dispose();
  });

  double xAt(Tick t) => controller.geometry.xOfTick(t);
  int laneOf(String trackId) =>
      controller.lanes.indexWhere((t) => t.id == trackId);
  Offset onLane(double x, String trackId) =>
      Offset(x, controller.geometry.topOfTrack(laneOf(trackId)) + 10);

  String overlayId([int n = 0]) => store.project.tracks
      .where((t) => t.kind == TrackKind.overlay)
      .elementAt(n)
      .id;

  group('adding lanes', () {
    test('an overlay goes above the visual lanes and below the audio', () {
      // Document order is compositing order, so this is what decides that an
      // overlay renders over the main track rather than under it.
      expect(controller.addOverlayTrack(), isTrue);

      final kinds = store.project.tracks.map((t) => t.kind).toList();
      expect(kinds, [TrackKind.main, TrackKind.overlay, TrackKind.audio]);
    });

    test('a second overlay goes above the first', () {
      controller.addOverlayTrack();
      final first = overlayId();
      controller.addOverlayTrack();

      final ids = store.project.tracks.map((t) => t.id).toList();
      expect(ids.indexOf(first), lessThan(ids.indexOf(overlayId(1))));
    });

    test('three is the limit the brief sets', () {
      expect(controller.addOverlayTrack(), isTrue);
      expect(controller.addOverlayTrack(), isTrue);
      expect(controller.addOverlayTrack(), isTrue);

      expect(controller.canAddOverlayTrack, isFalse);
      expect(controller.addOverlayTrack(), isFalse);
      expect(store.project.trackCountOfKind(TrackKind.overlay), 3);
    });

    test('the command says why rather than quietly doing nothing', () {
      for (var i = 0; i < 3; i++) {
        controller.addOverlayTrack();
      }
      expect(
        () => store.run(AddTrack(
            Track.of(id: 'x', kind: TrackKind.overlay, name: 'Overlay 4'))),
        throwsA(isA<EditException>()
            .having((e) => e.message, 'message', contains('at most 3'))),
      );
    });

    test('adding a lane is one undo entry', () {
      final before = encodeProject(store.project);
      controller.addOverlayTrack();
      store.undo();
      expect(encodeProject(store.project), before);
    });
  });

  group('lane order on screen', () {
    test('is not document order: what renders on top is drawn at the top', () {
      controller.addOverlayTrack();
      controller.addOverlayTrack();

      final document = store.project.tracks.map((t) => t.kind).toList();
      final shown = controller.lanes.map((t) => t.kind).toList();

      expect(document, [
        TrackKind.main,
        TrackKind.overlay,
        TrackKind.overlay,
        TrackKind.audio,
      ]);
      expect(shown, [
        TrackKind.overlay,
        TrackKind.overlay,
        TrackKind.main,
        TrackKind.audio,
      ]);
    });

    test('the topmost lane is the one that composites last', () {
      controller.addOverlayTrack();
      controller.addOverlayTrack();

      final top = controller.lanes.first;
      final documentIndex =
          store.project.tracks.indexWhere((t) => t.id == top.id);
      final others = store.project.tracks
          .where((t) => t.kind.isVisual && t.id != top.id)
          .map((t) => store.project.tracks.indexOf(t));
      for (final index in others) {
        expect(documentIndex, greaterThan(index));
      }
    });

    test('audio stays at the bottom whatever else is added', () {
      controller.addOverlayTrack();
      expect(controller.lanes.last.kind, TrackKind.audio);
    });

    test('a press finds the clip on the lane it looks like it is on', () {
      controller.addOverlayTrack();
      store.run(InsertClip(overlayId(),
          clipOf('ov', 'm1', start: Tick.zero, duration: secs(2))));

      controller.pointerDown(onLane(xAt(secs(1)), overlayId()));
      expect(controller.selectedClipId, 'ov');

      controller.pointerUp();
      controller.pointerDown(onLane(xAt(secs(1)), mainTrackId));
      expect(controller.selectedClipId, 'a');
      controller.pointerUp();
    });
  });

  group('removing lanes', () {
    test('takes the lane and its clips', () {
      controller.addOverlayTrack();
      store.run(InsertClip(overlayId(),
          clipOf('ov', 'm1', start: Tick.zero, duration: secs(2))));

      expect(controller.removeTrack(overlayId()), isTrue);
      expect(store.project.trackCountOfKind(TrackKind.overlay), 0);
      expect(store.project.clipById('ov'), isNull);
    });

    test('the main track cannot go', () {
      expect(controller.removeTrack(mainTrackId), isFalse);
      expect(
        () => store.run(const RemoveTrack(mainTrackId)),
        throwsA(isA<EditException>()),
      );
    });

    test('undo brings the lane and its clips back', () {
      controller.addOverlayTrack();
      store.run(InsertClip(overlayId(),
          clipOf('ov', 'm1', start: Tick.zero, duration: secs(2))));
      final before = encodeProject(store.project);

      controller.removeTrack(overlayId());
      store.undo();

      expect(encodeProject(store.project), before);
    });

    test('a selection on the removed lane does not outlive it', () {
      controller.addOverlayTrack();
      store.run(InsertClip(overlayId(),
          clipOf('ov', 'm1', start: Tick.zero, duration: secs(2))));
      controller.select('ov');

      controller.removeTrack(overlayId());
      expect(controller.selectedClipIds, isEmpty);
    });
  });

  group('dragging between lanes', () {
    setUp(() => controller.addOverlayTrack());

    test('a clip dragged up lands on the overlay lane', () {
      final overlay = overlayId();
      controller.pointerDown(onLane(xAt(secs(3)), mainTrackId));
      controller.pointerMove(onLane(xAt(secs(3)), overlay));
      controller.pointerUp();

      expect(store.project.trackOfClip('b')!.id, overlay);
      // And the lane it left closed up behind it.
      expect(store.project.mainTrack.clips.map((c) => c.id), ['a', 'c']);
      expect(store.project.mainTrack.clips.last.start, secs(2));
    });

    test('and back down again in the same gesture', () {
      // The gesture re-applies from its own start, so passing over a lane on
      // the way somewhere else must not leave the clip there.
      final overlay = overlayId();
      controller.pointerDown(onLane(xAt(secs(3)), mainTrackId));
      controller.pointerMove(onLane(xAt(secs(3)), overlay));
      controller.pointerMove(onLane(xAt(secs(3)), mainTrackId));
      controller.pointerUp();

      expect(store.project.trackOfClip('b')!.id, mainTrackId);
      expect(store.project.mainTrack.clips.map((c) => c.id), ['a', 'b', 'c']);
    });

    test('the whole cross-lane drag is one undo entry', () {
      final before = encodeProject(store.project);
      final entriesBefore = store.undoLabels.length; // setUp added the lane
      final overlay = overlayId();

      controller.pointerDown(onLane(xAt(secs(3)), mainTrackId));
      for (var px = 10; px <= 60; px += 10) {
        controller.pointerMove(Offset(xAt(secs(3)) + px,
            controller.geometry.topOfTrack(laneOf(overlay)) + 10));
      }
      controller.pointerUp();

      expect(store.undoLabels.length, entriesBefore + 1);
      expect(store.undoLabels.last, 'Move clip');
      store.undo();
      expect(encodeProject(store.project), before);
    });

    test('a video clip will not go on the audio lane', () {
      controller.pointerDown(onLane(xAt(secs(3)), mainTrackId));
      controller.pointerMove(onLane(xAt(secs(3)) + 200, audioTrackId));
      controller.pointerUp();

      expect(store.project.trackOfClip('b')!.id, mainTrackId,
          reason: 'it slides along its own lane instead of landing somewhere '
              'it cannot play');
    });

    test('an audio clip will not go on a video lane', () {
      final music = MediaAsset(
        id: 'song',
        path: '/f/song.m4a',
        displayName: 'song.m4a',
        probe: MediaProbe(
          kind: MediaKind.audio,
          duration: secs(30),
          hasAudio: true,
          audioChannels: 2,
          audioSampleRate: 48000,
        ),
      );
      store.run(AddMedia(music));
      store.run(InsertClip(audioTrackId,
          clipOf('mus', 'song', start: Tick.zero, duration: secs(4))));

      controller.pointerDown(onLane(xAt(secs(1)), audioTrackId));
      controller.pointerMove(onLane(xAt(secs(1)), mainTrackId));
      controller.pointerUp();

      expect(store.project.trackOfClip('mus')!.id, audioTrackId);
    });

    test('a locked lane will not take a clip either', () {
      final overlay = overlayId();
      store.run(SetTrackProperties(overlay, locked: true));

      controller.pointerDown(onLane(xAt(secs(3)), mainTrackId));
      controller.pointerMove(onLane(xAt(secs(3)), overlay));
      controller.pointerUp();

      expect(store.project.trackOfClip('b')!.id, mainTrackId);
    });

    test('a clip landing on a free-form lane keeps its own start', () {
      final overlay = overlayId();
      controller.pointerDown(onLane(xAt(secs(3)), mainTrackId));
      controller.pointerMove(onLane(xAt(secs(3)) + 160, overlay));
      controller.pointerUp();

      final moved = store.project.clipById('b')!;
      expect(store.project.trackOfClip('b')!.id, overlay);
      expect(moved.start, secs(4), reason: 'two seconds to the right of 2 s');
    });
  });

  group('what the engine is told', () {
    test('a clip moved to an overlay composites above the main track', () {
      controller.addOverlayTrack();
      final overlay = overlayId();
      controller.pointerDown(onLane(xAt(secs(3)), mainTrackId));
      controller.pointerMove(onLane(xAt(secs(3)), overlay));
      controller.pointerUp();

      final tracks = store.project.tracks;
      expect(tracks.indexWhere((t) => t.id == overlay),
          greaterThan(tracks.indexWhere((t) => t.id == mainTrackId)),
          reason: 'the render list uses document order as z-order');
    });
  });
}
