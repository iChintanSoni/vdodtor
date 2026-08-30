import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../commands/document_store.dart';
import '../engine/media_probe.dart';
import '../engine/timeline_sync.dart';
import '../model/clip.dart';
import '../model/ids.dart';
import '../model/project.dart';
import '../model/time.dart';

/// M1's walking skeleton: a real document, synced to the real engine, playing
/// through the real compositor. The timeline UI from S2 binds to this same
/// [DocumentStore] next; this screen exists to prove the pipe works end to end.
class PreviewScreen extends StatefulWidget {
  const PreviewScreen({super.key});

  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  PreviewEngine? _engine;
  DocumentStore? _store;
  Object? _error;
  Timer? _statsTimer;
  EngineStats? _stats;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final store = DocumentStore(_buildDemoProject());
      final engine = await PreviewEngine.create();
      engine.setTimeline(engineTimelineFor(store.project));
      engine.seek(0);

      // The engine notifies on transport changes; the document notifies on
      // edits. Both need to reach this screen.
      engine.addListener(_onEngineChanged);
      store.addListener(_onDocumentChanged);

      if (!mounted) {
        await engine.dispose();
        return;
      }
      setState(() {
        _store = store;
        _engine = engine;
      });
      _statsTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (mounted) setState(() => _stats = _engine?.stats);
      });

      if (Platform.environment['VD_SELFTEST'] == '1') {
        unawaited(_selfTest(engine, store));
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  /// Checks the preview pipeline the way M0 insisted on checking it: by
  /// looking at the pixels, not at the frame counter. Run with VD_SELFTEST=1.
  Future<void> _selfTest(PreviewEngine engine, DocumentStore store) async {
    final out = Directory.systemTemp.createTempSync('vdodtor_selftest_');
    stdout.writeln('[selftest] project ${store.project.format}, '
        '${store.project.mainTrack.clips.length} clips, '
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
    // seek pass above already rendered a dozen frames, and folding those into
    // a frame rate reports a number nothing actually ran at.
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

  void _onEngineChanged() => setState(() {});

  void _onDocumentChanged() {
    final store = _store;
    final engine = _engine;
    if (store == null || engine == null) return;
    // Every committed edit re-syncs. The engine keeps decoders open for
    // sources that are still in the timeline, so this is cheap.
    engine.setTimeline(engineTimelineFor(store.project));
    setState(() {});
  }

  /// The bundled dev samples, on the main track, back to back.
  ///
  /// The App Sandbox lets the app read its own bundle and nothing else, so
  /// until the file picker lands in M1's import work, this is the only media
  /// the app can legitimately reach.
  Project _buildDemoProject() {
    final ids = IdGen();
    final samples = _sampleFiles();
    const probeService = MediaProbeService();

    var project = Project.empty(
      id: ids.next('pr-'),
      name: 'Sample project',
      format: ProjectFormat.fromAspect(ProjectAspect.landscape16x9,
          frameRate: FrameRates.fps30),
      mainTrackId: 'main',
      audioTrackId: 'audio',
    );

    final clips = <Clip>[];
    var cursor = Tick.zero;
    for (final file in samples) {
      final name = file.uri.pathSegments.last;
      try {
        final asset = probeService.probe(
          id: ids.next('m-'),
          path: file.path,
          displayName: name,
        );
        if (!asset.probe.hasVideo) continue;
        project = project.addMedia(asset);
        clips.add(Clip(
          id: ids.next('c-'),
          mediaId: asset.id,
          start: cursor,
          duration: asset.probe.duration,
          label: name,
        ));
        cursor += asset.probe.duration;
      } on EngineException {
        // A sample that will not probe is not worth failing the launch over.
        continue;
      }
    }

    return project.updateTrack('main', (t) => t.withClips(clips));
  }

  List<File> _sampleFiles() {
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

  @override
  void dispose() {
    _statsTimer?.cancel();
    _store?.removeListener(_onDocumentChanged);
    _engine?.removeListener(_onEngineChanged);
    unawaited(_engine?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engine = _engine;
    final store = _store;

    return Scaffold(
      backgroundColor: const Color(0xFF16181C),
      appBar: AppBar(
        title: const Text('vdodtor'),
        backgroundColor: const Color(0xFF1F2228),
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: SelectableText('The engine did not start.\n\n$_error',
                    textAlign: TextAlign.center),
              ),
            )
          : engine == null || store == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: store.project.format.width /
                              store.project.format.height,
                          child: EnginePreview(engine: engine),
                        ),
                      ),
                    ),
                    _TransportBar(engine: engine, store: store),
                    _StatsStrip(stats: _stats, store: store),
                  ],
                ),
    );
  }
}

