import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../media/waveforms.dart';
import '../../model/track.dart';
import '../theme.dart';
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
  const TimelineView({super.key, required this.controller, this.waveforms});

  final TimelineController controller;

  /// Where clip waveforms come from. Optional: a timeline without one draws
  /// clips without waveforms, which is what a test about dragging wants and
  /// what the editor shows before the first analysis lands.
  final WaveformCache? waveforms;

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
            onPointerDown: (e) => widget.controller.pointerDown(
                  e.localPosition,
                  additive: HardwareKeyboard.instance.isMetaPressed ||
                      HardwareKeyboard.instance.isShiftPressed,
                ),
            onPointerMove: (e) => widget.controller.pointerMove(e.localPosition),
            onPointerUp: (_) => widget.controller.pointerUp(),
            onPointerCancel: (_) => widget.controller.pointerUp(),
            onPointerSignal: _onSignal,
            child: MouseRegion(
              cursor: SystemMouseCursors.basic,
              child: Stack(
                children: [
                  RepaintBoundary(
                    child: CustomPaint(
                      painter: TimelinePainter(widget.controller,
                          waveforms: widget.waveforms),
                      size: Size(constraints.maxWidth, constraints.maxHeight),
                      child: const SizedBox.expand(),
                    ),
                  ),
                  // Real widgets over the painted headers. The names and marks
                  // stay on the canvas — they are cheap and never interactive —
                  // but a button has to be a button, for its hit box, its
                  // cursor and its tooltip.
                  _LaneControls(controller: widget.controller),
                ],
              ),
            ),
          );
        },
      );
}

/// A remove button per lane, laid over the header column.
class _LaneControls extends StatelessWidget {
  const _LaneControls({required this.controller});

  final TimelineController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final lanes = controller.lanes;
          return Positioned(
            left: 0,
            top: 0,
            width: TimelineGeometry.headerWidth,
            bottom: 0,
            child: Stack(
              children: [
                for (var i = 0; i < lanes.length; i++)
                  if (lanes[i].kind != TrackKind.main)
                    Positioned(
                      left: TimelineGeometry.headerWidth - 26,
                      top: controller.geometry.topOfTrack(i) +
                          (TimelineGeometry.trackHeight - 22) / 2,
                      width: 22,
                      height: 22,
                      child: _RemoveLaneButton(
                        track: lanes[i],
                        onRemove: () => controller.removeTrack(lanes[i].id),
                      ),
                    ),
              ],
            ),
          );
        },
      );
}

class _RemoveLaneButton extends StatefulWidget {
  const _RemoveLaneButton({required this.track, required this.onRemove});

  final Track track;
  final VoidCallback onRemove;

  @override
  State<_RemoveLaneButton> createState() => _RemoveLaneButtonState();
}

class _RemoveLaneButtonState extends State<_RemoveLaneButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final clips = widget.track.clips.length;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: Tooltip(
        message: clips == 0
            ? 'Remove ${widget.track.name}'
            : 'Remove ${widget.track.name} and its '
                '$clips clip${clips == 1 ? '' : 's'}',
        waitDuration: const Duration(milliseconds: 500),
        child: GestureDetector(
          onTap: widget.onRemove,
          child: Opacity(
            opacity: _hovered ? 1 : 0.35,
            child: const Icon(Icons.close, size: 14, color: VdColors.dim),
          ),
        ),
      ),
    );
  }
}

/// How tall the timeline wants to be for [trackCount] lanes, bounded so a
/// project with many tracks does not eat the preview.
double timelineHeightFor(int trackCount) =>
    TimelineGeometry.heightFor(trackCount).clamp(120.0, 320.0);
