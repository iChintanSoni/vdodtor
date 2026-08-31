import 'dart:io';

import '../commands/command.dart';
import '../commands/document_store.dart';
import '../commands/edits.dart';
import '../engine/media_probe.dart';
import '../model/clip.dart';
import '../model/ids.dart';
import '../model/media.dart';
import '../model/project.dart';
import '../model/time.dart';
import '../model/track.dart';
import 'file_access.dart';

/// A file that would not import, and what to tell the user about it.
final class ImportFailure {
  const ImportFailure(this.path, this.reason);

  final String path;
  final String reason;

  String get displayName => path.split(Platform.pathSeparator).last;
}

/// What an import did.
final class ImportResult {
  const ImportResult({
    this.added = const [],
    this.reused = const [],
    this.clipsPlaced = 0,
    this.failures = const [],
  });

  /// Assets that were not in the bin before.
  final List<MediaAsset> added;

  /// Files already in the bin, matched by path. Re-importing one is not an
  /// error and not a duplicate — it places another clip from the same asset.
  final List<MediaAsset> reused;

  final int clipsPlaced;
  final List<ImportFailure> failures;

  int get importedCount => added.length + reused.length;
  bool get isEmpty => importedCount == 0 && failures.isEmpty;

  /// One line for the editor's notice bar, or null when there is nothing worth
  /// interrupting for.
  String? get notice {
    if (failures.isEmpty) return null;
    if (failures.length == 1) {
      return 'Could not import "${failures.single.displayName}": '
          '${failures.single.reason}';
    }
    return 'Could not import ${failures.length} files — '
        '${failures.first.displayName} and ${failures.length - 1} others.';
  }
}

/// Extensions worth probing when a *folder* is dropped.
///
/// Files the user picked or dropped individually are not filtered by this —
/// the platform already asked for media types, and second-guessing an explicit
/// choice by its extension is how an editor ends up refusing a file it can
/// play perfectly well. This list exists only so dropping a folder does not
/// probe every PDF in it.
const Set<String> importableExtensions = {
  '.mp4', '.mov', '.m4v', '.avi', '.mkv', '.webm', '.mpg', '.mpeg', '.mts',
  '.m2ts', '.3gp', '.hevc', //
  '.mp3', '.m4a', '.aac', '.wav', '.aiff', '.aif', '.flac', '.ogg', '.opus',
  '.caf', //
  '.jpg', '.jpeg', '.png', '.heic', '.gif', '.webp', '.tiff', '.tif', '.bmp',
  // An APNG is usually called .png, and is told apart from a still by its
  // codec rather than by its name — but the explicit extension exists too and
  // a drop that skipped it would be a file the editor can play perfectly well
  // and would not look at.
  '.apng',
};

/// Where an animated overlay lands: contained, and at a size that reads as an
/// overlay rather than as a backdrop.
///
/// **Never blur-filled**, which is the default every other clip gets. Blur-fill
/// exists to fill the bars beside a picture that does not reach the edges of
/// the frame, and a sticker's "bars" are the transparency it was chosen for —
/// so the default would paint a blurred copy of the sticker across the whole
/// shot and hide the very thing it is an overlay on.
///
/// Contained alone would still fill the frame's height, because that is what
/// containing a square in a landscape frame means. Two fifths of it is small
/// enough to be an overlay and big enough to see, and everything after the
/// first impression is a drag in the inspector.
const stickerTransform = ClipTransform(fit: ClipFit.contain, scale: 0.4);

/// How long a lengthless clip lasts when it lands on the timeline. A picture
/// has no duration of its own and a sticker's own length is not a limit on it,
/// so something has to be picked; five seconds is long enough to read and short
/// enough to trim down rather than up.
const Duration stillImageDuration = Duration(seconds: 5);

/// Turns files the user handed over into media assets and clips on the
/// timeline.
///
/// The whole of an import is one gesture, so it is one undo entry: dropping
/// eight clips and pressing ⌘Z puts the project back where it was, rather than
/// removing the eighth clip.
final class MediaImporter {
  MediaImporter({
    required this.prober,
    required this.access,
    IdGen? ids,
  }) : _ids = ids ?? IdGen();

  final MediaProber prober;
  final FileAccess access;
  final IdGen _ids;

  /// Imports [files] into [store]'s project.
  ///
  /// Directories are expanded to the media files immediately inside them —
  /// not recursively, because a drop should do the obvious thing and "the
  /// obvious thing" stops at one level.
  Future<ImportResult> import(
    DocumentStore store,
    List<GrantedFile> files, {
    bool placeOnTimeline = true,
  }) async {
    final expanded = await _expand(files);
    if (expanded.isEmpty) return const ImportResult();

    // Probe before touching the document: an import that half-applies and
    // then throws is worse than one that does nothing.
    final outcomes = await prober.probeAll([for (final f in expanded) f.path]);
    final probes = {
      for (final outcome in outcomes) outcome.path: outcome,
    };

    final added = <MediaAsset>[];
    final reused = <MediaAsset>[];
    final failures = <ImportFailure>[];
    var placed = 0;

    store.endGesture();
    for (final file in expanded) {
      final outcome = probes[file.path];
      if (outcome == null || outcome.probe == null) {
        failures.add(ImportFailure(
            file.path, outcome?.error ?? 'the engine did not answer'));
        continue;
      }
      final probe = outcome.probe!;
      if (!probe.hasVideo && !probe.hasAudio) {
        failures.add(ImportFailure(file.path, 'nothing playable inside'));
        continue;
      }

      final existing = _assetForPath(store.project, file.path);
      final asset = existing ??
          MediaAsset(
            id: _ids.next('m-'),
            path: file.path,
            displayName: _displayName(file.path),
            probe: probe,
            bookmark: file.bookmark,
          );

      if (existing == null) {
        store.run(AddMedia(asset));
        added.add(asset);
      } else {
        reused.add(asset);
      }

      if (!placeOnTimeline) continue;
      try {
        if (place(store, asset)) placed++;
      } on EditException catch (error) {
        // The asset is in the bin either way; only the placement failed, and
        // the user can drag it out of the bin themselves.
        failures.add(ImportFailure(file.path, error.message));
      }
    }
    store.endGesture();

    return ImportResult(
      added: added,
      reused: reused,
      clipsPlaced: placed,
      failures: failures,
    );
  }

