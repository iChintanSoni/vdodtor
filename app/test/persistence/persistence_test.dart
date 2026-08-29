import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/commands/document_store.dart';
import 'package:vdodtor/commands/edits.dart';
import 'package:vdodtor/model/serialization.dart';
import 'package:vdodtor/persistence/autosave.dart';
import 'package:vdodtor/persistence/project_file.dart';
import 'package:vdodtor/persistence/recents.dart';
import 'package:vdodtor/persistence/session.dart';

import '../fixtures.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('vdodtor_test_'));
  tearDown(() => dir.deleteSync(recursive: true));

  String at(String name) => '${dir.path}/$name';

  group('ProjectFile', () {
    test('saves and loads a project', () async {
      final f = ProjectFile(at('p.$kProjectExtension'));
      final p = projectWithThreeClips();
      await f.save(p);

      expect(f.exists, isTrue);
      expect(encodeProject(await f.load()), encodeProject(p));
    });

    test('creates missing parent directories', () async {
      final f = ProjectFile(at('nested/deeper/p.$kProjectExtension'));
      await f.save(emptyProject());
      expect(f.exists, isTrue);
    });

    test('keeps the previous version as a backup', () async {
      final f = ProjectFile(at('p.$kProjectExtension'));
      await f.save(projectWithThreeClips());
      await f.save(emptyProject());

      expect(f.backupFile.existsSync(), isTrue);
      expect((await f.load()).mainTrack.clips, isEmpty);
      expect(decodeProject(f.backupFile.readAsStringSync()).mainTrack.clips,
          hasLength(3));
    });

    test('falls back to the backup when the main file is corrupt', () async {
      final f = ProjectFile(at('p.$kProjectExtension'));
      await f.save(projectWithThreeClips());
      await f.save(emptyProject());

      f.file.writeAsStringSync('{ truncated mid-write');

      Object? reported;
      final recovered = await f.load(onRecovered: (e) => reported = e);
      expect(recovered.mainTrack.clips, hasLength(3),
          reason: 'the backup is the previous good save');
      expect(reported, isA<ProjectDecodeException>(),
          reason: 'recovery must be reported, not silent');
    });

    test('reports the original error when both copies are unreadable',
        () async {
      final f = ProjectFile(at('p.$kProjectExtension'));
      await f.save(emptyProject());
      await f.save(emptyProject().copyWith(name: 'second'));
      f.file.writeAsStringSync('nonsense');
      f.backupFile.writeAsStringSync('also nonsense');

      expect(f.load(), throwsA(isA<ProjectDecodeException>()));
    });

    test('loading a file that was never written throws', () async {
      expect(ProjectFile(at('missing.$kProjectExtension')).load(),
          throwsA(isA<ProjectDecodeException>()));
    });

    test('an interrupted write leaves the old project intact', () async {
      final f = ProjectFile(at('p.$kProjectExtension'));
      await f.save(projectWithThreeClips());
      final good = f.file.readAsStringSync();

      // Simulate a crash between "temp written" and "renamed into place".
      File('${f.path}.tmp').writeAsStringSync('half a document');

      expect(f.hasInterruptedWrite, isTrue);
      expect(f.file.readAsStringSync(), good);
      expect(encodeProject(await f.load()), good);

      await f.cleanUpInterruptedWrite();
      expect(f.hasInterruptedWrite, isFalse);
      expect(f.exists, isTrue);
    });
  });

  group('Autosaver', () {
    test('writes after an edit, once the debounce elapses', () async {
      final store = DocumentStore(emptyProject());
      final f = ProjectFile(at('p.$kProjectExtension'));
      final saver = Autosaver(
          store: store, file: f, debounce: const Duration(milliseconds: 20))
        ..start();
      addTearDown(saver.dispose);

      store.run(const RenameProject('edited'));
      expect(f.exists, isFalse, reason: 'not written synchronously');

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect((await f.load()).name, 'edited');
      expect(store.isDirty, isFalse);
    });

    test('a burst of edits collapses into one write', () async {
      final store = DocumentStore(projectWithThreeClips());
      final f = ProjectFile(at('p.$kProjectExtension'));
      final saver = Autosaver(
          store: store, file: f, debounce: const Duration(milliseconds: 30))
        ..start();
      addTearDown(saver.dispose);

      for (var i = 0; i < 50; i++) {
        store.run(MoveClip('c', secs(i * 0.01)));
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(saver.writeCount, 1, reason: 'a drag is one write, not fifty');
      expect((await f.load()).mainTrack.clips, hasLength(3));
    });

    test('flush writes immediately, for quit', () async {
      final store = DocumentStore(emptyProject());
      final f = ProjectFile(at('p.$kProjectExtension'));
      final saver = Autosaver(
          store: store, file: f, debounce: const Duration(seconds: 30))
        ..start();
      addTearDown(saver.dispose);

      store.run(const RenameProject('quitting'));
      await saver.flush();
      expect((await f.load()).name, 'quitting');
    });

    test('flush on an unchanged document writes nothing', () async {
      final store = DocumentStore(emptyProject());
      final f = ProjectFile(at('p.$kProjectExtension'));
      final saver = Autosaver(store: store, file: f)..start();
      addTearDown(saver.dispose);

      await saver.flush();
      expect(saver.writeCount, 0);
      expect(f.exists, isFalse);
    });

    test('an edit during a write is not lost', () async {
      final store = DocumentStore(emptyProject());
      final f = ProjectFile(at('p.$kProjectExtension'));
      final saver = Autosaver(
          store: store, file: f, debounce: const Duration(milliseconds: 5))
        ..start();
      addTearDown(saver.dispose);

      store.run(const RenameProject('first'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      store.run(const RenameProject('second'));
      await saver.flush();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect((await f.load()).name, 'second',
          reason: 'the last committed edit must reach disk');
      expect(store.isDirty, isFalse);
    });

    test('a failing write leaves the document dirty and reports', () async {
      final store = DocumentStore(emptyProject());
      // A path whose parent is a *file*, so create() fails.
      File(at('blocker')).writeAsStringSync('x');
      final f = ProjectFile(at('blocker/p.$kProjectExtension'));
      Object? reported;
      final saver = Autosaver(
        store: store,
        file: f,
        debounce: const Duration(milliseconds: 5),
        onError: (e, _) => reported = e,
      )..start();
      addTearDown(saver.dispose);

      store.run(const RenameProject('doomed'));
      await saver.flush();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(reported, isNotNull, reason: 'failures must surface');
      expect(store.isDirty, isTrue, reason: 'and must not look saved');
    });

    test('stops writing after dispose', () async {
      final store = DocumentStore(emptyProject());
      final f = ProjectFile(at('p.$kProjectExtension'));
      final saver = Autosaver(
          store: store, file: f, debounce: const Duration(milliseconds: 5))
        ..start();
      saver.dispose();

      store.run(const RenameProject('after dispose'));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(f.exists, isFalse);
    });
  });

  group('RecentProjects', () {
    test('records newest first and de-duplicates by path', () async {
      final r = RecentProjects(File(at('recents.json')));
      await r.record('/a.vdodtor', 'A');
      await r.record('/b.vdodtor', 'B');
      await r.record('/a.vdodtor', 'A renamed');

      final list = await r.load();
      expect(list.map((e) => e.path), ['/a.vdodtor', '/b.vdodtor']);
      expect(list.first.name, 'A renamed');
    });

    test('caps the list', () async {
      final r = RecentProjects(File(at('recents.json')), limit: 3);
      for (var i = 0; i < 10; i++) {
        await r.record('/p$i.vdodtor', 'P$i');
      }
      final list = await r.load();
      expect(list, hasLength(3));
      expect(list.first.path, '/p9.vdodtor');
    });

    test('marks entries whose file has gone', () async {
      final present = at('present.$kProjectExtension');
      await ProjectFile(present).save(emptyProject());
      final r = RecentProjects(File(at('recents.json')));
      await r.record(present, 'Present');
      await r.record('/nowhere/gone.vdodtor', 'Gone');

      final list = await r.load();
      expect(list.firstWhere((e) => e.name == 'Present').stillExists, isTrue);
      expect(list.firstWhere((e) => e.name == 'Gone').stillExists, isFalse,
          reason: 'shown greyed out, not silently dropped');
    });

    test('remove and clear', () async {
      final r = RecentProjects(File(at('recents.json')));
      await r.record('/a.vdodtor', 'A');
      await r.record('/b.vdodtor', 'B');
      expect(await r.remove('/a.vdodtor'), hasLength(1));
      await r.clear();
      expect(await r.load(), isEmpty);
    });

    test('a corrupt list reads as empty rather than failing launch', () async {
      final file = File(at('recents.json'))..writeAsStringSync('}{ garbage');
      expect(await RecentProjects(file).load(), isEmpty);
      // And it recovers on the next write.
      await RecentProjects(file).record('/a.vdodtor', 'A');
      expect(await RecentProjects(file).load(), hasLength(1));
    });

    test('missing list reads as empty', () async {
      expect(await RecentProjects(File(at('nope.json'))).load(), isEmpty);
    });

    test('entries survive a round trip through disk', () async {
      final r = RecentProjects(File(at('recents.json')));
      final when = DateTime.utc(2026, 8, 29, 12, 30);
      await r.record('/a.vdodtor', 'A', at: when);
      expect((await r.load()).first.lastOpened, when);
    });
  });

  group('SessionMarker', () {
    test('a clean close leaves nothing behind', () async {
      final m = SessionMarker(File(at('session.json')));
      await m.open('/p.vdodtor');
      expect(m.exists, isTrue);
      await m.close();
      expect(m.exists, isFalse);
      expect(await m.unfinishedProjectPath(), isNull);
    });

    test('a crash leaves the marker naming the open project', () async {
      final m = SessionMarker(File(at('session.json')));
      await m.open('/projects/holiday.vdodtor');
      // No close() — the process died here.

      final next = SessionMarker(File(at('session.json')));
      expect(next.exists, isTrue);
      expect(await next.unfinishedProjectPath(), '/projects/holiday.vdodtor');
    });

    test('a corrupt marker is treated as a clean exit', () async {
      final file = File(at('session.json'))..writeAsStringSync('not json');
      expect(await SessionMarker(file).unfinishedProjectPath(), isNull);
    });

    test('closing when there is no marker is harmless', () async {
      await SessionMarker(File(at('session.json'))).close();
    });
  });

  test('the full launch cycle: edit, crash, recover', () async {
    final projectPath = at('holiday.$kProjectExtension');
    final marker = SessionMarker(File(at('session.json')));
    final recents = RecentProjects(File(at('recents.json')));

    // --- session one: create, edit, then die without closing.
    final store = DocumentStore(emptyProject());
    final saver = Autosaver(
        store: store,
        file: ProjectFile(projectPath),
        debounce: const Duration(milliseconds: 5))
      ..start();
    await marker.open(projectPath);
    await recents.record(projectPath, 'Holiday');

    store.run(InsertClip(mainTrackId,
        clipOf('a', 'm1', start: secs(0), duration: secs(2))));
    store.endGesture();
    store.run(InsertClip(mainTrackId,
        clipOf('b', 'm1', start: secs(0), duration: secs(3))));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    saver.dispose(); // the process vanishes; no flush, no marker close.

    // --- session two: launch.
    final crashed = await marker.unfinishedProjectPath();
    expect(crashed, projectPath, reason: 'the crash is detected');

    final reopened = await ProjectFile(crashed!).load();
    expect(reopened.mainTrack.clips.map((c) => c.id), ['a', 'b'],
        reason: 'both committed edits survived the crash');
    expect((await recents.load()).first.name, 'Holiday');

    await marker.close();
    expect(await marker.unfinishedProjectPath(), isNull);
  });
}
