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
/// Changes where a clip sits inside the frame.
///
/// One command for the whole transform rather than one per property: the
/// inspector's controls are dragged, and a drag has to be one undo entry.
/// Merging on the clip id alone means a run of nudges to *any* of the fields
/// folds together, which is what someone adjusting a shot actually does.
final class SetClipTransform extends EditCommand {
  const SetClipTransform(this.clipId, this.transform);

  final String clipId;
  final ClipTransform transform;

  @override
  String get label => 'Adjust clip';

  @override
  Project apply(Project project) {
    final track = project.trackOfClip(clipId);
    if (track == null) throw EditException('no clip $clipId');
    final clip = track.clipById(clipId)!;
    if (clip.transform == transform) return project;

    return project.replaceTrack(track.withClips([
      for (final c in track.clips)
        c.id == clipId ? c.copyWith(transform: transform) : c,
    ]));
  }

  @override
  EditCommand? mergeWith(EditCommand next) =>
      next is SetClipTransform && next.clipId == clipId ? next : null;
}

/// Sets a clip's volume, mute and fades.
///
/// The audio counterpart of [SetClipTransform], and merged the same way: a
/// drag on the volume fader is one decision however many values it passes
/// through, and so is a run across the fader and then the fade fields.
final class SetClipAudio extends EditCommand {
  const SetClipAudio(this.clipId, this.audio);

  final String clipId;
  final ClipAudio audio;

  @override
  String get label => 'Adjust audio';

  @override
  Project apply(Project project) {
    final track = project.trackOfClip(clipId);
    if (track == null) throw EditException('no clip $clipId');
    final clip = track.clipById(clipId)!;
    // Clamped against this clip's own length, so no fader can ask for a fade
    // longer than the clip it is on.
    final next = audio.clampedTo(clip.duration);
    if (clip.audio == next) return project;

    return project.replaceTrack(track.withClips([
      for (final c in track.clips)
        c.id == clipId ? c.copyWith(audio: next) : c,
    ]));
  }

  @override
  EditCommand? mergeWith(EditCommand next) =>
      next is SetClipAudio && next.clipId == clipId ? next : null;
}

/// Changes what a caption says and how it looks.
///
/// The third of the trio with [SetClipTransform] and [SetClipAudio], merged
/// the same way: typing into the text field and then dragging the size slider
/// is one decision about one caption, and splitting it into an undo entry per
/// keystroke would make ⌘Z useless exactly where it is needed most.
///
/// A clip that is not a caption is refused rather than quietly given one. The
/// two kinds of clip are exclusive, and a command that could turn a video clip
/// into a text clip is a command that will.
final class SetClipText extends EditCommand {
  const SetClipText(this.clipId, this.text);

  final String clipId;
  final ClipText text;

  @override
  String get label => 'Edit text';

  @override
  Project apply(Project project) {
    final track = project.trackOfClip(clipId);
    if (track == null) throw EditException('no clip $clipId');
    final clip = track.clipById(clipId)!;
    if (!clip.isText) throw EditException('clip $clipId is not a caption');

    final next = text.clamped();
    if (clip.text == next) return project;

    return project.replaceTrack(track.withClips([
      for (final c in track.clips)
        c.id == clipId ? c.copyWith(text: next) : c,
    ]));
  }

  @override
  EditCommand? mergeWith(EditCommand next) =>
      next is SetClipText && next.clipId == clipId ? next : null;
}

/// Changes what a shape looks like.
///
/// [SetClipText] for the other thing the app draws, refusing a clip that is
/// not a shape for the same reason and merged on the clip id the same way:
/// picking a corner radius and then dragging the width is one decision about
/// one shape.
final class SetClipShape extends EditCommand {
  const SetClipShape(this.clipId, this.shape);

  final String clipId;
  final ClipShape shape;

  @override
  String get label => 'Edit shape';

  @override
  Project apply(Project project) {
    final track = project.trackOfClip(clipId);
    if (track == null) throw EditException('no clip $clipId');
    final clip = track.clipById(clipId)!;
    if (!clip.isShape) throw EditException('clip $clipId is not a shape');

    final next = shape.clamped();
    if (clip.shape == next) return project;

    return project.replaceTrack(track.withClips([
      for (final c in track.clips)
        c.id == clipId ? c.copyWith(shape: next) : c,
    ]));
  }

  @override
  EditCommand? mergeWith(EditCommand next) =>
      next is SetClipShape && next.clipId == clipId ? next : null;
}

