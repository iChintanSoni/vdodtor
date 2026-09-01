import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/engine/export_plan.dart';
import 'package:vdodtor/model/project.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../fixtures.dart';

void main() {
  group('the bitrate table', () {
    // The same table `kBitrates` in engine/tests/vd_export_test.c asserts.
    // One function in two languages, like vd_time.c and time.dart, and for the
    // reason vd_export.h gives: the encoder writes at this rate and the app
    // prints it under the picker. Change one and you must change the other.
    const rows = <(ExportCodec, int, int, Rational, int)>[
      (ExportCodec.h264, 1280, 720, FrameRates.fps30, 2800000),
      (ExportCodec.h264, 1920, 1080, FrameRates.fps30, 6200000),
      (ExportCodec.h264, 1920, 1080, FrameRates.fps23_976, 5000000),
      (ExportCodec.h264, 1080, 1920, FrameRates.fps60, 12400000),
      (ExportCodec.h264, 3840, 2160, FrameRates.fps30, 24900000),
      (ExportCodec.h264, 64, 64, FrameRates.fps30, 1000000),
      (ExportCodec.h264, 7680, 4320, FrameRates.fps60, 120000000),
      (ExportCodec.hevc, 1280, 720, FrameRates.fps30, 1700000),
      (ExportCodec.hevc, 1920, 1080, FrameRates.fps30, 3700000),
      (ExportCodec.hevc, 3840, 2160, FrameRates.fps30, 14900000),
      (ExportCodec.hevc, 3840, 2160, FrameRates.fps60, 29900000),
    ];

    test('is what the engine will encode at', () {
      for (final (codec, width, height, rate, bits) in rows) {
        expect(
          defaultVideoBitrate(codec, width, height, rate),
          bits,
          reason: '${codec.label} ${width}x$height @ $rate',
        );
      }
    });

    test('every figure reads like a decision', () {
      for (final (codec, width, height, rate, _) in rows) {
        expect(defaultVideoBitrate(codec, width, height, rate) % 100000, 0);
      }
    });

    test('a size with no pixels in it has no answer', () {
      expect(defaultVideoBitrate(ExportCodec.h264, 0, 1080, FrameRates.fps30), 0);
      expect(
          defaultVideoBitrate(ExportCodec.h264, 1920, -1, FrameRates.fps30), 0);
    });
  });

  group('resolution', () {
    final landscape = ProjectFormat.fromAspect(ProjectAspect.landscape16x9,
        frameRate: FrameRates.fps30);
    final portrait = ProjectFormat.fromAspect(ProjectAspect.portrait9x16,
        frameRate: FrameRates.fps30);

    test('matching the project changes nothing at all', () {
      expect(ExportResolution.matchProject.formatFor(landscape), landscape);
      expect(ExportResolution.matchProject.formatFor(portrait), portrait);
    });

    test('sizes the short side, so a vertical project stays vertical', () {
      // The whole reason the list is about the short side: "1080p" on a 9:16
      // project means 1080 across, not 1080 tall.
      final tall = ExportResolution.hd1080.formatFor(portrait);
      expect(tall.width, 1080);
      expect(tall.height, 1920);

      final wide = ExportResolution.hd1080.formatFor(landscape);
      expect(wide.width, 1920);
      expect(wide.height, 1080);
    });

    test('4K from a 1080p edit is the same aspect, twice over', () {
      final uhd = ExportResolution.uhd4k.formatFor(landscape);
      expect(uhd.width, 3840);
      expect(uhd.height, 2160);
      expect(uhd.aspect, ProjectAspect.landscape16x9);
    });

    test('never lands on an odd number', () {
      // Odd dimensions break 4:2:0 chroma subsampling, which is why
      // ProjectFormat asserts on them — a resolution that produced one would
      // crash rather than export.
      for (final aspect in ProjectAspect.values) {
        for (final resolution in ExportResolution.values) {
          final format = resolution.formatFor(
              ProjectFormat.fromAspect(aspect, frameRate: FrameRates.fps30));
          expect(format.width.isEven, isTrue, reason: '$aspect $resolution');
          expect(format.height.isEven, isTrue, reason: '$aspect $resolution');
        }
      }
    });

    test('leaves the frame rate alone', () {
      final odd = ProjectFormat(
          width: 1920, height: 1080, frameRate: FrameRates.fps23_976);
      expect(ExportResolution.uhd4k.formatFor(odd).frameRate,
          FrameRates.fps23_976);
    });
  });

  group('a plan', () {
    ExportPlan planFor(Project project) => ExportPlan.of(project);

    test('opens at the project\'s own size', () {
      final plan = planFor(projectWithThreeClips());
      expect(plan.resolution, ExportResolution.matchProject);
      expect(plan.outputFormat, projectWithThreeClips().format);
      expect(plan.codec, ExportCodec.h264);
      expect(plan.includeAudio, isTrue);
    });

    test('counts the frames the engine will write', () {
      // Six seconds of clips at 30 fps.
      expect(planFor(projectWithThreeClips()).frameCount, 180);
    });

    test('an empty timeline has nothing to export', () {
      expect(planFor(emptyProject()).frameCount, 0);
      expect(planFor(emptyProject()).estimatedBytes, 0);
    });

    test('the estimate is the bitrate over the length', () {
      final plan = planFor(projectWithThreeClips());
      // 6.2 Mbps of picture plus 192 kbps of sound over six seconds is about
      // 4.8 MB. A check on the shape of the arithmetic alone would pass with
      // the units wrong.
      expect(plan.estimatedBytes, greaterThan(4200000));
      expect(plan.estimatedBytes, lessThan(5400000));
    });

    test('twice as long is twice as big', () {
      final short = planFor(projectWithThreeClips());
      final long = ExportPlan(
          format: short.format, duration: short.duration * 2);
      expect(long.estimatedBytes, closeTo(short.estimatedBytes * 2, 2));
    });

    test('dropping the sound drops the estimate, and only that', () {
      final plan = planFor(projectWithThreeClips());
      final silent = plan.copyWith(includeAudio: false);
      expect(silent.estimatedBytes, lessThan(plan.estimatedBytes));
      expect(silent.videoBitrate, plan.videoBitrate);
      expect(silent.frameCount, plan.frameCount);
    });

    test('HEVC is smaller than H.264 for the same edit', () {
      final plan = planFor(projectWithThreeClips());
      expect(plan.copyWith(codec: ExportCodec.hevc).estimatedBytes,
          lessThan(plan.estimatedBytes));
    });

    test('4K is above the free tier and 1080p is not', () {
      final plan = planFor(projectWithThreeClips());
      expect(plan.isAboveFreeTier, isFalse);
      expect(plan.copyWith(resolution: ExportResolution.hd1080).isAboveFreeTier,
          isFalse);
      expect(plan.copyWith(resolution: ExportResolution.uhd4k).isAboveFreeTier,
          isTrue);
    });

    test('the render list is the project at the export\'s size', () {
      final project = projectWithThreeClips();
      final plan = planFor(project).copyWith(resolution: ExportResolution.uhd4k);
      final timeline = plan.timelineFor(project);

      expect(timeline.width, 3840);
      expect(timeline.height, 2160);
      // The rate is the project's, untouched: a bigger picture is a scale, and
      // a different rate would be a retime of the whole project.
      expect(timeline.frameRateNumerator, 30);
      expect(timeline.frameRateDenominator, 1);
      // And the clips are the same clips. Nothing in a render list is measured
      // in pixels, so exporting bigger is one number changing.
      expect(timeline.clips.length, 3);
      expect(timeline.clips.first.durationTicks,
          project.mainTrack.clips.first.duration.raw);
    });

    test('at the project\'s own size the render list is untouched', () {
      final project = projectWithThreeClips();
      final timeline = planFor(project).timelineFor(project);
      expect(timeline.width, project.format.width);
      expect(timeline.height, project.format.height);
    });
  });

  group('the numbers people read', () {
    test('bytes are quoted at a scale the estimate can support', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(4800), '4.8 kB');
      expect(formatBytes(4800000), '4.8 MB');
      expect(formatBytes(48000000), '48 MB');
      expect(formatBytes(4800000000), '4.8 GB');
    });

    test('bitrates are quoted in Mbps', () {
      expect(formatBitrate(6200000), '6.2 Mbps');
      expect(formatBitrate(24900000), '25 Mbps');
    });

    test('a countdown is rough on purpose', () {
      expect(formatRoughDuration(0.4), 'a moment');
      expect(formatRoughDuration(42), '42s');
      expect(formatRoughDuration(300), '5 min');
      expect(formatRoughDuration(7200), '2.0 h');
    });
  });
}
