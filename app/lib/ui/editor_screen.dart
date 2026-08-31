import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../app/workspace.dart';
import '../commands/document_store.dart';
import '../commands/edits.dart';
import '../dev/self_test.dart';
import '../engine/engine_transport.dart';
import '../engine/media_probe.dart';
import '../engine/timeline_sync.dart';
import '../media/file_access.dart';
import '../media/media_import.dart';
import '../media/thumbnails.dart';
import '../media/waveforms.dart';
import '../model/media.dart';
import '../model/time.dart';
import 'inspector.dart';
import 'media_bin.dart';
import 'theme.dart';
import 'timecode.dart';
import 'timeline/timeline_controller.dart';
import 'timeline/timeline_geometry.dart';
import 'timeline/timeline_view.dart';

/// The editor: one open document, synced to the engine, playing through the
/// real compositor.
///
/// M1's walking skeleton. The timeline from S2 binds to this same
/// [DocumentStore] next; for now the media bin and the transport bar are how
/// clips arrive and how the playhead moves.
class EditorScreen extends StatefulWidget {
  const EditorScreen({
    super.key,
    required this.open,
    required this.onClose,
    required this.access,
    this.prober = const EngineMediaProber(),
    this.peakCache,
  });

  final OpenProject open;
  final VoidCallback onClose;

  /// How the app gets at the user's files: the panel, drops and bookmarks.
  final FileAccess access;

  /// Injected so an import can be exercised without the native engine.
  final MediaProber prober;

  /// Where analysed waveforms are kept between sessions. Null keeps them in
  /// memory for the session only, which is what a test without a home
  /// directory gets.
  final Directory? peakCache;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  PreviewEngine? _engine;
  Object? _error;
  Timer? _statsTimer;
  EngineStats? _stats;

  late final MediaImporter _importer;
  TimelineController? _timeline;
  final ThumbnailCache _thumbnails = ThumbnailCache();
  late final WaveformCache _waveforms =
      WaveformCache(directory: widget.peakCache);
  StreamSubscription<MediaDrop>? _drops;
  bool _importing = false;
  bool _syncQueued = false;
  String? _notice;

  DocumentStore get _store => widget.open.store;

