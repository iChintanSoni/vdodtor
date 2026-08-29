// S1 spike app.
//
// Two modes:
//   interactive  — preview window with transport, layer count, scrub bar, live stats
//   benchmark    — VD_BENCH=1, runs a fixed script, prints a table, exits
//
// The benchmark is what answers the M0 exit criteria: sustained 4K60 and
// sub-100ms scrub.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:vdodtor_engine/vdodtor_engine.dart';

const kMediaDir = '/Users/chintansoni/Github/vdodtor/spikes/media';

const kClips = <String, String>{
  '4K60 H.264': '$kMediaDir/4k60_h264.mp4',
  '4K60 HEVC': '$kMediaDir/4k60_hevc.mp4',
  '1080p60 H.264': '$kMediaDir/1080p60_h264.mp4',
};

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.environment['VD_BENCH'] == '1') {
    runApp(const BenchApp());
  } else {
    runApp(const PreviewApp());
  }
}

// ============================================================== benchmark

class BenchCase {
  final String name;
  final String clip;
  final int outW, outH, layers;
  const BenchCase(this.name, this.clip, this.outW, this.outH, this.layers);
}

const kCases = <BenchCase>[
  // Realistic preview: decode 4K, composite to a 1080p window.
  BenchCase('4K60 H.264 -> 1080p, 1 layer', '4K60 H.264', 1920, 1080, 1),
  BenchCase('4K60 H.264 -> 1080p, 3 layers', '4K60 H.264', 1920, 1080, 3),
  BenchCase('4K60 HEVC  -> 1080p, 1 layer', '4K60 HEVC', 1920, 1080, 1),
  // Export-like: composite at full 4K.
  BenchCase('4K60 H.264 -> 4K, 1 layer', '4K60 H.264', 3840, 2160, 1),
  BenchCase('4K60 H.264 -> 4K, 3 layers', '4K60 H.264', 3840, 2160, 3),
  BenchCase('1080p60    -> 1080p, 1 layer', '1080p60 H.264', 1920, 1080, 1),
];

class BenchApp extends StatefulWidget {
  const BenchApp({super.key});
  @override
  State<BenchApp> createState() => _BenchAppState();
}

class _BenchAppState extends State<BenchApp> with SingleTickerProviderStateMixin {
  int? _textureId;
  List<FrameTiming> _timings = [];
  Ticker? _ticker;
  int _repaint = 0;

