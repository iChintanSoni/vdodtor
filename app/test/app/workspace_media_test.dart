import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/app/workspace.dart';
import 'package:vdodtor/commands/edits.dart';
import 'package:vdodtor/media/file_access.dart';
import 'package:vdodtor/model/ids.dart';
import 'package:vdodtor/model/media.dart';
import 'package:vdodtor/model/project.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor/persistence/app_paths.dart';
import 'package:vdodtor/persistence/project_file.dart';

import '../fixtures.dart';
import '../media/fakes.dart';

/// What a project file remembers about its media is a path *and* a bookmark,
/// and only one of the two is authoritative. These are the tests for what
/// happens when they disagree — a file moved, a bookmark went stale, a volume
/// is not mounted — because that is the day the user finds out whether the
/// editor keeps their edit or loses it.
void main() {
  late Directory home;
  late Directory footage;
  late AppPaths paths;
  late FakeFileAccess access;

  setUp(() async {
    home = Directory.systemTemp.createTempSync('vdodtor_wsmedia_');
    footage = Directory.systemTemp.createTempSync('vdodtor_footage_');
    paths = await AppPaths.resolve(home: home.path);
    access = FakeFileAccess();
  });
  tearDown(() {
    home.deleteSync(recursive: true);
    footage.deleteSync(recursive: true);
  });

  Workspace workspace() => Workspace(
        paths: paths,
        ids: IdGen.seeded(5),
        access: access,
        autosaveDebounce: Duration.zero,
      );

  String realFile(String name) {
    final file = File('${footage.path}/$name')..writeAsStringSync('footage');
    return file.path;
  }

  MediaAsset assetAt(String path, {String? bookmark, String id = 'm1'}) =>
      videoAsset(id).copyWith(path: path, bookmark: bookmark);

  /// Makes a project on disk holding [assets], and returns where it went.
  Future<String> projectWith(List<MediaAsset> assets) async {
    final w = workspace();
    await w.start();
    await w.create(
      name: 'Holiday',
      aspect: ProjectAspect.landscape16x9,
      frameRate: FrameRates.fps30,
    );
    for (final asset in assets) {
      w.open!.store.run(AddMedia(asset));
    }
    final path = w.open!.path;
    await w.close();
    w.dispose();
    return path;
  }

  Future<Workspace> reopen(String path) async {
    final w = workspace();
    await w.start();
    await w.openAt(path);
    return w;
  }

  test('opening a project resolves every bookmark it holds', () async {
    final media = realFile('clip.mp4');
    final path = await projectWith([assetAt(media, bookmark: 'bm-1')]);
    access.resolutions['bm-1'] =
        ResolvedFile(path: media, granted: true, stale: false);

    final w = await reopen(path);
    addTearDown(w.dispose);

    expect(access.resolved, ['bm-1']);
    expect(w.open!.unreachableMediaIds, isEmpty);
    expect(w.notice, isNull);
  });

  test('a file that moved is relinked, and the new path is written down',
      () async {
    final was = '${footage.path}/old-name.mp4';
    final now = realFile('new-name.mp4');
    final path = await projectWith([assetAt(was, bookmark: 'bm-1')]);
    access.resolutions['bm-1'] = ResolvedFile(
      path: now,
      granted: true,
      stale: true,
      refreshedBookmark: 'bm-2',
    );

    final w = await reopen(path);
    addTearDown(w.dispose);

    final asset = w.open!.project.media['m1']!;
    expect(asset.path, now);
    // The refreshed bookmark replaces the stale one, or the next launch pays
    // the same resolution again — and eventually stops resolving at all.
    expect(asset.bookmark, 'bm-2');
    expect(w.open!.unreachableMediaIds, isEmpty);

    // Written through, not left for the next edit to carry.
    final onDisk = await ProjectFile(path).load();
    expect(onDisk.media['m1']!.path, now);
    expect(onDisk.media['m1']!.bookmark, 'bm-2');
  });

  test('a bookmark that will not resolve leaves the asset and says so',
      () async {
    final gone = '${footage.path}/deleted.mp4';
    final path = await projectWith([assetAt(gone, bookmark: 'bm-1')]);
    // Not in the resolutions table: the bookmark is dead.

    final w = await reopen(path);
    addTearDown(w.dispose);

    // The asset stays. A clip whose media vanished is a clip the user can
    // point at a new file; a clip that vanished with it is lost work.
    expect(w.open!.project.media, contains('m1'));
    expect(w.open!.unreachableMediaIds, {'m1'});
    expect(w.notice, contains('m1.mp4'));
  });

  test('an asset with no bookmark is judged on whether its path still exists',
      () async {
    final present = realFile('present.mp4');
    final path = await projectWith([
      assetAt(present, id: 'm1'),
      assetAt('${footage.path}/absent.mp4', id: 'm2'),
    ]);

    final w = await reopen(path);
    addTearDown(w.dispose);

    expect(access.resolved, isEmpty);
    expect(w.open!.unreachableMediaIds, {'m2'});
  });

  test('more than one missing file is one sentence, not a list', () async {
    final path = await projectWith([
      assetAt('${footage.path}/a.mp4', id: 'm1'),
      assetAt('${footage.path}/b.mp4', id: 'm2'),
    ]);

    final w = await reopen(path);
    addTearDown(w.dispose);

    expect(w.open!.unreachableMediaIds, {'m1', 'm2'});
    expect(w.notice, contains('2 of this project'));
  });

  test('closing a project releases every scope it opened', () async {
    final one = realFile('one.mp4');
    final two = realFile('two.mp4');
    final path = await projectWith([
      assetAt(one, bookmark: 'bm-1', id: 'm1'),
      assetAt(two, bookmark: 'bm-2', id: 'm2'),
    ]);
    access.resolutions['bm-1'] =
        ResolvedFile(path: one, granted: true, stale: false);
    access.resolutions['bm-2'] =
        ResolvedFile(path: two, granted: true, stale: false);

    final w = await reopen(path);
    addTearDown(w.dispose);
    expect(access.released, isEmpty);

    await w.close();

    // The sandbox counts open scopes per process, so an editor that opened and
    // closed projects all day would eventually run out of them.
    expect(access.released, unorderedEquals([one, two]));
  });

  test('quitting releases them too', () async {
    final media = realFile('clip.mp4');
    final path = await projectWith([assetAt(media, bookmark: 'bm-1')]);
    access.resolutions['bm-1'] =
        ResolvedFile(path: media, granted: true, stale: false);

    final w = await reopen(path);
    addTearDown(w.dispose);
    await w.shutdown();

    expect(access.released, [media]);
  });

  test('a project whose media has not moved is not rewritten', () async {
    final media = realFile('clip.mp4');
    final path = await projectWith([assetAt(media, bookmark: 'bm-1')]);
    access.resolutions['bm-1'] =
        ResolvedFile(path: media, granted: true, stale: false);
    final before = File(path).lastModifiedSync();

    await Future<void>.delayed(const Duration(milliseconds: 20));
    final w = await reopen(path);
    addTearDown(w.dispose);

    expect(File(path).lastModifiedSync(), before);
  });
}
