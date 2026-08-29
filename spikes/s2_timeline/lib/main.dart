// S2 spike app — timeline interaction and how it scales.
//
//   interactive  — the timeline, to judge whether editing feels easy
//   benchmark    — VD_BENCH=1, scripted drags at several clip counts, prints a table

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'model.dart';
import 'timeline.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(Platform.environment['VD_BENCH'] == '1'
      ? const BenchApp()
      : const TimelineApp());
}

// ============================================================== benchmark

class BenchApp extends StatefulWidget {
  const BenchApp({super.key});
  @override
  State<BenchApp> createState() => _BenchAppState();
}

class _BenchAppState extends State<BenchApp> with SingleTickerProviderStateMixin {
  late TimelineController _c;
  List<FrameTiming> _timings = [];
  Ticker? _ticker;
  double _phase = 0;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _c = TimelineController(buildDemoDoc(clipsPerTrack: 8));
    SchedulerBinding.instance.addTimingsCallback((t) => _timings.addAll(t));
    _ticker = createTicker(_onTick)..start();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  void _onTick(Duration d) {
    if (!_dragging) return;
    // Oscillate a drag across the timeline: the worst realistic case is a
    // continuous drag forcing a full repaint every vsync.
    _phase += 0.05;
    final x = 420.0 + 240.0 * math.sin(_phase);
    _c.pointerMove(Offset(x, kRulerHeight + kTrackHeight / 2));
  }

  Future<void> _run() async {
    stdout.writeln('\n=== vdodtor S2 timeline benchmark ===');
    final rows = <List<String>>[];

    for (final perTrack in [8, 38, 192, 385]) {
      final doc = buildDemoDoc(clipsPerTrack: perTrack);
      final total = doc.tracks.fold<int>(0, (a, t) => a + t.clips.length);

      setState(() {
        _c = TimelineController(doc);
        // Zoom out so every clip is on screen — no culling relief.
        _c.pxPerSecond =
            (900 / secondsFromTicks(doc.durationTicks)).clamp(4.0, 1200.0);
      });
      await Future.delayed(const Duration(milliseconds: 400));

      // Grab a clip in the middle of the main track and drag it continuously.
      final main = doc.tracks.first;
      final victim = main.clips[main.clips.length ~/ 2];
      _c.selected = victim;
      _c.selectedTrack = main;
      _c.pointerDown(Offset(_c.xForTicks(victim.start) + 20,
          kRulerHeight + kTrackHeight / 2));

      _timings = [];
      _c.dragUpdates = 0;
      _dragging = true;
      await Future.delayed(const Duration(seconds: 4));
      _dragging = false;
      _c.pointerUp();

      final t = _timings;
      final build = t.map((f) => f.buildDuration.inMicroseconds / 1000.0).toList()..sort();
      final raster = t.map((f) => f.rasterDuration.inMicroseconds / 1000.0).toList()..sort();
      double p95(List<double> v) =>
          v.isEmpty ? 0 : v[(v.length * 0.95).floor().clamp(0, v.length - 1)];
      final worst = raster.isEmpty ? 0.0 : raster.last;

      rows.add([
        '$total clips',
        (t.length / 4.0).toStringAsFixed(1),
        p95(build).toStringAsFixed(2),
        p95(raster).toStringAsFixed(2),
        worst.toStringAsFixed(2),
        _c.dragUpdates.toString(),
      ]);
      stdout.writeln('  done: $total clips -> '
          '${(t.length / 4.0).toStringAsFixed(1)} fps');
    }

    // Verification: render the painter straight to a PNG so the visual result
    // is checkable without screen-capture permissions.
    await _dumpPng();

    stdout.writeln('');
    const header = ['timeline', 'fps', 'build p95', 'raster p95', 'raster max', 'drag events'];
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
    stdout.writeln('\n(ms figures are per frame; display is 120 Hz so 120 fps is the ceiling)');
    stdout.writeln('=== end benchmark ===');
    await stdout.flush();
    exit(0);
  }

  Future<void> _dumpPng() async {
    const w = 1400.0, h = 360.0;
    final doc = buildDemoDoc(clipsPerTrack: 9);
    final c = TimelineController(doc)
      ..pxPerSecond = 46
      ..playhead = ticksFromSeconds(7.4);
    c.selected = doc.tracks.first.clips[2];
    c.selectedTrack = doc.tracks.first;
    c.snapGuide = doc.tracks[1].clips.first.start;

    final recorder = ui.PictureRecorder();
    TimelinePainter(c).paint(Canvas(recorder), const Size(w, h));
    final img = await recorder.endRecording().toImage(w.toInt(), h.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    if (bytes != null) {
      File('/Users/chintansoni/Github/vdodtor/spikes/s2_timeline_render.png')
          .writeAsBytesSync(bytes.buffer.asUint8List());
      stdout.writeln('  wrote spikes/s2_timeline_render.png');
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF16181D),
          body: TimelineView(controller: _c),
        ),
      );
}

// ============================================================== interactive

class TimelineApp extends StatelessWidget {
  const TimelineApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'vdodtor S2 — timeline spike',
        theme: ThemeData.dark(useMaterial3: true),
        home: const TimelinePage(),
      );
}

class TimelinePage extends StatefulWidget {
  const TimelinePage({super.key});
  @override
  State<TimelinePage> createState() => _TimelinePageState();
}

class _TimelinePageState extends State<TimelinePage> {
  late final TimelineController _c = TimelineController(buildDemoDoc(clipsPerTrack: 10));
  final _focus = FocusNode();

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.delete:
      case LogicalKeyboardKey.backspace:
        _c.deleteSelected();
      case LogicalKeyboardKey.keyS:
        _c.splitAtPlayhead();
      case LogicalKeyboardKey.keyN:
        _c.toggleSnapping();
      case LogicalKeyboardKey.equal:
        _c.zoomAround(500, 1.2);
      case LogicalKeyboardKey.minus:
        _c.zoomAround(500, 0.83);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF16181D),
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Column(
          children: [
            Expanded(child: TimelineView(controller: _c)),
            AnimatedBuilder(
              animation: _c,
              builder: (_, _) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                color: const Color(0xFF1E2128),
                child: Row(
                  children: [
                    Text(
                      'playhead ${secondsFromTicks(_c.playhead).toStringAsFixed(2)}s'
                      '   zoom ${_c.pxPerSecond.toStringAsFixed(0)} px/s'
                      '   snap ${_c.snapping ? "on" : "off"}',
                      style: const TextStyle(fontFamily: 'Menlo', fontSize: 11),
                    ),
                    const Spacer(),
                    const Text(
                      'drag body to move · drag ends to trim · S split · Del ripple-delete · '
                      'N snap · ⌘scroll zoom',
                      style: TextStyle(fontSize: 11, color: Color(0xFF8A93A5)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