/// Changes how a clip joins the one before it.
///
/// On the *incoming* clip, because that is where a transition is written down
/// — see [ClipTransition]. Merged on the clip id like the rest of the set, so
/// picking a preset and then dragging its length is one decision about one cut.
///
/// Applies to any clip. A transition on a clip that does not abut another does
/// nothing at all rather than being refused: a clip is dragged away from its
/// neighbour and back again all the time, and a transition that had to be
/// re-picked every time it lost its cut would be a setting nobody trusts.
final class SetClipTransition extends EditCommand {
  const SetClipTransition(this.clipId, this.transition);

  final String clipId;
  final ClipTransition transition;

  @override
  String get label => 'Set transition';

  @override
  Project apply(Project project) {
    final track = project.trackOfClip(clipId);
    if (track == null) throw EditException('no clip $clipId');
    final clip = track.clipById(clipId)!;

    // Bounded by the two clips it joins: half the window sits on each side, so
    // the longest it may be is twice the shorter neighbour. The clip before it
    // is whatever ends exactly where this one starts — and when there is none,
    // only this clip's own length bounds it.
    final index = track.indexOfClip(clipId);
    final previous = index > 0 ? track.clips[index - 1] : null;
    final before = previous != null && previous.end == clip.start
        ? previous.duration
        : clip.duration;
    final next = transition.clamped().clampedBetween(before, clip.duration);
    if (clip.transition == next) return project;

    return project.replaceTrack(track.withClips([
      for (final c in track.clips)
        c.id == clipId ? c.copyWith(transition: next) : c,
    ]));
  }

  @override
  EditCommand? mergeWith(EditCommand next) =>
      next is SetClipTransition && next.clipId == clipId ? next : null;
}

/// Changes how a clip arrives and how it leaves.
///
/// The fifth of the set with [SetClipTransform], [SetClipAudio],
/// [SetClipText] and [SetClipShape], merged on the clip id the same way:
/// picking a preset and then dragging its length is one decision about one
/// clip.
///
/// Unlike the other three this applies to *any* clip. An animation is the
/// transform the clip already has, over time, so there is nothing about it
/// that only a caption can do — and a photo that pops in is a thing people
/// ask for. The typewriter is the exception, and it is one the engine handles
/// by drawing nothing different on a clip that has no text.
final class SetClipAnimation extends EditCommand {
  const SetClipAnimation(this.clipId, this.animation);

  final String clipId;
  final ClipAnimation animation;

  @override
  String get label => 'Animate clip';

  @override
  Project apply(Project project) {
    final track = project.trackOfClip(clipId);
    if (track == null) throw EditException('no clip $clipId');
    final clip = track.clipById(clipId)!;
    // Clamped against this clip's own length, so no picker can ask for an
    // entrance longer than the clip it is on.
    final next = animation.clampedTo(clip.duration);
    if (clip.animation == next) return project;

    return project.replaceTrack(track.withClips([
      for (final c in track.clips)
        c.id == clipId ? c.copyWith(animation: next) : c,
    ]));
  }

  @override
  EditCommand? mergeWith(EditCommand next) =>
      next is SetClipAnimation && next.clipId == clipId ? next : null;
}

/// One video clip's sound, lifted onto an audio lane as a clip of its own.
///
/// Two edits that have to be one: the new audio clip appears *and* the video
/// clip it came from goes silent. Apart, the intermediate state plays
/// everything twice, and undo would take two presses to get back from an edit
/// that felt like one.
///
/// The video clip is muted rather than stripped, because there is nothing to
/// strip — a clip is a window onto a file, and the file still has the sound in
/// it. That is also what makes the edit reversible by hand: unmute the
/// original and delete the detached clip.
typedef AudioDetachment = ({String fromClipId, String toTrackId, Clip clip});

final class DetachAudio extends EditCommand {
  const DetachAudio(this.detachments, {this.newTracks = const []});

  final List<AudioDetachment> detachments;

  /// Lanes to make before placing anything, when the ones that exist have no
  /// room. Passed in rather than invented here, so that detaching four
  /// overlapping clips at once stays a single undo entry instead of an
  /// AddTrack the user has to press ⌘Z through on the way back.
  final List<Track> newTracks;

  @override
  String get label =>
      detachments.length == 1 ? 'Detach audio' : 'Detach audio from '
          '${detachments.length} clips';

