import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/media/fonts.dart';

/// The typeface catalogue is written down in three places — the files on disk,
/// `BundledFonts.assets`, and `pubspec.yaml` — and none of them can see the
/// others. This is what makes them agree.
///
/// The failures it catches are both silent. A face that is in the folder and
/// not in the list ships in the bundle and is never offered; a face that is in
/// the list and not in the folder makes the app throw on launch, in a `load`
/// nobody is watching.
void main() {
  final dir = Directory('assets/fonts');
  final pubspec = File('pubspec.yaml').readAsStringSync();

  List<String> fontFilesOnDisk() => dir
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      .where((name) => name.endsWith('.ttf') || name.endsWith('.otf'))
      .toList()
    ..sort();

  test('every bundled font file is offered, and every offer exists', () {
    final listed = BundledFonts.assets
        .map((a) => a.split('/').last)
        .toList()
      ..sort();
    expect(listed, fontFilesOnDisk());
  });

  test('the family names match the ones declared to Flutter', () {
    // The names are written down twice — here for the picker, and in the
    // pubspec for Flutter's own text engine — because the picker has to list
    // the faces before an engine exists to ask. `vd_text_test.c` checks the
    // third copy, which is inside the files themselves.
    final declared = RegExp(r'- family: (.+)')
        .allMatches(pubspec)
        .map((m) => m.group(1)!.trim())
        .toSet();
    for (final face in BundledFonts.faces) {
      expect(declared, contains(face.family),
          reason: '${face.family} is offered in the picker but not declared '
              'to Flutter, so the preview would be in the wrong face');
    }
  });

  test('every face is declared to Flutter as well as to the engine', () {
    // Both, and for different reasons: `fonts:` is what lets the inspector
    // preview a face, `assets:` is what lets the app read the bytes and hand
    // them to the engine, which does the drawing.
    for (final asset in BundledFonts.assets) {
      expect(pubspec, contains('asset: $asset'),
          reason: '$asset is registered with the engine but not declared to '
              'Flutter, so the inspector cannot preview it');
    }
    expect(pubspec, contains('- assets/fonts/'),
        reason: 'the font directory has to be an asset, or rootBundle cannot '
            'read the files to register them');
  });

  test('every face carries its licence', () {
    // The OFL requires the notice to travel with the font, and a product sold
    // without an account has no room for a licensing argument.
    final licences = dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((name) => name.startsWith('OFL-'))
        .toSet();
    for (final asset in BundledFonts.assets) {
      final family = asset.split('/').last.replaceAll('.ttf', '');
      expect(licences, contains('OFL-$family.txt'),
          reason: '$family ships without its licence');
    }
  });

  test('the default family is one of the bundled faces', () {
    expect(BundledFonts.families, contains(BundledFonts.defaultFamily),
        reason: 'a caption that defaults to a face the app does not ship would '
            'silently be drawn in the system font instead');
  });
}
