import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/commands/command.dart';
import 'package:vdodtor/commands/document_store.dart';
import 'package:vdodtor/commands/edits.dart';
import 'package:vdodtor/model/serialization.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor/model/track.dart';

import '../fixtures.dart';

void main() {
  group('RemoveMedia', () {
    test('takes the asset and every clip that came from it', () {
      final store = DocumentStore(projectWithThreeClips());

      store.run(const RemoveMedia('m1'));

      // a and b came from m1; c came from m2 and stays.
      expect(store.project.media.keys, ['m2']);
      expect(store.project.mainTrack.clips.map((c) => c.id), ['c']);
    });

    test('closes the gap the clips left on a magnetic track', () {
      final store = DocumentStore(projectWithThreeClips());

      store.run(const RemoveMedia('m1'));

      expect(store.project.mainTrack.clips.single.start, Tick.zero);
      expect(store.project.duration, secs(1));
    });

    test('is one undo away from never having happened', () {
      final store = DocumentStore(projectWithThreeClips());
      final before = encodeProject(store.project);

      store.run(const RemoveMedia('m1'));
      store.undo();

      expect(encodeProject(store.project), before);
    });

    test('an asset nothing refers to just goes', () {
      final store = DocumentStore(emptyProject());
      store.run(const RemoveMedia('m2'));
      expect(store.project.media.keys, ['m1']);
    });

    test('an id the project never had is a no-op', () {
      final store = DocumentStore(projectWithThreeClips());
      store.run(const RemoveMedia('ghost'));
      expect(store.canUndo, isFalse);
    });
  });

  group('InsertClip', () {
    test('appends flush on a magnetic track, ignoring the requested start', () {
      final store = DocumentStore(emptyProject());
      store.run(InsertClip(mainTrackId,
          clipOf('a', 'm1', start: Tick.zero, duration: secs(2))));
      store.run(InsertClip(mainTrackId,
          clipOf('b', 'm1', start: secs(99), duration: secs(3))));

      expect(store.project.mainTrack.clips.map((c) => c.start.raw),
          [0, secs(2).raw]);
      expect(store.project.duration, secs(5));
    });

    test('keeps the requested start on a free-form track', () {
      final store = DocumentStore(withOverlayTrack(emptyProject()));
      store.run(InsertClip(overlayTrackId,
          clipOf('ov', 'm1', start: secs(4), duration: secs(2))));
      expect(store.project.clipById('ov')!.start, secs(4));
    });

    test('refuses an overlap on a free-form track', () {
      final store = DocumentStore(withOverlayTrack(emptyProject()));
      store.run(InsertClip(overlayTrackId,
          clipOf('a', 'm1', start: Tick.zero, duration: secs(3))));
      expect(
        () => store.run(InsertClip(overlayTrackId,
            clipOf('b', 'm1', start: secs(2), duration: secs(3)))),
        throwsA(isA<EditException>()),
      );
    });

    test('refuses media the project does not know about', () {
      final store = DocumentStore(emptyProject());
      expect(
        () => store.run(InsertClip(mainTrackId,
            clipOf('a', 'ghost', start: Tick.zero, duration: secs(1)))),
        throwsA(isA<EditException>().having(
            (e) => e.message, 'message', contains('unknown media'))),
      );
    });

    test('refuses a duplicate clip id', () {
      final store = DocumentStore(projectWithThreeClips());
      expect(
        () => store.run(InsertClip(mainTrackId,
            clipOf('a', 'm1', start: Tick.zero, duration: secs(1)))),
        throwsA(isA<EditException>()),
      );
    });

    test('refuses a zero-length clip', () {
      final store = DocumentStore(emptyProject());
      expect(
        () => store.run(InsertClip(
            mainTrackId, clipOf('a', 'm1', start: Tick.zero, duration: Tick.zero))),
        throwsA(isA<EditException>()),
      );
    });
  });

  group('MoveClip', () {
    test('dragging past a neighbour reorders a magnetic track', () {
      final store = DocumentStore(projectWithThreeClips());
      // a(0-2) b(2-5) c(5-6). Drag c to the front.
      store.run(const MoveClip('c', Tick.zero));
      expect(store.project.mainTrack.clips.map((c) => c.id), ['c', 'a', 'b']);
      expect(store.project.mainTrack.clips.map((c) => c.start.raw),
          [0, secs(1).raw, secs(3).raw]);
      expect(store.project.duration, secs(6), reason: 'no gaps appear');
    });

    test('a magnetic track never keeps a gap', () {
      final store = DocumentStore(projectWithThreeClips());
      store.run(MoveClip('b', secs(50)));
      final starts =
          store.project.mainTrack.clips.map((c) => c.start.raw).toList();
      expect(starts, [0, secs(2).raw, secs(3).raw]);
      expect(store.project.mainTrack.clips.map((c) => c.id), ['a', 'c', 'b']);
    });

    test('moves freely on a free-form track', () {
      var p = withOverlayTrack(emptyProject());
      p = p.updateTrack(
          overlayTrackId,
          (t) => t.withClips(
              [clipOf('ov', 'm1', start: secs(4), duration: secs(2))]));
      final store = DocumentStore(p);
      store.run(MoveClip('ov', secs(9)));
      expect(store.project.clipById('ov')!.start, secs(9));
    });

    test('refuses a move that would overlap on a free-form track', () {
      var p = withOverlayTrack(emptyProject());
      p = p.updateTrack(
          overlayTrackId,
          (t) => t.withClips([
                clipOf('x', 'm1', start: Tick.zero, duration: secs(2)),
                clipOf('y', 'm1', start: secs(6), duration: secs(2)),
              ]));
      final store = DocumentStore(p);
      store.run(MoveClip('y', secs(1)));
      expect(store.project.clipById('y')!.start, secs(6),
          reason: 'the overlapping move is refused, not applied');
      expect(store.canUndo, isFalse, reason: 'a refused edit is not history');
    });

    test('clamps a negative start to zero', () {
      var p = withOverlayTrack(emptyProject());
      p = p.updateTrack(
          overlayTrackId,
          (t) => t.withClips(
              [clipOf('ov', 'm1', start: secs(4), duration: secs(2))]));
      final store = DocumentStore(p);
      store.run(MoveClip('ov', const Tick(-99999)));
      expect(store.project.clipById('ov')!.start, Tick.zero);
    });

    test('throws for a clip that is not there', () {
      final store = DocumentStore(emptyProject());
      expect(() => store.run(const MoveClip('ghost', Tick.zero)),
          throwsA(isA<EditException>()));
    });
  });

  group('DeleteClips', () {
    test('ripples the gap closed on a magnetic track', () {
      final store = DocumentStore(projectWithThreeClips());
      store.run(const DeleteClips({'a'}));
      expect(store.project.mainTrack.clips.map((c) => c.id), ['b', 'c']);
      expect(store.project.mainTrack.clips.map((c) => c.start.raw),
          [0, secs(3).raw]);
      expect(store.project.duration, secs(4));
    });

    test('leaves a gap on a free-form track', () {
      var p = withOverlayTrack(emptyProject());
      p = p.updateTrack(
          overlayTrackId,
          (t) => t.withClips([
                clipOf('x', 'm1', start: Tick.zero, duration: secs(2)),
                clipOf('y', 'm1', start: secs(6), duration: secs(2)),
              ]));
      final store = DocumentStore(p);
      store.run(const DeleteClips({'x'}));
      expect(store.project.clipById('y')!.start, secs(6));
    });

    test('deleting something absent changes nothing', () {
      final store = DocumentStore(projectWithThreeClips());
      store.run(const DeleteClips({'ghost'}));
      expect(store.canUndo, isFalse);
      expect(store.revision, 0);
    });
  });

  group('other edits', () {
    test('AddMedia is idempotent', () {
      final store = DocumentStore(emptyProject());
      store.run(AddMedia(videoAsset('new')));
      expect(store.revision, 1);
      store.run(AddMedia(videoAsset('new')));
      expect(store.revision, 1, reason: 're-adding the same asset is a no-op');
    });

    test('AddTrack rejects a duplicate id', () {
      final store = DocumentStore(emptyProject());
      final t = Track.of(
          id: overlayTrackId, kind: TrackKind.overlay, name: 'Overlay 1');
      store.run(AddTrack(t));
      expect(() => store.run(AddTrack(t)), throwsA(isA<EditException>()));
    });

    test('SetTrackProperties changes only what it is given', () {
      final store = DocumentStore(emptyProject());
      store.run(const SetTrackProperties(audioTrackId, muted: true));
      final t = store.project.trackById(audioTrackId)!;
      expect(t.muted, isTrue);
      expect(t.name, 'Audio 1');
      expect(t.locked, isFalse);
    });

    test('RenameProject to the same name is a no-op', () {
      final store = DocumentStore(emptyProject());
      store.run(const RenameProject('Test project'));
      expect(store.revision, 0);
    });
  });

  group('undo / redo', () {
    test('restores the document exactly', () {
      final store = DocumentStore(projectWithThreeClips());
      final before = encodeProject(store.project);

      store.run(const DeleteClips({'b'}));
      store.endGesture();
      store.run(MoveClip('c', secs(0)));

      expect(encodeProject(store.project), isNot(before));
      store.undo();
      store.undo();
      expect(encodeProject(store.project), before);
      expect(store.canUndo, isFalse);
    });

    test('redo replays forward', () {
      final store = DocumentStore(projectWithThreeClips());
      store.run(const DeleteClips({'a'}));
      final afterDelete = encodeProject(store.project);
      store.undo();
      expect(store.project.clipById('a'), isNotNull);
      store.redo();
      expect(encodeProject(store.project), afterDelete);
      expect(store.canRedo, isFalse);
    });

    test('a new edit clears the redo stack', () {
      final store = DocumentStore(projectWithThreeClips());
      store.run(const DeleteClips({'a'}));
      store.undo();
      expect(store.canRedo, isTrue);
      store.run(const DeleteClips({'b'}));
      expect(store.canRedo, isFalse);
    });

    test('labels describe the pending undo and redo', () {
      final store = DocumentStore(projectWithThreeClips());
      expect(store.undoLabel, isNull);
      store.run(const DeleteClips({'a'}));
      expect(store.undoLabel, 'Delete clip');
      store.undo();
      expect(store.redoLabel, 'Delete clip');
      expect(store.undoLabel, isNull);
    });

    test('a drag collapses into one undo entry', () {
      final store = DocumentStore(projectWithThreeClips());
      final before = encodeProject(store.project);

      store.endGesture(); // pointer down
      for (var i = 1; i <= 40; i++) {
        store.run(MoveClip('c', secs(i * 0.05)));
      }
      store.endGesture(); // pointer up

      expect(store.undoLabels, ['Move clip']);
      store.undo();
      expect(encodeProject(store.project), before,
          reason: 'one undo must rewind the whole drag');
    });

    test('two separate drags stay two entries', () {
      final store = DocumentStore(projectWithThreeClips());
      store.endGesture();
      store.run(MoveClip('c', secs(0.1)));
      store.run(MoveClip('c', secs(0.2)));
      store.endGesture();
      store.run(MoveClip('c', secs(3)));
      expect(store.undoLabels, ['Move clip', 'Move clip']);
    });

    test('different clips never merge, even inside one gesture', () {
      final store = DocumentStore(projectWithThreeClips());
      store.endGesture();
      store.run(MoveClip('c', secs(0.1)));
      store.run(MoveClip('a', secs(4)));
      expect(store.undoLabels.length, 2);
    });

    test('history is bounded', () {
      final store = DocumentStore(emptyProject(), historyLimit: 5);
      for (var i = 0; i < 20; i++) {
        store.endGesture();
        store.run(RenameProject('name $i'));
      }
      expect(store.undoLabels.length, 5);
    });

    test('load clears history and marks the document clean', () {
      final store = DocumentStore(emptyProject());
      store.run(const RenameProject('edited'));
      expect(store.isDirty, isTrue);
      store.load(projectWithThreeClips());
      expect(store.canUndo, isFalse);
      expect(store.canRedo, isFalse);
      expect(store.isDirty, isFalse);
    });

    test('markSaved ignores a stale revision', () {
      final store = DocumentStore(emptyProject());
      store.run(const RenameProject('one'));
      final r1 = store.revision;
      store.endGesture();
      store.run(const RenameProject('two'));
      store.markSaved(r1); // a slow write landing late
      expect(store.isDirty, isTrue);
      store.markSaved(store.revision);
      expect(store.isDirty, isFalse);
    });

    test('notifies listeners once per applied edit', () {
      final store = DocumentStore(projectWithThreeClips());
      var notifications = 0;
      store.addListener(() => notifications++);
      store.run(const DeleteClips({'a'}));
      store.run(const DeleteClips({'ghost'})); // no-op
      store.undo();
      expect(notifications, 2);
    });

    test('the original document is never mutated', () {
      final original = projectWithThreeClips();
      final snapshot = encodeProject(original);
      final store = DocumentStore(original);
      store.run(const DeleteClips({'a'}));
      store.run(MoveClip('b', secs(9)));
      expect(encodeProject(original), snapshot);
    });
  });
}
