import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/media/looks.dart';

/// The look catalogue is written down in three places that cannot see each
/// other — the `.cube` files on disk, `BundledLooks.looks`, and the `assets:`
/// block in `pubspec.yaml` — and this is what makes them agree.
///
/// The failures it catches are both silent, exactly as they are for the fonts.
/// A cube in the folder and not in the list ships in the bundle and is never
/// offered; a cube in the list and not in the folder throws on launch, inside
/// a `load` nobody is watching.
///
/// What a look *does* is not checked here and could not be: it is arithmetic
/// on a lattice, and `engine/tests/vd_lut_test.c` reads these same files and
/// asserts on the numbers.
void main() {
  final dir = Directory('assets/luts');
  final pubspec = File('pubspec.yaml').readAsStringSync();

  List<String> cubesOnDisk() => dir
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      .where((name) => name.endsWith('.cube'))
      .toList()
    ..sort();

  test('every bundled look exists, and every cube is offered', () {
    final listed = BundledLooks.looks.map((l) => l.asset.split('/').last).toList()
      ..sort();
    expect(listed, cubesOnDisk());
  });

  test('the folder is declared to Flutter, or nothing can read it', () {
    // rootBundle only reaches what the pubspec lists. Without this the app
    // launches, registers nothing, and every look silently does nothing.
    expect(pubspec, contains('assets/luts/'));
  });

  test('no two looks share a name', () {
    // The name is the key the engine registers under and the string the
    // project file records. Two looks called the same thing would mean the
    // second is never registered and every clip naming it wears the first.
    final names = BundledLooks.names;
    expect(names.toSet().length, names.length);
  });

  test('a look is offered before anything has been registered', () {
    // The inspector lists looks with no engine alive — a widget test has none
    // — so the picker reads this rather than the engine's own catalogue.
    expect(BundledLooks.available, containsAll(BundledLooks.names));
  });

  test('none is the empty string, all the way down', () {
    // `VdTimelineClip::look` takes NULL for the same thing, and the plugin
    // turns an empty string into one. A sentinel like "None" would be a look
    // somebody could name a file after.
    expect(BundledLooks.none, isEmpty);
  });

  group('naming a file', () {
    test('a look is offered under the name the user gave the file', () {
      expect(BundledLooks.nameOf('/tmp/Kodak 2383.cube'), 'Kodak 2383');
      expect(BundledLooks.nameOf('/a/b/warm_film.CUBE'), 'warm_film');
    });

    test('a file with no extension keeps its whole name', () {
      expect(BundledLooks.nameOf('/tmp/plain'), 'plain');
    });

    test('a dotfile is not read as an empty name', () {
      expect(BundledLooks.nameOf('/tmp/.hidden'), '.hidden');
    });
  });

  test('the library sits under the app private folder, not the project', () {
    // A look is a tool rather than project material: two projects using one
    // look share it, and a project copied to another machine should not carry
    // a copy of every filter it happens to use.
    final support = Directory('/somewhere/Application Support/vdodtor');
    expect(BundledLooks.libraryOf(support).path,
        '/somewhere/Application Support/vdodtor/Looks');
  });
}
