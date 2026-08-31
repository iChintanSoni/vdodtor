import 'package:flutter/services.dart' show rootBundle;
import 'package:vdodtor_engine/vdodtor_engine.dart';

/// One bundled face: the family name a caption stores, and the file it lives
/// in.
typedef BundledFont = ({String family, String asset});

/// The typefaces the app ships, handed to the engine so it can draw with them.
///
/// The files are bundled rather than taken from the machine, so a project made
/// on one computer opens looking the same on another. That only works if the
/// engine and Flutter draw with the *same files*: `pubspec.yaml` declares each
/// one twice — once under `fonts:` so the inspector can preview a face, once
/// under `assets:` so [rootBundle] can hand the bytes to the engine — and both
/// entries name the same path.
///
/// Registration is by bytes rather than by path because the only address these
/// have inside a signed app bundle is an asset key. It is per process, and it
/// goes into the engine's own catalogue rather than into the machine's font
/// list: running vdodtor must not change which fonts the computer has.
abstract final class BundledFonts {
  /// Every face, in the order a font picker should offer them. Each does a job
  /// the others cannot: a workhorse sans, a poster face, a serif, a script and
  /// a monospace.
  ///
  /// All five are SIL Open Font Licence; the licences ship beside them in
  /// `assets/fonts/`. A face whose licence does not allow bundling has no
  /// business in a product sold without an account.
  ///
  /// The family names are written here as well as being inside the files,
  /// which is a duplication with a reason: the picker has to list the faces
  /// before the engine exists — a widget test has no engine at all — and
  /// asking the engine at build time makes the inspector unbuildable without
  /// one. [load] asserts the two agree, and `vd_text_test.c` checks each file
  /// reports the name claimed for it here.
  static const faces = <BundledFont>[
    (family: 'Inter', asset: 'assets/fonts/Inter.ttf'),
    (family: 'Anton', asset: 'assets/fonts/Anton.ttf'),
    (family: 'Playfair Display', asset: 'assets/fonts/PlayfairDisplay.ttf'),
    (family: 'Caveat', asset: 'assets/fonts/Caveat.ttf'),
    (family: 'Space Mono', asset: 'assets/fonts/SpaceMono.ttf'),
  ];

  /// What a caption uses when nobody has picked a face. First in the list
  /// because it is the one that reads at every size.
  static const defaultFamily = 'Inter';

  static List<String> get families => [for (final f in faces) f.family];
  static List<String> get assets => [for (final f in faces) f.asset];

  static bool _loaded = false;

  /// Registers every bundled face with the engine, once per process.
  ///
  /// Idempotent, because a hot restart runs it again and the engine's own
  /// catalogue drops the repeats. Awaited before the first project opens: a
  /// caption drawn before its face is registered would silently fall back to
  /// the system's, and re-registering afterwards would not redraw it.
  static Future<void> load() async {
    if (_loaded) return;
    for (final face in faces) {
      final data = await rootBundle.load(face.asset);
      TextFonts.register(data.buffer.asUint8List());
    }
    _loaded = true;

    // What the files actually call themselves, against what this file claims
    // they do. A mismatch means every caption set in that face silently draws
    // in the system font, which is a bug that looks like a design decision.
    assert(() {
      final registered = TextFonts.families;
      for (final face in faces) {
        if (!registered.contains(face.family)) {
          throw StateError('${face.asset} does not report the family '
              '"${face.family}"; the engine registered $registered');
        }
      }
      return true;
    }());
  }
}
