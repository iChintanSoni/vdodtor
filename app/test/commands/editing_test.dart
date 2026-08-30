import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/commands/command.dart';
import 'package:vdodtor/commands/document_store.dart';
import 'package:vdodtor/commands/edits.dart';
import 'package:vdodtor/model/media.dart';
import 'package:vdodtor/model/serialization.dart';
import 'package:vdodtor/model/time.dart';

import '../fixtures.dart';

/// Trim, split and duplicate: the three edits that move frames rather than
/// clips, and therefore the three with somewhere quiet to go wrong.
void main() {
  /// One frame at the fixtures' 30 fps.
  final frame = Timebase.project.ticksPerFrame(FrameRates.fps30);

  group('TrimClip: the head', () {
    test('takes the source window with it, so frames do not shift', () {
      // The whole point. Trimming a second off the front must show the clip
      // starting one second later into the file, not the same frames squeezed.
      final store = DocumentStore(projectWithThreeClips());
      store.run(TrimClip('b', start: secs(3)));

      final b = store.project.clipById('b')!;
      expect(b.sourceIn, secs(1), reason: 'a second was trimmed off the front');
      expect(b.duration, secs(2));
      expect(b.sourceOut, secs(3));
    });

    test('leaves the tail exactly where it was on a free-form track', () {
      final store = DocumentStore(withOverlayTrack(emptyProject()));
      store.run(InsertClip(overlayTrackId,
          clipOf('ov', 'm1', start: secs(2), duration: secs(4))));
      final endBefore = store.project.clipById('ov')!.end;

      store.run(TrimClip('ov', start: secs(3)));

      expect(store.project.clipById('ov')!.end, endBefore);
      expect(store.project.clipById('ov')!.start, secs(3));
    });

    test('cannot reveal frames before the start of the source', () {
      final store = DocumentStore(withOverlayTrack(emptyProject()));
      store.run(InsertClip(overlayTrackId,
          clipOf('ov', 'm1', start: secs(4), duration: secs(2))));

      // sourceIn is already 0, so dragging the head left has nowhere to go.
      store.run(TrimClip('ov', start: secs(1)));

      final ov = store.project.clipById('ov')!;
      expect(ov.sourceIn, Tick.zero);
      expect(ov.start, secs(4), reason: 'clamped, not moved');
    });

    test('stops a frame short of nothing', () {
      final store = DocumentStore(projectWithThreeClips());
      store.run(TrimClip('b', start: secs(99)));

      expect(store.project.clipById('b')!.duration.raw, frame);
    });

    test('on a magnetic lane, everything after slides back', () {
      final store = DocumentStore(projectWithThreeClips());
      // a 0-2, b 2-5, c 5-6. Trim a second off b's head.
      store.run(TrimClip('b', start: secs(3)));

      final clips = store.project.mainTrack.clips;
      expect(clips.map((c) => c.id), ['a', 'b', 'c']);
      expect(clips.map((c) => c.start.raw),
          [0, secs(2).raw, secs(4).raw]);
      expect(store.project.duration, secs(5));
    });

    test('on a free-form lane, it will not run into the clip before it', () {
      final store = DocumentStore(withOverlayTrack(emptyProject()));
      store.run(InsertClip(overlayTrackId,
          clipOf('first', 'm1', start: Tick.zero, duration: secs(2))));
      // sourceIn 3 s, so there are three seconds of source available to the
      // left. Without that the source runs out first and the neighbour is
      // never the binding constraint.
      store.run(InsertClip(
          overlayTrackId,
          clipOf('second', 'm1',
              start: secs(4), duration: secs(3), sourceIn: secs(3))));

      store.run(TrimClip('second', start: Tick.zero));

      expect(store.project.clipById('second')!.start, secs(2),
          reason: 'stopped by the clip before it, not by the source');
      expect(store.project.clipById('second')!.sourceIn, secs(1));
    });

    test('the source runs out before the neighbour does, when it is nearer',
        () {
      final store = DocumentStore(withOverlayTrack(emptyProject()));
      store.run(InsertClip(overlayTrackId,
          clipOf('first', 'm1', start: Tick.zero, duration: secs(1))));
      store.run(InsertClip(
          overlayTrackId,
          clipOf('second', 'm1',
              start: secs(6), duration: secs(2), sourceIn: secs(1))));

      store.run(TrimClip('second', start: Tick.zero));

      // Only one second of source to give back, and the gap was five.
      expect(store.project.clipById('second')!.start, secs(5));
      expect(store.project.clipById('second')!.sourceIn, Tick.zero);
    });
  });

  group('TrimClip: the tail', () {
    test('changes the length and nothing else', () {
      final store = DocumentStore(projectWithThreeClips());
      final before = store.project.clipById('b')!;

      store.run(TrimClip('b', end: secs(4)));

      final after = store.project.clipById('b')!;
      expect(after.start, before.start);
      expect(after.sourceIn, before.sourceIn);
      expect(after.duration, secs(2));
    });

    test('cannot run past the end of the source', () {
      // m1 is a 10-second asset; a clip starting 1 s in has 9 s available.
      final store = DocumentStore(withOverlayTrack(emptyProject()));
      store.run(InsertClip(
          overlayTrackId,
          clipOf('ov', 'm1',
              start: Tick.zero, duration: secs(2), sourceIn: secs(1))));

      store.run(TrimClip('ov', end: secs(60)));

      expect(store.project.clipById('ov')!.duration, secs(9));
    });

    test('a still image has no end to run past', () {
      final image = MediaAsset(
        id: 'img',
        path: '/f/still.png',
        displayName: 'still.png',
        probe: const MediaProbe(
            kind: MediaKind.image,
            duration: Tick.zero,
            width: 800,
            height: 600,
            hasVideo: true),
      );
      final store = DocumentStore(withOverlayTrack(emptyProject()));
      store.run(AddMedia(image));
      store.run(InsertClip(overlayTrackId,
          clipOf('ov', 'img', start: Tick.zero, duration: secs(5))));

      store.run(TrimClip('ov', end: secs(90)));

      expect(store.project.clipById('ov')!.duration, secs(90));
    });

    test('stops a frame short of nothing', () {
      final store = DocumentStore(projectWithThreeClips());
      store.run(TrimClip('b', end: Tick.zero));
      expect(store.project.clipById('b')!.duration.raw, frame);
    });

    test('on a free-form lane, it will not run into the clip after it', () {
      final store = DocumentStore(withOverlayTrack(emptyProject()));
      store.run(InsertClip(overlayTrackId,
          clipOf('first', 'm1', start: Tick.zero, duration: secs(2))));
      store.run(InsertClip(overlayTrackId,
          clipOf('second', 'm1', start: secs(5), duration: secs(2))));

      store.run(TrimClip('first', end: secs(9)));

      expect(store.project.clipById('first')!.end, secs(5));
    });
  });

  group('TrimClip: as a drag', () {
    test('a run of trims is one undo entry', () {
      final store = DocumentStore(projectWithThreeClips());
      final before = encodeProject(store.project);

      for (var i = 1; i <= 20; i++) {
        store.run(TrimClip('b', end: Tick(secs(5).raw - i * frame)));
      }
      expect(store.undoLabels, ['Trim clip']);

      store.undo();
      expect(encodeProject(store.project), before);
    });

    test('the two edges do not fold into each other', () {
      // Trimming the head and then the tail is two decisions, and undoing the
      // second should not undo the first.
      final store = DocumentStore(projectWithThreeClips());
      store.run(TrimClip('b', start: Tick(secs(2).raw + frame)));
      // b is now 2s..5s-frame after the lane repacked, so the tail has to be
      // asked for somewhere it is not already.
      store.run(TrimClip('b', end: secs(4)));

      expect(store.undoLabels, ['Trim clip', 'Trim clip']);
      expect(store.project.clipById('b')!.duration, secs(2));
    });

    test('a trim that changes nothing is not an edit', () {
      final store = DocumentStore(projectWithThreeClips());
      final revision = store.revision;
      store.run(TrimClip('b', end: secs(5)));
      expect(store.revision, revision);
      expect(store.canUndo, isFalse);
    });

    test('an unknown clip is a programming error, not a silent no-op', () {
      final store = DocumentStore(projectWithThreeClips());
      expect(() => store.run(TrimClip('ghost', end: secs(1))),
          throwsA(isA<EditException>()));
    });
  });

  group('SplitClip', () {
    test('makes two clips that exactly fill the one', () {
      final store = DocumentStore(projectWithThreeClips());
      store.run(SplitClip('b', secs(3), newClipId: 'b2'));

      final head = store.project.clipById('b')!;
      final tail = store.project.clipById('b2')!;
      expect(head.start, secs(2));
      expect(head.duration, secs(1));
      expect(tail.start, secs(3));
      expect(tail.duration, secs(2));
      expect(head.end, tail.start, reason: 'no gap, no overlap');
      expect(store.project.duration, secs(6), reason: 'nothing moved');
    });

    test('the tail continues the source where the head left off', () {
      // The whole reason a split is not two inserts: the second half has to
      // start at the frame the first half stopped on.
      final store = DocumentStore(withOverlayTrack(emptyProject()));
      store.run(InsertClip(
          overlayTrackId,
          clipOf('ov', 'm1',
              start: secs(10), duration: secs(4), sourceIn: secs(2))));

      store.run(SplitClip('ov', secs(11), newClipId: 'ov2'));

      expect(store.project.clipById('ov')!.sourceOut, secs(3));
      expect(store.project.clipById('ov2')!.sourceIn, secs(3));
    });

    test('keeps the order on the lane', () {
      final store = DocumentStore(projectWithThreeClips());
      store.run(SplitClip('b', secs(3), newClipId: 'b2'));
      expect(store.project.mainTrack.clips.map((c) => c.id),
          ['a', 'b', 'b2', 'c']);
    });

    test('lands on a frame even when asked not to', () {
      final store = DocumentStore(projectWithThreeClips());
      store.run(SplitClip('b', Tick(secs(3).raw + 17), newClipId: 'b2'));
      expect(store.project.clipById('b2')!.start, secs(3));
    });

    test('a cut at either edge does nothing', () {
      final store = DocumentStore(projectWithThreeClips());
      store.run(SplitClip('b', secs(2), newClipId: 'b2'));
      store.run(SplitClip('b', secs(5), newClipId: 'b3'));
      store.run(SplitClip('b', secs(9), newClipId: 'b4'));

      expect(store.project.mainTrack.clips, hasLength(3));
      expect(store.canUndo, isFalse);
    });

    test('refuses an id the project already has', () {
      final store = DocumentStore(projectWithThreeClips());
      expect(() => store.run(SplitClip('b', secs(3), newClipId: 'c')),
          throwsA(isA<EditException>()));
    });

    test('undoes in one step', () {
      final store = DocumentStore(projectWithThreeClips());
      final before = encodeProject(store.project);
      store.run(SplitClip('b', secs(3), newClipId: 'b2'));
      store.undo();
      expect(encodeProject(store.project), before);
    });
  });

  group('DuplicateClip', () {
    test('puts the copy straight after the original', () {
      final store = DocumentStore(projectWithThreeClips());
      store.run(const DuplicateClip('a', newClipId: 'a2'));

      final clips = store.project.mainTrack.clips;
      expect(clips.map((c) => c.id), ['a', 'a2', 'b', 'c']);
      expect(clips.map((c) => c.start.raw),
          [0, secs(2).raw, secs(4).raw, secs(7).raw]);
    });

    test('copies the source window, not just the length', () {
      final store = DocumentStore(withOverlayTrack(emptyProject()));
      store.run(InsertClip(
          overlayTrackId,
          clipOf('ov', 'm1',
              start: Tick.zero, duration: secs(2), sourceIn: secs(3))));

      store.run(const DuplicateClip('ov', newClipId: 'ov2'));

      final copy = store.project.clipById('ov2')!;
      expect(copy.sourceIn, secs(3));
      expect(copy.mediaId, 'm1');
      expect(copy.duration, secs(2));
    });

    test('stays next to its original even when it is the longest clip', () {
      // Ordering a magnetic lane by centre point would put this copy after
      // the short clip that follows it.
      final store = DocumentStore(emptyProject());
      store.run(InsertClip(mainTrackId,
          clipOf('long', 'm1', start: Tick.zero, duration: secs(8))));
      store.run(InsertClip(mainTrackId,
          clipOf('short', 'm1', start: secs(8), duration: secs(1))));

      store.run(const DuplicateClip('long', newClipId: 'long2'));

      expect(store.project.mainTrack.clips.map((c) => c.id),
          ['long', 'long2', 'short']);
    });

    test('on a free-form lane it goes to the end rather than overlapping', () {
      final store = DocumentStore(withOverlayTrack(emptyProject()));
      store.run(InsertClip(overlayTrackId,
          clipOf('first', 'm1', start: Tick.zero, duration: secs(2))));
      store.run(InsertClip(overlayTrackId,
          clipOf('second', 'm1', start: secs(2), duration: secs(2))));

      store.run(const DuplicateClip('first', newClipId: 'first2'));

      expect(store.project.clipById('first2')!.start, secs(4));
      expect(store.project.trackById(overlayTrackId)!.clips, hasLength(3));
    });

    test('refuses an id the project already has', () {
      final store = DocumentStore(projectWithThreeClips());
      expect(() => store.run(const DuplicateClip('a', newClipId: 'b')),
          throwsA(isA<EditException>()));
    });
  });

  group('delete ripples', () {
    test('the gap closes on a magnetic lane', () {
      final store = DocumentStore(projectWithThreeClips());
      store.run(const DeleteClip('a'));

      expect(store.project.mainTrack.clips.map((c) => c.start.raw),
          [0, secs(3).raw]);
      expect(store.project.duration, secs(4));
    });

    test('the gap stays on a free-form lane', () {
      final store = DocumentStore(withOverlayTrack(emptyProject()));
      store.run(InsertClip(overlayTrackId,
          clipOf('first', 'm1', start: Tick.zero, duration: secs(2))));
      store.run(InsertClip(overlayTrackId,
          clipOf('second', 'm1', start: secs(6), duration: secs(2))));

      store.run(const DeleteClip('first'));

      expect(store.project.trackById(overlayTrackId)!.clips.single.start,
          secs(6));
    });
  });

  group('every edit leaves a lane that still holds its invariant', () {
    test('sorted, disjoint, and packed where it should be', () {
      final store = DocumentStore(projectWithThreeClips());

      store.run(SplitClip('b', secs(3), newClipId: 'b2'));
      store.run(TrimClip('b2', end: Tick(secs(5).raw - frame * 3)));
      store.run(const DuplicateClip('a', newClipId: 'a2'));
      store.run(const DeleteClip('c'));
      store.run(TrimClip('a', start: Tick(frame * 4)));

      for (final track in store.project.tracks) {
        var previous = Tick.zero;
        for (final clip in track.clips) {
          expect(clip.start.raw, greaterThanOrEqualTo(previous.raw),
              reason: 'clips out of order on ${track.name}');
          expect(clip.duration.raw, greaterThan(0));
          previous = clip.end;
        }
        if (track.isMagnetic && track.clips.isNotEmpty) {
          expect(track.clips.first.start, Tick.zero);
          for (var i = 1; i < track.clips.length; i++) {
            expect(track.clips[i].start, track.clips[i - 1].end,
                reason: 'a magnetic lane may not have a gap');
          }
        }
      }
    });

    test('and undo puts every one of them back', () {
      final store = DocumentStore(projectWithThreeClips());
      final before = encodeProject(store.project);

      store.run(SplitClip('b', secs(3), newClipId: 'b2'));
      store.endGesture();
      store.run(const DuplicateClip('a', newClipId: 'a2'));
      store.endGesture();
      store.run(const DeleteClip('c'));
      store.endGesture();
      store.run(TrimClip('a', start: Tick(frame * 4)));

      while (store.canUndo) {
        store.undo();
      }
      expect(encodeProject(store.project), before);
    });
  });
}
