// Writes the notice vdodtor ships about the software it did not write, into
// app/assets/notices/.
//
//   dart run tools/make_notices.dart
//
// **Generated rather than written**, for the reason tools/make_luts.dart is:
// every fact in it is a fact about files that are actually on the disk, and a
// notice hand-edited beside a re-vendored library is a notice that says 7.1
// over a 9.0.1. For a look that would be a wrong picture; here it is a licence
// obligation described inaccurately, which is the one kind of staleness that
// is worse than a crash. So the version, the checksum, the library names and
// the configure flags are read out of third_party/ffmpeg — the same directory
// tools/build_ffmpeg.sh writes — and app/test/media/notices_test.dart asserts
// the shipped file still agrees with them.
//
// **It ships inside the app, not only beside it.** LGPL 2.1 §6 wants the user
// given prominent notice and a copy of the licence, and a DMG is a thing
// people throw away the day they mount it. So both files are Flutter assets,
// read by the About sheet — and tools/package_mac.sh copies the same two into
// the disk image as well, because somebody deciding whether to install should
// not have to install first.
//
// Two outputs:
//   app/assets/notices/THIRD_PARTY_NOTICES.md — what is in here and on what terms
//   app/assets/notices/LGPL-2.1.txt           — the licence text itself, verbatim

import 'dart:io';

/// Where somebody gets the exact source these binaries were built from.
///
/// An address we own rather than ffmpeg.org, on `Checkout.buy`'s terms: the
/// tarball URL is named too, and *that* one is the upstream, but a page we
/// control is the one that can still answer in 2031 when a release directory
/// has been reorganised. The offer underneath it is what LGPL 2.1 §3(b) asks
/// for and has to outlive any particular host.
const sourceOffer = 'https://vdodtor.app/source';

/// Who the offer is made by, and where a written request goes. LGPL 2.1 §3(b)
/// is an offer to *any* third party, so this has to be an address that is
/// read by somebody rather than a personal mailbox.
const sourceContact = 'source@vdodtor.app';

void main(List<String> args) {
  final root = Directory.current.path;
  final ffmpeg = Directory('$root/third_party/ffmpeg');
  if (!ffmpeg.existsSync()) {
    stderr.writeln('no vendored FFmpeg at ${ffmpeg.path}. '
        'Run tools/build_ffmpeg.sh, then this from the repository root.');
    exit(1);
  }

  final out = Directory('$root/app/assets/notices')..createSync(recursive: true);
  final build = BuildInfo.read(File('${ffmpeg.path}/BUILD_INFO.txt'));
  final libraries = sharedLibrariesIn(Directory('${ffmpeg.path}/lib'));
  final faces = openFontFacesIn(Directory('$root/app/assets/fonts'));

  File('${out.path}/LGPL-2.1.txt')
      .writeAsStringSync(File('${ffmpeg.path}/COPYING.LGPLv2.1').readAsStringSync());
  File('${out.path}/THIRD_PARTY_NOTICES.md')
      .writeAsStringSync(notices(build, libraries, faces));

  stdout.writeln('wrote ${out.path}/THIRD_PARTY_NOTICES.md '
      '(ffmpeg ${build.version}, ${libraries.length} libraries, '
      '${faces.length} faces)');

  // And the same two files at vdodtor.app/source, because the notice this
  // generator writes *names that address* as where the source is kept — so a
  // page there restating any of this in its own words would be a second copy
  // of a licence obligation, which is the one kind of duplicate worth going
  // to trouble to avoid. The site serves the bytes that shipped.
  final site = Directory('$root/site/source');
  if (site.existsSync()) {
    for (final name in const ['LGPL-2.1.txt', 'THIRD_PARTY_NOTICES.md']) {
      File('${out.path}/$name').copySync('${site.path}/$name');
    }
    stdout.writeln('wrote ${site.path}/THIRD_PARTY_NOTICES.md');
  }
}

/// What `tools/build_ffmpeg.sh` recorded about the build it produced.
class BuildInfo {
  BuildInfo({
    required this.version,
    required this.source,
    required this.sha256,
    required this.licence,
    required this.arches,
    required this.macos,
    required this.configureFlags,
  });