  @override
  void initState() {
    super.initState();
    // Does textureFrameAvailable alone drive Flutter to redraw, or must the app
    // pump repaints itself? VD_TICKER=1 forces a repaint every vsync so the two
    // cases can be told apart.
    if (Platform.environment['VD_TICKER'] == '1') {
      _ticker = createTicker((_) => setState(() => _repaint++))..start();
    }
    // Flutter's own frame timings: the engine's composite rate proves the
    // pipeline keeps up, but only these prove frames reach the screen.
    SchedulerBinding.instance.addTimingsCallback((t) => _timings.addAll(t));
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  /// (fps, p95 raster ms) for the frames Flutter presented over [seconds].
  (double, double) _flutterFrameStats(double seconds) {
    final t = _timings;
    if (t.isEmpty) return (0, 0);
    final raster = t.map((f) => f.rasterDuration.inMicroseconds / 1000.0).toList()..sort();
    return (t.length / seconds, raster[(raster.length * 0.95).floor().clamp(0, raster.length - 1)]);
  }

  Future<void> _run() async {
    stdout.writeln('\n=== vdodtor S1 benchmark ===');
    final rows = <List<String>>[];

    for (final c in kCases) {
      final engine = VdodtorEngine.create();
      final rc = engine.open(kClips[c.clip]!, outWidth: c.outW, outHeight: c.outH);
      if (rc != 0) {
        stdout.writeln('FAIL ${c.name}: open returned $rc');
        await engine.dispose();
        continue;
      }
      engine.setLayers(c.layers);
      final tid = await engine.registerTexture();
      setState(() => _textureId = tid);

      // Warm up (decoder priming, pool allocation), then measure.
      engine.play();
      await Future.delayed(const Duration(milliseconds: 1500));
      final before = engine.stats();
      _timings = [];
      await Future.delayed(const Duration(seconds: 6));
      final after = engine.stats();
      final (uiFps, rasterP95) = _flutterFrameStats(6.0);

      // Verification: prove the Metal path produced a real image, not just fast timings.
      if (c.layers > 1 || c == kCases.first) {
        final png = '$kMediaDir/../out_${c.name.replaceAll(RegExp(r"[^A-Za-z0-9]+"), "_")}.png';
        final rc2 = engine.dumpPng(png);
        if (rc2 != 0) stdout.writeln('  (png dump failed: $rc2)');
      }

      final dt = (after.positionNs - before.positionNs) / 1e9;
      final presented = after.framesPresented - before.framesPresented;
      final dropped = after.framesDropped - before.framesDropped;
      final fps = dt > 0 ? presented / dt : 0.0;

      // Scrub test: 8 seeks to scattered positions, measure time to frame.
      engine.pause();
      final seeks = <double>[];
      for (var i = 0; i < 8; i++) {
        final target = (1.0 + i * 2.1) % 18.0;
        engine.seekSeconds(target);
        await Future.delayed(const Duration(milliseconds: 350));
        seeks.add(engine.stats().lastSeekMs);
      }
      seeks.sort();
      final seekMedian = seeks[seeks.length ~/ 2];
      final seekWorst = seeks.last;

      rows.add([
        c.name,
        fps.toStringAsFixed(1),
        dropped.toString(),
        after.compositeMsAvg.toStringAsFixed(2),
        uiFps.toStringAsFixed(1),
        rasterP95.toStringAsFixed(1),
        after.cpuPercent.toStringAsFixed(0),
        seekMedian.toStringAsFixed(0),
        seekWorst.toStringAsFixed(0),
      ]);
      stdout.writeln('  done: ${c.name} -> ${fps.toStringAsFixed(1)} fps');

      setState(() => _textureId = null);
      await engine.dispose();
      await Future.delayed(const Duration(milliseconds: 300));
    }

    // ---- concurrency: how many simultaneous 4K60 decoders hold 60 fps?
    stdout.writeln('\n--- concurrent 4K60 decoders (parallel video tracks) ---');
    final concRows = <List<String>>[];
    for (final n in [1, 2, 3, 4]) {
      final engines = <VdodtorEngine>[];
      var openFailed = false;
      for (var i = 0; i < n; i++) {
        final e = VdodtorEngine.create();
        if (e.open(kClips['4K60 H.264']!, outWidth: 1920, outHeight: 1080) != 0) {
          openFailed = true;
          await e.dispose();
          break;
        }
        e.seekSeconds(i * 1.5);  // stagger so they aren't decoding identical GOPs
        engines.add(e);
      }
      if (openFailed) {
        stdout.writeln('  n=$n: open failed');
        for (final e in engines) {
          await e.dispose();
        }
        continue;
      }

      for (final e in engines) {
        e.play();
      }
      await Future.delayed(const Duration(milliseconds: 1500));
      final b = [for (final e in engines) e.stats()];
      await Future.delayed(const Duration(seconds: 5));
      final a = [for (final e in engines) e.stats()];

      var worst = 1e9, totalDrop = 0;
      var cpu = 0.0;
      for (var i = 0; i < n; i++) {
        final dt = (a[i].positionNs - b[i].positionNs) / 1e9;
        final f = dt > 0 ? (a[i].framesPresented - b[i].framesPresented) / dt : 0.0;
        if (f < worst) worst = f;
        totalDrop += a[i].framesDropped - b[i].framesDropped;
        cpu = a[i].cpuPercent;  // process-wide, same for all
      }
      concRows.add([
        '$n x 4K60 -> 1080p',
        worst.toStringAsFixed(1),
        totalDrop.toString(),
        cpu.toStringAsFixed(0),
      ]);
      stdout.writeln('  n=$n: worst-stream ${worst.toStringAsFixed(1)} fps, '
          'dropped $totalDrop, cpu ${cpu.toStringAsFixed(0)}%');
      for (final e in engines) {
        await e.dispose();
      }
      await Future.delayed(const Duration(milliseconds: 400));
    }

    stdout.writeln('');
    const header = ['case', 'eng fps', 'drop', 'gpu ms', 'ui fps', 'raster p95', 'cpu%', 'seek p50', 'seek max'];
    final widths = List<int>.generate(header.length, (i) {
      var w = header[i].length;
      for (final r in rows) {
        if (r[i].length > w) w = r[i].length;
      }
      return w;
    });
    String fmt(List<String> r) => [
          for (var i = 0; i < r.length; i++)
            i == 0 ? r[i].padRight(widths[i]) : r[i].padLeft(widths[i])
        ].join('  ');
    stdout.writeln(fmt(header));
    stdout.writeln(widths.map((w) => '-' * w).join('  '));
    for (final r in rows) {
      stdout.writeln(fmt(r));
    }
    stdout.writeln('');
    stdout.writeln('concurrent streams   worst fps  dropped  cpu%');
    stdout.writeln('-------------------  ---------  -------  ----');
    for (final r in concRows) {
      stdout.writeln('${r[0].padRight(19)}  ${r[1].padLeft(9)}  ${r[2].padLeft(7)}  ${r[3].padLeft(4)}');
    }
    stdout.writeln('\n=== end benchmark ===');
    await stdout.flush();
    exit(0);
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: _textureId == null
              ? Text('benchmark running… $_repaint',
                  style: const TextStyle(color: Colors.white))
              : Texture(textureId: _textureId!),
        ),
      ),
    );
  }
}

