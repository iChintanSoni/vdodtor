import 'dart:async';
import 'dart:io';

import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../app/workspace.dart';
import '../model/project.dart';
import '../model/time.dart';

/// True when the app was launched to measure itself rather than to be used.
bool get selfTestRequested => Platform.environment['VD_SELFTEST'] == '1';

/// The self test measures the preview pipeline, which needs a document open,
/// so it opens one: the same project every run, created on the first.
Future<void> openSelfTestProject(Workspace workspace) async {
  const name = 'Self test';
  for (final entry in workspace.projects) {
    if (entry.exists && entry.name == name) {
      await workspace.openAt(entry.path);
      return;
    }
  }
  await workspace.create(
    name: name,
    aspect: ProjectAspect.landscape16x9,
    frameRate: FrameRates.fps30,
  );
}

/// Checks the preview pipeline the way M0 insisted on checking it: by looking
/// at the pixels, not at the frame counter. Run the app with VD_SELFTEST=1.
Future<void> runSelfTest(PreviewEngine engine, Project project) async {
  final out = Directory.systemTemp.createTempSync('vdodtor_selftest_');
  stdout.writeln('[selftest] project ${project.format}, '
      '${project.mainTrack.clips.length} clips, '
      'duration ${engine.durationTicks} ticks');

  final duration = engine.durationTicks;
  for (final fraction in [0.0, 0.25, 0.5, 0.75, 0.99]) {
    engine.seek((duration * fraction).round());
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final percent = (fraction * 100).round();
    final path = '${out.path}/at_$percent.png';
    engine.dumpPng(path);
    stdout.writeln('[selftest] seek $percent% -> $path');
  }

  engine.seek(0);
  // Measure the delta across the play, not the counters since launch: the
  // seek pass above already rendered a dozen frames, and folding those into a
  // frame rate reports a number nothing actually ran at.
  final before = engine.stats;
  final clock = Stopwatch()..start();
  engine.play();
  await Future<void>.delayed(const Duration(seconds: 3));
  final playing = engine.stats;
  clock.stop();
  engine.pause();

  final rendered = playing.framesPresented - before.framesPresented;
  final seconds = clock.elapsedMilliseconds / 1000.0;
  stdout.writeln('[selftest] rendered $rendered frames in '
      '${seconds.toStringAsFixed(2)}s wall = '
      '${(rendered / seconds).toStringAsFixed(1)} fps, '
      'forced=${playing.forcedRenders - before.forcedRenders} '
      'regressions=${playing.clockRegressions - before.clockRegressions} '
      'media advanced '
      '${((playing.positionTicks - before.positionTicks) / 120000).toStringAsFixed(3)}s');

  stdout.writeln('[selftest] played 3s: '
      'state=${playing.state.name} '
      'fps=${playing.presentFps.toStringAsFixed(1)} '
      'gpu=${playing.compositeMsAvg.toStringAsFixed(2)}ms '
      'presented=${playing.framesPresented} '
      'late=${playing.framesLate} '
      'audio=${playing.audioAvailable} '
      'underruns=${playing.audioUnderruns} '
      'buffered=${playing.audioBufferedFrames} '
      'seek=${playing.lastSeekMs.toStringAsFixed(1)}ms '
      'decoders=${playing.openDecoders} '
      'layers=${playing.activeLayers} '
      'position=${playing.positionTicks}');
  stdout.writeln('[selftest] frames in ${out.path}');
}