  @override
  Project apply(Project project) {
    if (detachments.isEmpty) return project;

    var next = project;
    for (final track in newTracks) {
      next = AddTrack(track).apply(next);
    }

    for (final d in detachments) {
      final source = next.clipById(d.fromClipId);
      if (source == null) throw EditException('no clip ${d.fromClipId}');
      final asset = next.assetFor(source);
      if (asset == null || !asset.probe.hasAudio) {
        throw EditException('clip ${d.fromClipId} has no sound to detach');
      }
      final to = next.trackById(d.toTrackId);
      if (to == null) throw EditException('no track ${d.toTrackId}');
      if (to.kind != TrackKind.audio) {
        throw EditException('${d.toTrackId} is not an audio lane');
      }
    }

    // Mute the originals first. Doing it after the insert would work too, but
    // this way the project is never momentarily louder than it started.
    for (final d in detachments) {
      final track = next.trackOfClip(d.fromClipId)!;
      next = next.replaceTrack(track.withClips([
        for (final c in track.clips)
          c.id == d.fromClipId
              ? c.copyWith(audio: c.audio.copyWith(muted: true))
              : c,
      ]));
    }

    return InsertClips(
      [for (final d in detachments) (trackId: d.toTrackId, clip: d.clip, index: null)],
      label: label,
    ).apply(next);
  }
}

/// Puts a clip somewhere: along its lane, and — with [toTrackId] — onto a
/// different one.
///
/// One command for both axes rather than two, because a drag moves in both at
/// once and two commands would coalesce into two undo entries for one gesture.
///
/// Magnetic tracks repack afterwards, which turns a drag past a neighbour into
/// a reorder.
final class MoveClip extends EditCommand {
  const MoveClip(this.clipId, this.newStart, {this.toTrackId});

  final String clipId;
  final Tick newStart;

  /// The lane the clip should end up on. Null leaves it where it is.
  final String? toTrackId;

  @override
  String get label => 'Move clip';

  @override
  Project apply(Project project) {
    final from = project.trackOfClip(clipId);
    if (from == null) throw EditException('no clip $clipId');
    final clip = from.clipById(clipId)!;
    final target = newStart.raw < 0 ? Tick.zero : newStart;

    if (toTrackId != null && toTrackId != from.id) {
      return _moveAcross(project, from, clip, target);
    }

    if (target == clip.start && !from.isMagnetic) return project;
    final moved = clip.movedTo(target);

    if (from.isMagnetic) {
      // The moved clip may overlap its neighbours right now; repackedFrom is
      // what resolves that into an order and closes the lane up.
      final others = from.clips.where((c) => c.id != clipId).toList();
      return project.replaceTrack(from.repackedFrom([...others, moved]));
    }

    for (final other in from.clips) {
      if (other.id == clipId) continue;
      if (other.span.overlaps(moved.span)) return project; // refuse, silently
    }
    final next = from.clips.map((c) => c.id == clipId ? moved : c).toList();
    return project.replaceTrack(from.withClips(next));
  }

  Project _moveAcross(Project project, Track from, Clip clip, Tick target) {
    final to = project.trackById(toTrackId!);
    if (to == null) throw EditException('no track $toTrackId');
    if (!accepts(to, project.assetFor(clip),
        from: from.kind, isGenerated: clip.isGenerated)) {
      return project;
    }

    final moved = clip.movedTo(target);
    final emptied = from
        .withClips(from.clips.where((c) => c.id != clipId).toList())
        .repacked();
    var next = project.replaceTrack(emptied);

    final destination = next.trackById(to.id)!;
    if (destination.isMagnetic) {
      return next.replaceTrack(
          destination.repackedFrom([...destination.clips, moved]));
    }
    // A free-form lane will not take an overlapping clip. Refusing the whole
    // move keeps the clip where it was, which reads as the lane declining it
    // rather than as the clip disappearing.
    for (final other in destination.clips) {
      if (other.span.overlaps(moved.span)) return project;
    }
    next = next
        .replaceTrack(destination.withClips([...destination.clips, moved]));
    return next;
  }

