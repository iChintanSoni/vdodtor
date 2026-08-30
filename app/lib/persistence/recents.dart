import 'dart:convert';
import 'dart:io';

/// One entry in the recent-projects list.
final class RecentProject {
  const RecentProject({
    required this.path,
    required this.name,
    required this.lastOpened,
  });

  final String path;
  final String name;
  final DateTime lastOpened;

  /// False once the file has been moved or deleted. Shown greyed out rather
  /// than quietly dropped, so the user can see what happened to their project.
  bool get stillExists => File(path).existsSync();

  Map<String, Object?> toJson() => {
        'path': path,
        'name': name,
        'lastOpened': lastOpened.toUtc().toIso8601String(),
      };

  static RecentProject? fromJson(Object? json) {
    if (json is! Map) return null;
    final path = json['path'];
    final name = json['name'];
    final opened = DateTime.tryParse(json['lastOpened'] as String? ?? '');
    if (path is! String || name is! String || opened == null) return null;
    return RecentProject(path: path, name: name, lastOpened: opened);
  }

  @override
  String toString() => 'RecentProject($name, $path)';
}

/// The recent-projects list, newest first.
///
/// Backed by a plain JSON file. A corrupt or missing list is treated as empty:
/// losing the recents is a nuisance, and must never stop the app launching.
final class RecentProjects {
  RecentProjects(this.file, {this.limit = 15});

  final File file;
  final int limit;

  Future<List<RecentProject>> load() async {
    if (!file.existsSync()) return const [];
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded) ?RecentProject.fromJson(entry),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Moves [path] to the front, de-duplicating by path.
  Future<List<RecentProject>> record(String path, String name,
      {DateTime? at}) async {
    final entries = await load();
    final next = <RecentProject>[
      RecentProject(path: path, name: name, lastOpened: at ?? DateTime.now()),
      for (final e in entries)
        if (e.path != path) e,
    ];
    final trimmed = next.take(limit).toList();
    await _write(trimmed);
    return trimmed;
  }

  Future<List<RecentProject>> remove(String path) async {
    final next = [
      for (final e in await load())
        if (e.path != path) e,
    ];
    await _write(next);
    return next;
  }

  Future<void> clear() => _write(const []);

  Future<void> _write(List<RecentProject> entries) async {
    if (!file.parent.existsSync()) await file.parent.create(recursive: true);
    await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert([
          for (final e in entries) e.toJson(),
        ]),
        flush: true);
  }
}