// ============================================================== interactive

class PreviewApp extends StatelessWidget {
  const PreviewApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'vdodtor S1 — preview spike',
      theme: ThemeData.dark(useMaterial3: true),
      home: const PreviewPage(),
    );
  }
}

class PreviewPage extends StatefulWidget {
  const PreviewPage({super.key});
  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage> with SingleTickerProviderStateMixin {
  VdodtorEngine? _engine;
  int? _textureId;
  Timer? _poll;
  EngineStats _stats = EngineStats.empty;
  String _clip = kClips.keys.first;
  int _layers = 1;
  bool _playing = false;
  String? _error;
  Ticker? _ticker;

  @override
  void initState() {
    super.initState();
    // textureFrameAvailable: does not schedule a Flutter frame on macOS+Impeller,
    // so the preview has to pump its own repaints. (M1: scope this to a
    // RepaintBoundary around the Texture instead of the whole page.)
    _ticker = createTicker((_) => setState(() {}))..start();
    _load(_clip);
    _poll = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final e = _engine;
      if (e == null) return;
      setState(() => _stats = e.stats());
    });
  }

  Future<void> _load(String clip) async {
    await _engine?.dispose();
    setState(() {
      _engine = null;
      _textureId = null;
      _error = null;
      _playing = false;
    });
    try {
      final e = VdodtorEngine.create();
      final rc = e.open(kClips[clip]!, outWidth: 1920, outHeight: 1080);
      if (rc != 0) {
        setState(() => _error = 'open failed: $rc');
        return;
      }
      e.setLayers(_layers);
      final tid = await e.registerTexture();
      e.seekNs(0);
      setState(() {
        _engine = e;
        _textureId = tid;
        _clip = clip;
      });
    } catch (err) {
      setState(() => _error = '$err');
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _poll?.cancel();
    _engine?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _stats;
    final dur = s.durationNs > 0 ? s.durationNs / 1e9 : 1.0;
    final pos = (s.positionNs / 1e9).clamp(0.0, dur);

    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Container(
              color: Colors.black,
              child: Center(
                child: _error != null
                    ? Text(_error!, style: const TextStyle(color: Colors.redAccent))
                    : _textureId == null
                        ? const CircularProgressIndicator()
                        : AspectRatio(
                            aspectRatio: 16 / 9,
                            child: Texture(textureId: _textureId!),
                          ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                      onPressed: _engine == null
                          ? null
                          : () {
                              _playing ? _engine!.pause() : _engine!.play();
                              setState(() => _playing = !_playing);
                            },
                    ),
                    Expanded(
                      child: Slider(
                        value: pos,
                        max: dur,
                        onChanged: _engine == null
                            ? null
                            : (v) => _engine!.seekSeconds(v),
                      ),
                    ),
                    Text('${pos.toStringAsFixed(2)} / ${dur.toStringAsFixed(2)}s'),
                  ],
                ),
                Row(
                  children: [
                    DropdownButton<String>(
                      value: _clip,
                      items: [
                        for (final k in kClips.keys)
                          DropdownMenuItem(value: k, child: Text(k))
                      ],
                      onChanged: (v) => v == null ? null : _load(v),
                    ),
                    const SizedBox(width: 24),
                    const Text('layers'),
                    const SizedBox(width: 8),
                    for (final n in [1, 2, 3, 5])
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: ChoiceChip(
                          label: Text('$n'),
                          selected: _layers == n,
                          onSelected: (_) {
                            setState(() => _layers = n);
                            _engine?.setLayers(n);
                          },
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'src ${s.width}x${s.height}  out ${s.outWidth}x${s.outHeight}\n'
                    'present ${s.presentFps.toStringAsFixed(1)} fps   '
                    'decode ${s.decodeMsAvg.toStringAsFixed(2)} ms   '
                    'gpu ${s.compositeMsAvg.toStringAsFixed(2)} ms   '
                    'cpu ${s.cpuPercent.toStringAsFixed(0)}%\n'
                    'decoded ${s.framesDecoded}  presented ${s.framesPresented}  '
                    'dropped ${s.framesDropped}   '
                    'last seek ${s.lastSeekMs.toStringAsFixed(0)} ms   [${s.stateName}]',
                    style: const TextStyle(fontFamily: 'Menlo', fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
