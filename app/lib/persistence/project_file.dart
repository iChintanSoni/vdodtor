import 'dart:async';
import 'dart:io';

import '../model/project.dart';
import '../model/serialization.dart';

/// The extension for a vdodtor project document.
const String kProjectExtension = 'vdodtor';

/// Reads and writes project documents.
///
/// Writes are atomic and keep one generation of backup, because autosave fires
/// constantly and the one thing a video editor may never do is lose the
/// project file. The sequence is: write `.tmp`, flush it to the platter, move
/// the current file aside as `.bak`, rename `.tmp` into place.
final class ProjectFile {
  const ProjectFile(this.path);

  final String path;

  File get file => File(path);
  File get backupFile => File('$path.bak');
  File get _tempFile => File('$path.tmp');

  bool get exists => file.existsSync();

  /// True when the last write did not finish — the temp file outlived it.
  bool get hasInterruptedWrite => _tempFile.existsSync();

  Future<void> save(Project project) async {
    final bytes = encodeProject(project);

    final parent = file.parent;
    if (!parent.existsSync()) await parent.create(recursive: true);

    // Write and fsync before anything touches the real file, so a crash here
    // leaves the previous project intact.
    final handle = await _tempFile.open(mode: FileMode.write);
    try {
      await handle.writeString(bytes);
      await handle.flush();
    } finally {
      await handle.close();
    }

    if (file.existsSync()) {
      if (backupFile.existsSync()) await backupFile.delete();
      await file.rename(backupFile.path);
    }
    await _tempFile.rename(path);
  }

  /// Loads the project, falling back to the backup if the main file is
  /// unreadable. [onRecovered] is called when the fallback was used, so the UI
  /// can say so rather than silently serving older work.
  Future<Project> load({void Function(Object error)? onRecovered}) async {
    Object? primaryError;
    if (file.existsSync()) {
      try {
        return decodeProject(await file.readAsString());
      } on ProjectDecodeException catch (e) {
        primaryError = e;
      } on FileSystemException catch (e) {
        primaryError = e;
      }
    } else {
      primaryError = ProjectDecodeException('no project file at $path');
    }

    if (backupFile.existsSync()) {
      try {
        final recovered = decodeProject(await backupFile.readAsString());
        onRecovered?.call(primaryError);
        return recovered;
      } on ProjectDecodeException {
        // Fall through and report the original failure, which is the more
        // useful one.
      }
    }
    throw primaryError;
  }

  /// Removes the temp file left behind by an interrupted write. The backup is
  /// deliberately kept.
  Future<void> cleanUpInterruptedWrite() async {
    if (_tempFile.existsSync()) await _tempFile.delete();
  }

  @override
  String toString() => 'ProjectFile($path)';
}
