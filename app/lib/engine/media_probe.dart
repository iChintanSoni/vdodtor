import 'dart:isolate';

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
    // The rule lives on MediaProbe so the project decoder can apply the same
    // one with no engine alive — see MediaProbe.kindFor.
    final kind = MediaProbe.kindFor(
      hasVideo: native.hasVideo,
      duration: Tick(native.durationTicks),
      videoCodec: native.videoCodec.isEmpty ? null : native.videoCodec,
    );

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
      // A zero either way means the container did not say, and square is the
      // only safe reading of that.
      pixelAspect: native.pixelAspectNumerator > 0 &&
              native.pixelAspectDenominator > 0
          ? Rational(native.pixelAspectNumerator, native.pixelAspectDenominator)
          : Rational.one,
      hasVideo: native.hasVideo,
      hasAudio: native.hasAudio,
      audioChannels: native.audioChannels,
      audioSampleRate: native.audioSampleRate,
      videoCodec: native.videoCodec.isEmpty ? null : native.videoCodec,
      audioCodec: native.audioCodec.isEmpty ? null : native.audioCodec,
    );
  }
}

/// What probing one file produced: what is in it, or why it could not be read.
typedef ProbeOutcome = ({String path, MediaProbe? probe, String? error});

/// Probing a batch of files.
///
/// An interface because import is the app's most failure-prone path — a file
/// that moved, a codec nobody has, a folder of holiday photos — and none of
/// those cases are reachable in a test that needs the native engine.
abstract interface class MediaProber {
  /// Probes every path, in order, one outcome per input. Never throws for a
  /// file it could not read: an import of twelve files where one is broken
  /// should import eleven and say so.
  Future<List<ProbeOutcome>> probeAll(List<String> paths);
}

/// The real one: the engine's probe, on a background isolate.
///
/// One isolate for the whole batch rather than one per file. Probing reads
/// container headers, so it is milliseconds each — but it is milliseconds of
/// disk, and a folder drop can be hundreds of files, which is exactly long
/// enough to drop frames if it ran on the UI isolate.
final class EngineMediaProber implements MediaProber {
  const EngineMediaProber();

  @override
  Future<List<ProbeOutcome>> probeAll(List<String> paths) => paths.isEmpty
      ? Future.value(const [])
      : Isolate.run(() => _probeAll(paths));

  static List<ProbeOutcome> _probeAll(List<String> paths) {
    const service = MediaProbeService();
    final outcomes = <ProbeOutcome>[];
    for (final path in paths) {
      try {
        final probe = service.toProbe(VdodtorEngine.probeFile(path));
        outcomes.add((path: path, probe: probe, error: null));
      } on EngineException catch (error) {
        outcomes.add((path: path, probe: null, error: error.message));
      }
    }
    return outcomes;
  }
}