class _TransportBar extends StatelessWidget {
  const _TransportBar({required this.engine, required this.store});

  final PreviewEngine engine;
  final DocumentStore store;

  @override
  Widget build(BuildContext context) {
    final duration = engine.durationTicks;
    final position = engine.positionTicks.clamp(0, duration).toDouble();

    return Container(
      color: const Color(0xFF1F2228),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          IconButton(
            iconSize: 32,
            icon: Icon(engine.isPlaying ? Icons.pause : Icons.play_arrow),
            onPressed: () => engine.isPlaying ? engine.pause() : engine.play(),
          ),
          IconButton(
            icon: const Icon(Icons.skip_previous),
            onPressed: () => engine.seek(0),
          ),
          const SizedBox(width: 8),
          Text(_timecode(position.round(), store.project.format.frameRate),
              style: const TextStyle(fontFamily: 'Menlo', fontSize: 12)),
          Expanded(
            child: Slider(
              value: position,
              max: duration == 0 ? 1 : duration.toDouble(),
              // Scrubbing drives the engine directly: every drag update is a
              // seek, and the engine renders a frame even while paused.
              onChanged: (value) => engine.seek(value.round()),
            ),
          ),
          Text(_timecode(duration, store.project.format.frameRate),
              style: const TextStyle(fontFamily: 'Menlo', fontSize: 12)),
        ],
      ),
    );
  }

  static String _timecode(int ticks, Rational fps) {
    final totalFrames = Timebase.project.frameOfTick(Tick(ticks), fps);
    final perSecond = (fps.numerator / fps.denominator).round();
    final frames = totalFrames % perSecond;
    final totalSeconds = totalFrames ~/ perSecond;
    final seconds = totalSeconds % 60;
    final minutes = totalSeconds ~/ 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(minutes)}:${two(seconds)}:${two(frames)}';
  }
}

class _StatsStrip extends StatelessWidget {
  const _StatsStrip({required this.stats, required this.store});

  final EngineStats? stats;
  final DocumentStore store;

  @override
  Widget build(BuildContext context) {
    final s = stats;
    final project = store.project;
    final entries = <String, String>{
      'project': '${project.format.width}x${project.format.height} '
          '@ ${project.format.frameRate}',
      'clips': '${project.mainTrack.clips.length}',
      'state': s?.state.name ?? '—',
      'fps': s == null ? '—' : s.presentFps.toStringAsFixed(1),
      'gpu': s == null ? '—' : '${s.compositeMsAvg.toStringAsFixed(2)} ms',
      'seek': s == null ? '—' : '${s.lastSeekMs.toStringAsFixed(1)} ms',
      'late': '${s?.framesLate ?? 0}',
      'audio': s == null
          ? '—'
          : (s.audioAvailable
              ? 'clock · ${s.audioBufferedFrames} buffered'
              : 'none'),
      'underruns': '${s?.audioUnderruns ?? 0}',
      'decoders': '${s?.openDecoders ?? 0}',
      'layers': '${s?.activeLayers ?? 0}',
    };

    return Container(
      width: double.infinity,
      color: const Color(0xFF14161A),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Wrap(
        spacing: 20,
        runSpacing: 4,
        children: [
          for (final entry in entries.entries)
            Text('${entry.key} ${entry.value}',
                style: const TextStyle(
                    fontFamily: 'Menlo', fontSize: 11, color: Colors.white70)),
        ],
      ),
    );
  }
}
