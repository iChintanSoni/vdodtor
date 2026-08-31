import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/commands/document_store.dart';
import 'package:vdodtor/media/file_access.dart';
import 'package:vdodtor/media/media_import.dart';
import 'package:vdodtor/model/ids.dart';
import 'package:vdodtor/model/clip.dart';
import 'package:vdodtor/model/media.dart';
import 'package:vdodtor/model/project.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor/model/track.dart';

import '../fixtures.dart';
import 'fakes.dart';

/// A project with nothing in it — not [emptyProject], which comes with two
/// assets already registered. Import is measured by what it added.
Project blank() => Project.empty(
      id: 'pr-import',
      name: 'Import test',
      format: ProjectFormat.fromAspect(ProjectAspect.landscape16x9,
          frameRate: FrameRates.fps30),
      mainTrackId: mainTrackId,
      audioTrackId: audioTrackId,
    );

void main() {
  late FakeFileAccess access;

  setUp(() => access = FakeFileAccess());

  MediaImporter importerFor(Map<String, MediaProbe> answers) => MediaImporter(
        prober: FakeProber(answers),
        access: access,
        ids: IdGen.seeded(11),
      );

  List<GrantedFile> granted(List<String> paths, {String? bookmark}) =>
      [for (final p in paths) GrantedFile(path: p, bookmark: bookmark)];

  group('placing what came in', () {
    test('a video lands in the bin and on the main track', () async {
      final store = DocumentStore(blank());
      final importer = importerFor({'/f/a.mp4': videoProbe(seconds: 4)});

      final result = await importer.import(store, granted(['/f/a.mp4']));

      expect(result.added, hasLength(1));
      expect(result.clipsPlaced, 1);
      expect(result.failures, isEmpty);
      expect(result.notice, isNull);

      final asset = result.added.single;
      expect(asset.displayName, 'a.mp4');
      expect(store.project.media[asset.id], asset);
      expect(store.project.mainTrack.clips.single.mediaId, asset.id);
      expect(store.project.mainTrack.duration, secs(4));
    });

    test('an audio-only file goes to the audio track, not the main one',
        () async {
      final store = DocumentStore(blank());
      final importer = importerFor({'/f/song.m4a': audioProbe(seconds: 10)});

      await importer.import(store, granted(['/f/song.m4a']));

      expect(store.project.mainTrack.clips, isEmpty);
      final audio =
          store.project.tracks.firstWhere((t) => t.kind == TrackKind.audio);
      expect(audio.clips.single.duration, secs(10));
    });

    test('several audio files queue up rather than colliding', () async {
      // The audio track is free-form, so unlike the main track it will refuse
      // an overlapping insert. Import has to know where the end is.
      final store = DocumentStore(blank());
      final importer = importerFor({
        '/f/one.m4a': audioProbe(seconds: 3),
        '/f/two.m4a': audioProbe(seconds: 5),
      });

      final result =
          await importer.import(store, granted(['/f/one.m4a', '/f/two.m4a']));

      expect(result.failures, isEmpty);
      final audio =
          store.project.tracks.firstWhere((t) => t.kind == TrackKind.audio);
      expect(audio.clips.map((c) => c.start.raw), [0, secs(3).raw]);
    });

    test('a still image gets a duration it does not have', () async {
      final store = DocumentStore(blank());
      final importer = importerFor({'/f/still.png': imageProbe()});

      await importer.import(store, granted(['/f/still.png']));

      expect(store.project.mainTrack.clips.single.duration,
          secs(stillImageDuration.inSeconds));
    });

    test('an animated overlay goes on an overlay lane, not the main one',
        () async {
      // On the magnetic main lane a sticker would repack the footage around it
      // and then composite underneath it, which is two surprises for one drop
      // — where the thing somebody dropped a GIF to get is one *over* the shot.
      final store = DocumentStore(blank());
      final importer = importerFor({'/f/wave.gif': stickerProbe()});

      final result = await importer.import(store, granted(['/f/wave.gif']));

      expect(result.clipsPlaced, 1);
      expect(store.project.mainTrack.clips, isEmpty);
      final overlay = store.project.tracks
          .firstWhere((t) => t.kind == TrackKind.overlay);
      expect(overlay.clips.single.mediaId, result.added.single.id);
    });

    test('the overlay lane is made if there is not one, with the clip on it',
        () async {
      // A new project has no overlay lane, so the first sticker has to bring
      // one — and the lane and the clip have to be *one* command, or undoing
      // the clip leaves an empty lane behind that nobody asked for.
      final store = DocumentStore(blank());
      expect(store.project.tracks.where((t) => t.kind == TrackKind.overlay),
          isEmpty);
      final importer = importerFor({'/f/wave.gif': stickerProbe()});

      await importer.import(store, granted(['/f/wave.gif']));
      expect(store.project.tracks.where((t) => t.kind == TrackKind.overlay),
          hasLength(1));

      store.undo();
      expect(store.project.tracks.where((t) => t.kind == TrackKind.overlay),
          isEmpty);

      // And the rest of the import comes back off with the presses after it,
      // the way every other import does.
      while (store.canUndo) {
        store.undo();
      }
      expect(store.project.media, isEmpty);
    });

    test('a sticker lands contained, not blur-filled', () async {
      // Blur-fill is the default every other clip gets, and on a sticker it
      // paints a blurred copy of the overlay across the whole shot — hiding
      // the picture it is an overlay on, and with it the transparency the
      // format was chosen for.
      final store = DocumentStore(blank());
      final importer = importerFor({'/f/wave.gif': stickerProbe()});

      await importer.import(store, granted(['/f/wave.gif']));

      final overlay = store.project.tracks
          .firstWhere((t) => t.kind == TrackKind.overlay);
      expect(overlay.clips.single.transform.fit, ClipFit.contain);
      expect(overlay.clips.single.transform.scale, lessThan(1.0));
    });

    test('a video still lands blur-filled', () async {
      final store = DocumentStore(blank());
      final importer = importerFor({'/f/a.mp4': videoProbe()});

      await importer.import(store, granted(['/f/a.mp4']));

      expect(store.project.mainTrack.clips.single.transform,
          ClipTransform.identity);
    });

    test('a sticker gets a length rather than its own', () async {
      // It loops, so one loop is not a length anybody is stuck with — and
      // using it would make a half-second GIF a clip too short to see.
      final store = DocumentStore(blank());
      final importer =
          importerFor({'/f/wave.gif': stickerProbe(seconds: 0.5)});

      await importer.import(store, granted(['/f/wave.gif']));

      final overlay = store.project.tracks
          .firstWhere((t) => t.kind == TrackKind.overlay);
      expect(overlay.clips.single.duration,
          secs(stillImageDuration.inSeconds));
    });

    test('several stickers queue up on the lane rather than colliding',
        () async {
      final store = DocumentStore(blank());
      final importer = importerFor({
        '/f/a.gif': stickerProbe(),
        '/f/b.gif': stickerProbe(),
      });

      await importer.import(store, granted(['/f/a.gif', '/f/b.gif']));

      final overlay = store.project.tracks
          .firstWhere((t) => t.kind == TrackKind.overlay);
      expect(overlay.clips, hasLength(2));
      expect(overlay.clips[0].end, overlay.clips[1].start);
    });

    test('clips land in the order the files were given', () async {
      final store = DocumentStore(blank());
      final importer = importerFor({
        '/f/a.mp4': videoProbe(seconds: 1),
        '/f/b.mp4': videoProbe(seconds: 2),
        '/f/c.mp4': videoProbe(seconds: 3),
      });

      await importer
          .import(store, granted(['/f/a.mp4', '/f/b.mp4', '/f/c.mp4']));

      expect(store.project.mainTrack.clips.map((c) => c.label),
          ['a.mp4', 'b.mp4', 'c.mp4']);
    });

    test('placeOnTimeline: false fills the bin and leaves the timeline alone',
        () async {
      final store = DocumentStore(blank());
      final importer = importerFor({'/f/a.mp4': videoProbe()});

      final result = await importer.import(store, granted(['/f/a.mp4']),
          placeOnTimeline: false);

      expect(result.added, hasLength(1));
      expect(result.clipsPlaced, 0);
      expect(store.project.mainTrack.clips, isEmpty);
    });
  });

  group('undo', () {
    test('a whole import is one undo entry', () async {
      final store = DocumentStore(blank());
      final before = store.project;
      final importer = importerFor({
        '/f/a.mp4': videoProbe(),
        '/f/b.mp4': videoProbe(),
        '/f/c.mp4': videoProbe(),
      });

      await importer
          .import(store, granted(['/f/a.mp4', '/f/b.mp4', '/f/c.mp4']));
      expect(store.project.mainTrack.clips, hasLength(3));

      // Six commands went in — three assets and three clips — and they are one
      // gesture, so one press of ⌘Z has to put the project back.
      var presses = 0;
      while (store.canUndo && presses < 10) {
        store.undo();
        presses++;
      }
      expect(store.project.mainTrack.clips, isEmpty);
      expect(store.project.media, isEmpty);
      expect(store.project.duration, before.duration);
    });

    test('an import does not merge with the edit before it', () async {
      final store = DocumentStore(projectWithThreeClips());
      final importer = importerFor({'/f/a.mp4': videoProbe()});

      await importer.import(store, granted(['/f/a.mp4']));
      store.undo();

      expect(store.project.mainTrack.clips, hasLength(3));
      expect(store.project.media.keys, containsAll(['m1', 'm2']));
    });
  });

  group('the same file twice', () {
    test('re-importing reuses the asset and places another clip', () async {
      final store = DocumentStore(blank());
      final importer = importerFor({'/f/a.mp4': videoProbe(seconds: 2)});

      await importer.import(store, granted(['/f/a.mp4']));
      final second = await importer.import(store, granted(['/f/a.mp4']));

      expect(second.added, isEmpty);
      expect(second.reused, hasLength(1));
      expect(second.clipsPlaced, 1);
      // One asset, two clips: the bin does not grow a duplicate row.
      expect(store.project.media, hasLength(1));
      expect(store.project.mainTrack.clips, hasLength(2));
    });

    test('the same file twice in one drop is imported once', () async {
      final store = DocumentStore(blank());
      final importer = importerFor({'/f/a.mp4': videoProbe()});

      final result =
          await importer.import(store, granted(['/f/a.mp4', '/f/a.mp4']));

      expect(result.importedCount, 1);
      expect(store.project.mainTrack.clips, hasLength(1));
    });
  });

  group('files that will not import', () {
    test('one bad file does not stop the others', () async {
      final store = DocumentStore(blank());
      final importer = importerFor({
        '/f/a.mp4': videoProbe(),
        '/f/c.mp4': videoProbe(),
      });

      final result = await importer
          .import(store, granted(['/f/a.mp4', '/f/broken.mp4', '/f/c.mp4']));

      expect(result.added, hasLength(2));
      expect(result.failures.single.path, '/f/broken.mp4');
      expect(result.notice, contains('broken.mp4'));
      expect(store.project.mainTrack.clips, hasLength(2));
    });

    test('a file with neither picture nor sound is refused', () async {
      final store = DocumentStore(blank());
      final importer = importerFor({
        '/f/empty.mp4': nothingPlayableProbe(),
      });

      final result = await importer.import(store, granted(['/f/empty.mp4']));

      expect(result.added, isEmpty);
      expect(result.failures.single.reason, contains('nothing playable'));
      expect(store.project.media, isEmpty);
    });

    test('several failures collapse into one line', () async {
      final store = DocumentStore(blank());
      final importer = importerFor(const {});

      final result = await importer
          .import(store, granted(['/f/a.mp4', '/f/b.mp4', '/f/c.mp4']));

      expect(result.failures, hasLength(3));
      expect(result.notice, contains('3 files'));
    });

    test('nothing at all is a no-op, not an empty edit', () async {
      final store = DocumentStore(blank());
      final importer = importerFor(const {});
      final revision = store.revision;

      final result = await importer.import(store, const []);

      expect(result.isEmpty, isTrue);
      expect(store.revision, revision);
      expect(store.canUndo, isFalse);
    });
  });

  group('bookmarks', () {
    test('a bookmark that came with the file is kept', () async {
      final store = DocumentStore(blank());
      final importer = importerFor({'/f/a.mp4': videoProbe()});

      final result = await importer
          .import(store, granted(['/f/a.mp4'], bookmark: 'already-had-one'));

      expect(result.added.single.bookmark, 'already-had-one');
      expect(access.bookmarked, isEmpty);
    });

    test('a file without one has a bookmark minted for it', () async {
      final store = DocumentStore(blank());
      final importer = importerFor({'/f/a.mp4': videoProbe()});

      final result = await importer.import(store, granted(['/f/a.mp4']));

      expect(access.bookmarked, ['/f/a.mp4']);
      expect(result.added.single.bookmark, 'bm:/f/a.mp4');
    });

    test('a sandbox that will not mint one still imports the file', () async {
      // Access lasts as long as the process either way; only the next launch
      // is affected, and refusing the import would help nobody.
      access.bookmarksWork = false;
      final store = DocumentStore(blank());
      final importer = importerFor({'/f/a.mp4': videoProbe()});

      final result = await importer.import(store, granted(['/f/a.mp4']));

      expect(result.added.single.bookmark, isNull);
      expect(store.project.mainTrack.clips, hasLength(1));
    });
  });

  group('folders', () {
    late Directory folder;

    setUp(() {
      folder = Directory.systemTemp.createTempSync('vdodtor_import_');
      File('${folder.path}/b.mp4').writeAsStringSync('x');
      File('${folder.path}/a.mov').writeAsStringSync('x');
      File('${folder.path}/notes.txt').writeAsStringSync('x');
      Directory('${folder.path}/nested').createSync();
      File('${folder.path}/nested/deep.mp4').writeAsStringSync('x');
    });
    tearDown(() => folder.deleteSync(recursive: true));

    test('a dropped folder imports the media inside it, sorted', () async {
      final store = DocumentStore(blank());
      final importer = importerFor({
        '${folder.path}/a.mov': videoProbe(seconds: 1),
        '${folder.path}/b.mp4': videoProbe(seconds: 2),
      });

      final result = await importer.import(store, granted([folder.path]));

      expect(result.added.map((a) => a.displayName), ['a.mov', 'b.mp4']);
      // Not the .txt, and not one level down: a drop does the obvious thing.
      expect(result.failures, isEmpty);
      expect(store.project.media, hasLength(2));
    });

    test('every file found in a folder gets its own bookmark', () async {
      final store = DocumentStore(blank());
      final importer = importerFor({
        '${folder.path}/a.mov': videoProbe(),
        '${folder.path}/b.mp4': videoProbe(),
      });

      await importer.import(store, granted([folder.path]));

      expect(access.bookmarked,
          ['${folder.path}/a.mov', '${folder.path}/b.mp4']);
    });
  });

  test('probing happens once, for the whole batch', () async {
    final store = DocumentStore(blank());
    final prober = FakeProber({
      '/f/a.mp4': videoProbe(),
      '/f/b.mp4': videoProbe(),
    });
    final importer =
        MediaImporter(prober: prober, access: access, ids: IdGen.seeded(3));

    await importer.import(store, granted(['/f/a.mp4', '/f/b.mp4']));

    // One isolate hop, not one per file.
    expect(prober.batches, hasLength(1));
    expect(prober.batches.single, ['/f/a.mp4', '/f/b.mp4']);
  });
}
