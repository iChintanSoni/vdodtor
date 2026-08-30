import 'dart:async';
import 'dart:io';

import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../app/workspace.dart';
import '../commands/document_store.dart';
import '../engine/media_probe.dart';
import '../media/file_access.dart';
import '../media/media_import.dart';
import '../media/thumbnails.dart';
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

/// The clips bundled with the app, for the self test only.
///
/// The self test runs unattended, so it cannot open a file panel and cannot be
/// dropped on. The App Sandbox lets the app read its own bundle, which makes
/// these the only files it can reach without a user — everyone else imports.
List<File> sampleMediaFiles() {
  final exe = File(Platform.resolvedExecutable).parent; // …/Contents/MacOS
  final bundled = Directory('${exe.parent.path}/Frameworks/App.framework/'
      'Resources/flutter_assets/assets/dev');
  final dir = bundled.existsSync()
      ? bundled
      : Directory('${Directory.current.path}/assets/dev');
  if (!dir.existsSync()) return const [];

  return dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.mp4'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

/// Copies the bundled samples into [into], and returns where they landed.
///
/// Importing straight out of the app bundle would not be a fair test: a bundle
/// resource is readable but *not* bookmarkable — the sandbox grants it by
/// being the app's own, not by a scope there is anything to remember — so
/// every mint would fail for a reason no user will ever hit. The library
/// folder is granted by entitlement and behaves like the user's own footage.
List<File> stageSampleMedia(Directory into) {
  final staged = Directory('${into.path}/self-test-media');
  staged.createSync(recursive: true);
  return [
    for (final source in sampleMediaFiles())
      source.copySync('${staged.path}/${source.uri.pathSegments.last}'),
  ];
}

/// Puts the samples on the timeline the way a user would: through the real
/// importer, the real probe and the real sandbox.
///
/// This is the only unattended check there is on the import path — a panel and
/// a drop both need a person — so it deliberately goes the long way round,
/// including the security-scoped bookmark round trip and one thumbnail, and
/// prints what each step actually did rather than only whether it threw.
Future<void> runImportSelfTest(
  DocumentStore store, {
  required Directory library,
  FileAccess access = const SystemFileAccess(),
  MediaProber prober = const EngineMediaProber(),
}) async {
  final files = stageSampleMedia(library);
  stdout.writeln('[selftest] import: ${files.length} samples staged in '
      '${library.path}');
  if (files.isEmpty) return;

  final importer = MediaImporter(prober: prober, access: access);
  final clock = Stopwatch()..start();
  final result = await importer.import(
      store, [for (final f in files) GrantedFile(path: f.path)]);
  clock.stop();

  stdout.writeln('[selftest] import: added ${result.added.length}, '
      'reused ${result.reused.length}, placed ${result.clipsPlaced}, '
      'failed ${result.failures.length}, ${clock.elapsedMilliseconds} ms');
  for (final failure in result.failures) {
    stdout.writeln('[selftest]   FAILED ${failure.displayName}: '
        '${failure.reason}');
  }
  for (final asset in result.added) {
    stdout.writeln('[selftest]   ${asset.displayName} '
        '${asset.probe.displayWidth}x${asset.probe.displayHeight} '
        '${(asset.probe.duration.raw / 120000).toStringAsFixed(2)}s '
        'bookmark=${asset.bookmark == null ? "NONE" : "minted"}');
  }

  final sample = result.added.isEmpty ? null : result.added.first;
  if (sample == null) return;

  // The bookmark is the only part of import that has to survive a quit, so it
  // is the part worth resolving here rather than next launch.
  final bookmark = sample.bookmark;
  if (bookmark == null) {
    stdout.writeln('[selftest] bookmark: NOT MINTED — this project will not '
        'reopen with its media');
  } else {
    final resolved = await access.resolve(bookmark);
    stdout.writeln('[selftest] bookmark: resolved='
        '${resolved != null} granted=${resolved?.granted} '
        'stale=${resolved?.stale} '
        'sameFile=${resolved?.path == sample.path}');
  }

  final thumbClock = Stopwatch()..start();
  try {
    final thumb = await Thumbnails.render(sample.path,
        ticks: thumbnailTick(sample.probe).raw, maxWidth: 320, maxHeight: 320);
    thumbClock.stop();
    stdout.writeln('[selftest] thumbnail: '
        '${thumb == null ? "no picture" : "${thumb.width}x${thumb.height}, "
            "${thumb.bgra.length} bytes"}'
        ', ${thumbClock.elapsedMilliseconds} ms');
  } catch (error) {
    stdout.writeln('[selftest] thumbnail: FAILED $error');
  }
}
