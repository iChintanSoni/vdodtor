import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vdodtor_engine/vdodtor_engine.dart';

import 'engine/media_probe.dart';
import 'model/media.dart';
import 'model/project.dart';
import 'model/time.dart';

void main() {
  runApp(const VdodtorApp());
}

class VdodtorApp extends StatelessWidget {
  const VdodtorApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'vdodtor',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF4C8DF6), brightness: Brightness.dark),
          useMaterial3: true,
        ),
        home: const EngineStatusPage(),
      );
}

/// Development scaffold for M1: proves the Dart -> FFI -> engine -> FFmpeg
/// chain end to end. The editor UI replaces this once the timeline is bound to
/// the document.
class EngineStatusPage extends StatefulWidget {
  const EngineStatusPage({super.key});

  @override
  State<EngineStatusPage> createState() => _EngineStatusPageState();
}

class _EngineStatusPageState extends State<EngineStatusPage> {
  static const _probeService = MediaProbeService();

  bool? _engineAvailable;
  final List<(String, Object)> _probes = [];

  @override
  void initState() {
    super.initState();
    _runSmokeTest();
  }

  /// The bundled dev samples, on disk inside the .app.
  ///
  /// The App Sandbox is on, so the app can read its own bundle and nothing
  /// else without the user handing it a file. That is exactly the constraint
  /// import has to live with, which makes it the right place to prove the
  /// probe path works.
  static Directory? _sampleDir() {
    final exe = File(Platform.resolvedExecutable).parent; // …/Contents/MacOS
    final bundled = Directory('${exe.parent.path}/Frameworks/App.framework/'
        'Resources/flutter_assets/assets/dev');
    if (bundled.existsSync()) return bundled;

    // Running from `flutter test` or a bare dart entry point.
    final local = Directory('${Directory.current.path}/assets/dev');
    return local.existsSync() ? local : null;
  }

  void _runSmokeTest() {
    final available = VdodtorEngine.isAvailable;
    final results = <(String, Object)>[];
    stdout.writeln('[vdodtor] native engine available: $available');

    final fixtures = _sampleDir();
    if (fixtures == null) {
      stdout.writeln('[vdodtor] no bundled samples found');
    } else {
      for (final entry in fixtures.listSync().whereType<File>()) {
        if (entry.path.endsWith('.sh') || entry.path.endsWith('.txt')) continue;
        final name = entry.uri.pathSegments.last;
        try {
          final probe =
              _probeService.toProbe(VdodtorEngine.probeFile(entry.path));
          results.add((name, probe));
          stdout.writeln('[vdodtor] $name -> ${_describe(probe)}');
        } on EngineException catch (e) {
          results.add((name, e));
          stdout.writeln('[vdodtor] $name -> $e');
        }
      }
    }

    setState(() {
      _engineAvailable = available;
      _probes
        ..clear()
        ..addAll(results);
    });
  }

  @override
  Widget build(BuildContext context) {
    final format = ProjectFormat.fromAspect(ProjectAspect.landscape16x9,
        frameRate: FrameRates.fps30);

    return Scaffold(
      appBar: AppBar(
        title: const Text('vdodtor — engine status'),
        actions: [
          IconButton(
            onPressed: _runSmokeTest,
            icon: const Icon(Icons.refresh),
            tooltip: 'Re-probe',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _Row('Native engine',
              _engineAvailable == true ? 'loaded' : 'NOT AVAILABLE'),
          _Row('Project timebase', '${Timebase.project.ticksPerSecond}/s'),
          _Row('Default format', '$format'),
          _Row('Ticks per frame (engine)',
              FrameRates.all
                  .map((r) => '$r=${VdodtorEngine.ticksPerFrame(
                      r.numerator, r.denominator)}')
                  .join('  ')),
          _Row('Ticks per frame (Dart)',
              FrameRates.all
                  .map((r) => '$r=${Timebase.project.ticksPerFrame(r)}')
                  .join('  ')),
          const Divider(height: 40),
          Text('Probed fixtures', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_probes.isEmpty)
            const Text('No fixtures found next to the app.')
          else
            for (final (name, result) in _probes)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: result is MediaProbe
                    ? _Row(name, _describe(result))
                    : _Row(name, '$result'),
              ),
        ],
      ),
    );
  }

  static String _describe(MediaProbe p) => [
        p.kind.name,
        if (p.hasVideo) '${p.width}x${p.height}',
        if (p.hasVideo) '${p.frameRate} fps',
        if (p.variableFrameRate) 'VFR',
        if (p.rotationDegrees != 0) 'rot ${p.rotationDegrees}°',
        if (p.hasAudio) '${p.audioChannels}ch ${p.audioSampleRate}Hz',
        '${Timebase.project.toSecondsForDisplay(p.duration)}s',
        [p.videoCodec, p.audioCodec].nonNulls.join('+'),
      ].join(' · ');
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 200,
              child: Text(label,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            Expanded(
              child: SelectableText(value,
                  style: const TextStyle(fontFamily: 'Menlo', fontSize: 12)),
            ),
          ],
        ),
      );
}
