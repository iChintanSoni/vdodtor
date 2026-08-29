import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../model/project.dart';

/// Turns the document into the flat render list the engine composites from.
///
/// This is the whole of "document sync". The engine never sees the scene
/// graph: it gets clips with paths and times, ordered bottom to top. Keeping
/// the boundary this narrow is what makes the engine replaceable — a WebCodecs
/// backend has to implement this contract and nothing else.
EngineTimeline engineTimelineFor(Project project) {
  final clips = <EngineClip>[];

  for (var index = 0; index < project.tracks.length; index++) {
    final track = project.tracks[index];
    // Audio has its own path to the device; hidden tracks are not composited.
    if (!track.kind.isVisual || track.hidden) continue;

    for (final clip in track.clips) {
      if (!clip.enabled) continue;
      final asset = project.assetFor(clip);
      if (asset == null) continue;
      if (!asset.probe.hasVideo) continue;

      clips.add(EngineClip(
        path: asset.path,
        startTicks: clip.start.raw,
        durationTicks: clip.duration.raw,
        sourceInTicks: clip.sourceIn.raw,
        // List order is z-order: the main track is first, so it renders first.
        track: index,
        fit: FitMode.contain,
      ));
    }
  }

  return EngineTimeline(
    width: project.format.width,
    height: project.format.height,
    frameRateNumerator: project.format.frameRate.numerator,
    frameRateDenominator: project.format.frameRate.denominator,
    clips: clips,
  );
}