  /// Appends a clip for [asset] to whichever track can hold it: video and
  /// stills go on the main track, animated overlays on an overlay track, and
  /// audio-only files on the audio track. Returns false when the project has
  /// no lane for it and none may be made.
  ///
  /// Public because the media bin places assets that were imported in an
  /// earlier session, and it should do it exactly the way import does.
  bool place(DocumentStore store, MediaAsset asset) {
    final project = store.project;
    // A sticker is an overlay, which is the whole reason it is worth telling
    // apart from video. On the magnetic main lane it would repack the footage
    // around it and then composite underneath it — two surprises for one drop
    // — where the thing somebody dropped a GIF to get is one *over* the shot.
    final kind = switch (asset.probe.kind) {
      MediaKind.audio => TrackKind.audio,
      MediaKind.sticker => TrackKind.overlay,
      MediaKind.video || MediaKind.image => TrackKind.main,
    };

    var track = _trackOfKind(project, kind);
    Track? created;
    if (track == null) {
      // Only overlays are missing from a new project, and a sticker with
      // nowhere to land would be a drop that appeared to do nothing. The lane
      // goes in with the clip as one command rather than as an AddTrack before
      // it, so undoing the clip cannot leave an empty lane behind — the same
      // thing InsertClips.newTracks does for the first caption in a project.
      if (kind != TrackKind.overlay ||
          !project.canAddTrackOfKind(TrackKind.overlay)) {
        return false;
      }
      created = Track.of(
        id: _ids.next('tr-'),
        kind: TrackKind.overlay,
        name: 'Overlay ${project.trackCountOfKind(TrackKind.overlay) + 1}',
      );
      track = created;
    }

    // A sticker loops, so the length of one loop is not a length anybody is
    // stuck with — and using it would make a half-second GIF a clip too short
    // to see. It gets what every other lengthless thing gets.
    final duration = asset.probe.kind.isEndless || asset.probe.duration.raw == 0
        ? project.timebase
            .fromSeconds(Rational(stillImageDuration.inMilliseconds, 1000))
        : asset.probe.duration;

    store.run(InsertClips(
      [
        (
          trackId: track.id,
          clip: Clip(
            id: _ids.next('c-'),
            mediaId: asset.id,
            // The main track is magnetic and appends whatever this says; the
            // others are not, so they have to be told where the end is.
            start: track.isMagnetic ? Tick.zero : track.duration,
            duration: duration,
            label: asset.displayName,
            transform: asset.probe.kind == MediaKind.sticker
                ? stickerTransform
                : ClipTransform.identity,
          ),
          index: null,
        ),
      ],
      label: 'Import',
      newTracks: created == null ? const [] : [created],
    ));
    return true;
  }

  static Track? _trackOfKind(Project project, TrackKind kind) {
    for (final track in project.tracks) {
      if (track.kind == kind && !track.locked) return track;
    }
    return null;
  }

  static MediaAsset? _assetForPath(Project project, String path) {
    for (final asset in project.media.values) {
      if (asset.path == path) return asset;
    }
    return null;
  }

  /// Expands folders, drops duplicates, and makes sure every file carries a
  /// bookmark if one can be had.
  Future<List<GrantedFile>> _expand(List<GrantedFile> files) async {
    final out = <GrantedFile>[];
    final seen = <String>{};

    Future<void> take(GrantedFile file) async {
      if (!seen.add(file.path)) return;
      // A file inside a dropped folder arrives without one of its own; the
      // drop granted access to the folder's contents, so this is the moment
      // it can be minted.
      final bookmark = file.bookmark ?? await access.bookmark(file.path);
      out.add(GrantedFile(path: file.path, bookmark: bookmark));
    }

    for (final file in files) {
      final directory = Directory(file.path);
      if (!directory.existsSync()) {
        await take(file);
        continue;
      }

      final children = directory
          .listSync(followLinks: false)
          .whereType<File>()
          .where((f) => importableExtensions.contains(_extension(f.path)))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final child in children) {
        await take(GrantedFile(path: child.path));
      }
    }
    return out;
  }

  static String _extension(String path) {
    final name = _displayName(path);
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? '' : name.substring(dot).toLowerCase();
  }

  static String _displayName(String path) {
    final parts = path.split(Platform.pathSeparator);
    return parts.isEmpty ? path : parts.last;
  }
}
