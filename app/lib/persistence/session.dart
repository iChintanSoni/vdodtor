import 'dart:convert';
import 'dart:io';

/// Detects that the previous run ended without a clean shutdown.
///
/// The marker is written when a project is opened and deleted on quit. Finding
/// one at launch means the app died with that project open. Because autosave
/// commits every edit, recovery is simply "reopen it" — the marker exists so
/// the app can say what happened instead of pretending nothing did.
final class SessionMarker {
  const SessionMarker(this.file);

  final File file;

  bool get exists => file.existsSync();

  Future<void> open(String projectPath) async {
    if (!file.parent.existsSync()) await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'projectPath': projectPath,
        'openedAt': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
  }

  /// The project that was open when the app died, or null if the previous run
  /// exited cleanly (or the marker is unreadable).
  Future<String?> unfinishedProjectPath() async {
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      final path = (decoded as Map)['projectPath'];
      return path is String ? path : null;
    } catch (_) {
      return null;
    }
  }

  /// Marks a clean shutdown.
  Future<void> close() async {
    if (file.existsSync()) await file.delete();
  }
}
