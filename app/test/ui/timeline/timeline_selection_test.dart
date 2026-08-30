import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/commands/document_store.dart';
import 'package:vdodtor/commands/edits.dart';
import 'package:vdodtor/model/ids.dart';
import 'package:vdodtor/model/serialization.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor/ui/timeline/timeline_controller.dart';

import '../../fixtures.dart';
import 'timeline_controller_test.dart' show FakeTransport;

/// Choosing several clips at once, and the three things worth doing to them:
/// deleting, duplicating, and moving them through the clipboard.
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
      ids: IdGen.seeded(21),
    );
  });
  tearDown(() {
    controller.dispose();
    store.dispose();
  });

  double xAt(Tick t) => controller.geometry.xOfTick(t);
  Offset on(double x, int lane) =>
      Offset(x, controller.geometry.topOfTrack(lane) + 10);

  group('choosing', () {
    test('a plain press replaces the selection', () {
      controller.pointerDown(on(xAt(secs(1)), 0));
      controller.pointerUp();
      controller.pointerDown(on(xAt(secs(3)), 0));
      controller.pointerUp();

      expect(controller.selectedClipIds, {'b'});
    });

    test('a modified press adds, and adds again to take away', () {
      controller.pointerDown(on(xAt(secs(1)), 0));
      controller.pointerUp();
      controller.pointerDown(on(xAt(secs(3)), 0), additive: true);
      controller.pointerDown(on(xAt(secs(5.5)), 0), additive: true);

      expect(controller.selectedClipIds, {'a', 'b', 'c'});

      controller.pointerDown(on(xAt(secs(3)), 0), additive: true);
      expect(controller.selectedClipIds, {'a', 'c'});
    });

    test('a modified press starts no drag', () {
      // Choosing what to act on and moving it are different intentions, and
      // one of them should not smuggle in the other.
      controller.pointerDown(on(xAt(secs(1)), 0));
      controller.pointerUp();
      controller.pointerDown(on(xAt(secs(3)), 0), additive: true);

      expect(controller.drag, TimelineDrag.none);
      final before = encodeProject(store.project);
      controller.pointerMove(on(xAt(secs(3)) + 200, 0));
      expect(encodeProject(store.project), before);
    });

    test('a plain press on a member narrows the selection to it', () {
      controller.selectAll();
      controller.pointerDown(on(xAt(secs(3)), 0));

      expect(controller.selectedClipIds, {'b'},
          reason: 'a drag moves one clip, and four outlined would say '
              'otherwise');
      expect(controller.drag, TimelineDrag.move);
      controller.pointerUp();
    });

    test('select all takes every clip on every lane', () {
      store.run(InsertClip(audioTrackId,
          clipOf('music', 'm1', start: Tick.zero, duration: secs(4))));
      controller.selectAll();

      expect(controller.selectedClipIds, {'a', 'b', 'c', 'music'});
    });

    test('escape and empty space both clear it', () {
      controller.selectAll();
      controller.clearSelection();
      expect(controller.selectedClipIds, isEmpty);

      controller.selectAll();
      controller.pointerDown(on(xAt(secs(30)), 0));
      expect(controller.selectedClipIds, isEmpty);
    });

    test('one selected clip is a lone clip; several are not', () {
      // What the trim handles ask, since trimming is a single-clip idea.
      controller.select('a');
      expect(controller.selectedClipId, 'a');

      controller.toggleSelection('b');
      expect(controller.selectedClipId, isNull);
      expect(controller.selectedClipIds, hasLength(2));
    });

    test('clips deleted behind the selection drop out of it', () {
      controller.selectAll();
      store.run(const DeleteClips({'a'}));

      expect(controller.selectedClipIds, {'b', 'c'},
          reason: 'a selection naming clips the document does not have is a '
              'selection that silently does nothing when acted on');
    });
  });

  group('deleting several', () {
    test('takes them all and closes the gaps', () {
      controller.select('a');
      controller.toggleSelection('c');
      expect(controller.deleteSelected(), isTrue);

      expect(store.project.mainTrack.clips.map((c) => c.id), ['b']);
      expect(store.project.mainTrack.clips.single.start, Tick.zero);
      expect(controller.selectedClipIds, isEmpty);
    });

    test('is one undo entry however many clips it was', () {
      final before = encodeProject(store.project);
      controller.selectAll();
      controller.deleteSelected();

      expect(store.undoLabels, ['Delete clips']);
      store.undo();
      expect(encodeProject(store.project), before);
    });

    test('reaches across lanes in one go', () {
      store.run(InsertClip(audioTrackId,
          clipOf('music', 'm1', start: Tick.zero, duration: secs(4))));
      controller.select('a');
      controller.toggleSelection('music');
      controller.deleteSelected();

      expect(store.project.clipById('a'), isNull);
      expect(store.project.clipById('music'), isNull);
      expect(store.project.clipById('b'), isNotNull);
    });

    test('skips a locked lane and keeps the rest', () {
      store.run(InsertClip(audioTrackId,
          clipOf('music', 'm1', start: Tick.zero, duration: secs(4))));
      store.run(const SetTrackProperties(audioTrackId, locked: true));

      controller.select('a');
      controller.toggleSelection('music');
      expect(controller.deleteSelected(), isTrue);

      expect(store.project.clipById('a'), isNull);
      expect(store.project.clipById('music'), isNotNull,
          reason: 'locked means locked, even in a crowd');
    });
  });

  group('duplicating several', () {
    test('each copy lands next to its own original', () {
      controller.select('a');
      controller.toggleSelection('c');
      expect(controller.duplicateSelected(), isTrue);

      final ids = store.project.mainTrack.clips.map((c) => c.id).toList();
      expect(ids, hasLength(5));
      expect(ids[0], 'a');
      expect(ids[2], 'b');
      expect(ids[3], 'c');
      // The copies sit at index 1 and 4 — right after a and right after c.
      expect(controller.selectedClipIds, {ids[1], ids[4]});
    });

    test('is one undo entry', () {
      final before = encodeProject(store.project);
      controller.selectAll();
      controller.duplicateSelected();

      expect(store.undoLabels, ['Duplicate clips']);
      expect(store.project.mainTrack.clips, hasLength(6));
      store.undo();
      expect(encodeProject(store.project), before);
    });

    test('the copies keep the source window, not just the length', () {
      controller.select('b');
      controller.duplicateSelected();

      final copy = controller.selectedClip!;
      final original = store.project.clipById('b')!;
      expect(copy.sourceIn, original.sourceIn);
      expect(copy.duration, original.duration);
      expect(copy.mediaId, original.mediaId);
    });
  });

  group('the clipboard', () {
    test('copy takes the selection and paste puts it at the playhead', () {
      controller.select('a');
      expect(controller.copySelection(), isTrue);

      transport.playTo(secs(5).raw);
      expect(controller.paste(), isTrue);

      expect(store.project.mainTrack.clips, hasLength(4));
      final pasted = controller.selectedClip!;
      expect(pasted.duration, secs(2));
      expect(pasted.mediaId, 'm1');
    });

    test('copying does not change the document', () {
      final before = encodeProject(store.project);
      controller.selectAll();
      controller.copySelection();

      expect(encodeProject(store.project), before);
      expect(store.canUndo, isFalse);
    });

    test('paste keeps the shape of what was copied', () {
      // Two clips with a gap between them on a free-form lane: pasting has to
      // reproduce the gap, not close it.
      final store2 = DocumentStore(withOverlayTrack(emptyProject()));
      final c = TimelineController(
          store: store2,
          transport: FakeTransport(durationTicks: secs(60).raw),
          ids: IdGen.seeded(3));
      addTearDown(() {
        c.dispose();
        store2.dispose();
      });
      store2.run(InsertClip(overlayTrackId,
          clipOf('one', 'm1', start: secs(1), duration: secs(1))));
      store2.run(InsertClip(overlayTrackId,
          clipOf('two', 'm1', start: secs(4), duration: secs(1))));

      c.selectAll();
      c.copySelection();
      (c.transport as FakeTransport).playTo(secs(20).raw);
      c.paste();

      final pasted = store2.project
          .trackById(overlayTrackId)!
          .clips
          .where((clip) => c.selectedClipIds.contains(clip.id))
          .toList();
      expect(pasted, hasLength(2));
      expect(pasted.first.start, secs(20),
          reason: 'the earliest lands on the playhead');
      expect(pasted.last.start, secs(23),
          reason: 'and the gap between them survives');
    });

    test('paste goes back on the lane it came from', () {
      store.run(InsertClip(audioTrackId,
          clipOf('music', 'm1', start: Tick.zero, duration: secs(4))));
      controller.select('music');
      controller.copySelection();

      transport.playTo(secs(10).raw);
      controller.paste();

      final audio = store.project.trackById(audioTrackId)!;
      expect(audio.clips, hasLength(2));
      expect(store.project.mainTrack.clips, hasLength(3),
          reason: 'audio pasted onto a video lane is a paste nobody wanted');
    });

    test('paste with an empty clipboard does nothing', () {
      expect(controller.paste(), isFalse);
      expect(store.canUndo, isFalse);
    });

    test('copy with nothing selected takes nothing', () {
      expect(controller.copySelection(), isFalse);
      expect(controller.clipboard.isEmpty, isTrue);
    });

    test('the clipboard survives the clips it was taken from', () {
      controller.select('a');
      controller.copySelection();
      controller.select('a');
      controller.deleteSelected();

      transport.playTo(Tick.zero.raw);
      expect(controller.paste(), isTrue,
          reason: 'the clipboard holds clips, not references to them');
    });

    test('cut is a copy and a delete, and undoes as one', () {
      final before = encodeProject(store.project);
      controller.select('b');
      expect(controller.cutSelection(), isTrue);

      expect(store.project.clipById('b'), isNull);
      expect(controller.clipboard.isNotEmpty, isTrue);

      store.undo();
      expect(encodeProject(store.project), before);
    });

    test('pasting on a magnetic lane inserts after the clip you are on', () {
      controller.select('c');
      controller.copySelection();

      // Playhead inside b, which is the second clip.
      transport.playTo(secs(3).raw);
      controller.paste();

      final ids = store.project.mainTrack.clips.map((clip) => clip.id).toList();
      expect(ids[0], 'a');
      expect(ids[1], 'b');
      expect(ids[2], controller.selectedClipId,
          reason: 'the paste lands after the clip the playhead is over');
      expect(ids[3], 'c');
      // Nothing was overwritten: the lane got longer by exactly the paste.
      expect(store.project.duration, secs(7));
    });

    test('pasting media the project no longer has is skipped', () {
      controller.select('a');
      controller.copySelection();
      controller.select('a');
      controller.deleteSelected();
      controller.select('b');
      controller.deleteSelected();
      store.run(const RemoveMedia('m1'));

      expect(controller.paste(), isFalse,
          reason: 'a paste that plays black is worse than no paste');
    });
  });
}
