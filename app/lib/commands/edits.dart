import '../model/clip.dart';
import '../model/media.dart';
import '../model/project.dart';
import '../model/time.dart';
import '../model/track.dart';
import 'command.dart';

/// Registers a file in the project's media bin. Idempotent.
final class AddMedia extends EditCommand {
  const AddMedia(this.asset);

  final MediaAsset asset;

  @override
  String get label => 'Import media';

  @override
  Project apply(Project project) => project.addMedia(asset);
}

/// Places a clip on a track.
///
/// On a magnetic track the clip is appended and the track repacked, so it
/// lands flush against its neighbour whatever [Clip.start] said. On a
/// free-form track the clip keeps its start and must not overlap.
final class InsertClip extends EditCommand {
  const InsertClip(this.trackId, this.clip);

  final String trackId;
  final Clip clip;

  @override
  String get label => 'Add clip';

  @override
  Project apply(Project project) {
    final track = project.trackById(trackId);
    if (track == null) throw EditException('no track $trackId');
    if (project.clipById(clip.id) != null) {
      throw EditException('clip ${clip.id} is already in the project');
    }
    if (clip.duration.raw <= 0) {
      throw EditException('clip ${clip.id} has non-positive duration');
    }
    if (clip.mediaId != null && !project.media.containsKey(clip.mediaId)) {
      throw EditException('clip ${clip.id} refers to unknown media '
          '${clip.mediaId}; add the media first');
    }

    if (track.isMagnetic) {
      final appended = clip.movedTo(track.duration);
      return project.replaceTrack(track.withClips([...track.clips, appended]));
    }

    for (final existing in track.clips) {
      if (existing.span.overlaps(clip.span)) {
        throw EditException(
            'clip ${clip.id} overlaps ${existing.id} on track $trackId');
      }
    }
    return project.replaceTrack(track.withClips([...track.clips, clip]));
  }
}

/// Slides a clip along its track. Magnetic tracks repack afterwards, which
/// turns a drag past a neighbour into a reorder.
final class MoveClip extends EditCommand {
  const MoveClip(this.clipId, this.newStart);

  final String clipId;
  final Tick newStart;

  @override
  String get label => 'Move clip';

  @override
  Project apply(Project project) {
    final track = project.trackOfClip(clipId);
    if (track == null) throw EditException('no clip $clipId');
    final clip = track.clipById(clipId)!;

    final target = newStart.raw < 0 ? Tick.zero : newStart;
    if (target == clip.start && !track.isMagnetic) return project;

    final moved = clip.movedTo(target);

    if (track.isMagnetic) {
      // The moved clip may overlap its neighbours right now; repackedFrom is
      // what resolves that into an order and closes the lane up.
      final others = track.clips.where((c) => c.id != clipId).toList();
      return project.replaceTrack(track.repackedFrom([...others, moved]));
    }

    for (final other in track.clips) {
      if (other.id == clipId) continue;
      if (other.span.overlaps(moved.span)) return project; // refuse, silently
    }
    final next = track.clips.map((c) => c.id == clipId ? moved : c).toList();
    return project.replaceTrack(track.withClips(next));
  }

  /// A drag is one undo entry: fold consecutive moves of the same clip.
  @override
  EditCommand? mergeWith(EditCommand next) =>
      next is MoveClip && next.clipId == clipId ? next : null;
}

/// Removes a clip. On a magnetic track the gap closes behind it.
final class DeleteClip extends EditCommand {
  const DeleteClip(this.clipId);

  final String clipId;

  @override
  String get label => 'Delete clip';

  @override
  Project apply(Project project) {
    final track = project.trackOfClip(clipId);
    if (track == null) return project;
    final remaining = track.clips.where((c) => c.id != clipId).toList();
    return project.replaceTrack(track.withClips(remaining).repacked());
  }
}

/// Adds an empty track. Used when a drop needs a lane that does not exist yet.
final class AddTrack extends EditCommand {
  const AddTrack(this.track, {this.at});

  final Track track;
  final int? at;

  @override
  String get label => 'Add track';

  @override
  Project apply(Project project) {
    if (project.trackById(track.id) != null) {
      throw EditException('track ${track.id} is already in the project');
    }
    return project.addTrack(track, at: at);
  }
}

/// Mute / lock / hide, and renaming a lane.
final class SetTrackProperties extends EditCommand {
  const SetTrackProperties(
    this.trackId, {
    this.name,
    this.muted,
    this.locked,
    this.hidden,
  });

  final String trackId;
  final String? name;
  final bool? muted;
  final bool? locked;
  final bool? hidden;

  @override
  String get label => 'Change track';

  @override
  Project apply(Project project) => project.updateTrack(
      trackId,
      (t) => t.copyWith(
          name: name, muted: muted, locked: locked, hidden: hidden));
}

final class RenameProject extends EditCommand {
  const RenameProject(this.name);

  final String name;

  @override
  String get label => 'Rename project';

  @override
  Project apply(Project project) =>
      project.name == name ? project : project.copyWith(name: name);

  @override
  EditCommand? mergeWith(EditCommand next) =>
      next is RenameProject ? next : null;
}
