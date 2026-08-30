import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/persistence/app_paths.dart';
import 'package:vdodtor/persistence/library.dart';
import 'package:vdodtor/persistence/project_file.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('vdodtor_lib_'));
  tearDown(() => dir.deleteSync(recursive: true));

  File project(String name) =>
      File('${dir.path}/$name.$kProjectExtension')..writeAsStringSync('{}');

  group('ProjectLibrary', () {
    test('lists only project files, newest written first', () async {
      project('older');
      // Two files written in the same millisecond would sort arbitrarily.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      project('newer');
      File('${dir.path}/notes.txt').writeAsStringSync('not a project');

      final entries = ProjectLibrary(dir).list();
      expect(entries.map((e) => e.name), ['newer', 'older']);
    });

    test('a library that does not exist lists as empty', () {
      final missing = Directory('${dir.path}/nope');
      expect(ProjectLibrary(missing).list(), isEmpty);
    });

    test('numbers a name that is already taken', () {
      final library = ProjectLibrary(dir);
      expect(library.pathFor('Untitled'),
          '${dir.path}/Untitled.$kProjectExtension');

      project('Untitled');
      expect(library.pathFor('Untitled'),
          '${dir.path}/Untitled 2.$kProjectExtension');

      project('Untitled 2');
      expect(library.pathFor('Untitled'),
          '${dir.path}/Untitled 3.$kProjectExtension');
    });

    test('keeps the name recognisable but file-system safe', () {
      expect(ProjectLibrary.fileNameFor('Holiday 2026'), 'Holiday 2026');
      expect(ProjectLibrary.fileNameFor('a/b:c'), 'a-b-c');
      expect(ProjectLibrary.fileNameFor('  spaced   out  '), 'spaced out');
      expect(ProjectLibrary.fileNameFor('.hidden'), 'hidden');
      expect(ProjectLibrary.fileNameFor('   '), 'Untitled');
      expect(ProjectLibrary.fileNameFor('/'), 'Untitled',
          reason: 'a name of only separators must still produce a file');
      expect(ProjectLibrary.fileNameFor('x' * 200).length, 60);
    });

    test('reads the name back off a path', () {
      expect(ProjectLibrary.nameOfFile('/a/b/Holiday.$kProjectExtension'),
          'Holiday');
      expect(ProjectLibrary.nameOfFile('/a/b/mystery.txt'), 'mystery.txt');
    });
  });

  group('AppPaths', () {
    test('creates its locations under the home it is given', () async {
      final paths = await AppPaths.resolve(home: dir.path);

      expect(paths.support.existsSync(), isTrue);
      // Canonical, not as-typed: a temp dir on macOS is itself a symlink.
      final real = dir.resolveSymbolicLinksSync();
      expect(paths.library.path, '$real/Movies/vdodtor');
      expect(paths.library.existsSync(), isTrue);
      expect(paths.recentsFile.path, '${paths.support.path}/recents.json');
      expect(paths.sessionFile.path, '${paths.support.path}/session.json');
    });

    test('falls back to app-private storage when Movies is unusable',
        () async {
      // A file where the folder should be: the library cannot be created.
      File('${dir.path}/Movies').writeAsStringSync('in the way');

      final paths = await AppPaths.resolve(home: dir.path);
      expect(paths.library.path, '${paths.support.path}/Projects');
      expect(paths.library.existsSync(), isTrue);
    });

    test('refuses to guess when there is no home', () {
      expect(AppPaths.resolve(home: ''), throwsA(isA<FileSystemException>()));
    });
  });
}
