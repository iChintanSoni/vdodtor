import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/app/workspace.dart';
import 'package:vdodtor/commands/edits.dart';
import 'package:vdodtor/model/ids.dart';
import 'package:vdodtor/model/project.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor/persistence/app_paths.dart';
import 'package:vdodtor/persistence/project_file.dart';

import '../fixtures.dart';

void main() {
  late Directory home;
  late AppPaths paths;

  setUp(() async {
    home = Directory.systemTemp.createTempSync('vdodtor_ws_');
    paths = await AppPaths.resolve(home: home.path);
  });
  tearDown(() => home.deleteSync(recursive: true));

  Workspace workspace() => Workspace(
        paths: paths,
        ids: IdGen.seeded(7),
        autosaveDebounce: Duration.zero,
      );

  Future<Workspace> started() async {
    final w = workspace();
    await w.start();
    return w;
  }

  Future<void> newProject(Workspace w, String name,
          {ProjectAspect aspect = ProjectAspect.landscape16x9,
          Rational frameRate = FrameRates.fps30}) =>
      w.create(name: name, aspect: aspect, frameRate: frameRate);

  /// One media asset and one clip, run as real edits so autosave sees them.
  void placeAClip(Workspace w) {
    final store = w.open!.store;
    final asset = videoAsset('m1');
    store.run(AddMedia(asset));
    store.run(InsertClip(
      store.project.mainTrack.id,
      clipOf('c1', asset.id, start: Tick.zero, duration: secs(2)),
    ));
  }

  group('launch', () {
    test('a fresh install opens on an empty chooser', () async {
      final w = await started();

      expect(w.stage, WorkspaceStage.chooser);
      expect(w.projects, isEmpty);
      expect(w.recovery, isNull);
      expect(w.notice, isNull);
    });

    test('storage it cannot reach is a state, not an exception', () async {
      final w = Workspace(
        resolvePaths: () =>
            Future<AppPaths>.error(const FileSystemException('no disk')),
      );
      await w.start();

      expect(w.stage, WorkspaceStage.failed);
      expect(w.failure, isA<FileSystemException>());
      // The stage the window can actually render, rather than a crash before
      // the first frame.
      expect(w.projects, isEmpty);
    });
  });

  group('create', () {
    test('writes a project into the library and opens it', () async {
      final w = await started();
      await newProject(w, 'Holiday',
          aspect: ProjectAspect.portrait9x16, frameRate: FrameRates.fps24);

      expect(w.stage, WorkspaceStage.editing);
      final open = w.open!;
      expect(open.name, 'Holiday');
      expect(open.path, '${paths.library.path}/Holiday.$kProjectExtension');
      expect(File(open.path).existsSync(), isTrue,
          reason: 'a new project is on disk before the user does anything');
      expect(open.project.format.width, 1080);
      expect(open.project.format.height, 1920);
      expect(open.project.format.frameRate, FrameRates.fps24);
      expect(open.project.mainTrack.isEmpty, isTrue);
    });

    test('the same name twice makes two projects', () async {
      final w = await started();
      await newProject(w, 'Untitled');
      final first = w.open!.path;
      await newProject(w, 'Untitled');
      final second = w.open!.path;

      expect(second, isNot(first));
      expect(File(first).existsSync(), isTrue);
      expect(File(second).existsSync(), isTrue);
    });

    test('an empty name still produces a project', () async {
      final w = await started();
      await newProject(w, '   ');
      expect(w.open!.name, 'Untitled');
    });
  });

  group('open and close', () {
    test('an edit survives closing and reopening', () async {
      final w = await started();
      await newProject(w, 'Holiday');
      final path = w.open!.path;
      placeAClip(w);

      await w.close();
      expect(w.stage, WorkspaceStage.chooser);
      expect(w.open, isNull);

      await w.openAt(path);
      expect(w.stage, WorkspaceStage.editing);
      expect(w.open!.project.mainTrack.clips, hasLength(1));
      expect(w.open!.project.mainTrack.clips.single.duration, secs(2));
    });

    test('the chooser lists projects, most recently opened first', () async {
      final w = await started();
      await newProject(w, 'First');
      await newProject(w, 'Second');
      await w.close();

      expect(w.projects.map((p) => p.name), ['Second', 'First']);
      expect(w.projects.every((p) => p.exists && p.inLibrary), isTrue);
    });

    test('a project that has gone away is listed, not opened', () async {
      final w = await started();
      await newProject(w, 'Gone');
      final path = w.open!.path;
      await w.close();
      File(path).deleteSync();

      await w.refresh();
      expect(w.projects.single.exists, isFalse);

      await w.openAt(path);
      expect(w.stage, WorkspaceStage.chooser);
      expect(w.notice, contains('Could not open "Gone"'));

      await w.forget(path);
      expect(w.projects, isEmpty);
    });

    test('says so when it had to fall back to the backup', () async {
      final w = await started();
      await newProject(w, 'Holiday');
      final path = w.open!.path;
      placeAClip(w);
      await w.close();

      // The last write did not land: main file truncated, backup intact.
      expect(File('$path.bak').existsSync(), isTrue);
      File(path).writeAsStringSync('{ truncated mid-write');

      await w.openAt(path);
      expect(w.stage, WorkspaceStage.editing);
      expect(w.notice, contains('did not finish'));
      expect(w.open!.project.mainTrack.isEmpty, isTrue,
          reason: 'the backup is the state before the last save');
    });
  });

  group('crash recovery', () {
    test('a clean quit leaves nothing to recover', () async {
      final first = await started();
      await newProject(first, 'Holiday');
      await first.shutdown();

      final second = await started();
      expect(second.recovery, isNull);
    });

    test('being killed with a project open offers it back', () async {
      final first = await started();
      await newProject(first, 'Holiday');
      final path = first.open!.path;
      placeAClip(first);
      await first.open!.autosaver.flush();
      first.dispose(); // killed: no flush, no session close

      final second = await started();
      expect(second.recovery, isNotNull);
      expect(second.recovery!.name, 'Holiday');
      expect(second.recovery!.path, path);

      await second.recoverLastSession();
      expect(second.stage, WorkspaceStage.editing);
      expect(second.open!.project.mainTrack.clips, hasLength(1),
          reason: 'autosave had already written every committed edit');
      expect(second.recovery, isNull);
    });

    test('the offer is not made twice once dismissed', () async {
      final first = await started();
      await newProject(first, 'Holiday');
      first.dispose();

      final second = await started();
      expect(second.recovery, isNotNull);
      await second.dismissRecovery();
      await second.shutdown();

      final third = await started();
      expect(third.recovery, isNull);
    });

    test('a project deleted after the crash is not offered', () async {
      final first = await started();
      await newProject(first, 'Holiday');
      final path = first.open!.path;
      first.dispose();
      File(path).deleteSync();

      final second = await started();
      expect(second.recovery, isNull);
    });
  });
}
