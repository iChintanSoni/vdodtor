import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../app/workspace.dart';
import '../commands/document_store.dart';
import '../commands/edits.dart';
import '../engine/media_probe.dart';
import '../engine/timeline_sync.dart';
import '../media/file_access.dart';
import '../media/media_import.dart';
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
  controller.zoomToFit(size.width);

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
