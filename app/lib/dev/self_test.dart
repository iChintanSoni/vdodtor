import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../app/workspace.dart';
import '../commands/document_store.dart';
import '../commands/edits.dart';
import '../engine/export_plan.dart';
import '../engine/media_probe.dart';
import '../engine/timeline_sync.dart';
import '../media/file_access.dart';
import '../media/media_import.dart';
import '../media/fonts.dart';
import '../media/packs.dart';
import '../media/peaks.dart';
import '../media/thumbnails.dart';
import '../media/waveforms.dart';
import '../model/clip.dart';
import '../model/media.dart';
import '../model/project.dart';
import '../model/time.dart';
import '../model/track.dart';
import '../ui/timeline/timeline_controller.dart';
import '../ui/timeline/timeline_painter.dart';

/// True when the app was launched to measure itself rather than to be used.
bool get selfTestRequested => Platform.environment['VD_SELFTEST'] == '1';

/// True when it was launched to look at the *sample* project instead.
///
/// A separate mode rather than another pass over the synthetic project,
/// because the two ask opposite questions. Everything else in this file builds
/// a timeline in order to measure the engine under it; this one is handed a
/// timeline somebody will actually be shown on their first launch and asks
/// whether it came out looking like an edit. There is nothing to build and
/// nothing to put back afterwards — it only looks.
bool get sampleSelfTestRequested =>
    Platform.environment['VD_SELFTEST'] == 'sample';

/// The project the self test owns, and the only one it may touch.
const selfTestProjectName = 'Self test';

/// True for the project the self test made for itself.
///
/// The self test *edits* the document it is given — it imports, it adds a
/// caption, it puts a shape and a sticker on lanes it makes — so which project
/// it is pointed at is not a detail. Gating on "the main track is empty" alone
/// meant every project the user created by hand in a self-test build was
/// filled with sample media, which reads as the editor inventing clips.
bool isSelfTestProject(Project project) => project.name == selfTestProjectName;

/// The self test measures the preview pipeline, which needs a document open,
/// so it opens one: the same project every run, created on the first.
Future<void> openSelfTestProject(Workspace workspace) async {
  for (final entry in workspace.projects) {
    if (entry.exists && entry.name == selfTestProjectName) {
      await workspace.openAt(entry.path);
      return;
    }
  }
  await workspace.create(
    name: selfTestProjectName,
    aspect: ProjectAspect.landscape16x9,
    frameRate: FrameRates.fps30,
  );
}

/// Looks at the sample project the way a first launch does, and says what it
/// found.
///
/// The document half of the first-run experience has unit tests — the shape of
/// the edit is asserted in `test/media/sample_project_test.dart` with a fake
/// probe — and none of them can answer the only question that matters about a
/// sample project, which is whether it looks like anything. So this dumps the
/// five frames the arrangement was designed around: the title over the first
/// shot, the middle of the dissolve, the graded shot on its own, the middle of
/// the wipe, and the closing caption over the last one.
///
/// It edits nothing. That is the difference between this and every other pass
/// in this file, and it is the point: the frames it writes are the frames the
/// user gets.
Future<void> runSampleSelfTest(PreviewEngine engine, DocumentStore store) async {
  final project = store.project;
  final clips = project.mainTrack.clips;
  stdout.writeln('[selftest] sample: ${project.format}, '
      '${clips.length} shots, '
      '${project.tracks.length} lanes, '
      '${project.media.length} files, '
      '${(project.duration.raw / Timebase.project.ticksPerSecond)
          .toStringAsFixed(2)}s');

  for (final clip in clips) {
    stdout.writeln('[selftest] sample:   shot ${clip.label} '
        'in=${clip.transition.preset.name} '
        'look=${clip.color.look.isEmpty ? '-' : clip.color.look}'
        '@${clip.color.lookStrength.toStringAsFixed(2)} '
        'anim=${clip.animation.inPreset.name}/${clip.animation.outPreset.name}');
  }
  for (final track in project.tracks.where((t) => t.kind == TrackKind.text)) {
    for (final clip in track.clips) {
      stdout.writeln('[selftest] sample:   ${track.name} '
          '${clip.isText ? '"${clip.text!.text}" ${clip.text!.font}' : 'shape '
              '${clip.shape!.kind.name}'} '
          'at ${(clip.start.raw / Timebase.project.ticksPerSecond)
              .toStringAsFixed(2)}s');
    }
  }

  final out = Directory.systemTemp.createTempSync('vdodtor_sample_');
  final seconds = <String, double>{
    'title': 2.5,
    'dissolve': 5.0,
    'graded': 7.5,
    'wipe': 10.0,
    'closing': 12.5,
  };

  // A seek nobody looks at, first. The engine has been alive for a few
  // milliseconds at this point and its decoders have not opened a file yet, so
  // the first frame asked for arrives after the dump rather than before it —
  // which came out as three identical black PNGs and a pass that looked like
  // it had found a bug in the compositor.
  engine.seek(0);
  await Future<void>.delayed(const Duration(milliseconds: 600));

  for (final entry in seconds.entries) {
    engine.seek((entry.value * Timebase.project.ticksPerSecond).round());
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final path = '${out.path}/${entry.key}.png';
    engine.dumpPng(path);
    stdout.writeln('[selftest] sample: ${entry.key} at ${entry.value}s -> '
        '$path');
  }

  // Played rather than only seeked, because the bed is half of what the
  // sample is demonstrating and a silent first launch would look identical in
  // every frame above.
  engine.seek(0);
  final before = engine.stats;
  engine.play();
  await Future<void>.delayed(const Duration(seconds: 3));
  final playing = engine.stats;
  engine.pause();
  stdout.writeln('[selftest] sample: played 3s '
      'fps=${playing.presentFps.toStringAsFixed(1)} '
      'gpu=${playing.compositeMsAvg.toStringAsFixed(2)}ms '
      'layers=${playing.activeLayers} '
      'decoders=${playing.openDecoders} '
      'audio=${playing.audioAvailable} '
      'underruns=${playing.audioUnderruns} '
      'rasters=${playing.textRasters - before.textRasters} '
      'lut_uploads=${playing.lutUploads - before.lutUploads}');
}

