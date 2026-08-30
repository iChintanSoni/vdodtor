import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../app/workspace.dart';
import '../commands/document_store.dart';
import '../dev/sample_clips.dart';
import '../dev/self_test.dart';
import '../engine/timeline_sync.dart';
import '../model/time.dart';
import 'theme.dart';

/// The editor: one open document, synced to the engine, playing through the
/// real compositor.
///
/// M1's walking skeleton. The timeline from S2 binds to this same
/// [DocumentStore] next; for now the transport bar is the only way to move the
/// playhead.
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.open, required this.onClose});

  final OpenProject open;
  final VoidCallback onClose;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  PreviewEngine? _engine;
  Object? _error;
  Timer? _statsTimer;
  EngineStats? _stats;

  DocumentStore get _store => widget.open.store;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onDocumentChanged);
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final engine = await PreviewEngine.create();
      engine.setTimeline(engineTimelineFor(_store.project));
      engine.seek(0);
      engine.addListener(_onEngineChanged);

      if (!mounted) {
        await engine.dispose();
        return;
      }
      setState(() => _engine = engine);
      _statsTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (mounted) setState(() => _stats = _engine?.stats);
      });

      if (selfTestRequested) {
        if (_store.project.mainTrack.isEmpty) _addSampleClips();
        unawaited(runSelfTest(engine, _store.project));
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  void _onEngineChanged() => setState(() {});

  void _onDocumentChanged() {
    // Every committed edit re-syncs. The engine keeps decoders open for
    // sources that are still in the timeline, so this is cheap.
    _engine?.setTimeline(engineTimelineFor(_store.project));
    setState(() {});
  }

  void _addSampleClips() => addSampleClips(_store);

  void _togglePlayback() {
    final engine = _engine;
    if (engine == null) return;
    engine.isPlaying ? engine.pause() : engine.play();
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _store.removeListener(_onDocumentChanged);
    _engine?.removeListener(_onEngineChanged);
    unawaited(_engine?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engine = _engine;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): _togglePlayback,
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true):
            _store.undo,
        const SingleActivator(LogicalKeyboardKey.keyZ,
            meta: true, shift: true): _store.redo,
        const SingleActivator(LogicalKeyboardKey.keyW, meta: true):
            widget.onClose,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: VdColors.canvas,
          body: Column(
            children: [
              _EditorBar(
                open: widget.open,
                onClose: widget.onClose,
              ),
              Expanded(
                child: _error != null
                    ? _EngineFailure(error: _error!)
                    : engine == null
                        ? const Center(child: CircularProgressIndicator())
                        : _Stage(
                            engine: engine,
                            store: _store,
                            onAddSamples:
                                kDebugMode && sampleMediaFiles().isNotEmpty
                                    ? _addSampleClips
                                    : null,
                          ),
              ),
              if (engine != null) ...[
                _TransportBar(engine: engine, store: _store),
                _StatsStrip(stats: _stats, store: _store),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The preview, at the project's aspect, with the "there is nothing here yet"
/// state that M1 will have until import lands.
class _Stage extends StatelessWidget {
  const _Stage({
    required this.engine,
    required this.store,
    required this.onAddSamples,
  });

  final PreviewEngine engine;
  final DocumentStore store;
  final VoidCallback? onAddSamples;

  @override
  Widget build(BuildContext context) {
    final format = store.project.format;
    final empty = store.project.mainTrack.isEmpty;

    return Center(
      child: AspectRatio(
        aspectRatio: format.width / format.height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            EnginePreview(engine: engine),
            if (empty)
              Container(
                color: Colors.black.withValues(alpha: 0.55),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('Nothing on the timeline yet',
                        style: TextStyle(color: VdColors.dim)),
                    if (onAddSamples != null) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: onAddSamples,
                        icon: const Icon(Icons.science_outlined, size: 18),
                        label: const Text('Add sample clips'),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EditorBar extends StatelessWidget {
  const _EditorBar({required this.open, required this.onClose});

  final OpenProject open;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final store = open.store;
    final format = open.project.format;

    return Container(
      color: VdColors.panel,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Projects (⌘W)',
            icon: const Icon(Icons.arrow_back),
            onPressed: onClose,
          ),
          const SizedBox(width: 4),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(open.name,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14)),
              Text(
                '${format.width}×${format.height} · '
                '${format.frameRate.numerator ~/ format.frameRate.denominator}'
                ' fps',
                style: const TextStyle(fontSize: 11, color: VdColors.dim),
              ),
            ],
          ),
          const Spacer(),
          IconButton(
            tooltip: store.undoLabel == null
                ? 'Nothing to undo'
                : 'Undo ${store.undoLabel} (⌘Z)',
            icon: const Icon(Icons.undo),
            onPressed: store.canUndo ? store.undo : null,
          ),
          IconButton(
            tooltip: store.redoLabel == null
                ? 'Nothing to redo'
                : 'Redo ${store.redoLabel} (⇧⌘Z)',
            icon: const Icon(Icons.redo),
            onPressed: store.canRedo ? store.redo : null,
          ),
          const SizedBox(width: 12),
          _SaveState(store: store),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

/// There is no Save command; an edit is saved. This says so, because an editor
/// that never mentions saving has to earn the trust some other way.
class _SaveState extends StatelessWidget {
  const _SaveState({required this.store});

  final DocumentStore store;

  @override
  Widget build(BuildContext context) {
    final dirty = store.isDirty;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: dirty ? VdColors.warn : const Color(0xFF4CAF7D),
          ),
        ),
        const SizedBox(width: 6),
        Text(dirty ? 'Saving…' : 'Saved',
            style: const TextStyle(fontSize: 11, color: VdColors.dim)),
      ],
    );
  }
}

class _EngineFailure extends StatelessWidget {
  const _EngineFailure({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: SelectableText('The engine did not start.\n\n$error',
              textAlign: TextAlign.center),
        ),
      );
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
      color: VdColors.panel,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          IconButton(
            iconSize: 32,
            tooltip: engine.isPlaying ? 'Pause (space)' : 'Play (space)',
            icon: Icon(engine.isPlaying ? Icons.pause : Icons.play_arrow),
            onPressed: () => engine.isPlaying ? engine.pause() : engine.play(),
          ),
          IconButton(
            tooltip: 'Back to start',
            icon: const Icon(Icons.skip_previous),
            onPressed: () => engine.seek(0),
          ),
          const SizedBox(width: 8),
          Text(timecode(position.round(), store.project.format.frameRate),
              style: vdMono),
          Expanded(
            child: Slider(
              value: position,
              max: duration == 0 ? 1 : duration.toDouble(),
              // Scrubbing drives the engine directly: every drag update is a
              // seek, and the engine renders a frame even while paused.
              onChanged: (value) => engine.seek(value.round()),
            ),
          ),
          Text(timecode(duration, store.project.format.frameRate),
              style: vdMono),
        ],
      ),
    );
  }
}

/// mm:ss:ff on the project's own frame rate.
String timecode(int ticks, Rational fps) {
  final totalFrames = Timebase.project.frameOfTick(Tick(ticks), fps);
  final perSecond = (fps.numerator / fps.denominator).round();
  final frames = totalFrames % perSecond;
  final totalSeconds = totalFrames ~/ perSecond;
  final seconds = totalSeconds % 60;
  final minutes = totalSeconds ~/ 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(minutes)}:${two(seconds)}:${two(frames)}';
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
      color: VdColors.rail,
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
