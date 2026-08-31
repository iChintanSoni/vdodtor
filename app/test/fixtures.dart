import 'package:vdodtor/model/clip.dart';
import 'package:vdodtor/model/ids.dart';
import 'package:vdodtor/model/media.dart';
import 'package:vdodtor/model/project.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor/model/track.dart';

const mainTrackId = 'tr-main';
const audioTrackId = 'tr-audio';
const overlayTrackId = 'tr-overlay';

/// Seconds, as ticks. Test sugar only — production code never starts from
/// a double.
Tick secs(num s) =>
    Timebase.project.fromSeconds(Rational((s * 1000).round(), 1000));

MediaAsset videoAsset(String id, {double seconds = 10, bool audio = true}) =>
    MediaAsset(
      id: id,
      path: '/media/$id.mp4',
      displayName: '$id.mp4',
      probe: MediaProbe(
        kind: MediaKind.video,
        duration: secs(seconds),
        width: 1920,
        height: 1080,
        frameRate: FrameRates.fps30,
        hasVideo: true,
        hasAudio: audio,
        audioChannels: audio ? 2 : 0,
        audioSampleRate: audio ? 48000 : 0,
        videoCodec: 'h264',
        audioCodec: audio ? 'aac' : null,
      ),
    );

/// An animated overlay: a picture, no sound, and a length that is one loop
/// rather than a limit.
MediaAsset stickerAsset(String id, {double seconds = 1}) => MediaAsset(
      id: id,
      path: '/media/$id.gif',
      displayName: '$id.gif',
      probe: MediaProbe(
        kind: MediaKind.sticker,
        duration: secs(seconds),
        width: 480,
        height: 480,
        frameRate: FrameRates.fps30,
        hasVideo: true,
        videoCodec: 'gif',
      ),
    );

/// A file with sound and no picture — a music bed. The case that made audio
/// lanes worth having, and the one nothing reached the engine for until the
/// levels work.
MediaAsset audioAsset(String id, {double seconds = 30}) => MediaAsset(
      id: id,
      path: '/media/$id.m4a',
      displayName: '$id.m4a',
      probe: MediaProbe(
        kind: MediaKind.audio,
        duration: secs(seconds),
        hasVideo: false,
        hasAudio: true,
        audioChannels: 2,
        audioSampleRate: 48000,
        audioCodec: 'aac',
      ),
    );

Clip clipOf(
  String id,
  String mediaId, {
  required Tick start,
  required Tick duration,
  Tick sourceIn = Tick.zero,
}) =>
    Clip(
      id: id,
      mediaId: mediaId,
      start: start,
      duration: duration,
      sourceIn: sourceIn,
      label: id,
    );

/// A 16:9 30 fps project with a main and an audio track, and one media asset
/// registered but no clips placed.
Project emptyProject() => Project.empty(
      id: 'pr-1',
      name: 'Test project',
      format: ProjectFormat.fromAspect(ProjectAspect.landscape16x9,
          frameRate: FrameRates.fps30),
      mainTrackId: mainTrackId,
      audioTrackId: audioTrackId,
    ).addMedia(videoAsset('m1')).addMedia(videoAsset('m2', seconds: 20));

/// The same project with three clips packed on the main track:
/// a (0–2s), b (2–5s), c (5–6s).
Project projectWithThreeClips() {
  final p = emptyProject();
  return p.updateTrack(
    mainTrackId,
    (t) => t.withClips([
      clipOf('a', 'm1', start: Tick.zero, duration: secs(2)),
      clipOf('b', 'm1', start: secs(2), duration: secs(3)),
      clipOf('c', 'm2', start: secs(5), duration: secs(1)),
    ]),
  );
}

Project withOverlayTrack(Project p) => p.addTrack(
      Track.of(id: overlayTrackId, kind: TrackKind.overlay, name: 'Overlay 1'),
    );

IdGen testIds() => IdGen.seeded(42);