/// The whole edit, written to a file, while the preview is still open.
///
/// `vd_export_test.c` already pins what an export *is* — that the file opens,
/// that its index is at the front, that HEVC is tagged `hvc1`, that the picture
/// is the one the compositor drew and the sound is the one the mixer made. All
/// of that runs on a 320x240 fixture in a second.
///
/// Two things it cannot answer. How fast this actually is on a real machine at
/// the project's real size, with real footage, captions, shapes, a sticker and
/// a transition in it — the ratio at the end of this is the only honest answer
/// to "how long will my export take". And whether an export and a preview can
/// be alive at once: they are two engines, two compositors and two sets of
/// decoders over the same files, and the failure mode if they cannot is the
/// export finishing and the preview having quietly stopped.
Future<void> runExportSelfTest(PreviewEngine engine, DocumentStore store) async {
  final project = store.project;
  if (project.duration.raw <= 0) {
    stdout.writeln('[selftest] export: nothing on the timeline');
    return;
  }

  // Free, like a fresh installation — which is what makes the line below a
  // check on the gate and not a way around it. The self-test project is
  // 1080p, so the gate lets it through; a 4K one would stop here, which is
  // the point.
  final plan = ExportPlan.of(project);
  if (!plan.isPermitted) {
    stdout.writeln('[selftest] export: '
        '${plan.outputFormat.width}x${plan.outputFormat.height} needs Pro');
    return;
  }
  final path = '${Directory.systemTemp.path}/vdodtor_selftest_export.mp4';
  final file = File(path);
  if (file.existsSync()) file.deleteSync();

  stdout.writeln('[selftest] export: '
      '${plan.outputFormat.width}x${plan.outputFormat.height}, '
      '${plan.frameCount} frames, '
      '${formatBitrate(plan.videoBitrate)}, '
      'about ${formatBytes(plan.estimatedBytes)}');

  final before = engine.stats;
  final clock = Stopwatch()..start();
  final exporter = Exporter.start(
    plan.timelineFor(project),
    path,
    settings: plan.settings,
  );

  // Polled rather than awaited: the point is that the app's own event loop
  // keeps turning while a native thread writes a film.
  while (exporter.progress.isRunning && clock.elapsed.inMinutes < 5) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  clock.stop();
  final progress = exporter.progress;
  exporter.dispose();

  final seconds = clock.elapsedMilliseconds / 1000;
  final projectSeconds = project.duration.raw / Timebase.project.ticksPerSecond;
  stdout.writeln('[selftest] export: ${progress.state.name} — '
      '${progress.framesWritten}/${progress.framesTotal} frames in '
      '${seconds.toStringAsFixed(2)}s '
      '(${(projectSeconds / (seconds == 0 ? 1 : seconds)).toStringAsFixed(1)}x '
      'realtime)');

  if (progress.state != ExportState.done) {
    stdout.writeln('[selftest] export: failed — ${exporter.failureMessage}');
    return;
  }

  // Read back rather than trusted. The engine wrote it; the probe is a
  // different piece of code opening it as any other player would.
  final size = file.existsSync() ? file.lengthSync() : 0;
  final probe = VdodtorEngine.probeFile(path);
  stdout.writeln('[selftest] export: ${formatBytes(size)} on disk '
      '(estimated ${formatBytes(plan.estimatedBytes)}) — '
      '${probe.width}x${probe.height} ${probe.videoCodec}'
      '${probe.hasAudio ? " + ${probe.audioCodec}" : ", silent"}, '
      '${(probe.durationTicks / Timebase.project.ticksPerSecond)
          .toStringAsFixed(2)}s');
  stdout.writeln('[selftest] export: written to $path');

  // The preview was up the whole time. If two engines over one set of files
  // were a problem, this is where it would show: a texture that stopped
  // publishing, or a decoder that failed under a second reader.
  engine.seek(0);
  await Future<void>.delayed(const Duration(milliseconds: 200));
  final after = engine.stats;
  stdout.writeln('[selftest] export: preview still alive — '
      '${after.framesPresented - before.framesPresented} frames presented '
      'across the export, ${after.openDecoders} decoders open');
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
List<File> sampleMediaFiles({String suffix = '.mp4'}) {
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
      .where((f) => f.path.endsWith(suffix))
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
    for (final source in [
      ...sampleMediaFiles(),
      // A file with no picture, so the import lands on an audio lane rather
      // than the main track. That branch of `place` had never been walked by
      // anything unattended, and a music bed on an audio lane is the shape
      // this milestone exits on.
      ...sampleMediaFiles(suffix: '.m4a'),
      // And an animated overlay, which walks the third branch: an overlay lane
      // the project does not have yet, made as part of the same edit.
      ...sampleMediaFiles(suffix: '.gif'),
    ])
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

/// What the container said about each source's geometry, and what came out of
/// the compositor once it had been believed.
///
/// Rotation and sample aspect are the two things about a file that decide its
/// shape without changing a pixel of it, and both fail quietly: a clip on its
/// side, or squeezed to half the width it should be, still plays, still
/// exports, and still looks like a file someone shot badly. So this prints the
/// coded size, the metadata and the display size for every asset — the three
/// numbers that have to agree — and then dumps a frame of every turned clip,
/// because which way up a picture is can only be seen.
///
/// It does not say which *frame* of a variable-rate source came out. Nothing
/// up here can: the engine reports a position on the project's grid, not the
/// source timestamp it resolved to, and adding a back channel for a self test
/// would be a worse trade than testing it where the timestamps are legible.
/// That is `test_a_frame_is_on_screen_until_the_next_one` in
/// engine/tests/vd_decoder_test.c, which asserts the whole mapping.
Future<void> runSourceGeometrySelfTest(
    PreviewEngine engine, Project project) async {
  final out = Directory.systemTemp.createTempSync('vdodtor_geometry_');

  for (final asset in project.media.values) {
    if (!asset.probe.hasVideo) continue;
    final p = asset.probe;
    stdout.writeln('[selftest] geometry: ${asset.displayName} '
        'coded ${p.width}x${p.height} '
        'par ${p.pixelAspect} rot ${p.rotationDegrees} '
        'vfr ${p.variableFrameRate} '
        '-> display ${p.displayWidth}x${p.displayHeight}');
  }

  // One frame from the middle of each turned clip. Only the turned ones: a
  // sample aspect changes the shape of the picture and the line above already
  // says so in numbers, where which way up a picture is can only be seen.
  for (final clip in project.tracks.expand((t) => t.clips)) {
    final asset = project.assetFor(clip);
    if (asset == null || !asset.probe.hasVideo) continue;
    if (asset.probe.rotationDegrees == 0) continue;
    engine.seek(clip.start.raw + clip.duration.raw ~/ 2);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final name = asset.displayName.replaceAll('.', '_');
    final path = '${out.path}/$name.png';
    engine.dumpPng(path);
    stdout.writeln('[selftest] geometry: ${asset.displayName} at '
        '${clip.start.raw + clip.duration.raw ~/ 2} -> $path');
  }
  stdout.writeln('[selftest] geometry: frames in ${out.path}');
}

/// Analyses a file's audio through the real engine and prints the envelope it
/// produced, then does it again to show the cache doing its job.
///
/// The fixture it prefers is `audio_steps.m4a`, whose shape is known by
/// construction: a second of silence, a second at a quarter, and a second at
/// nine tenths on one channel only. Printed a second at a time, a correct
/// analysis reads 0.00 / 0.25 / 0.90 straight down the page — which is a check
/// anyone can make at a glance, where a number of buckets is a check on
/// nothing.
Future<void> runWaveformSelfTest() async {
  final samples = [
    ...sampleMediaFiles(suffix: 'audio_steps.m4a'),
    ...sampleMediaFiles(),
  ];
  if (samples.isEmpty) {
    stdout.writeln('[selftest] waveform: no sample to analyse');
    return;
  }
  final sample = samples.first;

  final clock = Stopwatch()..start();
  final NativePeaks? native;
  try {
    native = await Peaks.analyze(sample.path);
  } catch (error) {
    stdout.writeln('[selftest] waveform: FAILED $error');
    return;
  }
  clock.stop();

  if (native == null) {
    stdout.writeln('[selftest] waveform: ${sample.uri.pathSegments.last} '
        'has no audio');
    return;
  }

  final peaks = PeakPyramid.fromNative(native);
  stdout.writeln('[selftest] waveform: ${sample.uri.pathSegments.last} '
      '${peaks.levelCount} levels, ${peaks.buckets.length ~/ 2} buckets, '
      '${(peaks.duration.raw / 120000).toStringAsFixed(2)}s, '
      '${PeakFile.encode(peaks).length ~/ 1024} KB, '
      '${clock.elapsedMilliseconds} ms');

  // One pixel per second, then one per tenth: the same file read at two
  // resolutions has to agree about where the loud part is, and that is the
  // whole claim the pyramid makes. A column is always at least one whole
  // bucket wide, so at the coarse end a step smears by up to a bucket — which
  // at one column per second is most of a column, and at any zoom the timeline
  // actually offers is a pixel.
  for (final perPixel in [1.0, 0.1]) {
    final ticksPerPixel = 120000 * perPixel;
    final pixels = (peaks.duration.raw / ticksPerPixel).floor();
    if (pixels < 1) continue;
    final envelope = peaks.envelope(
        from: Tick.zero, ticksPerPixel: ticksPerPixel, pixels: pixels);
    final heights = [
      for (var i = 0; i < pixels; i++) envelope[i * 2 + 1].toStringAsFixed(2),
    ];
    stdout.writeln('[selftest] waveform: ${perPixel}s per column — '
        '${heights.join(" ")}');
  }

  // And the cache, end to end: written on the first ask, read on the second.
  // In a scratch directory rather than the app's real one: this measures a
  // cold cache, and it would not be cold twice if it shared the app's.
  final directory =
      Directory.systemTemp.createTempSync('vdodtor_peaks_selftest_');
  final asset = MediaAsset(
    id: 'selftest-waveform',
    path: sample.path,
    displayName: sample.uri.pathSegments.last,
    probe: MediaProbe(kind: MediaKind.audio, duration: peaks.duration,
        hasAudio: true),
  );
  for (final pass in ['analysed', 'cached']) {
    final passClock = Stopwatch()..start();
    final one = WaveformCache(directory: directory);
    one.request(asset);
    for (var i = 0; i < 4000; i++) {
      if (one.stateOf(asset.id) != WaveformState.pending) break;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    passClock.stop();
    stdout.writeln('[selftest] waveform: $pass in '
        '${passClock.elapsedMilliseconds} ms, '
        'state ${one.stateOf(asset.id).name}');
    one.dispose();
  }

  await drawWaveformSelfTest(sample, peaks, directory);
}

/// The volume line, end to end: a duck put on a real clip with the real
/// command, evaluated by the real model, and drawn by the real painter.
///
/// The mixer's side of this is measured in C, where the level of what comes
/// out of it can actually be read — `engine/tests/vd_audio_test.c`. What only
/// this can show is the rest of the chain: that a curve drawn on a document
/// survives into the render list as points rather than as a resolved gain, and
/// that the timeline draws the dip where the dip is.
///
/// The duck is left on the clip rather than undone, so the play pass that
/// follows is playing a ducked timeline and anyone watching can hear it.
Future<void> runVolumeLineSelfTest(DocumentStore store) async {
  final target = _clipToDuck(store.project);
  if (target == null) {
    stdout.writeln('[selftest] volume line: nothing with sound to duck');
    return;
  }
  final (:trackId, :clip) = target;
  final asset = store.project.assetFor(clip)!;

  // Full for the first third, a fifth through the middle, back up for the
  // last: the shape of a duck under a voice-over, and the one a listener can
  // recognise without a meter.
  final third = Tick(clip.duration.raw ~/ 3);
  final ramp = Tick(third.raw ~/ 4);
  final points = [
    VolumePoint(clip.sourceIn + third - ramp, 1),
    VolumePoint(clip.sourceIn + third, 0.2),
    VolumePoint(clip.sourceIn + third + third, 0.2),
    VolumePoint(clip.sourceIn + third + third + ramp, 1),
  ];

  store.endGesture();
  store.run(SetClipAudio(
      clip.id, clip.audio.withoutAutomation.copyWith(points: points)));
  store.endGesture();

  final ducked = store.project.clipById(clip.id)!;
  stdout.writeln('[selftest] volume line: ${asset.displayName} on $trackId, '
      '${ducked.audio.points.length} points over '
      '${(ducked.duration.raw / 120000).toStringAsFixed(2)}s');

  // A tenth of a second a column, the way the waveform envelope is printed:
  // a correct curve reads 1.00 down to 0.20 and back up, and a curve read
  // against the clip instead of the source would start in the wrong place.
  final tenth = 120000 ~/ 10;
  final columns = ducked.duration.raw ~/ tenth;
  final gains = [
    for (var i = 0; i < columns; i++)
      ducked.gainAt(Tick(i * tenth)).toStringAsFixed(2),
  ];
  stdout.writeln('[selftest] volume line: 0.1s per column — ${gains.join(" ")}');

  // And what actually crosses to the engine. Points, not a number: the mixer
  // has to evaluate this per audio frame.
  final list = engineTimelineFor(store.project);
  final sent = list.clips.where((c) => c.path == asset.path).toList();
  if (sent.isEmpty) {
    stdout.writeln('[selftest] volume line: FAILED — the clip did not reach '
        'the render list at all');
  } else {
    final entry = sent.first;
    stdout.writeln('[selftest] volume line: engine gets gain '
        '${entry.gain.toStringAsFixed(2)} and '
        '${entry.volumePoints.length} points '
        '[${entry.volumePoints.map((p) => "${p.sourceTicks}:"
            "${p.value.toStringAsFixed(2)}").join(" ")}]');
  }

  final cache =
      Directory.systemTemp.createTempSync('vdodtor_volume_selftest_');
  final out = '${Directory.systemTemp.path}/vdodtor_volume_line.png';
  await _drawTimeline(store.project, cache, out,
      const Size(900, 220), duration: store.project.duration);
  stdout.writeln('[selftest] volume line: timeline drawn to $out');
}

/// The clip a duck goes on: the first one on an audio lane, and failing that
/// the first one with any sound in it.
({String trackId, Clip clip})? _clipToDuck(Project project) {
  ({String trackId, Clip clip})? fallback;
  for (final track in project.tracks) {
    for (final clip in track.clips) {
      final asset = project.assetFor(clip);
      if (asset == null || !asset.probe.hasAudio) continue;
      if (track.kind == TrackKind.audio) return (trackId: track.id, clip: clip);
      fallback ??= (trackId: track.id, clip: clip);
    }
  }
  return fallback;
}

/// Draws [project]'s timeline, waveforms and all, and writes it to [path].
Future<void> _drawTimeline(Project project, Directory cache, String path,
    Size size, {required Tick duration}) async {
  final store = DocumentStore(project);
  final controller = TimelineController(
      store: store, transport: _StillTransport(duration.raw));
  controller.viewportWidth = size.width;
  controller.zoomToFit();

  final waveforms = WaveformCache(directory: cache);
  for (final asset in project.media.values) {
    waveforms.request(asset);
  }
  for (var i = 0; i < 8000; i++) {
    if (project.media.values
        .every((a) => waveforms.stateOf(a.id) != WaveformState.pending)) {
      break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }

  final recorder = PictureRecorder();
  TimelinePainter(controller, waveforms: waveforms)
      .paint(Canvas(recorder), size);
  final image = await recorder
      .endRecording()
      .toImage(size.width.round(), size.height.round());
  final png = await image.toByteData(format: ImageByteFormat.png);
  image.dispose();
  waveforms.dispose();
  controller.dispose();
  store.dispose();

  if (png == null) {
    stdout.writeln('[selftest] could not encode the timeline');
    return;
  }
  await File(path).writeAsBytes(png.buffer.asUint8List());
}

/// Draws the timeline with the analysed file on an audio lane and writes it
/// out, so what a waveform built from real peaks looks like is something
/// anyone can open rather than something to take on trust.
Future<void> drawWaveformSelfTest(
    File sample, PeakPyramid peaks, Directory cache) async {
  const size = Size(900, 134);

  final asset = MediaAsset(
    id: 'wave',
    path: sample.path,
    displayName: sample.uri.pathSegments.last,
    probe: MediaProbe(
        kind: MediaKind.audio, duration: peaks.duration, hasAudio: true),
  );
  final project = Project.empty(
    id: 'wave',
    name: 'Waveform',
    format: ProjectFormat.fromAspect(ProjectAspect.landscape16x9,
        frameRate: FrameRates.fps30),
    mainTrackId: 'tr-main',
    audioTrackId: 'tr-audio',
  ).addMedia(asset).updateTrack(
        'tr-audio',
        (t) => t.withClips([
          Clip(
            id: 'c1',
            mediaId: asset.id,
            start: Tick.zero,
            duration: peaks.duration,
            label: asset.displayName,
          ),
        ]),
      );

  final out = '${Directory.systemTemp.path}/vdodtor_waveform.png';
  await _drawTimeline(project, cache, out, size, duration: peaks.duration);
  stdout.writeln('[selftest] waveform: timeline drawn to $out');
}

/// Puts a caption on the timeline through the real commands, then dumps the
/// frame the engine draws for it.
///
/// The engine's own tests check the layout in ink bounds, which is the only
/// thing a rasteriser can be pinned on across macOS releases. What they cannot
/// check is that a caption reaches the screen *through the app*: the fonts
/// registered from the bundle, the document sync carrying the words rather
/// than a path, the compositor accepting a premultiplied BGRA layer over a
/// decoded one. All three fail silently, and all three are visible in one PNG.
///
/// It also prints the raster count before and after a scrub, because the whole
/// value of the cache is a number that does not move.
/// Returns the caption it worked on, so the animation pass that follows
/// animates *that* one rather than whichever it happens to find first.
Future<Clip?> runCaptionSelfTest(PreviewEngine engine, DocumentStore store,
    TimelineController timeline) async {
  stdout.writeln('[selftest] caption: fonts registered — '
      '${BundledFonts.families.join(", ")}');

  const styled = ClipText(
    text: 'vdodtor',
    font: 'Anton',
    size: 0.16,
    strokeColor: 0xFF101010,
    strokeWidth: 0.06,
    shadowColor: 0xB3000000,
    shadowOffsetY: 0.05,
    shadowBlur: 0.05,
    boxColor: 0x99000000,
  );

  // The sample project is the same one every run, so a pass that always added
  // a caption would leave a lane behind every time until there were no lanes
  // left — and two overlapping captions saying the same thing make every
  // dumped frame ambiguous. Restyle the one that is there, or make one.
  final existing = store.project.tracks
      .expand((t) => t.clips)
      .where((c) => c.isText)
      .firstOrNull;
  String? id;
  if (existing != null) {
    store.endGesture();
    store.run(SetClipText(existing.id, styled));
    store.endGesture();
    id = existing.id;
  } else {
    // Over the middle of what is already there, so the frame shows the
    // caption on top of a picture rather than on black.
    final duration = store.project.duration;
    timeline.seekTo(Tick(duration.raw ~/ 3));
    if (!timeline.addTextClip(text: styled)) {
      stdout.writeln('[selftest] caption: nowhere to put one');
      return null;
    }
    id = timeline.selectedClipId;
  }
  if (id == null) return null;

  final clip = store.project.clipById(id)!;
  final track = store.project.trackOfClip(clip.id)!;
  stdout.writeln('[selftest] caption: "${clip.text!.label}" on ${track.name} '
      'at ${clip.start.raw} for ${clip.duration.raw} ticks');

  final sent = engineTimelineFor(store.project)
      .clips
      .where((c) => c.text != null)
      .toList();
  stdout.writeln('[selftest] caption: ${sent.length} reached the engine, '
      'path=${sent.isEmpty ? "-" : sent.first.path} '
      'font=${sent.isEmpty ? "-" : sent.first.text!.font}');

  // Let the render list land, then look at the middle of the caption.
  await Future<void>.delayed(const Duration(milliseconds: 200));
  engine.seek(clip.start.raw + clip.duration.raw ~/ 2);
  await Future<void>.delayed(const Duration(milliseconds: 200));

  final drawn = engine.stats;
  final path = '${Directory.systemTemp.path}/vdodtor_caption.png';
  engine.dumpPng(path);
  stdout.writeln('[selftest] caption: layers=${drawn.activeLayers} '
      'rasters=${drawn.textRasters} -> $path');

  // Scrubbing across it must not lay it out again: a caption does not change
  // with time, and re-running Core Text every frame is the failure the cache
  // exists to prevent.
  for (var i = 1; i <= 8; i++) {
    engine.seek(clip.start.raw + clip.duration.raw * i ~/ 9);
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
  stdout.writeln('[selftest] caption: after 8 seeks, rasters='
      '${engine.stats.textRasters} (was ${drawn.textRasters})');
  return clip;
}

/// A transition at a real cut, dumped frame by frame.
///
/// The engine's own tests check that both clips reach the screen; what they
/// cannot check is what a transition *looks like*, and a preset is a design
/// decision before it is a function. So this puts one on the first cut in the
/// project and dumps five frames across it — the only way to tell a dissolve
/// from a cross-fade to black is to look at the middle one.
///
/// It also prints the layer count through the window, which is the number that
/// says the overlap is happening at all: one clip either side of the
/// transition and two — or three, with a colour dipped between them — inside.
Future<void> runTransitionSelfTest(
    PreviewEngine engine, DocumentStore store) async {
  final main = store.project.mainTrack;
  if (main.clips.length < 2) {
    stdout.writeln('[selftest] transition: no cut to put one on');
    return;
  }

  // The first pair that actually meet. A gap is not a cut, and a transition
  // needs one.
  Clip? incoming;
  for (var i = 1; i < main.clips.length; i++) {
    if (main.clips[i - 1].end == main.clips[i].start) {
      incoming = main.clips[i];
      break;
    }
  }
  if (incoming == null) {
    stdout.writeln('[selftest] transition: every clip has a gap before it');
    return;
  }

  final out = Directory.systemTemp.createTempSync('vdodtor_transition_');
  for (final preset in [
    TransitionPreset.dissolve,
    TransitionPreset.fadeWhite,
    TransitionPreset.wipe,
    TransitionPreset.push,
  ]) {
    final transition = ClipTransition(
        preset: preset, duration: Tick(Timebase.project.ticksPerSecond));
    store.endGesture();
    store.run(SetClipTransition(incoming.id, transition));
    store.endGesture();

    final applied = store.project.clipById(incoming.id)!;
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final half = applied.transition.duration.raw ~/ 2;
    final buffer = StringBuffer();
    for (var i = 0; i <= 4; i++) {
      // From the start of the window to its end, straddling the cut.
      final at = applied.start.raw - half + (2 * half * i ~/ 4);
      engine.seek(at);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      engine.dumpPng('${out.path}/${preset.name}_$i.png');
      buffer.write('${engine.stats.activeLayers} ');
    }
    stdout.writeln('[selftest] transition: ${preset.name} across the cut at '
        '${applied.start.raw} — layers $buffer');
  }

  // And back to a plain cut, so the passes after this one see the timeline
  // they expect rather than one with a dissolve left on it.
  store.endGesture();
  store.run(SetClipTransition(incoming.id, ClipTransition.none));
  store.endGesture();
  stdout.writeln('[selftest] transition: frames in ${out.path}');
}

/// An animated overlay, imported the way a user would and then watched.
///
/// The engine's own tests check which frame is on screen when; what they
/// cannot check is that a GIF gets there *through the app* — classified by its
/// codec rather than its extension, placed on an overlay lane rather than
/// repacked into the main one, and opened as a sticker rather than handed to a
/// video decoder that cannot export a BGRA frame at all. The last of those
/// fails silently, as a clip that renders as a gap.
///
/// It prints the frame counter before and after a scrub, which is the number
/// that says the retiming is happening: a sticker should change frames at its
/// own rate and not at the project's.
Future<void> runStickerSelfTest(PreviewEngine engine, DocumentStore store,
    TimelineController timeline) async {
  final sticker = store.project.media.values
      .where((a) => a.probe.kind == MediaKind.sticker)
      .firstOrNull;
  if (sticker == null) {
    stdout.writeln('[selftest] sticker: none in the project');
    return;
  }

  final clip = store.project.tracks
      .expand((t) => t.clips)
      .where((c) => c.mediaId == sticker.id)
      .firstOrNull;
  if (clip == null) {
    stdout.writeln('[selftest] sticker: ${sticker.displayName} is in the bin '
        'and not on the timeline');
    return;
  }
  final track = store.project.trackOfClip(clip.id)!;
  stdout.writeln('[selftest] sticker: ${sticker.displayName} '
      'codec=${sticker.probe.videoCodec} '
      '${sticker.probe.displayWidth}x${sticker.probe.displayHeight} '
      'loop=${(sticker.probe.duration.raw / 120000).toStringAsFixed(2)}s '
      'on ${track.name} (${track.kind.name}) for '
      '${(clip.duration.raw / 120000).toStringAsFixed(2)}s');

  final sent = engineTimelineFor(store.project)
      .clips
      .where((c) => c.sticker)
      .toList();
  stdout.writeln('[selftest] sticker: ${sent.length} reached the engine as '
      'stickers');

  // Over the middle of the shot rather than on black, so the dumped frame
  // shows the overlay compositing and not just existing.
  timeline.seekTo(clip.start);
  await Future<void>.delayed(const Duration(milliseconds: 300));

  final out = Directory.systemTemp.createTempSync('vdodtor_sticker_');
  final before = engine.stats;
  // Four frames across one loop of the animation: if the retiming works these
  // are four different pictures, and if it does not they are all the first.
  for (var i = 0; i < 4; i++) {
    engine.seek(clip.start.raw + sticker.probe.duration.raw * i ~/ 4);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    engine.dumpPng('${out.path}/frame_$i.png');
  }
  final scrubbed = engine.stats;
  stdout.writeln('[selftest] sticker: 4 seeks across one loop put '
      '${scrubbed.stickerFrames - before.stickerFrames} further frames on '
      'screen, opens=${scrubbed.stickerOpens} '
      'held=${(scrubbed.stickerBytes / 1024).round()} KiB');

  // The ratio is the claim. Thirty renders across an animation that changes
  // four times has to put four frames on screen, not thirty — which is what
  // "retimed to the project's rate" means when nothing resamples anything.
  final dense = engine.stats;
  for (var i = 0; i < 30; i++) {
    engine.seek(clip.start.raw + sticker.probe.duration.raw * i ~/ 30);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  stdout.writeln('[selftest] sticker: 30 renders across the same loop cost '
      '${engine.stats.stickerFrames - dense.stickerFrames} frame changes');

  // And past the end of the animation, where it has to start again rather than
  // freeze — which is what makes a one-second GIF usable on a longer clip.
  engine.seek(clip.start.raw + sticker.probe.duration.raw * 2);
  await Future<void>.delayed(const Duration(milliseconds: 150));
  engine.dumpPng('${out.path}/looped.png');
  stdout.writeln('[selftest] sticker: frames in ${out.path}');
}

/// A shape on the timeline, drawn by the engine and dumped as a PNG.
///
/// [runCaptionSelfTest] for why a pass like this exists at all: the engine's
/// own tests check the geometry in ink bounds, and what they cannot check is
/// that a shape reaches the screen *through the app* — the document sync
/// carrying a spec rather than a path, the compositor accepting a second
/// premultiplied BGRA layer, the lane it shares with the captions ordering it
/// underneath them. All of those fail silently and all of them are visible in
/// one frame.
///
/// The four kinds go on one after another rather than side by side, because
/// four shapes in one frame is a picture nobody can read — and each is dumped
/// with the raster count beside it, which is the number that says the cache is
/// keyed on what it claims to be keyed on.
Future<void> runShapeSelfTest(PreviewEngine engine, DocumentStore store,
    TimelineController timeline) async {
  // Where the caption already is, a third of the way in, so a shape lands over
  // a picture rather than on black — and, the caption's own lane being busy at
  // that moment, on a lane above it. That is the frame worth dumping: two
  // drawn layers and a decoded one, in an order somebody can check by eye.
  final duration = store.project.duration;
  timeline.seekTo(Tick(duration.raw ~/ 3));

  final existing = store.project.tracks
      .expand((t) => t.clips)
      .where((c) => c.isShape)
      .firstOrNull;
  String? id = existing?.id;
  if (id == null) {
    // The sample project is the same one every run, so a pass that always
    // added one would leave a lane behind every time until there were none
    // left.
    if (!timeline.addShapeClip()) {
      stdout.writeln('[selftest] shape: nowhere to put one');
      return;
    }
    id = timeline.selectedClipId;
  }
  if (id == null) return;

  final track = store.project.trackOfClip(id)!;
  stdout.writeln('[selftest] shape: on ${track.name} at '
      '${store.project.clipById(id)!.start.raw} ticks');

  final out = Directory.systemTemp.createTempSync('vdodtor_shape_');
  for (final shape in [
    const ClipShape(
      width: 1.2,
      height: 0.22,
      corner: 0.4,
      fillColor: 0xCC101010,
      strokeColor: 0xFFFFFFFF,
      strokeWidth: 0.004,
      shadowColor: 0xB3000000,
      shadowOffsetY: 0.02,
      shadowBlur: 0.02,
    ),
    ClipShape.of(ShapeKind.ellipse),
    ClipShape.of(ShapeKind.line),
    ClipShape.of(ShapeKind.arrow).copyWith(headSize: 0.35),
  ]) {
    store.endGesture();
    store.run(SetClipShape(id, shape));
    store.endGesture();

    // Let the render list land, then look at the middle of the clip.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final clip = store.project.clipById(id)!;
    engine.seek(clip.start.raw + clip.duration.raw ~/ 2);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final stats = engine.stats;
    engine.dumpPng('${out.path}/${shape.kind.name}.png');
    stdout.writeln('[selftest] shape: ${shape.kind.name} '
        'layers=${stats.activeLayers} rasters=${stats.shapeRasters}');
  }

  // Scrubbing across it must not draw it again — the same bargain a caption
  // gets, and the reason the raster is kept rather than made per frame.
  final before = engine.stats;
  final clip = store.project.clipById(id)!;
  for (var i = 1; i <= 8; i++) {
    engine.seek(clip.start.raw + clip.duration.raw * i ~/ 9);
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
  stdout.writeln('[selftest] shape: after 8 seeks, '
      '${engine.stats.shapeRasters - before.shapeRasters} further draws');
  stdout.writeln('[selftest] shape: frames in ${out.path}');
}

/// An animation, watched frame by frame in the running app.
///
/// The engine's own tests check the arithmetic and the wiring; what they
/// cannot check is what it *looks like*, and a preset is a design decision
/// before it is a function. So this puts one on a caption and dumps the
/// entrance a few frames apart — four PNGs where the words arrive is the only
/// way to tell a pop from a jolt.
///
/// It also prints what a typewriter costs, which is the one preset that is not
/// free: every other animation is the same pixels moved about, and the
/// typewriter redraws. Once per character is right; once per frame is the bug.
Future<void> runAnimationSelfTest(
    PreviewEngine engine, DocumentStore store, Clip? caption) async {
  if (caption == null) {
    stdout.writeln('[selftest] animation: no caption to animate');
    return;
  }

  const animation = ClipAnimation(
    inPreset: AnimationPreset.typewriter,
    inDuration: Tick(120000),
    outPreset: AnimationPreset.slideUp,
    outDuration: Tick(48000),
  );
  store.endGesture();
  store.run(SetClipAnimation(caption.id, animation));
  store.endGesture();

  final animated = store.project.clipById(caption.id)!;
  stdout.writeln('[selftest] animation: '
      'in ${animated.animation.inPreset.name} '
      '${animated.animation.inDuration.raw} ticks, '
      'out ${animated.animation.outPreset.name} '
      '${animated.animation.outDuration.raw} ticks');

  // Wait for the render list to reach the engine before asking it anything.
  await Future<void>.delayed(const Duration(milliseconds: 200));
  final before = engine.stats;

  final out = Directory.systemTemp.createTempSync('vdodtor_animation_');
  for (final fraction in [0.0, 0.25, 0.5, 0.75, 1.0]) {
    final at = animated.start.raw +
        (animated.animation.inDuration.raw * fraction).round();
    engine.seek(at);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final percent = (fraction * 100).round();
    engine.dumpPng('${out.path}/in_$percent.png');
  }
  // And one from the exit, which is a transform rather than a redraw.
  engine.seek(animated.end.raw - animated.animation.outDuration.raw ~/ 2);
  await Future<void>.delayed(const Duration(milliseconds: 150));
  engine.dumpPng('${out.path}/out_50.png');

  final typed = engine.stats.textRasters - before.textRasters;
  stdout.writeln('[selftest] animation: typing cost $typed layouts across '
      '6 frames of a ${animated.text!.text.length}-character caption');

  // The exit moves the same pixels, so scrubbing it must cost nothing at all.
  final settled = engine.stats;
  for (var i = 0; i < 8; i++) {
    engine.seek(animated.end.raw -
        animated.animation.outDuration.raw * i ~/ 8);
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
  stdout.writeln('[selftest] animation: the exit cost '
      '${engine.stats.textRasters - settled.textRasters} layouts');
  stdout.writeln('[selftest] animation: frames in ${out.path}');
}

/// A grade on a real shot, dumped one slider at a time.
///
/// The engine's own tests pin the arithmetic against numbers and one graded
/// pixel against a flat fixture. What neither can answer is whether the throw
/// of a slider is *usable* — whether full warmth is a correction or a
/// sunburn, whether full contrast still has a picture in it — and that is a
/// question only a frame of real footage asks. So this puts each slider at
/// both of its ends on the first video clip and dumps a frame of each.
///
/// It also prints the layer count and the decoder count around the drag. Both
/// should be flat: a grade is not an extra layer, and a slider that reopened
/// the file on every value would stutter the preview for the whole length of
/// the drag — which is exactly when the user is trying to look at it.
Future<void> runColorSelfTest(
    PreviewEngine engine, DocumentStore store) async {
  final clip = store.project.mainTrack.clips
      .where((c) => !c.isGenerated)
      .firstOrNull;
  if (clip == null) {
    stdout.writeln('[selftest] colour: nothing on the main lane to grade');
    return;
  }

  // Somewhere inside the clip, and away from its head so a transition or an
  // entrance left by an earlier pass cannot be what the frame shows.
  final at = clip.start.raw + clip.duration.raw ~/ 2;
  engine.seek(at);
  await Future<void>.delayed(const Duration(milliseconds: 200));

  final out = Directory.systemTemp.createTempSync('vdodtor_colour_');
  engine.dumpPng('${out.path}/neutral.png');
  final before = engine.stats;

  const grades = <String, ClipColor>{
    'warm': ClipColor(temperature: 1),
    'cool': ClipColor(temperature: -1),
    'magenta': ClipColor(tint: 1),
    'green': ClipColor(tint: -1),
    'bright': ClipColor(brightness: 0.5),
    'dark': ClipColor(brightness: -0.5),
    'punchy': ClipColor(contrast: 0.5),
    'flat': ClipColor(contrast: -0.5),
    'vivid': ClipColor(saturation: 1),
    'mono': ClipColor(saturation: -1),
    // The look somebody would actually reach for, and the one that says the
    // five compose into something rather than five things fighting.
    'graded': ClipColor(
        temperature: 0.25, brightness: 0.1, contrast: 0.3, saturation: 0.2),
  };

  for (final entry in grades.entries) {
    store.endGesture();
    store.run(SetClipColor(clip.id, entry.value));
    store.endGesture();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    engine.dumpPng('${out.path}/${entry.key}.png');
  }

  final after = engine.stats;
  stdout.writeln('[selftest] colour: ${grades.length} grades on ${clip.id} '
      'at $at — layers ${before.activeLayers} then ${after.activeLayers}, '
      'decoders ${before.openDecoders} then ${after.openDecoders}');

  // And back to the shot as it was shot, so the passes after this one see the
  // timeline they expect rather than one with a look left on it.
  store.endGesture();
  store.run(SetClipColor(clip.id, ClipColor.neutral));
  store.endGesture();
  await Future<void>.delayed(const Duration(milliseconds: 150));
  engine.dumpPng('${out.path}/neutral_again.png');
  stdout.writeln('[selftest] colour: frames in ${out.path}');
}

/// Every look the app ships, on a real shot, at full strength and at half.
///
/// `vd_lut_test.c` asserts what each of these cubes does to a colour and
/// `vd_compositor_test.c` asserts that one reaches a fragment. Neither can
/// answer the only question that matters about a *look*, which is whether it
/// is one anybody would choose — and that is a question a frame of real
/// footage asks and a lattice of numbers cannot.
///
/// It also prints the upload count around the whole pass. A cube is a few
/// hundred kilobytes and the same cube on every frame of every clip wearing
/// it, so this should tick once per look and never again: once per look for
/// the whole run, and *not* once more for the half-strength dump of the same
/// one, which is the drag on the strength slider in miniature.
Future<void> runLookSelfTest(
    PreviewEngine engine, DocumentStore store) async {
  final clip = store.project.mainTrack.clips
      .where((c) => !c.isGenerated)
      .firstOrNull;
  if (clip == null) {
    stdout.writeln('[selftest] looks: nothing on the main lane to grade');
    return;
  }

  final at = clip.start.raw + clip.duration.raw ~/ 2;
  engine.seek(at);
  await Future<void>.delayed(const Duration(milliseconds: 200));

  final out = Directory.systemTemp.createTempSync('vdodtor_looks_');
  engine.dumpPng('${out.path}/none.png');
  final before = engine.stats;

  // Every look the catalogue offers, the built-in five *and* the ones the
  // Cinema pack brought — because the tier gates what may be chosen and never
  // what is drawn, and the way to prove that is to render the locked ones on a
  // free installation and look at the pictures.
  final catalogue = ContentPacks.looks;
  for (final item in catalogue) {
    final name = item.name;
    for (final strength in const [1.0, 0.5]) {
      store.endGesture();
      store.run(SetClipColor(
          clip.id, ClipColor(look: name, lookStrength: strength)));
      store.endGesture();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final slug = name.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '_');
      engine.dumpPng(
          '${out.path}/${slug}_${(strength * 100).round()}.png');
    }
  }

  // A look and the five sliders on one clip, which is the whole feature in one
  // frame: the sliders correct the shot and the look styles what they left.
  store.endGesture();
  store.run(SetClipColor(
      clip.id,
      ClipColor(
        temperature: 0.2,
        contrast: 0.2,
        look: catalogue.first.name,
        lookStrength: 0.7,
      )));
  store.endGesture();
  await Future<void>.delayed(const Duration(milliseconds: 150));
  engine.dumpPng('${out.path}/corrected_then_looked.png');

  final after = engine.stats;
  final locked = catalogue.where((l) => l.isLocked).length;
  stdout.writeln('[selftest] looks: ${catalogue.length} looks '
      '($locked from packs) at two strengths on ${clip.id} at $at — '
      'layers ${before.activeLayers} then ${after.activeLayers}, '
      'decoders ${before.openDecoders} then ${after.openDecoders}, '
      'cubes uploaded ${before.lutUploads} then ${after.lutUploads}');
  stdout.writeln('[selftest] packs: '
      '${ContentPacks.packs.map((p) => '${p.name}/${p.tier.name}').join(', ')}');

  // And back to the shot as it was shot, so the passes after this one see the
  // timeline they expect.
  store.endGesture();
  store.run(SetClipColor(clip.id, ClipColor.neutral));
  store.endGesture();
  await Future<void>.delayed(const Duration(milliseconds: 150));
  engine.dumpPng('${out.path}/none_again.png');
  stdout.writeln('[selftest] looks: frames in ${out.path}');
}

/// The two things a clip can do to its own sound beyond its level: the shape
/// its fades ramp in, and the filter it runs through.
///
/// The engine's own tests pin both against numbers — `vd_audio_test.c` asserts
/// the same fade table this prints, curve for curve, and `vd_eq_test.c` pushes
/// sine waves through every preset and reads the decibels off. What neither
/// can show is the part that only exists up here: that a curve chosen in the
/// inspector survives into the render list as a *shape* rather than as a
/// number, that a preset survives as a name, and that the envelope the
/// timeline draws is the one the mixer plays.
///
/// So this prints the envelope a tenth of a second at a time, once per curve,
/// straight out of `Clip.gainAt` — the function the waveform painter uses. Four
/// rows that all start at 0 and end at 1 and get there differently is a check
/// anybody can make at a glance.
///
/// It puts the clip's sound back the way it found it, so the play pass at the
/// end is playing the timeline the passes before it left.
Future<void> runAudioEffectsSelfTest(
    PreviewEngine engine, DocumentStore store) async {
  final target = _clipToDuck(store.project);
  if (target == null) {
    stdout.writeln('[selftest] audio: nothing with sound to shape');
    return;
  }
  final (:trackId, :clip) = target;
  final asset = store.project.assetFor(clip)!;
  final original = clip.audio;

  // A fade over the first and last second of the clip, which is long enough
  // for the four curves to be visibly different a tenth of a second apart.
  //
  // Without the volume line the pass before this one drew, and only for the
  // printing: `gainAt` multiplies the fade by the duck, so a table read
  // through one would be four curves with a descending ramp folded into all of
  // them. The duck goes back on at the end with everything else.
  final second = Tick(Timebase.project.ticksPerSecond);
  final fades =
      original.withoutAutomation.copyWith(fadeIn: second, fadeOut: second);
  final tenth = Timebase.project.ticksPerSecond ~/ 10;
  final columns = (second.raw / tenth).floor();

  stdout.writeln('[selftest] audio: ${asset.displayName} on $trackId, '
      '${(clip.duration.raw / 120000).toStringAsFixed(2)}s, '
      '1s fades');

  for (final curve in FadeCurve.values) {
    store.endGesture();
    store.run(SetClipAudio(clip.id, fades.copyWith(fadeCurve: curve)));
    store.endGesture();

    final shaped = store.project.clipById(clip.id)!;
    // Through `gainAt` rather than through `fadeShapeAt`, deliberately: that
    // is the function the waveform painter calls, so this is the envelope the
    // timeline actually draws and not a second opinion about it.
    final gains = [
      for (var i = 0; i < columns; i++)
        shaped.gainAt(Tick(i * tenth)).toStringAsFixed(2),
    ];
    final sent = engineTimelineFor(store.project)
        .clips
        .where((c) => c.path == asset.path)
        .toList();
    stdout.writeln('[selftest] audio: ${curve.label.padRight(11)} '
        '${gains.join(" ")}  — engine gets '
        '${sent.isEmpty ? "-" : sent.first.fadeCurve.name}');
  }

  // And the filter. What crosses is the preset's *name*: nothing up here knows
  // what a "voice" is, which is the same bargain a look takes.
  for (final preset in EqPreset.values) {
    store.endGesture();
    store.run(SetClipAudio(
        clip.id, fades.copyWith(fadeCurve: FadeCurve.smooth, eq: preset)));
    store.endGesture();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final sent = engineTimelineFor(store.project)
        .clips
        .where((c) => c.path == asset.path)
        .toList();
    stdout.writeln('[selftest] audio: eq ${preset.label.padRight(10)} '
        'engine gets ${sent.isEmpty ? "-" : sent.first.eq.name}');
  }

  // The part no offline test can reach: a cascade of biquads running under a
  // real deadline. Every underrun here is audible, and a filter that cannot
  // keep up shows up nowhere else.
  store.endGesture();
  store.run(SetClipAudio(
      clip.id,
      fades.copyWith(fadeCurve: FadeCurve.equalPower, eq: EqPreset.voice)));
  store.endGesture();
  await Future<void>.delayed(const Duration(milliseconds: 300));

  engine.seek(clip.start.raw);
  await Future<void>.delayed(const Duration(milliseconds: 200));
  final before = engine.stats;
  final clock = Stopwatch()..start();
  engine.play();
  await Future<void>.delayed(const Duration(seconds: 3));
  final playing = engine.stats;
  clock.stop();
  engine.pause();

  stdout.writeln('[selftest] audio: played 3s of a filtered, faded clip — '
      'underruns ${playing.audioUnderruns - before.audioUnderruns}, '
      'buffered ${playing.audioBufferedFrames}, '
      'frames ${playing.framesPresented - before.framesPresented} in '
      '${(clock.elapsedMilliseconds / 1000).toStringAsFixed(2)}s, '
      'late ${playing.framesLate - before.framesLate}');

  // Drawn, because the waveform is scaled by the same envelope and a fade the
  // page shows and the speakers play disagreeing about is the whole thing the
  // shared table exists to prevent.
  final cache = Directory.systemTemp.createTempSync('vdodtor_audiofx_');
  final out = '${Directory.systemTemp.path}/vdodtor_fade_curves.png';
  // Tall enough to reach the audio lane. By the time this pass runs there are
  // two text lanes, an overlay and the main track above it, and a canvas the
  // height the volume-line pass uses would cut off the clip this is about.
  await _drawTimeline(store.project, cache, out, const Size(900, 360),
      duration: store.project.duration);
  stdout.writeln('[selftest] audio: timeline drawn to $out');

  store.endGesture();
  store.run(SetClipAudio(clip.id, original));
  store.endGesture();
  stdout.writeln('[selftest] audio: put back — '
      'eq ${store.project.clipById(clip.id)!.audio.eq.name}, '
      'curve ${store.project.clipById(clip.id)!.audio.fadeCurve.name}');
}

/// A clip played at other speeds, watched and listened to.
///
/// The engine's own tests pin both halves of this against numbers:
/// `vd_engine_test.c` checks which source frame reaches the screen at a given
/// rate, and `vd_stretch_test.c` and `vd_audio_test.c` check that a 440 Hz tone
/// is still 440 Hz at 2x — or 880 with the toggle on. What none of them can
/// answer is whether the stretcher keeps up *in real time*, because they all
/// pull the renderer offline with no device and no deadline.
///
/// So this one plays. The number to read is the underrun count across the
/// play: every underrun is audible, and a WSOLA that cannot fill the ring
/// inside its budget shows up here and nowhere else. The frames it dumps
/// answer the other question a page of numbers cannot — whether four times
/// slower looks like slow motion or like a stutter.
///
/// It puts the clip back at its own speed, so the passes after it see the
/// timeline they expect. Retiming rounds to a whole tick each time, so "back"
/// is within a few microseconds rather than exact.
Future<void> runSpeedSelfTest(PreviewEngine engine, DocumentStore store) async {
  final target = _clipToRetime(store.project);
  if (target == null) {
    stdout.writeln('[selftest] speed: nothing on the main lane to retime');
    return;
  }
  final asset = store.project.assetFor(target)!;
  final original = target.duration;
  stdout.writeln('[selftest] speed: ${asset.displayName} on ${target.id}, '
      '${(original.raw / 120000).toStringAsFixed(2)}s, '
      'sound=${asset.probe.hasAudio}');

  final out = Directory.systemTemp.createTempSync('vdodtor_speed_');
  final before = engine.stats;

  for (final speed in const [
    ClipSpeed(rate: 0.25),
    ClipSpeed(rate: 0.5),
    ClipSpeed(rate: 2),
    ClipSpeed(rate: 4),
    // The tape, which is the other half of the toggle and the one worth
    // hearing rather than reading.
    ClipSpeed(rate: 2, pitchShift: true),
  ]) {
    store.endGesture();
    store.run(SetClipSpeed(target.id, speed));
    store.endGesture();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final clip = store.project.clipById(target.id)!;
    final sent = engineTimelineFor(store.project)
        .clips
        .where((c) => c.path == asset.path)
        .toList();
    final slug = '${(speed.rate * 100).round()}'
        '${speed.pitchShift ? '_pitched' : ''}';

    // Four *project* frames in a row from the head of the clip, which is the
    // only way to see what a rate does: at a quarter speed those four are the
    // same picture, and at four times they are sixteen source frames apart.
    // Seeking to the same fraction of each clip would land on the same frame
    // of the file every time and dump five identical PNGs.
    final frame = Timebase.project.ticksPerFrame(FrameRates.fps30);
    final sourceTimes = <String>[];
    for (var i = 0; i < 4; i++) {
      final at = clip.start.raw + i * frame;
      engine.seek(at);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      engine.dumpPng('${out.path}/at_${slug}_f$i.png');
      sourceTimes.add(
          (clip.sourceTimeAt(Tick(at)).raw / 120000).toStringAsFixed(3));
    }

    stdout.writeln('[selftest] speed: ${speed.rate}x'
        '${speed.pitchShift ? ' pitched' : ''} — '
        '${(clip.duration.raw / 120000).toStringAsFixed(2)}s on the timeline, '
        '${(clip.sourceDuration.raw / 120000).toStringAsFixed(2)}s of file, '
        'engine gets speed=${sent.isEmpty ? '-' : sent.first.speed} '
        'shift=${sent.isEmpty ? '-' : sent.first.pitchShift}, '
        'four frames land at ${sourceTimes.join(" ")}, '
        'layers=${engine.stats.activeLayers} '
        'decoders=${engine.stats.openDecoders}');
  }

  // And the part only a running app can measure: playing a retimed clip at
  // half speed with the pitch kept, which is the expensive path, and counting
  // what the device had to be given silence for.
  store.endGesture();
  store.run(SetClipSpeed(target.id, const ClipSpeed(rate: 0.5)));
  store.endGesture();
  await Future<void>.delayed(const Duration(milliseconds: 300));

  final retimed = store.project.clipById(target.id)!;
  engine.seek(retimed.start.raw);
  await Future<void>.delayed(const Duration(milliseconds: 200));
  final beforePlay = engine.stats;
  final clock = Stopwatch()..start();
  engine.play();
  await Future<void>.delayed(const Duration(seconds: 3));
  final playing = engine.stats;
  clock.stop();
  engine.pause();

  stdout.writeln('[selftest] speed: played 3s at half speed — '
      'underruns ${playing.audioUnderruns - beforePlay.audioUnderruns}, '
      'buffered ${playing.audioBufferedFrames}, '
      'frames ${playing.framesPresented - beforePlay.framesPresented} in '
      '${(clock.elapsedMilliseconds / 1000).toStringAsFixed(2)}s, '
      'late ${playing.framesLate - beforePlay.framesLate}');

  store.endGesture();
  store.run(SetClipSpeed(target.id, ClipSpeed.normal));
  store.endGesture();
  await Future<void>.delayed(const Duration(milliseconds: 200));
  engine.seek(store.project.clipById(target.id)!.start.raw);
  await Future<void>.delayed(const Duration(milliseconds: 200));
  engine.dumpPng('${out.path}/at_100_again_f0.png');

  final restored = store.project.clipById(target.id)!;
  stdout.writeln('[selftest] speed: back at 1x — '
      '${(restored.duration.raw / 120000).toStringAsFixed(3)}s against '
      '${(original.raw / 120000).toStringAsFixed(3)}s, '
      'layers ${before.activeLayers} then ${engine.stats.activeLayers}, '
      'decoders ${before.openDecoders} then ${engine.stats.openDecoders}');
  stdout.writeln('[selftest] speed: frames in ${out.path}');
}

/// The clip a retime goes on: the first one on the main lane with sound in it,
/// and failing that the first one at all. Sound, because the expensive half of
/// a speed change is the stretcher and a silent clip would not run it.
Clip? _clipToRetime(Project project) {
  Clip? fallback;
  for (final clip in project.mainTrack.clips) {
    if (clip.isGenerated) continue;
    final asset = project.assetFor(clip);
    if (asset == null || asset.probe.kind == MediaKind.image) continue;
    if (asset.probe.hasAudio) return clip;
    fallback ??= clip;
  }
  return fallback;
}

/// A playhead that never moves. The timeline needs one to draw; nothing here
/// is playing.
class _StillTransport implements TimelineTransport {
  _StillTransport(this.durationTicks);

  @override
  final int durationTicks;

  @override
  int get positionTicks => 0;

  @override
  bool get isPlaying => false;

  @override
  void seek(int ticks) {}

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
