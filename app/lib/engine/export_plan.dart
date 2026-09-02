/// What the export sheet is deciding, as a value.
///
/// The engine owns what an export *is* — the frame counter, the compositor,
/// the encoder. This owns the four questions a person is asked before one
/// starts: how big, which codec, with or without sound, and where to put it.
/// Keeping them here rather than in the sheet means the arithmetic under the
/// picker — the estimated size, the disk check — is testable without a widget.
library;

import 'package:flutter/foundation.dart';
import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../model/project.dart';
import '../model/time.dart';
import '../pro/entitlement.dart';
import 'timeline_sync.dart';

/// The size an export is written at.
///
/// A short list rather than a pair of number fields, and the list is
/// deliberately about *the short side* rather than about width and height: a
/// vertical project exported at "1080p" should be 1080 across and 1920 tall,
/// which is what everybody means and not what a width field would give them.
///
/// Nothing in the render list is measured in pixels — a caption's size is a
/// fraction of the output height, a shape's box is a fraction of the output
/// height, an offset is a fraction of the frame — so exporting at a size the
/// project was never cut at is one number changing and no re-layout at all.
enum ExportResolution {
  /// Whatever the project is. First because it is the answer for almost
  /// everybody, and the only one that cannot be wrong.
  matchProject('Same as project', null),
  hd720('720p', 720),
  hd1080('1080p', 1080),
  uhd4k('4K', 2160);

  const ExportResolution(this.label, this.shortSide);

  final String label;

  /// The short side in pixels, or null to leave the project's size alone.
  final int? shortSide;

  /// This resolution applied to [project], keeping its aspect and its rate.
  ///
  /// The rate is deliberately untouched: changing how big a picture is is a
  /// scale, and changing how often there is one is a retime of the whole
  /// project — a different feature, and one that would quietly move every
  /// frame away from the instant it was cut on.
  ProjectFormat formatFor(ProjectFormat project) {
    final short = shortSide;
    if (short == null || project.shortSide == short) return project;
    final scale = short / project.shortSide;
    int even(int value) => value.isEven ? value : value + 1;
    return ProjectFormat(
      width: even((project.width * scale).round()),
      height: even((project.height * scale).round()),
      frameRate: project.frameRate,
    );
  }
}

/// One export, decided but not started.
///
/// Immutable and cheap, so the sheet rebuilds one per keystroke on the picker
/// and reads the estimate off it.
@immutable
class ExportPlan {
  const ExportPlan({
    required this.format,
    required this.duration,
    this.resolution = ExportResolution.matchProject,
    this.codec = ExportCodec.h264,
    this.includeAudio = true,
    this.tier = Tier.free,
  });

  /// The plan the sheet opens on: the project's own size, unless this
  /// installation may not write one that big.
  ///
  /// **The sheet opens on the largest size it can actually write.** A free
  /// installation with a 4K project would otherwise open on a choice it has to
  /// refuse, so the first thing the user saw would be a locked button — which
  /// is the upsell-first behaviour this product exists in opposition to. It
  /// opens on 1080p instead, with the project's own size sitting one chip away
  /// wearing a badge. Nothing is hidden and nothing is silently substituted:
  /// the line under the picker always says the size that will be written.
  factory ExportPlan.of(Project project, {Tier tier = Tier.free}) => ExportPlan(
        format: project.format,
        duration: project.duration,
        tier: tier,
        resolution: tier.isPro || !project.format.isAboveFreeTier
            ? ExportResolution.matchProject
            : ExportResolution.hd1080,
      );

  /// The *project's* format, not the export's — see [outputFormat].
  final ProjectFormat format;

  final Tick duration;
  final ExportResolution resolution;
  final ExportCodec codec;
  final bool includeAudio;

  /// What this installation may write — see [isPermitted].
  ///
  /// It is on the plan and not read from a notifier deeper down so that the
  /// gate is a property of the *decision*, testable with no widget and no
  /// engine, in the file that already owns every other consequence of the four
  /// choices in the sheet.
  final Tier tier;

  ExportPlan copyWith({
    ExportResolution? resolution,
    ExportCodec? codec,
    bool? includeAudio,
    Tier? tier,
  }) =>
      ExportPlan(
        format: format,
        duration: duration,
        resolution: resolution ?? this.resolution,
        codec: codec ?? this.codec,
        includeAudio: includeAudio ?? this.includeAudio,
        tier: tier ?? this.tier,
      );

  /// What the file will be.
  ProjectFormat get outputFormat => resolution.formatFor(format);

  ExportSettings get settings => ExportSettings(
        codec: codec,
        includeAudio: includeAudio,
      );

  /// Whether this export needs Pro. Product brief §5: the free editor exports
  /// at 1080p, with no watermark, ever.
  ///
  /// Measured on [outputFormat] and never on which chip is lit, because 4K is
  /// not the only way to ask for 4K: "same as project" on a project that was
  /// cut at 4K is the same file. The gate is on the number of pixels leaving
  /// the machine, so there is one rule and no second place to get it wrong.
  bool get isAboveFreeTier => outputFormat.isAboveFreeTier;

  /// Whether this export may be written at all.
  ///
  /// **The gate is the whole mechanism.** There is no watermark, no
  /// shortened export, no reduced quality and no silent downscale — a file
  /// that came out smaller than the one that was asked for is worse than a
  /// refusal, because nobody re-checks the dimensions of a render they
  /// watched finish. Above the free tier without Pro, nothing is written and
  /// the sheet says so; below it, the tier changes nothing whatsoever about
  /// the file, which is what [timelineFor] and [settings] not mentioning it
  /// is the proof of.
  bool get isPermitted => tier.isPro || !isAboveFreeTier;

