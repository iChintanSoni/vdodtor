import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'timeline_controller.dart';
import 'timeline_painter.dart';
import 'timeline_geometry.dart';

/// The timeline: the document as lanes and blocks, with a playhead that is
/// the engine's own position.
///
/// The widget itself is thin, and deliberately. It owns two things the
/// controller cannot: the pointer, and a ticker — because the transport does
/// not announce every frame it plays, so something has to ask once a vsync
/// while the playhead is moving. That ticker runs only during playback, and
/// what it drives is a repaint of one [RepaintBoundary], never a rebuild.
class TimelineView extends StatefulWidget {
  const TimelineView({super.key, required this.controller});

  final TimelineController controller;

  @override
  State<TimelineView> createState() => _TimelineViewState();
}

class _TimelineViewState extends State<TimelineView>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _width = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    widget.controller.transport.addListener(_syncTicker);
    _syncTicker();
  }

  @override
  void didUpdateWidget(TimelineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.transport.removeListener(_syncTicker);
      widget.controller.transport.addListener(_syncTicker);
      _syncTicker();
    }
  }

  void _onTick(Duration _) => widget.controller.pump(_width);

  /// Runs only while playing. A paused timeline still repaints — a seek
  /// notifies the transport, which notifies the controller — but it costs
  /// nothing per vsync when the playhead is standing still.
  void _syncTicker() {
    if (!mounted) return;
    final shouldRun = widget.controller.transport.isPlaying;
    if (shouldRun && !_ticker.isActive) {
      _ticker.start();
    } else if (!shouldRun && _ticker.isActive) {
      _ticker.stop();
      // One last pass, so the frame playback stopped on is the one drawn.
      _onTick(Duration.zero);
    }
  }

  void _onSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final keys = HardwareKeyboard.instance;
    if (keys.isMetaPressed || keys.isControlPressed) {
      widget.controller.zoomAround(
          event.localPosition.dx, event.scrollDelta.dy > 0 ? 0.9 : 1.1);
      return;
    }
    // A trackpad swipes horizontally; a wheel only has one axis, so it pans
    // too rather than doing nothing.
    final dx = event.scrollDelta.dx != 0
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    widget.controller.panBy(dx);
  }

  @override
  void dispose() {
    widget.controller.transport.removeListener(_syncTicker);
    // Stopped before disposed: SingleTickerProviderStateMixin asserts on a
    // widget torn down with a live ticker, and a project closed mid-playback
    // is exactly that.
    if (_ticker.isActive) _ticker.stop(canceled: true);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          _width = constraints.maxWidth;
          return Listener(
            onPointerDown: (e) => widget.controller.pointerDown(e.localPosition),
            onPointerMove: (e) => widget.controller.pointerMove(e.localPosition),
            onPointerUp: (_) => widget.controller.pointerUp(),
            onPointerCancel: (_) => widget.controller.pointerUp(),
            onPointerSignal: _onSignal,
            child: MouseRegion(
              cursor: SystemMouseCursors.basic,
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: TimelinePainter(widget.controller),
                  size: Size(constraints.maxWidth, constraints.maxHeight),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          );
        },
      );
}

/// How tall the timeline wants to be for [trackCount] lanes, bounded so a
/// project with many tracks does not eat the preview.
double timelineHeightFor(int trackCount) =>
    TimelineGeometry.heightFor(trackCount).clamp(120.0, 300.0);
