import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
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
///
/// It owns a second ticker for the same reason it owns the pointer: a flick of
/// the trackpad keeps moving after the fingers have gone, and nothing below
/// this line knows a finger exists.
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
    with TickerProviderStateMixin {
  late final Ticker _ticker;

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

  void _onTick(Duration _) => widget.controller.pump();

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
    _stopMomentum();
    final keys = HardwareKeyboard.instance;
    if (keys.isMetaPressed || keys.isControlPressed) {
      widget.controller.zoomAround(
          event.localPosition.dx, event.scrollDelta.dy > 0 ? 0.9 : 1.1);
      return;
    }
    // A wheel only has one axis, so a vertical one pans too rather than doing
    // nothing. There is no vertical scrolling here for it to mean instead.
    final dx = event.scrollDelta.dx != 0
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    widget.controller.panBy(dx);
  }

  /// The cumulative pinch of the gesture in progress, so an update can be
  /// turned into what *this* frame is worth.
  double _panZoomScale = 1;

  /// The axis the current swipe was decided to be along, fixed for as long as
  /// it lasts; how far it has travelled, which is what decides that axis; and
  /// the tracker that says how fast it was going when it ended.
  Axis? _panAxis;
  Offset _panTravel = Offset.zero;
  VelocityTracker? _panVelocity;

  /// The glide after the fingers have gone. Null when nothing is coasting.
  Ticker? _momentum;

  void _onPanZoomStart(PointerPanZoomStartEvent event) {
    _stopMomentum();
    _panZoomScale = 1;
    _panAxis = null;
    _panTravel = Offset.zero;
    _panVelocity = VelocityTracker.withKind(PointerDeviceKind.trackpad)
      ..addPosition(event.timeStamp, Offset.zero);
  }

  /// A trackpad, which macOS does not report as a wheel.
  ///
  /// This is the whole of scrolling on a laptop and it was missing. A discrete
  /// wheel arrives as a [PointerScrollEvent]; a two-finger swipe has an
  /// `NSEvent` phase, so the embedder sends it as a pan/zoom sequence instead,
  /// and a [Listener] that handles only the signal hears nothing at all. The
  /// timeline could therefore be panned with a mouse and not with the trackpad
  /// of the machine it was being written on — and a project longer than the
  /// window had an end nobody could reach.
  ///
  /// **The sign is opposite to the wheel's, and that is not a preference.**
  /// The embedder negates a wheel's delta on the way through and does not
  /// negate a pan's, because a pan is a drag: the framework feeds it to the
  /// same recognisers as a finger, and a drag *subtracts* from a scroll offset
  /// where a wheel delta adds to it. Following the fingers therefore means
  /// negating it, and the two gestures then move the timeline the same way —
  /// which is the only thing anybody can check by hand.
  void _onPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    // Accumulated from the deltas rather than read off `localPan`, which is
    // not the offset it looks like: the framework transforms it as a
    // *position*, so it arrives with this widget's own place in the window
    // added to it. Every horizontal swipe then measures as overwhelmingly
    // vertical, because the timeline sits hundreds of pixels down the screen.
    // A delta is transformed as a delta and carries none of that.
    final delta = event.localPanDelta;
    _panTravel += delta;
    _panVelocity?.addPosition(event.timeStamp, _panTravel);

    // A pinch reports the scale accumulated since the gesture began, so what
    // this frame is worth is the ratio to the last one. A pan reports exactly
    // 1.0 throughout, which is what keeps these two apart.
    if (event.scale != _panZoomScale) {
      final factor = event.scale / _panZoomScale;
      _panZoomScale = event.scale;
      _panAxis = null;
      _panTravel = Offset.zero;
      widget.controller.zoomAround(event.localPosition.dx, factor);
      return;
    }

    // **The axis is decided once and then held.** Both of a trackpad's axes
    // carry a real number — a swipe meant to be horizontal still drifts
    // vertically — so choosing the larger one per event makes a diagonal swipe
    // flip between them frame to frame and the timeline stutter under a hand
    // that is moving smoothly. Deciding at the start of the gesture is what
    // makes it feel like one gesture rather than a poll.
    _panAxis ??= _panTravel.distance < _axisLockThreshold
        ? null
        : (_panTravel.dx.abs() >= _panTravel.dy.abs()
            ? Axis.horizontal
            : Axis.vertical);
    final axis = _panAxis;
    if (axis == null) return;

    final along = axis == Axis.horizontal ? delta.dx : delta.dy;
    if (along == 0) return;

    // Held down, either axis zooms, which is what ⌘ and the wheel already do.
    final keys = HardwareKeyboard.instance;
    if (keys.isMetaPressed || keys.isControlPressed) {
      widget.controller
          .zoomAround(event.localPosition.dx, along > 0 ? 1.1 : 0.9);
      return;
    }

    // **A vertical swipe does nothing on its own.** Time runs across, so
    // swiping down the screen and having the film run forwards is a gesture
    // pointing one way and a result going another. The wheel is the exception
    // and stays one: it has a single axis, so a vertical notch is the only
    // thing it can offer and doing nothing with it would leave a mouse unable
    // to scroll at all. A trackpad has the axis that means what it says.
    if (axis != Axis.horizontal) return;
    widget.controller.panBy(-along);
  }

  /// Hands the swipe over to the momentum ticker.
  ///
  /// macOS sends **nothing** after the fingers lift: the embedder drops the
  /// inertia events outright, on the grounds that the framework will generate
  /// the momentum — which [Scrollable] does, from the drag's velocity, and a
  /// bare [Listener] does not. So a swipe stopped dead the instant contact
  /// ended, in an operating system where every other window coasts. That is
  /// what "sticky" was, and it could not be found by reading the events that
  /// arrive, because the whole of it is the events that do not.
  void _onPanZoomEnd(PointerPanZoomEndEvent event) {
    final tracker = _panVelocity;
    final axis = _panAxis;
    _panVelocity = null;
    _panAxis = null;
    _panTravel = Offset.zero;
    if (tracker == null || axis == null) return;

    // Only the gesture that moved anything has anywhere to coast to.
    if (axis != Axis.horizontal) return;
    _startMomentum(-tracker.getVelocity().pixelsPerSecond.dx);
  }

  /// Coasts to a stop from [velocity] px/s, in the timeline's own direction.
  void _startMomentum(double velocity) {
    if (velocity.abs() < kMinFlingVelocity) return;
    final simulation = FrictionSimulation(
      _momentumDrag,
      0,
      velocity.clamp(-kMaxFlingVelocity, kMaxFlingVelocity),
    )..tolerance = const Tolerance(velocity: 16, distance: 0.5);

    var last = 0.0;
    _momentum = createTicker((elapsed) {
      final t = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
      final x = simulation.x(t);
      widget.controller.panBy(x - last);
      last = x;
      // Stopped at the left edge too: panBy clamps at zero, so a glide that
      // has run out of timeline is a ticker spending frames on nothing.
      if (simulation.isDone(t) || widget.controller.geometry.scrollPx == 0) {
        _stopMomentum();
      }
    })
      ..start();
  }

  /// Ends any glide. Touching the timeline stops it — a coast you cannot
  /// interrupt is worse than none — so this is called from every gesture that
  /// starts.
  void _stopMomentum() {
    _momentum?.dispose();
    _momentum = null;
  }

  /// How far from the start a swipe has to travel before it counts as having a
  /// direction. Below it the numbers are noise and the axis would be a guess.
  static const double _axisLockThreshold = 6;

  /// The framework's own inertial constant, so a timeline coasts like
  /// everything else on the machine rather than to a number invented here.
  static const double _momentumDrag = 0.135;

  @override
  void dispose() {
    _stopMomentum();
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
          // The controller needs this for anything that has to leave the
          // playhead on screen — following it during playback, zooming from a
          // key. Set at layout rather than passed to each call, so there is
          // one answer and it is never the caller's guess.
          widget.controller.viewportWidth = constraints.maxWidth;
          widget.controller.viewportHeight = constraints.maxHeight;
          return Listener(
            onPointerDown: (e) {
              _stopMomentum();
              widget.controller.pointerDown(
                e.localPosition,
                additive: HardwareKeyboard.instance.isMetaPressed ||
                    HardwareKeyboard.instance.isShiftPressed,
                alt: HardwareKeyboard.instance.isAltPressed,
              );
            },
            onPointerMove: (e) => widget.controller.pointerMove(e.localPosition),
            onPointerUp: (_) => widget.controller.pointerUp(),
            onPointerCancel: (_) => widget.controller.pointerUp(),
            onPointerSignal: _onSignal,
            onPointerPanZoomStart: _onPanZoomStart,
            onPointerPanZoomUpdate: _onPanZoomUpdate,
            onPointerPanZoomEnd: _onPanZoomEnd,
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
                  _TimelineScrollbar(controller: widget.controller),
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

/// How much timeline there is, and where in it you are looking.
///
/// The timeline pans freely and has no edges to bump into, so until there was
/// a bar there was **nothing on screen that said the project continued past
/// the right-hand side** — a two-minute edit under a twenty-second window
/// looked like a twenty-second edit. That is the failure this exists for, and
/// it is why the thumb appears only when there is something off screen: a bar
/// that is always full is furniture.
///
/// A widget rather than paint, for [_LaneControls]'s reason — it is grabbed,
/// so it needs a hit box and a cursor — and the arithmetic stays in
/// [TimelineGeometry.scrollbarThumb] so the thing drawn and the thing dragged
/// cannot disagree.
class _TimelineScrollbar extends StatefulWidget {
  const _TimelineScrollbar({required this.controller});

  final TimelineController controller;

  @override
  State<_TimelineScrollbar> createState() => _TimelineScrollbarState();
}

class _TimelineScrollbarState extends State<_TimelineScrollbar> {
  bool _hovered = false;
  bool _dragging = false;

  /// Content pixels per thumb pixel for the drag in progress, taken once at
  /// the start: it is a function of the zoom and of how far there is to go,
  /// and both move underneath a drag that is changing the second of them.
  double _scale = 1;

  void _onDragStart(DragStartDetails details, double trackWidth) {
    final thumb = widget.controller.scrollbarThumb;
    if (thumb == null) return;
    _scale = thumb.scale;
    _dragging = true;

    // Pressing the track rather than the thumb takes you there, then drags
    // from there: a press that did nothing until you moved would read as a
    // dead bar, and one that paged would need a second gesture to arrive.
    final x = details.localPosition.dx;
    if (x < thumb.left || x > thumb.left + thumb.width) {
      widget.controller
          .panBy((x - thumb.width / 2 - thumb.left) * thumb.scale);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final thumb = widget.controller.scrollbarThumb;
          return Positioned(
            left: TimelineGeometry.headerWidth,
            right: 0,
            bottom: 0,
            height: TimelineGeometry.scrollbarHeight,
            child: thumb == null
                ? const SizedBox.shrink()
                : LayoutBuilder(
                    builder: (context, constraints) => MouseRegion(
                      onEnter: (_) => setState(() => _hovered = true),
                      onExit: (_) => setState(() => _hovered = false),
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragStart: (d) =>
                            _onDragStart(d, constraints.maxWidth),
                        onHorizontalDragUpdate: (d) =>
                            widget.controller.panBy(d.delta.dx * _scale),
                        onHorizontalDragEnd: (_) =>
                            setState(() => _dragging = false),
                        onHorizontalDragCancel: () =>
                            setState(() => _dragging = false),
                        child: Stack(
                          children: [
                            Positioned(
                              left: thumb.left,
                              width: thumb.width,
                              top: 2,
                              bottom: 2,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: VdColors.dim.withValues(
                                      alpha: _dragging
                                          ? 0.75
                                          : _hovered
                                              ? 0.55
                                              : 0.35),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ],
                        ),
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
    TimelineGeometry.heightFor(trackCount).clamp(120.0, 320.0);
