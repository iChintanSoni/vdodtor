import 'dart:io';

/// Where vdodtor keeps its own files.
///
/// Under the App Sandbox `$HOME` is the app's container, so every path here is
/// container-relative in the shipped app and user-relative in a test or an
/// unsandboxed run. That is deliberate: the same code has to work in both, and
/// nothing in this file may ever need a file panel.
final class AppPaths {
  const AppPaths._({
    required this.support,
    required this.library,
    required this.peaks,
    required this.reports,
  });

  /// App-private state: the recents list, the session marker, caches. Nothing
  /// the user is meant to open in Finder.
  final Directory support;

  /// Where new projects are created.
  ///
  /// `~/Movies/vdodtor` when it can be reached, because a video editor's
  /// projects belong with the user's video and the sandbox grants the whole
  /// Movies tree at once — which is what makes the atomic write's sibling
  /// `.tmp` and `.bak` files legal without a single security-scoped bookmark.
  /// A project that lives somewhere the app can always reach is a project that
  /// always reopens; that is worth more in M1 than letting the user file it.
  final Directory library;

  /// Waveform peak files, one per media file the timeline has drawn.
  ///
  /// Under `support` because it is a cache: every file in here is derived from
  /// a media file and can be rebuilt from it, so losing the lot costs some
  /// seconds of decoding and nothing else. It is not in the project folder for
  /// the same reason — two projects using the same music bed should analyse it
  /// once between them, and a project copied to another machine should not
  /// carry megabytes of something that machine can work out for itself.
  final Directory peaks;

  /// Problem reports: what went wrong, written down and sent nowhere.
  ///
  /// Under `support` with the rest of the app's private state, and pointedly
  /// **not** beside [peaks] in spirit even though it is beside it on disk: a
  /// cache may be thrown away by anything that needs the space, and a report
  /// is evidence — it is the only account of a fault that exists anywhere,
  /// because there is no server holding a copy. See `lib/app/crash.dart`.
  final Directory reports;

  File get recentsFile => File('${support.path}/recents.json');
  File get sessionFile => File('${support.path}/session.json');

  /// The Pro licence, if this installation has one.
  ///
  /// Under `support` with the rest of the app's private state, and not in the
  /// project library, because a licence belongs to the machine rather than to
  /// any project — and because a project folder is the thing people copy to a
  /// USB stick and hand to somebody else.
  File get licenceFile => File('${support.path}/licence.key');

  /// Resolves the locations and creates them, falling back to app-private
  /// storage if `~/Movies` cannot be written — a missing library must never
  /// stop the app launching.
  static Future<AppPaths> resolve({
    String? home,
    String appName = 'vdodtor',
  }) async {
    final base = home ?? Platform.environment['HOME'];
    if (base == null || base.isEmpty) {
      throw const FileSystemException('no HOME to resolve app paths from');
    }

    final support = await _canonical(
        await Directory('$base/Library/Application Support/$appName')
            .create(recursive: true));

    Directory library;
    try {
      library =
          await Directory('$base/Movies/$appName').create(recursive: true);
      // Creating it is not the same as being allowed to write in it.
      final probe = File('${library.path}/.writable');
      await probe.writeAsString('', flush: true);
      await probe.delete();
    } on FileSystemException {
      library = await Directory('${support.path}/Projects').create(
        recursive: true,
      );
    }

    return AppPaths._(
      support: support,
      library: await _canonical(library),
      peaks: await Directory('${support.path}/Peaks').create(recursive: true),
      reports:
          await Directory('${support.path}/Reports').create(recursive: true),
    );
  }

  /// The real path, not the route taken to it.
  ///
  /// A sandboxed `$HOME/Movies` is a symlink into the user's actual Movies
  /// folder, so the same project has two spellings — and a recents list keyed
  /// by path would list it twice. It is also the path the user is shown, and
  /// nobody wants to read their container id.
  static Future<Directory> _canonical(Directory dir) async {
    try {
      return Directory(await dir.resolveSymbolicLinks());
    } on FileSystemException {
      return dir;
    }
  }

  @override
  String toString() => 'AppPaths(support: ${support.path}, '
      'library: ${library.path})';
}
