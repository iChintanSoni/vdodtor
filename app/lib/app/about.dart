/// What this build is, and what it is made of.
///
/// Two obligations meet in one small file. The first is ordinary: an app
/// should be able to say which version it is, because "it does not do that on
/// mine" is unanswerable without one. The second is the licence FFmpeg is
/// under — LGPL 2.1 §6 wants the user given prominent notice that the library
/// is in here, a copy of the licence, and the means to build and drop in their
/// own copy of it. That is not a footnote to be satisfied by a line in a
/// README nobody ships: it has to be reachable from the running app, which is
/// what [showAboutSheet] is for.
///
/// The notices themselves are **generated**, by `tools/make_notices.dart`, out
/// of the files actually vendored — see the head of that file for why. This
/// one only says where they are.
library;

import 'package:flutter/services.dart' show rootBundle;

abstract final class About {
  /// The version this build calls itself.
  ///
  /// Written twice — here and as `version:` in `pubspec.yaml`, which is what
  /// reaches `CFBundleShortVersionString` through `FLUTTER_BUILD_NAME` — and
  /// tested once, in `app/test/app/about_test.dart`, on the
  /// `vd_time.c`/`time.dart` arrangement. The alternative is a plugin whose
  /// entire job is to read a plist, in an app that has no other plugins.
  static const version = '1.0.0';

  /// As it appears in `NSHumanReadableCopyright`, and for the same reason as
  /// [version]: `macos/Runner/Configs/AppInfo.xcconfig` has the other copy and
  /// the test makes them agree.
  static const copyright = 'Copyright © 2026 Chintan Soni';

  /// Where the source of the LGPL libraries in here is kept.
  ///
  /// An address we own rather than ffmpeg.org, on [Checkout.buy]'s terms — a
  /// page we control is the one that can still answer in 2031. The exact
  /// upstream tarball and its checksum are named in the notice itself, so this
  /// being unreachable costs a convenience rather than the obligation.
  static final source = Uri.parse('https://vdodtor.app/source');

  /// What is in here that we did not write, and on what terms. Markdown, shown
  /// as it is: this is the file that ships, and a prettier rendering of it
  /// would be a second document to keep true.
  static const noticesAsset = 'assets/notices/THIRD_PARTY_NOTICES.md';

  /// The licence text itself, verbatim from the FFmpeg tarball.
  static const licenceAsset = 'assets/notices/LGPL-2.1.txt';

  /// Reads one of the two, out of the bundle.
  ///
  /// Not cached. This is opened by hand, at most once a session, and holding
  /// twenty-six kilobytes of licence text for the life of the process to save
  /// a read nobody is waiting on is the wrong trade.
  static Future<String> read(String asset) => rootBundle.loadString(asset);
}