  final String version;
  final String source;
  final String sha256;
  final String licence;
  final String arches;
  final String macos;
  final List<String> configureFlags;

  /// Reads `BUILD_INFO.txt` — `name: value` lines, then a `configure flags:`
  /// block of indented lines. Missing keys are an error rather than an empty
  /// string: a notice with a blank checksum in it looks filled in.
  static BuildInfo read(File file) {
    if (!file.existsSync()) {
      stderr.writeln('no ${file.path}. Run tools/build_ffmpeg.sh.');
      exit(1);
    }
    final lines = file.readAsLinesSync();
    final fields = <String, String>{};
    final flags = <String>[];
    var inFlags = false;
    for (final line in lines) {
      if (line.trim() == 'configure flags:') {
        inFlags = true;
        continue;
      }
      if (inFlags) {
        final flag = line.trim();
        if (flag.isNotEmpty) flags.add(flag);
        continue;
      }
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      fields[line.substring(0, colon).trim()] = line.substring(colon + 1).trim();
    }

    String need(String key) {
      final value = fields[key];
      if (value == null || value.isEmpty) {
        stderr.writeln('${file.path} has no "$key:" line');
        exit(1);
      }
      return value;
    }

    return BuildInfo(
      version: need('version'),
      source: need('source'),
      sha256: need('sha256'),
      licence: need('licence'),
      arches: need('arches'),
      macos: need('macos'),
      configureFlags: flags,
    );
  }
}

/// The libraries that actually get embedded, under the names they are embedded
/// as.
///
/// Symlinks are skipped for the reason the podspec's embed phase skips them:
/// the unversioned names are for the linker and nothing at runtime looks for
/// one, so listing `libavcodec.dylib` in a notice would name a file that is
/// not in the shipped bundle.
List<String> sharedLibrariesIn(Directory lib) {
  final names = lib
      .listSync(followLinks: false)
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      .where((name) => name.endsWith('.dylib'))
      .toList()
    ..sort();
  if (names.isEmpty) {
    stderr.writeln('no dylibs in ${lib.path}. Run tools/build_ffmpeg.sh.');
    exit(1);
  }
  return names;
}

/// One bundled typeface: the file it is in, and the copyright line its licence
/// opens with.
typedef OpenFontFace = ({String file, String copyright});

