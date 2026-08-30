import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/commands/document_store.dart';
import 'package:vdodtor/commands/edits.dart';
import 'package:vdodtor/model/ids.dart';
import 'package:vdodtor/model/serialization.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor/ui/timeline/timeline_controller.dart';
import 'package:vdodtor/ui/timeline/timeline_geometry.dart';

import '../../fixtures.dart';
import 'timeline_controller_test.dart' show FakeTransport;

/// Editing with the pointer: what a drag on a clip means, where it stops, and
/// what one gesture costs in undo entries.
///
/// The fixture is a magnetic main lane holding a 0–2 s, b 2–5 s, c 5–6 s, at
/// the default 80 px per second.
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
      ids: IdGen.seeded(4),
    );
  });
  tearDown(() {
    controller.dispose();
    store.dispose();
  });

  double xAt(Tick t) => controller.geometry.xOfTick(t);
  double laneY(int index) => controller.geometry.topOfTrack(index) + 10;
  Offset on(double x, int lane) => Offset(x, laneY(lane));

  group('what a press means', () {
    test('the middle of a clip is a move', () {
      controller.pointerDown(on(xAt(secs(3)), 0));
      expect(controller.drag, TimelineDrag.move);
      expect(controller.selectedClipId, 'b');
    });

    test('near the leading edge is a head trim', () {
      controller.pointerDown(on(xAt(secs(2)) + 3, 0));
      expect(controller.drag, TimelineDrag.trimStart);
    });

    test('near the trailing edge is a tail trim', () {
      controller.pointerDown(on(xAt(secs(5)) - 3, 0));
      expect(controller.drag, TimelineDrag.trimEnd);
    });

    test('a clip too narrow to have handles is all body', () {
      // Zoomed out until c (one second) is a few pixels wide, its edges must
      // not swallow the only way to grab it.
      controller.zoomAround(TimelineGeometry.headerWidth, 0.05);
      final c = store.project.clipById('c')!;
      final middle = (xAt(c.start) + xAt(c.end)) / 2;

      controller.pointerDown(on(middle, 0));
      expect(controller.selectedClipId, 'c');
      expect(controller.drag, TimelineDrag.move);
    });

    test('empty lane space is no drag at all', () {
      controller.pointerDown(on(xAt(secs(20)), 0));
      expect(controller.drag, TimelineDrag.none);
      expect(controller.selectedClipId, isNull);
    });

    test('a locked lane selects but does not edit', () {
      store.run(const SetTrackProperties(mainTrackId, locked: true));
      controller.pointerDown(on(xAt(secs(3)), 0));

      expect(controller.selectedClipId, 'b',
          reason: 'locked is not invisible');
      expect(controller.drag, TimelineDrag.none);

      final before = encodeProject(store.project);
      controller.pointerMove(on(xAt(secs(4)), 0));
      expect(encodeProject(store.project), before);
    });
  });

  group('moving', () {
    test('dragging past a neighbour reorders a magnetic lane', () {
      // b has to travel past the middle of c before they swap, which is what
      // keeps a reorder deliberate rather than twitchy.
      controller.pointerDown(on(xAt(secs(3)), 0));
      controller.pointerMove(on(xAt(secs(3)) + 200, 0));
      controller.pointerUp();

      expect(store.project.mainTrack.clips.map((c) => c.id), ['a', 'c', 'b']);
      expect(store.project.mainTrack.clips.map((c) => c.start.raw),
          [0, secs(2).raw, secs(3).raw]);
      expect(store.project.duration, secs(6), reason: 'nothing was lost');
    });

    test('a nudge too small to reorder leaves the lane packed as it was', () {
      final before = encodeProject(store.project);
      controller.pointerDown(on(xAt(secs(3)), 0));
      controller.pointerMove(on(xAt(secs(3)) + 30, 0));
      controller.pointerUp();

      expect(encodeProject(store.project), before);
    });

    test('the whole drag is one undo entry', () {
      controller.pointerDown(on(xAt(secs(3)), 0));
      for (var px = 10; px <= 200; px += 10) {
        controller.pointerMove(on(xAt(secs(3)) + px, 0));
      }
      controller.pointerUp();

      expect(store.undoLabels, ['Move clip']);
    });

    test('a second drag is a second undo entry', () {
      final before = encodeProject(store.project);

      controller.pointerDown(on(xAt(secs(3)), 0));
      controller.pointerMove(on(xAt(secs(3)) + 200, 0));
      controller.pointerUp();
      controller.pointerDown(on(xAt(secs(4)), 0));
      controller.pointerMove(on(xAt(secs(4)) - 200, 0));
      controller.pointerUp();

      expect(store.undoLabels, hasLength(2),
          reason: 'releasing the pointer ends the gesture');
      store.undo();
      store.undo();
      expect(encodeProject(store.project), before);
    });

    test('measures from where the clip began, not where it has got to', () {
      // A magnetic lane repacks under the pointer. If the next move were
      // measured from the repacked position the drag would run away.
      controller.pointerDown(on(xAt(secs(3)), 0));
      controller.pointerMove(on(xAt(secs(3)) + 200, 0));
      controller.pointerMove(on(xAt(secs(3)), 0));
      controller.pointerUp();

      expect(store.project.mainTrack.clips.map((c) => c.id), ['a', 'b', 'c'],
          reason: 'coming back to the start undoes the reorder');
    });

    test('a clip cannot be dragged before zero', () {
      final store2 = DocumentStore(withOverlayTrack(emptyProject()));
      final c = TimelineController(
          store: store2, transport: FakeTransport(durationTicks: secs(9).raw));
      addTearDown(() {
        c.dispose();
        store2.dispose();
      });
      store2.run(InsertClip(overlayTrackId,
          clipOf('ov', 'm1', start: secs(4), duration: secs(2))));

      c.pointerDown(Offset(c.geometry.xOfTick(secs(5)), c.geometry.topOfTrack(2) + 10));
      c.pointerMove(Offset(c.geometry.xOfTick(secs(5)) - 900,
          c.geometry.topOfTrack(2) + 10));
      c.pointerUp();

      expect(store2.project.clipById('ov')!.start, Tick.zero);
    });
  });

  group('trimming', () {
    test('the tail edge follows the pointer', () {
      controller.pointerDown(on(xAt(secs(5)) - 1, 0));
      controller.pointerMove(on(xAt(secs(4)) - 1, 0));
      controller.pointerUp();

      expect(store.project.clipById('b')!.duration, secs(2));
      // The lane closes up behind it.
      expect(store.project.clipById('c')!.start, secs(4));
      expect(store.project.duration, secs(5));
    });

    test('the head edge takes the source window with it', () {
      controller.pointerDown(on(xAt(secs(2)) + 1, 0));
      controller.pointerMove(on(xAt(secs(3)) + 1, 0));
      controller.pointerUp();

      final b = store.project.clipById('b')!;
      expect(b.sourceIn, secs(1), reason: 'a second of source was skipped');
      expect(b.duration, secs(2));
      expect(b.start, secs(2), reason: 'a magnetic lane keeps it flush');
    });

    test('a trim drag is one undo entry, and undoes whole', () {
      final before = encodeProject(store.project);
      controller.pointerDown(on(xAt(secs(5)) - 1, 0));
      for (var px = 5; px <= 120; px += 5) {
        controller.pointerMove(on(xAt(secs(5)) - px, 0));
      }
      controller.pointerUp();

      expect(store.undoLabels, ['Trim clip']);
      store.undo();
      expect(encodeProject(store.project), before);
    });

    test('cannot be dragged shorter than a frame', () {
      controller.pointerDown(on(xAt(secs(5)) - 1, 0));
      controller.pointerMove(on(xAt(Tick.zero) - 400, 0));
      controller.pointerUp();

      expect(store.project.clipById('b')!.duration.raw,
          Timebase.project.ticksPerFrame(FrameRates.fps30));
    });

    test('cannot be dragged past the end of its source', () {
      // m1 runs ten seconds and b already shows three of them from zero.
      controller.pointerDown(on(xAt(secs(5)) - 1, 0));
      controller.pointerMove(on(xAt(secs(90)), 0));
      controller.pointerUp();

      expect(store.project.clipById('b')!.duration, secs(10));
    });
  });

  group('snapping', () {
    test('an edge dragged near the playhead lands exactly on it', () {
      transport.playTo(secs(3.5).raw);

      controller.pointerDown(on(xAt(secs(5)) - 1, 0));
      controller.pointerMove(on(xAt(secs(3.5)) + 4, 0));

      expect(store.project.clipById('b')!.end, secs(3.5));
      expect(controller.snapGuide, secs(3.5));
      controller.pointerUp();
    });

    test('and is left alone when it is nowhere near', () {
      transport.playTo(secs(3.5).raw);

      controller.pointerDown(on(xAt(secs(5)) - 1, 0));
      controller.pointerMove(on(xAt(secs(4.5)) - 1, 0));

      expect(controller.snapGuide, isNull);
      expect(store.project.clipById('b')!.end, secs(4.5));
      controller.pointerUp();
    });

    test('a clip snaps by whichever of its edges is closer', () {
      final store2 = DocumentStore(withOverlayTrack(emptyProject()));
      final c = TimelineController(
          store: store2, transport: FakeTransport(durationTicks: secs(20).raw));
      addTearDown(() {
        c.dispose();
        store2.dispose();
      });
      // A one-second clip out on its own, and a cut at 8 s on the main lane
      // to aim its trailing edge at.
      store2.run(InsertClip(mainTrackId,
          clipOf('main', 'm1', start: Tick.zero, duration: secs(8))));
      store2.run(InsertClip(overlayTrackId,
          clipOf('ov', 'm1', start: secs(12), duration: secs(1))));

      final y = c.geometry.topOfTrack(2) + 10;
      final grab = c.geometry.xOfTick(secs(12.5));
      c.pointerDown(Offset(grab, y));
      // Aim so the clip's *end* lands four pixels past the cut at 8 s: near
      // enough for the trailing edge to snap, while the leading edge is
      // nowhere near anything.
      c.pointerMove(Offset(grab - 4.95 * 80, y));

      expect(c.snapGuide, secs(8));
      expect(store2.project.clipById('ov')!.end, secs(8));
      expect(store2.project.clipById('ov')!.start, secs(7));
      c.pointerUp();
    });

    test('a clip never snaps to itself', () {
      // Its own edges are excluded, or the first pixel of every drag would
      // pull the clip straight back where it started.
      controller.pointerDown(on(xAt(secs(3)), 0));
      controller.pointerMove(on(xAt(secs(3)) + 200, 0));
      expect(controller.snapGuide, isNot(secs(2)));
      controller.pointerUp();
    });

    test('the guide goes when the drag does', () {
      transport.playTo(secs(3.5).raw);
      controller.pointerDown(on(xAt(secs(5)) - 1, 0));
      controller.pointerMove(on(xAt(secs(3.5)) + 4, 0));
      expect(controller.snapGuide, isNotNull);

      controller.pointerUp();
      expect(controller.snapGuide, isNull);
    });
  });

  group('edits with no pointer', () {
    test('split cuts the clip under the playhead', () {
      transport.playTo(secs(3).raw);
      expect(controller.splitAtPlayhead(), isTrue);

      final clips = store.project.mainTrack.clips;
      expect(clips, hasLength(4));
      expect(clips.map((c) => c.start.raw),
          [0, secs(2).raw, secs(3).raw, secs(5).raw]);
      expect(store.project.duration, secs(6));
    });

    test('split selects the half the playhead is now at the start of', () {
      transport.playTo(secs(3).raw);
      controller.splitAtPlayhead();

      final selected = controller.selectedClip!;
      expect(selected.start, secs(3));
      expect(selected.id, isNot('b'));
    });

    test('split prefers the selected clip when the playhead is inside it', () {
      final store2 = DocumentStore(withOverlayTrack(emptyProject()));
      final c = TimelineController(
          store: store2,
          transport: FakeTransport(durationTicks: secs(10).raw),
          ids: IdGen.seeded(9));
      addTearDown(() {
        c.dispose();
        store2.dispose();
      });
      store2.run(InsertClip(mainTrackId,
          clipOf('main', 'm1', start: Tick.zero, duration: secs(8))));
      store2.run(InsertClip(overlayTrackId,
          clipOf('ov', 'm1', start: Tick.zero, duration: secs(6))));

      c.select('ov');
      (c.transport as FakeTransport).playTo(secs(3).raw);
      expect(c.splitAtPlayhead(), isTrue);

      expect(store2.project.trackById(overlayTrackId)!.clips, hasLength(2));
      expect(store2.project.mainTrack.clips, hasLength(1),
          reason: 'the selection said which lane was meant');
    });

    test('split at a clip boundary does nothing', () {
      transport.playTo(secs(2).raw);
      expect(controller.splitAtPlayhead(), isFalse);
      expect(store.project.mainTrack.clips, hasLength(3));
      expect(store.canUndo, isFalse);
    });

    test('split with the playhead in empty space does nothing', () {
      transport.playTo(secs(30).raw);
      expect(controller.splitAtPlayhead(), isFalse);
    });

    test('delete removes the selection and closes the gap', () {
      controller.select('a');
      expect(controller.deleteSelected(), isTrue);

      expect(store.project.mainTrack.clips.map((c) => c.id), ['b', 'c']);
      expect(store.project.mainTrack.clips.first.start, Tick.zero);
      expect(controller.selectedClipId, isNull,
          reason: 'nothing is selected once the selection is gone');
    });

    test('delete with nothing selected does nothing', () {
      expect(controller.deleteSelected(), isFalse);
      expect(store.canUndo, isFalse);
    });

    test('duplicate puts a copy after the original and selects it', () {
      controller.select('a');
      expect(controller.duplicateSelected(), isTrue);

      final clips = store.project.mainTrack.clips;
      expect(clips, hasLength(4));
      expect(clips[1].id, controller.selectedClipId);
      expect(clips[1].duration, clips[0].duration);
      expect(clips[1].mediaId, clips[0].mediaId);
    });

    test('a locked lane refuses all three', () {
      controller.select('a');
      store.run(const SetTrackProperties(mainTrackId, locked: true));
      transport.playTo(secs(3).raw);

      expect(controller.deleteSelected(), isFalse);
      expect(controller.duplicateSelected(), isFalse);
      expect(controller.splitAtPlayhead(), isFalse);
      expect(store.project.mainTrack.clips, hasLength(3));
    });

    test('each is its own undo entry', () {
      final before = encodeProject(store.project);
      controller.select('a');
      controller.duplicateSelected();
      transport.playTo(secs(1).raw);
      controller.splitAtPlayhead();
      controller.deleteSelected();

      expect(store.undoLabels,
          ['Duplicate clip', 'Split clip', 'Delete clip']);
      while (store.canUndo) {
        store.undo();
      }
      expect(encodeProject(store.project), before);
    });
  });
}