  /// Whether picking [resolution] would need Pro, for badging the chips.
  bool needsPro(ExportResolution resolution) =>
      !tier.isPro && resolution.formatFor(format).isAboveFreeTier;

  /// Frames the export will write. Rounded up, on the engine's terms: a
  /// timeline that ends part-way through a frame still gets that frame.
  int get frameCount {
    final perFrame = Timebase.project.ticksPerFrame(format.frameRate);
    if (perFrame <= 0 || duration.raw <= 0) return 0;
    return (duration.raw + perFrame - 1) ~/ perFrame;
  }

  /// Bits per second the picture will be written at.
  int get videoBitrate => defaultVideoBitrate(
        codec,
        outputFormat.width,
        outputFormat.height,
        format.frameRate,
      );

  /// The render list, at the export's size.
  EngineTimeline timelineFor(Project project) {
    final base = engineTimelineFor(project);
    final output = outputFormat;
    if (output == format) return base;
    return EngineTimeline(
      width: output.width,
      height: output.height,
      frameRateNumerator: base.frameRateNumerator,
      frameRateDenominator: base.frameRateDenominator,
      clips: base.clips,
    );
  }

  /// Roughly how big the file will be, for the sentence under the picker and
  /// for the disk check before anything is written.
  ///
  /// Bitrate times length plus a couple of per cent for the container, which
  /// is near enough for both jobs and would be a lie to give more decimal
  /// places to. The audio is counted whether or not the timeline turns out to
  /// have any: both readers of this number would rather it were a little high
  /// than a little low.
  int get estimatedBytes {
    if (duration.raw <= 0) return 0;
    final bits = videoBitrate + (includeAudio ? _audioBitrate : 0);
    final seconds = duration.raw / Timebase.project.ticksPerSecond;
    return (bits * seconds / 8 * 1.02).round();
  }

  /// Whether there is room for it where it is going, or null when the volume
  /// will not say — which is a reason not to warn rather than a reason to.
  ///
  /// The margin is deliberate: the estimate is a bitrate multiplied by a
  /// length, so it is right to within a few per cent, and a disk filled to
  /// exactly the last byte is a machine in trouble anyway.
  bool? hasRoomFor(String path) {
    final free = Exporter.freeBytes(path);
    if (free == null) return null;
    return free > estimatedBytes + _headroom;
  }

  /// What `VD_EXPORT_DEFAULT_AUDIO_BITRATE` is: 192 kbps of AAC-LC, which
  /// nobody will hear the edge of and nobody will notice the size of.
  static const _audioBitrate = 192000;

  /// Half a gigabyte kept back. macOS behaves badly long before a volume is
  /// actually full, and an export that succeeds by filling the disk is not a
  /// success.
  static const _headroom = 512 * 1024 * 1024;
}

/// Bits per second the picture is written at, for a size, a rate and a codec.
///
/// The same function as `vd_export_default_bitrate` in engine/src/vd_export.mm,
/// and the two test the same table — the `vd_time.c` / `time.dart`
/// arrangement. It is written twice for the reason the audio envelopes are:
/// the encoder writes at this rate and the app *draws* it, under the preset
/// picker, and a sentence promising 6.2 Mbps over a file written at 3.7 is
/// worse than no sentence at all. Change one and you must change the other.
///
/// Bits per pixel per frame rather than a table of presets: a table has to
/// guess which sizes anyone will pick, and the whole point of a resolution
/// nobody thought of is that nobody thought of it.
int defaultVideoBitrate(
  ExportCodec codec,
  int width,
  int height,
  Rational frameRate,
) {
  if (width <= 0 || height <= 0) return 0;
  var fps = frameRate.denominator > 0
      ? frameRate.numerator / frameRate.denominator
      : 0.0;
  if (fps <= 0) fps = 30;

  final perPixel = codec == ExportCodec.hevc ? 0.06 : 0.10;
  var bits = width * height * fps * perPixel;
  if (bits < 1000000) bits = 1000000;
  if (bits > 120000000) bits = 120000000;

  // To the nearest 100 kbps, so the number reads like a decision rather than
  // like the output of the line above it.
  return ((bits + 50000) ~/ 100000) * 100000;
}

/// A size in the units people read sizes in.
///
/// Rounded to a scale that says what it is worth: an estimate accurate to a
/// few per cent quoted to three decimal places is a claim it cannot support.
String formatBytes(int bytes) {
  if (bytes < 1000) return '$bytes B';
  const units = ['kB', 'MB', 'GB', 'TB'];
  var value = bytes / 1000;
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  return '${value < 10 ? value.toStringAsFixed(1) : value.round()} '
      '${units[unit]}';
}

/// A bitrate in the units a preset picker quotes them in.
String formatBitrate(int bitsPerSecond) {
  final mbps = bitsPerSecond / 1000000;
  return '${mbps < 10 ? mbps.toStringAsFixed(1) : mbps.round()} Mbps';
}

/// A rough duration, for "about four minutes left".
String formatRoughDuration(double seconds) {
  if (seconds < 1) return 'a moment';
  if (seconds < 60) return '${seconds.round()}s';
  final minutes = seconds / 60;
  if (minutes < 60) return '${minutes.round()} min';
  return '${(minutes / 60).toStringAsFixed(1)} h';
}
