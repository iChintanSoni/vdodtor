import 'dart:io';

import 'project_file.dart';

/// One project file, as the chooser sees it.
///
/// The name comes from the file name rather than from the document, because
/// listing the library must not mean decoding every project in it. Creation
/// keeps the two in step, and the recents list carries the document's own name
/// for anything opened from elsewhere.
final class LibraryEntry {
  const LibraryEntry({
    required this.path,
    required this.name,
    required this.modified,
  });

  final String path;
  final String name;
  final DateTime modified;

  @override
  String toString() => 'LibraryEntry($name, $path)';
}

/// The folder new projects are created in.
final class ProjectLibrary {
  const ProjectLibrary(this.directory);

  final Directory directory;

  /// Every project in the library, most recently written first. A library that
  /// cannot be read lists as empty rather than throwing: the chooser still has
  /// a New Project button, and that is the more useful failure.
  List<LibraryEntry> list() {
    if (!directory.existsSync()) return const [];

    final entries = <LibraryEntry>[];
    try {
      for (final file in directory.listSync().whereType<File>()) {
        if (!file.path.endsWith('.$kProjectExtension')) continue;
        entries.add(LibraryEntry(
          path: file.path,
          name: nameOfFile(file.path),
          modified: file.statSync().modified,
        ));
      }
    } on FileSystemException {
      return const [];
    }

    entries.sort((a, b) => b.modified.compareTo(a.modified));
    return entries;
  }

  /// A free path for a project called [name], numbered if that name is taken,
  /// so creating "Untitled" twice never overwrites the first one.
  String pathFor(String name) {
    final base = fileNameFor(name);
    var candidate = '${directory.path}/$base.$kProjectExtension';
    for (var n = 2; File(candidate).existsSync(); n++) {
      candidate = '${directory.path}/$base $n.$kProjectExtension';
    }
    return candidate;
  }

  /// The document name a project file's name implies.
  static String nameOfFile(String path) {
    final base = path.split(Platform.pathSeparator).last;
    return base.endsWith('.$kProjectExtension')
        ? base.substring(0, base.length - kProjectExtension.length - 1)
        : base;
  }

  /// Turns a project name into something a file system will accept, keeping it
  /// recognisable: the user typed this name and has to find it in Finder.
  static String fileNameFor(String name) {
    final cleaned = name
        .replaceAll(RegExp(r'[/\\:\x00-\x1f]'), '-')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    // A leading dot hides the file, and a name made only of separators has
    // been reduced to dashes by now — neither is a name anyone typed.
    final safe = cleaned.replaceAll(RegExp(r'^[.\-\s]+|[\-\s]+$'), '');
    if (safe.isEmpty) return 'Untitled';
    return safe.length <= 60 ? safe : safe.substring(0, 60).trim();
  }
}