  /// Whether a clip coming from a lane of kind [from] could land on [track].
  ///
  /// Sound goes on audio lanes and pictures go on visual ones. The asymmetry
  /// worth knowing is on the audio side: a lane there takes anything that
  /// *makes a sound*, but only from another audio lane or from a file with no
  /// picture. A video clip dragged down onto an audio lane would throw its
  /// picture away without saying so, and [DetachAudio] is how that gets asked
  /// for on purpose.
  ///
  /// Which is why [from] has to be here at all: after a detach, an audio lane
  /// holds a clip whose *file* still has video, and it has to be free to move
  /// between the six audio lanes like anything else.
  ///
  /// A drawn clip is decided by [isGenerated] rather than by having no asset,
  /// because those are different reasons to have none: a caption or a shape
  /// belongs on a text lane and nowhere else, where a clip whose media is
  /// merely missing is still a video clip and still belongs where video goes.
  static bool accepts(Track track, MediaAsset? asset,
      {TrackKind from = TrackKind.main, bool isGenerated = false}) {
    if (track.locked) return false;
    // Both ways round: a drawn clip may only land on a text lane, and a text
    // lane may only hold drawn ones. A caption on the magnetic main lane would
    // repack the video around it and then composite underneath it, which is
    // two surprises for one drag.
    //
    // A shape shares the lane rather than getting lanes of its own. It is the
    // same kind of thing — no file, drawn by the engine, wants to sit over the
    // picture — and a second family of lanes would mean a second cap to keep
    // in step with VD_MAX_LAYERS for no difference anybody could see.
    if (isGenerated || track.kind == TrackKind.text) {
      return isGenerated && track.kind == TrackKind.text;
    }
    if (asset == null) return track.kind.isVisual;
    if (track.kind.isVisual) return asset.probe.hasVideo;
    if (!asset.probe.hasAudio) return false;
    return from == TrackKind.audio || !asset.probe.hasVideo;
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

    // Both halves keep everything the clip had. A tail that came back at full
    // volume, unfaded and untransformed would make splitting a destructive
    // edit to properties the cut had nothing to do with.
    //
    // The fades are the one thing that has to be divided rather than copied:
    // each half keeps the fade at the end it still has, because a fade in on
    // the tail would be a ramp out of the middle of a continuous sound. The
    // volume line is copied whole to both, and needs no dividing at all —
    // being measured in the source, each half already reads the part of the
    // curve its own window lands on.
    final headDuration = cut - clip.start;
    final tailDuration = clip.end - cut;
    final head = clip.copyWith(
      duration: headDuration,
      audio: clip.audio.copyWith(fadeOut: Tick.zero).clampedTo(headDuration),
      animation: clip.animation
          .copyWith(outPreset: AnimationPreset.none, outDuration: Tick.zero)
          .clampedTo(headDuration),
    );
    final tail = Clip(
      id: newClipId,
      mediaId: clip.mediaId,
      start: cut,
      duration: tailDuration,
      sourceIn: clip.sourceTimeAt(cut),
      label: clip.label,
      enabled: clip.enabled,
      transform: clip.transform,
      audio: clip.audio.copyWith(fadeIn: Tick.zero).clampedTo(tailDuration),
      // The animations divide the way the fades do: each half keeps the one
      // at the end it still has. An entrance on the tail would be the clip
      // arriving in the middle of itself.
      animation: clip.animation
          .copyWith(inPreset: AnimationPreset.none, inDuration: Tick.zero)
          .clampedTo(tailDuration),
      // A caption or a shape is copied whole, like the transform. Neither
      // varies with time, so both halves draw the same thing — and a tail
      // that lost its words would be a cut that deleted them.
      text: clip.text,
      shape: clip.shape,
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

/// Where a clip is going: which lane, and — on a magnetic lane, where order is
/// the only thing that decides position — which slot in it.
typedef ClipPlacement = ({String trackId, Clip clip, int? index});

/// Puts ready-made clips onto tracks.
///
/// The one command behind paste and duplicate. It is deliberately incurious:
/// the caller has already decided what the clips are, which lane each goes on
/// and where in the order it lands, so nothing here has to guess what the
/// gesture meant. That is what lets paste-at-the-playhead and
/// duplicate-in-place share an implementation instead of drifting apart.
///
/// On a magnetic lane [ClipPlacement.index] is a slot in the lane's *current*
/// order and the lane repacks around it. On a free-form lane the clip keeps
/// its own start, and moves to the end of the lane if that space is taken —
/// a clip that appears somewhere beats one that appears nowhere and says
/// nothing.
final class InsertClips extends EditCommand {
  const InsertClips(this.placements,
      {this.label = 'Paste', this.newTracks = const []});

  final List<ClipPlacement> placements;

  /// Lanes to make first, for a clip that has nowhere to go yet — the first
  /// caption in a project lands on a text lane that does not exist until it
  /// does. Part of this command rather than a separate [AddTrack] for the same
  /// reason [DetachAudio] carries its own: adding a caption is one action, and
  /// two undo entries for one button is one of them always wrong.
  final List<Track> newTracks;

  @override
  final String label;

  @override
  Project apply(Project project) {
    if (placements.isEmpty && newTracks.isEmpty) return project;

    for (final track in newTracks) {
      project = AddTrack(track).apply(project);
    }
    if (placements.isEmpty) return project;

    final seen = <String>{};
    for (final placement in placements) {
      if (!seen.add(placement.clip.id)) {
        throw EditException('clip ${placement.clip.id} placed twice');
      }
      if (project.clipById(placement.clip.id) != null) {
        throw EditException(
            'clip ${placement.clip.id} is already in the project');
      }
      if (placement.clip.duration.raw <= 0) {
        throw EditException(
            'clip ${placement.clip.id} has non-positive duration');
      }
      final mediaId = placement.clip.mediaId;
      if (mediaId != null && !project.media.containsKey(mediaId)) {
        throw EditException('clip ${placement.clip.id} refers to unknown '
            'media $mediaId; add the media first');
      }
      if (project.trackById(placement.trackId) == null) {
        throw EditException('no track ${placement.trackId}');
      }
    }

    var next = project;
    for (final trackId in placements.map((p) => p.trackId).toSet()) {
      final track = next.trackById(trackId)!;
      final incoming =
          placements.where((p) => p.trackId == trackId).toList();

      if (!track.isMagnetic) {
        final clips = List<Clip>.of(track.clips);
        for (final placement in incoming) {
          final overlaps =
              clips.any((c) => c.span.overlaps(placement.clip.span));
          clips.add(overlaps
              ? placement.clip.movedTo(_endOf(clips))
              : placement.clip);
        }
        next = next.replaceTrack(track.withClips(clips));
        continue;
      }

      // Indices name slots in the lane as it was, so they are applied in
      // ascending order with a running offset for the ones already put in.
      incoming.sort((a, b) =>
          (a.index ?? track.clips.length).compareTo(b.index ?? track.clips.length));
      final ordered = List<Clip>.of(track.clips);
      var inserted = 0;
      for (final placement in incoming) {
        final at = (placement.index ?? track.clips.length) + inserted;
        ordered.insert(at.clamp(0, ordered.length), placement.clip);
        inserted++;
      }
      next = next.replaceTrack(track.packedInOrder(ordered));
    }
    return next;
  }

  static Tick _endOf(List<Clip> clips) => clips.isEmpty
      ? Tick.zero
      : clips.map((c) => c.end).reduce(Tick.larger);
}

/// Removes clips. On a magnetic track the gaps close behind them.
///
/// Takes a set rather than one id because a selection is a set: deleting four
/// clips has to be one edit, or undo becomes four presses to reverse one
/// decision.
final class DeleteClips extends EditCommand {
  const DeleteClips(this.clipIds);

  final Set<String> clipIds;

  @override
  String get label => clipIds.length == 1 ? 'Delete clip' : 'Delete clips';

  @override
  Project apply(Project project) {
    final ids = clipIds;
    var next = project;
    for (final track in project.tracks) {
      final remaining = track.clips.where((c) => !ids.contains(c.id)).toList();
      if (remaining.length == track.clips.length) continue;
      next = next.replaceTrack(track.withClips(remaining).repacked());
    }
    return next;
  }
}

/// Adds an empty track.
///
/// With no [at], the lane goes where its kind belongs: a new overlay lands
/// above every visual lane already there and below the audio ones. That is not
/// cosmetic — list order is compositing order, so where a lane is inserted
/// decides what it renders on top of.
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
    if (!project.canAddTrackOfKind(track.kind)) {
      throw EditException('a project may hold at most '
          '${Project.maxTracksOfKind(track.kind)} ${track.kind.name} tracks');
    }
    return project.addTrack(track,
        at: at ?? project.insertIndexFor(track.kind));
  }
}

/// Removes a track, and everything on it.
///
/// The main track cannot go: it is the one lane the document guarantees, and
/// half the model asks for it by name.
final class RemoveTrack extends EditCommand {
  const RemoveTrack(this.trackId);

  final String trackId;

  @override
  String get label => 'Remove track';

  @override
  Project apply(Project project) {
    final track = project.trackById(trackId);
    if (track == null) return project;
    if (track.kind == TrackKind.main) {
      throw EditException('the main track cannot be removed');
    }
    return project.removeTrack(trackId);
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
