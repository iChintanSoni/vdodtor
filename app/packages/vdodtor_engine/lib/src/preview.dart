import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'engine.dart';

/// Shows what the engine is compositing.
///
/// The awkward part, and the reason this is a widget rather than a bare
/// [Texture]: on macOS with Impeller, `textureFrameAvailable:` does **not**
/// schedule a Flutter frame. M0 measured 0 ui fps with the window frontmost
/// and no ticker, and 120 fps with one. So the app has to pump its own
/// repaints while playing.
///
/// The pump is scoped as tightly as it can be — a ticker that runs only during
/// playback, dirtying one [RepaintBoundary] that contains only the texture.
/// Nothing else in the tree rebuilds or repaints, which is what keeps a
/// playing preview from costing the timeline its frame budget.
class EnginePreview extends StatefulWidget {
  const EnginePreview({
    super.key,
    required this.engine,
    this.backgroundColor = const Color(0xFF000000),
  });

  final PreviewEngine engine;
  final Color backgroundColor;

  @override
  State<EnginePreview> createState() => _EnginePreviewState();
}

class _EnginePreviewState extends State<EnginePreview>
    with SingleTickerProviderStateMixin {
  /// Bumped once per vsync while playing; the render object below listens.
  final ChangeNotifier _vsync = ChangeNotifier();
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    widget.engine.addListener(_syncTicker);
    _syncTicker();
  }

  @override
  void didUpdateWidget(EnginePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.engine != widget.engine) {
      oldWidget.engine.removeListener(_syncTicker);
      widget.engine.addListener(_syncTicker);
      _syncTicker();
    }
  }

  void _onTick(Duration _) {
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    _vsync.notifyListeners();
  }

  /// Runs only while playing. A paused preview still updates — seeking
  /// publishes a frame and the engine's notification rebuilds this widget —
  /// but it costs nothing per vsync when nothing is moving.
  void _syncTicker() {
    if (!mounted) return;
    final shouldRun = widget.engine.isPlaying;
    if (shouldRun && !_ticker.isActive) {
      _ticker.start();
    } else if (!shouldRun && _ticker.isActive) {
      _ticker.stop();
      // One last repaint, so the frame the engine settled on is the one left
      // on screen rather than whatever the last tick happened to catch.
      _onTick(Duration.zero);
    }
  }

  @override
  void dispose() {
    widget.engine.removeListener(_syncTicker);
    _ticker.dispose();
    _vsync.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textureId = widget.engine.textureId;
    return ColoredBox(
      color: widget.backgroundColor,
      child: textureId == null
          ? const SizedBox.expand()
          : RepaintBoundary(
              child: _RepaintPump(
                listenable: _vsync,
                child: Texture(textureId: textureId),
              ),
            ),
    );
  }
}

/// Repaints its subtree whenever [listenable] fires, without rebuilding it.
///
/// Rebuilding would also work and would be one line shorter, but it would
/// allocate a new widget every vsync for no reason: the texture id has not
/// changed, only the pixels behind it have.
class _RepaintPump extends SingleChildRenderObjectWidget {
  const _RepaintPump({required this.listenable, required Widget super.child});

  final Listenable listenable;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderRepaintPump(listenable);

  @override
  void updateRenderObject(
      BuildContext context, _RenderRepaintPump renderObject) {
    renderObject.listenable = listenable;
  }
}

class _RenderRepaintPump extends RenderProxyBox {
  _RenderRepaintPump(this._listenable);

  Listenable _listenable;

  set listenable(Listenable value) {
    if (identical(value, _listenable)) return;
    if (attached) _listenable.removeListener(markNeedsPaint);
    _listenable = value;
    if (attached) _listenable.addListener(markNeedsPaint);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _listenable.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _listenable.removeListener(markNeedsPaint);
    super.detach();
  }
}
