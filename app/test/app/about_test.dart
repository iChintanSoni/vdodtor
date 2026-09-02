import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/app/about.dart';

/// The notice vdodtor ships about the software it did not write, checked
/// against the software it actually ships.
///
/// This is the `vd_time.c`/`time.dart` arrangement pointed at a licence rather
/// than at arithmetic, and it is here because the failure it catches is
/// completely silent: `tools/build_ffmpeg.sh` vendors a new FFmpeg, nobody
/// re-runs `tools/make_notices.dart`, and the app goes on stating a version
/// and a checksum for libraries it is no longer carrying. Nothing crashes and
/// nothing looks wrong — the notice is simply no longer true, which for an
/// LGPL obligation is the whole of the problem.
///
/// So every number in the shipped notice is compared to the file
/// `build_ffmpeg.sh` wrote, and the licence text to the one that came out of
/// the tarball. Re-run the generator and this goes green:
///
///   dart run tools/make_notices.dart      # from the repository root
void main() {
  // Tests run with the app package as the working directory; the vendored
  // libraries are a level up, beside it.
  final buildInfo = File('../third_party/ffmpeg/BUILD_INFO.txt');
  final notices = File('assets/notices/THIRD_PARTY_NOTICES.md');
  final lgpl = File('assets/notices/LGPL-2.1.txt');

  String field(String name) => buildInfo
      .readAsLinesSync()
      .firstWhere((l) => l.startsWith('$name:'))
      .split(':')
      .sublist(1)
      .join(':')
      .trim();

  group('the shipped notice', () {
    test('is in the bundle, and the bundle can reach it', () {
      expect(notices.existsSync(), isTrue,
          reason: 'run `dart run tools/make_notices.dart`');
      expect(lgpl.existsSync(), isTrue);

      // rootBundle only reaches what the pubspec lists. Without this the About
      // sheet opens on a spinner that never stops.
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('assets/notices/'));

      // And the sheet has to name assets that are actually there.
      expect(About.noticesAsset, 'assets/notices/THIRD_PARTY_NOTICES.md');
      expect(About.licenceAsset, 'assets/notices/LGPL-2.1.txt');
    });

    test('names the FFmpeg that is actually vendored', () {
      final text = notices.readAsStringSync();
      for (final name in ['version', 'source', 'sha256']) {
        expect(text, contains(field(name)),
            reason: 'BUILD_INFO.txt records $name = "${field(name)}" and the '
                'notice does not say so — re-run tools/make_notices.dart');
      }
    });

    test('lists every library that gets embedded, and nothing else', () {
      final text = notices.readAsStringSync();

      // Real files only, matching the podspec's embed phase: the unversioned
      // names in that directory are linker symlinks, and naming one in a
      // notice would name a file that is not in the shipped bundle.
      final embedded = Directory('../third_party/ffmpeg/lib')
          .listSync(followLinks: false)
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((name) => name.endsWith('.dylib'))
          .toList()
        ..sort();

      expect(embedded, isNotEmpty);
      for (final name in embedded) {
        expect(text, contains('`$name`'), reason: '$name ships and is unlisted');
      }

      final listed = RegExp(r'`(lib\w+\.\d+\.dylib)`')
          .allMatches(text)
          .map((m) => m.group(1)!)
          .toSet();
      expect(listed, embedded.toSet(),
          reason: 'the notice names a library that is not in the bundle');
    });

    test('carries every configure flag, so the library can be rebuilt', () {
      // LGPL 2.1 §6 is about being able to substitute your own build. A flag
      // list that has quietly fallen behind produces a library that links but
      // is missing a decoder, which is a worse answer than no list at all.
      final text = notices.readAsStringSync();
      final flags = buildInfo
          .readAsLinesSync()
          .skipWhile((l) => l.trim() != 'configure flags:')
          .skip(1)
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty);

      expect(flags, isNotEmpty);
      for (final flag in flags) {
        expect(text, contains(flag), reason: '$flag is not in the notice');
      }
    });

    test('makes a written offer somebody can act on', () {
      final text = notices.readAsStringSync();
      expect(text, contains(About.source.toString()));
      expect(text, contains('three years'));
      expect(text, contains(RegExp(r'<[^@\s>]+@[^@\s>]+>')),
          reason: 'LGPL 2.1 §3(b) is an offer to any third party, so there '
              'has to be somewhere for one to write');
    });

    test('reproduces the copyright line of every bundled face', () {
      // The OFL requires the notice to travel with the font, and a retyped
      // notice is a different notice — so the generator copies the first line
      // of each licence rather than writing one.
      final text = notices.readAsStringSync();
      final licences = Directory('assets/fonts')
          .listSync(followLinks: false)
          .whereType<File>()
          .where((f) => f.uri.pathSegments.last.startsWith('OFL-'));

      expect(licences, isNotEmpty);
      for (final licence in licences) {
        final copyright = licence
            .readAsLinesSync()
            .firstWhere((l) => l.trim().isNotEmpty)
            .trim();
        expect(text, contains(copyright),
            reason: '${licence.path} is bundled and unattributed');
      }
    });
  });

  test('the licence text is the one that came out of the tarball', () {
    // Verbatim, byte for byte. A licence with a line rewrapped by an editor is
    // a modified licence.
    expect(
      lgpl.readAsStringSync(),
      File('../third_party/ffmpeg/COPYING.LGPLv2.1').readAsStringSync(),
    );
  });

  group('what the sheet claims about this build', () {
    test('the version is the one the bundle will call itself', () {
      // `version:` in the pubspec is what reaches CFBundleShortVersionString
      // through FLUTTER_BUILD_NAME. Written twice because reading the plist
      // back would mean a plugin whose whole job is that.
      final declared = RegExp(r'^version:\s*(\S+)$', multiLine: true)
          .firstMatch(File('pubspec.yaml').readAsStringSync())!
          .group(1)!;
      expect(declared.split('+').first, About.version);
    });

    test('the copyright is the one in the bundle', () {
      final xcconfig =
          File('macos/Runner/Configs/AppInfo.xcconfig').readAsStringSync();
      final declared = RegExp(r'^PRODUCT_COPYRIGHT\s*=\s*(.+)$',
              multiLine: true)
          .firstMatch(xcconfig)!
          .group(1)!
          .trim();
      expect(declared, About.copyright);
    });

    test('"no network access at all" is true of the release build', () {
      // The sheet and the notice both say it, and it is the product's loudest
      // promise — "your footage never leaves this machine". A sandboxed app
      // with no network entitlement cannot open a socket, so this is the whole
      // enforcement, and it is one line away from being undone by accident.
      //
      // It is also the reason there is no updater: see About.download. Anything
      // that checked for a new version would need this entitlement, and the
      // claim above is worth more than the notification. DebugProfile has
      // com.apple.security.network.server for the Dart VM service and is not
      // checked here — nothing is shipped from it.
      final entitlements =
          File('macos/Runner/Release.entitlements').readAsStringSync();
      expect(entitlements, contains('com.apple.security.app-sandbox'));
      expect(entitlements, isNot(contains('com.apple.security.network')));
    });

    test('and nothing in the app so much as tries', () {
      // The entitlement is what *stops* it; this is what stops somebody
      // spending an afternoon on an updater before finding out. A socket in
      // here would fail at runtime inside the sandbox, which is a bug report
      // from a user rather than a red test — and outside the sandbox, in a
      // `flutter run`, it would appear to work perfectly.
      const forbidden = [
        'HttpClient',
        'WebSocket',
        'RawSocket',
        'Socket.connect',
        'package:http/',
        'dart:html',
      ];

      final offenders = <String>[];
      for (final file in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final source = file.readAsStringSync();
        for (final needle in forbidden) {
          if (source.contains(needle)) offenders.add('${file.path}: $needle');
        }
      }

      expect(offenders, isEmpty,
          reason: 'vdodtor reaches the network through the browser and in no '
              'other way — see About.download');
    });
  });
}