/// The faces, read off the `OFL-*.txt` files that ship beside them.
///
/// The copyright line comes out of the licence file rather than being written
/// here, because reproducing that exact notice is the OFL's requirement and a
/// retyped one is a different notice. `app/test/media/fonts_test.dart` already
/// makes the file list and the picker agree; this only has to not invent
/// anything.
List<OpenFontFace> openFontFacesIn(Directory fonts) {
  final licences = fonts
      .listSync(followLinks: false)
      .whereType<File>()
      .where((f) => f.uri.pathSegments.last.startsWith('OFL-'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  return [
    for (final licence in licences)
      (
        file: '${licence.uri.pathSegments.last.substring(4).split('.').first}'
            '.ttf',
        copyright: licence
            .readAsLinesSync()
            .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '')
            .trim(),
      ),
  ];
}

String notices(
  BuildInfo ffmpeg,
  List<String> libraries,
  List<OpenFontFace> faces,
) {
  final b = StringBuffer();

  b.writeln('# Third-party software in vdodtor');
  b.writeln();
  b.writeln('This file is generated by `tools/make_notices.dart` from the '
      'libraries and');
  b.writeln('typefaces actually vendored into this build. Everything else in '
      'vdodtor — the');
  b.writeln('editor, the engine, the compositor and the colour looks — is our '
      'own work.');
  b.writeln();
  b.writeln('vdodtor sends nothing anywhere. Nothing listed here changes '
      'that: none of it');
  b.writeln('opens a socket, and the app is built with no network entitlement '
      'at all.');
  b.writeln();

  // ---- FFmpeg ----
  b.writeln('## FFmpeg — GNU Lesser General Public Licence, version 2.1 or '
      'later');
  b.writeln();
  b.writeln('vdodtor uses **unmodified** FFmpeg libraries to read and write '
      'media files.');
  b.writeln('They are **dynamically linked** and ship as separate files '
      'inside the app');
  b.writeln('bundle, which is the arrangement LGPL 2.1 §6(b) describes.');
  b.writeln();
  b.writeln('| | |');
  b.writeln('| --- | --- |');
  b.writeln('| Version | ${ffmpeg.version} |');
  b.writeln('| Source | ${ffmpeg.source} |');
  b.writeln('| SHA-256 | `${ffmpeg.sha256}` |');
  b.writeln('| Licence | ${ffmpeg.licence} |');
  // "min 11.0" is how build_ffmpeg.sh writes it down; "macOS min 11.0 or
  // later" is not a sentence.
  final minimum = ffmpeg.macos.replaceFirst(RegExp(r'^min\s+'), '');
  b.writeln('| Built for | ${ffmpeg.arches}, macOS $minimum or later |');
  b.writeln();
  b.writeln('The libraries, in '
      '`vdodtor.app/Contents/Frameworks/vdodtor_engine.framework/Versions/A/Frameworks`:');
  b.writeln();
  for (final name in libraries) {
    b.writeln('- `$name`');
  }
  b.writeln();

  b.writeln('### Getting the source');
  b.writeln();
  b.writeln('The exact tarball these were built from is the one in the table '
      'above, and its');
  b.writeln('checksum is there so you can be sure you have it. A copy is kept '
      'at');
  b.writeln('<$sourceOffer> alongside the script that built them.');
  b.writeln();
  b.writeln('**Written offer.** For at least three years from the date you '
      'received this');
  b.writeln('copy of vdodtor, we will give any third party, for no more than '
      'the cost of');
  b.writeln('physically performing the distribution, a complete '
      'machine-readable copy of the');
  b.writeln('corresponding source code for the FFmpeg libraries above, under '
      'the terms of');
  b.writeln('LGPL 2.1 §3(b). Write to <$sourceContact>.');
  b.writeln();

  b.writeln('### Rebuilding them, and replacing them');
  b.writeln();
  b.writeln('LGPL 2.1 §6 exists so that you can use a version of the library '
      'you built');
  b.writeln('yourself. These were configured with:');
  b.writeln();
  b.writeln('```');
  b.writeln('./configure \\');
  for (var i = 0; i < ffmpeg.configureFlags.length; i++) {
    final last = i == ffmpeg.configureFlags.length - 1;
    b.writeln('  ${ffmpeg.configureFlags[i]}${last ? '' : ' \\'}');
  }
  b.writeln('```');
  b.writeln();
  b.writeln('Build a replacement with the same `soname` — the install name '
      'must stay');
  b.writeln('`@rpath/<file>` — and copy it over the one in the Frameworks '
      'folder listed');
  b.writeln('above. macOS will refuse to launch an app whose signature no '
      'longer matches its');
  b.writeln('contents, so re-sign the bundle afterwards:');
  b.writeln();
  b.writeln('```');
  b.writeln('codesign --force --deep --sign - /Applications/vdodtor.app');
  b.writeln('```');
  b.writeln();
  b.writeln('That replaces our signature with an ad-hoc one. The app runs; it '
      'is no longer');
  b.writeln('notarized, so the first launch needs the right-click → Open '
      'route.');
  b.writeln();

  b.writeln('### The licence');
  b.writeln();
  b.writeln('The full text of the GNU Lesser General Public Licence 2.1 ships '
      'with vdodtor');
  b.writeln('as `LGPL-2.1.txt`, next to this file, and is shown by the About '
      'sheet.');
  b.writeln();

  // ---- Typefaces ----
  b.writeln('## Typefaces — SIL Open Font Licence 1.1');
  b.writeln();
  b.writeln('The faces a caption can be set in. Each licence ships in the app '
      'bundle beside');
  b.writeln('the font it covers, as the OFL requires.');
  b.writeln();
  for (final face in faces) {
    b.writeln('- **`${face.file}`** — ${face.copyright}');
  }
  b.writeln();
  b.writeln('Reserved Font Names are respected: the files are redistributed '
      'unmodified, under');
  b.writeln('their original names.');
  b.writeln();

  return b.toString();
}
