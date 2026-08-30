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

/// Takes a file out of the media bin, and every clip that came from it off
/// the timeline with it.
///
/// The alternative — refusing while clips still refer to it — makes the bin a
/// place things get stuck. Removing the clips too is one undo entry away from
/// being wrong, and undo is right there.
final class RemoveMedia extends EditCommand {
  const RemoveMedia(this.mediaId);

  final String mediaId;

  @override
  String get label => 'Remove media';

  @override
  Project apply(Project project) {
    if (!project.media.containsKey(mediaId)) return project;

    var next = project;
    for (final track in project.tracks) {
      final remaining =
          track.clips.where((c) => c.mediaId != mediaId).toList();
      if (remaining.length == track.clips.length) continue;
      next = next.replaceTrack(track.withClips(remaining).repacked());
    }
    return next.removeMedia(mediaId);
  }
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

/// Moves one edge of a clip without moving the other.
///
/// A trim is not a resize. The head edge takes [Clip.sourceIn] with it, so the
/// frames stay where they were and fewer of them are shown; the tail edge only
/// changes how many. Getting that wrong is the bug where trimming the front of
/// a clip silently shifts every frame in it.
///
/// Both edges are clamped rather than refused: this is what a drag runs on,
/// and a drag that stops at the limit is right where one that snaps back to
/// the start is not. The limits are one frame of length, the source's own
/// extent, and — on a free-form track — the neighbours.
final class TrimClip extends EditCommand {
  const TrimClip(this.clipId, {this.start, this.end});

  final String clipId;

  /// Where the clip's first frame should now sit on the timeline. Null leaves
  /// the head alone.
  final Tick? start;

  /// Where the clip should now end on the timeline. Null leaves the tail
  /// alone.
  final Tick? end;

  @override
  String get label => 'Trim clip';

  @override
  Project apply(Project project) {
    final track = project.trackOfClip(clipId);
    if (track == null) throw EditException('no clip $clipId');
    final clip = track.clipById(clipId)!;
    final minimum = project.ticksPerFrame;

    var next = clip;
    if (start != null) {
      var delta = start!.raw - clip.start.raw;
      // Cannot show frames the source does not have, and cannot trim a clip
      // out of existence.
      if (clip.sourceIn.raw + delta < 0) delta = -clip.sourceIn.raw;
      if (clip.duration.raw - delta < minimum) {
        delta = clip.duration.raw - minimum;
      }
      if (!track.isMagnetic) {
        final floor = _endOfPrevious(track, clip);
        if (clip.start.raw + delta < floor) delta = floor - clip.start.raw;
      } else if (clip.start.raw + delta < 0) {
        delta = -clip.start.raw;
      }
      next = next.trimHeadBy(Tick(delta));
    }

    if (end != null) {
      final head = next;
      var wanted = end!.raw - head.start.raw;
      if (wanted < minimum) wanted = minimum;

      final limit = maxDurationFor(head, project.assetFor(head));
      if (limit.raw > 0 && wanted > limit.raw) wanted = limit.raw;
      if (!track.isMagnetic) {
        final ceiling = _startOfNext(track, clip);
        if (ceiling != null && head.start.raw + wanted > ceiling) {
          wanted = ceiling - head.start.raw;
        }
      }
      if (wanted < minimum) wanted = minimum;
      next = head.copyWith(duration: Tick(wanted));
    }

    if (next == clip) return project;

    final replaced = [
      for (final c in track.clips) c.id == clipId ? next : c,
    ];
    // A magnetic lane has no gaps to leave behind: shortening a clip pulls
    // everything after it back, in the order they already had.
    return project.replaceTrack(track.isMagnetic
        ? track.packedInOrder(replaced)
        : track.withClips(replaced));
  }

  static int _endOfPrevious(Track track, Clip clip) {
    var floor = 0;
    for (final other in track.clips) {
      if (other.id == clip.id) continue;
      if (other.end.raw <= clip.start.raw && other.end.raw > floor) {
        floor = other.end.raw;
      }
    }
    return floor;
  }

  static int? _startOfNext(Track track, Clip clip) {
    int? ceiling;
    for (final other in track.clips) {
      if (other.id == clip.id) continue;
      if (other.start.raw >= clip.end.raw &&
          (ceiling == null || other.start.raw < ceiling)) {
        ceiling = other.start.raw;
      }
    }
    return ceiling;
  }

  /// A trim drag is one undo entry, the same way a move drag is.
  @override
  EditCommand? mergeWith(EditCommand next) =>
      next is TrimClip &&
              next.clipId == clipId &&
              (next.start == null) == (start == null)
          ? next
          : null;
}

/// Cuts a clip in two at [at], leaving both halves where they were.
///
/// The head keeps the id — everything already pointing at this clip keeps
/// pointing at the part that did not move — and the tail is new.
final class SplitClip extends EditCommand {
  const SplitClip(this.clipId, this.at, {required this.newClipId});

  final String clipId;
  final Tick at;
  final String newClipId;

  @override
  String get label => 'Split clip';

  @override
  Project apply(Project project) {
    final track = project.trackOfClip(clipId);
    if (track == null) throw EditException('no clip $clipId');
    if (project.clipById(newClipId) != null) {
      throw EditException('clip $newClipId is already in the project');
    }
    final clip = track.clipById(clipId)!;

    // Snapped, because a cut between two frames is a cut at neither of them
    // and every length downstream inherits the rounding.
    final cut = Timebase.project.snapToFrame(at, project.format.frameRate);
    if (cut <= clip.start || cut >= clip.end) return project;

    final head = clip.copyWith(duration: cut - clip.start);
    final tail = Clip(
      id: newClipId,
      mediaId: clip.mediaId,
      start: cut,
      duration: clip.end - cut,
      sourceIn: clip.sourceTimeAt(cut),
      label: clip.label,
      enabled: clip.enabled,
    );

    final index = track.indexOfClip(clipId);
    final next = List<Clip>.of(track.clips)
      ..[index] = head
      ..insert(index + 1, tail);
    // The two halves exactly fill what the original did, so no lane moves and
    // there is nothing to repack on either kind of track.
    return project.replaceTrack(track.withClips(next));
  }
}

/// Copies a clip and drops the copy in right after the original.
final class DuplicateClip extends EditCommand {
  const DuplicateClip(this.clipId, {required this.newClipId});

  final String clipId;
  final String newClipId;

  @override
  String get label => 'Duplicate clip';

  @override
  Project apply(Project project) {
    final track = project.trackOfClip(clipId);
    if (track == null) throw EditException('no clip $clipId');
    if (project.clipById(newClipId) != null) {
      throw EditException('clip $newClipId is already in the project');
    }
    final clip = track.clipById(clipId)!;
    final copy = clip.copyWith(id: newClipId, start: clip.end);
    final index = track.indexOfClip(clipId);

    if (track.isMagnetic) {
      final next = List<Clip>.of(track.clips)..insert(index + 1, copy);
      // In order, not by centre: the copy belongs next to its original even
      // when it is longer than whatever follows.
      return project.replaceTrack(track.packedInOrder(next));
    }

    // A free-form lane may already have something in that space. Land at the
    // end of the lane rather than refusing — a duplicate that appears
    // somewhere is better than one that appears nowhere and says nothing.
    final overlaps = track.clips.any((c) => c.span.overlaps(copy.span));
    final placed = overlaps ? copy.movedTo(track.duration) : copy;
    return project.replaceTrack(track.withClips([...track.clips, placed]));
  }
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