  @override
  void initState() {
    super.initState();
    _importer = MediaImporter(prober: widget.prober, access: widget.access);
    _store.addListener(_onDocumentChanged);
    _drops = MediaAccess.drops.listen(_onDrop);
    // Once per open, not once per write: peak files are cheap to keep and dear
    // to lose, so the sweep should be rare and take the oldest when it runs.
    unawaited(_waveforms.prune());
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
      final timeline = TimelineController(
        store: _store,
        transport: EngineTransport(engine),
      )..unreachableMediaIds = widget.open.unreachableMediaIds;
      setState(() {
        _engine = engine;
        _timeline = timeline;
      });
      _statsTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (mounted) setState(() => _stats = _engine?.stats);
      });

      if (selfTestRequested) {
        final library = File(widget.open.path).parent;
        if (_store.project.mainTrack.isEmpty) {
          await runImportSelfTest(_store,
              library: library,
              access: widget.access,
              prober: widget.prober);
        }
        // Not inside the import check: a waveform is worth measuring on every
        // run, and the import only happens on the first.
        await runWaveformSelfTest(library);
        unawaited(runSelfTest(engine, _store.project));
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  void _onEngineChanged() => setState(() {});

  void _onDocumentChanged() {
    if (_syncQueued) return;
    _syncQueued = true;
    // Coalesced, because an import commits two edits per file — the asset and
    // the clip — in one synchronous burst. Syncing on each would rebuild the
    // engine's render list two hundred times for a hundred files, and the
    // ninety-nine it threw away were all wrong anyway. A microtask runs once
    // the burst is over.
    scheduleMicrotask(() {
      _syncQueued = false;
      if (!mounted) return;
      _engine?.setTimeline(engineTimelineFor(_store.project));
      setState(() {});
    });
  }

  /// The file panel. Cancelling returns nothing and changes nothing.
  Future<void> _importFromPicker() async {
    if (_importing) return;
    final files = await widget.access.pick();
    if (files.isEmpty) return;
    await _runImport(files);
  }

  void _onDrop(MediaDrop drop) {
    // The drop position is the timeline's business, and there is no timeline
    // yet: for now everything appends, wherever it landed.
    if (drop.files.isNotEmpty) unawaited(_runImport(drop.files));
  }

  Future<void> _runImport(List<GrantedFile> files) async {
    setState(() {
      _importing = true;
      _notice = null;
    });
    try {
      final result = await _importer.import(_store, files);
      if (!mounted) return;
      setState(() => _notice = result.notice);
    } catch (error) {
      if (mounted) setState(() => _notice = 'Import failed: $error');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _place(MediaAsset asset) {
    _store.endGesture();
    _importer.place(_store, asset);
    _store.endGesture();
  }

  void _remove(MediaAsset asset) {
    _store.endGesture();
    _store.run(RemoveMedia(asset.id));
    _store.endGesture();
    _thumbnails.forget(asset.id);
    _waveforms.forget(asset.id);
    final timeline = _timeline;
    if (timeline != null) {
      timeline.unreachableMediaIds =
          timeline.unreachableMediaIds.difference({asset.id});
    }
  }

  void _togglePlayback() {
    final engine = _engine;
    if (engine == null) return;
    engine.isPlaying ? engine.pause() : engine.play();
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    unawaited(_drops?.cancel());
    _store.removeListener(_onDocumentChanged);
    _engine?.removeListener(_onEngineChanged);
    _timeline?.dispose();
    unawaited(_engine?.dispose());
    _thumbnails.dispose();
    _waveforms.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engine = _engine;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): _togglePlayback,
        const SingleActivator(LogicalKeyboardKey.keyI, meta: true): () =>
            unawaited(_importFromPicker()),
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true):
            _store.undo,
        const SingleActivator(LogicalKeyboardKey.keyZ,
            meta: true, shift: true): _store.redo,
        const SingleActivator(LogicalKeyboardKey.keyW, meta: true):
            widget.onClose,
        // A frame at a time, which is the unit the playhead moves in and the
        // only way to land on an exact cut with a pointer that cannot.
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _timeline?.nudge(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _timeline?.nudge(1),
        const SingleActivator(LogicalKeyboardKey.home): () =>
            _timeline?.seekTo(Tick.zero),
        // The three edits with no pointer gesture of their own. The full
        // shortcut pass is its own item; these are here because without them
        // there is no way to reach the commands at all.
        const SingleActivator(LogicalKeyboardKey.keyB, meta: true): () =>
            _timeline?.splitAtPlayhead(),
        const SingleActivator(LogicalKeyboardKey.keyD, meta: true): () =>
            _timeline?.duplicateSelected(),
        const SingleActivator(LogicalKeyboardKey.keyD, meta: true, shift: true):
            () => _timeline?.detachAudio(),
        const SingleActivator(LogicalKeyboardKey.delete): () =>
            _timeline?.deleteSelected(),
        const SingleActivator(LogicalKeyboardKey.backspace): () =>
            _timeline?.deleteSelected(),
        const SingleActivator(LogicalKeyboardKey.keyA, meta: true): () =>
            _timeline?.selectAll(),
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            _timeline?.clearSelection(),
        const SingleActivator(LogicalKeyboardKey.keyC, meta: true): () =>
            _timeline?.copySelection(),
        const SingleActivator(LogicalKeyboardKey.keyX, meta: true): () =>
            _timeline?.cutSelection(),
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true): () =>
            _timeline?.paste(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: VdColors.canvas,
          body: Stack(
            children: [
              Column(
                children: [
                  _EditorBar(
                    open: widget.open,
                    onClose: widget.onClose,
                    onImport: () => unawaited(_importFromPicker()),
                  ),
                  if (_notice != null)
                    _NoticeBar(
                      message: _notice!,
                      onDismiss: () => setState(() => _notice = null),
                    ),
                  Expanded(
                    child: Row(
                      children: [
                        MediaBin(
                          assets: _store.project.media.values.toList(),
                          thumbnails: _thumbnails,
                          unreachable: widget.open.unreachableMediaIds,
                          busy: _importing,
                          onImport: () => unawaited(_importFromPicker()),
                          onPlace: _place,
                          onRemove: _remove,
                        ),
                        const VerticalDivider(width: 1, color: VdColors.line),
                        Expanded(
                          child: _error != null
                              ? _EngineFailure(error: _error!)
                              : engine == null
                                  ? const Center(
                                      child: CircularProgressIndicator())
                                  : _Stage(
                                      engine: engine,
                                      store: _store,
                                      onImport: () =>
                                          unawaited(_importFromPicker()),
                                    ),
                        ),
                        if (_timeline != null) ...[
                          const VerticalDivider(
                              width: 1, color: VdColors.line),
                          Inspector(timeline: _timeline!),
                        ],
                      ],
                    ),
                  ),
                  if (engine != null && _timeline != null) ...[
                    _TransportBar(
                      engine: engine,
                      store: _store,
                      timeline: _timeline!,
                    ),
                    SizedBox(
                      height: timelineHeightFor(_store.project.tracks.length),
                      child: TimelineView(
                        controller: _timeline!,
                        waveforms: _waveforms,
                      ),
                    ),
                    _StatsStrip(stats: _stats, store: _store),
                  ],
                ],
              ),
              const _DropOverlay(),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the window shows while footage is being dragged over it.
///
/// Over everything, and ignoring pointers: the native drop target is a
/// transparent view above the whole Flutter view, so a drag anywhere in the
/// window is a drop anywhere in the window, and the highlight should say so
/// rather than implying some smaller target.
class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) => Positioned.fill(
        child: IgnorePointer(
          child: ValueListenableBuilder<bool>(
            valueListenable: MediaAccess.isDragOver,
            builder: (context, over, _) => AnimatedOpacity(
              opacity: over ? 1 : 0,
              duration: const Duration(milliseconds: 90),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: VdColors.accent.withValues(alpha: 0.10),
                  border: Border.all(color: VdColors.accent, width: 2),
                ),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 14),
                    decoration: BoxDecoration(
                      color: VdColors.panel,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: VdColors.accent),
                    ),
                    child: const Text('Drop to import',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

/// The preview, at the project's aspect, with the "there is nothing here yet"
/// state and the one button that fixes it.
class _Stage extends StatelessWidget {
  const _Stage({
    required this.engine,
    required this.store,
    required this.onImport,
  });

  final PreviewEngine engine;
  final DocumentStore store;
  final VoidCallback onImport;

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
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: onImport,
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: const Text('Import media'),
                    ),
                    const SizedBox(height: 8),
                    const Text('or drop files anywhere in this window',
                        style: TextStyle(fontSize: 11, color: VdColors.dim)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NoticeBar extends StatelessWidget {
  const _NoticeBar({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        color: VdColors.warn.withValues(alpha: 0.16),
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            const Icon(Icons.warning_amber, size: 16, color: VdColors.warn),
            const SizedBox(width: 10),
            Expanded(
              child: Text(message, style: const TextStyle(fontSize: 12)),
            ),
            IconButton(
              tooltip: 'Dismiss',
              icon: const Icon(Icons.close, size: 15),
              visualDensity: VisualDensity.compact,
              onPressed: onDismiss,
            ),
          ],
        ),
      );
}

class _EditorBar extends StatelessWidget {
  const _EditorBar({
    required this.open,
    required this.onClose,
    required this.onImport,
  });

  final OpenProject open;
  final VoidCallback onClose;
  final VoidCallback onImport;

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
          const SizedBox(width: 20),
          OutlinedButton.icon(
            onPressed: onImport,
            icon: const Icon(Icons.download_outlined, size: 16),
            label: const Text('Import'),
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

/// Play, position, and how far in the timeline below is zoomed.
///
/// The slider that used to live here is gone. It scrubbed the same playhead
/// the timeline's ruler now scrubs, over the same range, and two controls for
/// one value is two things to keep in step and one of them always wrong.
class _TransportBar extends StatelessWidget {
  const _TransportBar({
    required this.engine,
    required this.store,
    required this.timeline,
  });

  final PreviewEngine engine;
  final DocumentStore store;
  final TimelineController timeline;

  @override
  Widget build(BuildContext context) {
    final fps = store.project.format.frameRate;
    final duration = engine.durationTicks;
    final position = engine.positionTicks.clamp(0, duration);

    return Container(
      color: VdColors.panel,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        children: [
          IconButton(
            iconSize: 28,
            tooltip: engine.isPlaying ? 'Pause (space)' : 'Play (space)',
            icon: Icon(engine.isPlaying ? Icons.pause : Icons.play_arrow),
            onPressed: () => engine.isPlaying ? engine.pause() : engine.play(),
          ),
          IconButton(
            tooltip: 'Back to start (home)',
            icon: const Icon(Icons.skip_previous),
            onPressed: () => timeline.seekTo(Tick.zero),
          ),
          const SizedBox(width: 10),
          Text(timecode(position, fps), style: vdMono),
          Text('  /  ${timecode(duration, fps)}',
              style: vdMono.copyWith(color: VdColors.dim)),
          const Spacer(),
          IconButton(
            tooltip: timeline.canAddOverlayTrack
                ? 'Add an overlay track'
                : 'A project may have three overlay tracks',
            icon: const Icon(Icons.layers_outlined, size: 20),
            onPressed: timeline.canAddOverlayTrack
                ? timeline.addOverlayTrack
                : null,
          ),
          IconButton(
            tooltip: timeline.canAddAudioTrack
                ? 'Add an audio track'
                : 'A project may have six audio tracks',
            icon: const Icon(Icons.graphic_eq, size: 20),
            onPressed:
                timeline.canAddAudioTrack ? timeline.addAudioTrack : null,
          ),
          IconButton(
            tooltip: timeline.canDetachAudio
                ? "Detach the selection's audio onto its own lane (⌘⇧D)"
                : 'Select a clip with sound to detach it',
            icon: const Icon(Icons.call_split, size: 20),
            onPressed: timeline.canDetachAudio ? timeline.detachAudio : null,
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Zoom out',
            icon: const Icon(Icons.zoom_out, size: 20),
            onPressed: () => timeline.zoomAround(
                TimelineGeometry.headerWidth, 1 / 1.4),
          ),
          IconButton(
            tooltip: 'Zoom in',
            icon: const Icon(Icons.zoom_in, size: 20),
            onPressed: () =>
                timeline.zoomAround(TimelineGeometry.headerWidth, 1.4),
          ),
          TextButton(
            onPressed: () => timeline.zoomToFit(
                MediaQuery.sizeOf(context).width - 240),
            child: const Text('Fit'),
          ),
        ],
      ),
    );
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
      'clips': '${project.mainTrack.clips.length}',
      'media': '${project.media.length}',
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
