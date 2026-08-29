import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../model/media.dart';
import '../model/time.dart';

/// Turns files into [MediaAsset]s by asking the native engine what is in them.
///
/// The engine reports raw container facts; the mapping to the document model
/// lives here so the engine package stays free of document knowledge.
class MediaProbeService {
  const MediaProbeService();

  /// Probes [path] and builds an asset ready to place on a track.
  ///
  /// Throws [EngineException] if the file cannot be read or holds nothing
  /// playable — callers should surface that, not swallow it, because a
  /// silently-skipped import looks like a bug in the drop target.
  MediaAsset probe({
    required String id,
    required String path,
    required String displayName,
    String? bookmark,
  }) {
    final native = VdodtorEngine.probeFile(path);
    return MediaAsset(
      id: id,
      path: path,
      displayName: displayName,
      bookmark: bookmark,
      probe: toProbe(native),
    );
  }

  /// Maps an engine probe onto the document model's [MediaProbe].
  MediaProbe toProbe(NativeProbe native) {
    final kind = native.hasVideo
        ? (native.durationTicks == 0 ? MediaKind.image : MediaKind.video)
        : MediaKind.audio;

    // A rate of 0/1 means the container did not say; leave it at 1 fps rather
    // than inventing a plausible number, and let VFR normalisation sort it out
    // at decode time.
    final frameRate = native.frameRateNumerator > 0 &&
            native.frameRateDenominator > 0
        ? Rational(native.frameRateNumerator, native.frameRateDenominator)
        : Rational.one;

    return MediaProbe(
      kind: kind,
      duration: Tick(native.durationTicks),
      width: native.width,
      height: native.height,
      frameRate: frameRate,
      variableFrameRate: native.variableFrameRate,
      rotationDegrees: native.rotationDegrees,
      hasVideo: native.hasVideo,
      hasAudio: native.hasAudio,
      audioChannels: native.audioChannels,
      audioSampleRate: native.audioSampleRate,
      videoCodec: native.videoCodec.isEmpty ? null : native.videoCodec,
      audioCodec: native.audioCodec.isEmpty ? null : native.audioCodec,
    );
  }
}
