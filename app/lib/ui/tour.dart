import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// One stop on the tour: what it points at, and what it says about it.
///
/// [target] is a key on a widget that is already on screen for its own
/// reasons. Nothing here is a tour-shaped copy of the editor — the tour points
/// at the real panels, so a stop that goes stale is one whose key stopped
/// resolving rather than one whose picture stopped matching.
@immutable
final class TourStop {
  const TourStop({required this.title, required this.body, this.target});

  final String title;
  final String body;

  /// What to cut out of the scrim. Null dims the whole window and centres the
  /// card, which is what a stop that is about the app rather than about a
  /// panel wants.
  final GlobalKey? target;
}

/// Where the tour points. One key per stop, held by whoever builds the editor
/// so the panels can be handed them and the tour can find them again.
///
/// A record rather than a map: the compiler then says so when a stop names an
/// anchor nobody attached, where a missing map key would be a hole in the
/// scrim that silently stopped appearing.
typedef TourAnchors = ({
  GlobalKey preview,
  GlobalKey timeline,
  GlobalKey bin,
  GlobalKey inspector,
  GlobalKey export,
});

TourAnchors makeTourAnchors() => (
      preview: GlobalKey(debugLabel: 'tour.preview'),
      timeline: GlobalKey(debugLabel: 'tour.timeline'),
      bin: GlobalKey(debugLabel: 'tour.bin'),
      inspector: GlobalKey(debugLabel: 'tour.inspector'),
      export: GlobalKey(debugLabel: 'tour.export'),
    );

/// The tour, in order. Six stops, because the promise in PLAN.md is sixty
/// seconds and ten seconds is about as long as anybody reads a card for.
///
/// Every one of them says something the editor cannot say by looking like
/// itself: which lane is magnetic, that there is no import dialog to hunt for,
/// that 1080p carries no watermark, that nothing leaves the machine. The
/// things that *are* obvious from the picture are left out — a tour that
/// narrates what is already on screen is one people learn to skip.
List<TourStop> editorTour(TourAnchors anchors) => [
      TourStop(
        target: anchors.preview,
        title: 'This is your film',
        body: 'Space plays and pauses. What you see here is exactly what an '
            'export writes — same compositor, same frame, only the clock is '
            'different.',
      ),
      TourStop(
        target: anchors.timeline,
        title: 'The timeline',
        body: 'Drag a clip to move it, grab an edge to trim, and press S to '
            'split at the playhead. The top lane is magnetic: delete a clip '
            'and the rest close up behind it.',
      ),
      TourStop(
        target: anchors.bin,
        title: 'Your footage',
        body: 'Everything this project uses. To add more, drop files anywhere '
            'in the window — there is no import dialog to go and find.',
      ),
      TourStop(
        target: anchors.inspector,
        title: 'One clip at a time',
        body: 'Select a clip and this is everything about it: where it sits, '
            'its colour and its look, how it arrives and leaves, and how loud '
            'it is. Nothing here is measured in pixels, so a cut made at '
            '1080p exports the same at 4K.',
      ),
      TourStop(
        target: anchors.export,
        title: 'Getting it out',
        body: '⌘E writes an MP4. 1080p is free — no watermark, no account, no '
            'export limit. 4K is the one thing Pro is for.',
      ),
      const TourStop(
        title: 'That is the tour',
        body: 'Press ? for every shortcut, and take this project apart: it is '
            'a project like any other. Nothing you do in vdodtor leaves this '
            'machine — the app ships with no network access at all.',
      ),
    ];

/// The scrim, so a test can read the hole off it without hunting through
/// every [CustomPaint] a [Scaffold] puts on screen.
const scrimKey = ValueKey('tour.scrim');

/// The dimmed layer with a hole in it, and the card beside the hole.
///
/// Sits at the top of the editor's own [Stack] rather than in a route, for one
/// reason: it has to point at panels that are on screen, and a dialog would
/// put a barrier between the card and the thing it is talking about. That also
/// means the editor underneath stays live — pressing space during the first
/// stop plays the film, which is the stop's own instruction working.
class TourOverlay extends StatefulWidget {
  const TourOverlay({
    super.key,
    required this.stops,
    required this.onFinished,
  });

  final List<TourStop> stops;

  /// Called once, whether the tour was finished or skipped. There is no
  /// difference worth recording: both mean "do not show this again", and a
  /// product that treats skipping as unfinished business shows it twice.
  final VoidCallback onFinished;

  @override
  State<TourOverlay> createState() => _TourOverlayState();
}

class _TourOverlayState extends State<TourOverlay> {
  /// The layer's own box, so a target measured in global coordinates can be
  /// put back into the coordinates this thing paints in.
  final GlobalKey _layer = GlobalKey(debugLabel: 'tour.layer');

  int _index = 0;
  Rect? _hole;

  /// How far the hole is inflated past the widget it is cut around. Enough to
  /// read as a highlight rather than as a crop.
  static const double _padding = 6;

  @override
  void initState() {
    super.initState();
    _scheduleMeasure();
  }

  /// Re-measured after every frame rather than only when the stop changes.
  ///
  /// The things being pointed at move for reasons the tour cannot see: the
  /// window is resized, the engine finishes starting and the preview replaces
  /// a spinner, a lane is added and the timeline grows. Measuring once would
  /// leave the hole behind, and the hole being in the wrong place is worse
  /// than no hole at all. It settles after one frame, because a rect that has
  /// not moved schedules no rebuild.
  void _scheduleMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final next = _measure();
      if (next != _hole) setState(() => _hole = next);
      _scheduleMeasure();
    });
  }

  Rect? _measure() {
    final target = widget.stops[_index].target?.currentContext;
    final layer = _layer.currentContext?.findRenderObject();
    if (target == null || layer is! RenderBox) return null;

    final box = target.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;

    final topLeft = layer.globalToLocal(box.localToGlobal(Offset.zero));
    return (topLeft & box.size).inflate(_padding);
  }

  void _next() {
    if (_index + 1 >= widget.stops.length) {
      widget.onFinished();
      return;
    }
    setState(() {
      _index++;
      // Cleared rather than kept: the old hole belongs to the old stop, and
      // leaving it up for the frame before the next measurement lands is a
      // visible jump from one panel to another via a third.
      _hole = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final stop = widget.stops[_index];
    final last = _index + 1 == widget.stops.length;

    return Positioned.fill(
      // Shortcuts outside the focus rather than inside it: `CallbackShortcuts`
      // handles keys that *bubble through* it, so the focused node has to be
      // one of its descendants. The other way round the bindings are above the
      // node the event starts at and never see it — which is the arrangement
      // the chooser already uses in `main.dart`.
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): widget.onFinished,
          const SingleActivator(LogicalKeyboardKey.enter): _next,
        },
        child: Focus(
          autofocus: true,
          child: LayoutBuilder(
            key: _layer,
            builder: (context, constraints) {
              final size = Size(constraints.maxWidth, constraints.maxHeight);
              return Stack(
                children: [
                  // Swallows the click that would otherwise land on whatever
                  // is under the scrim. The hole is a highlight, not a
                  // cut-out anybody may reach through: a tour whose fourth
                  // stop can be dismissed by clicking the panel it is
                  // describing is one that ends by accident.
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {},
                      child: CustomPaint(
                        key: scrimKey,
                        painter: TourScrimPainter(hole: _hole),
                      ),
                    ),
                  ),
                  _card(size, stop, last),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _card(Size size, TourStop stop, bool last) {
    const width = 380.0;
    const margin = 24.0;
    final hole = _hole;

    // Centred when there is nothing to sit beside, and otherwise under the
    // hole — or over it when the hole is low enough that under would be off
    // the bottom. Horizontally it is pinned to the hole's own left edge and
    // then pulled back inside the window, which keeps the card next to a
    // narrow rail instead of floating in the middle of the screen.
    if (hole == null) {
      return Center(
        child: SizedBox(width: width, child: _Card(
          stop: stop,
          index: _index,
          total: widget.stops.length,
          last: last,
          onNext: _next,
          onSkip: widget.onFinished,
        )),
      );
    }

    const estimatedHeight = 210.0;
    final below = hole.bottom + 14;
    final above = hole.top - 14 - estimatedHeight;
    final top = below + estimatedHeight + margin <= size.height
        ? below
        : (above >= margin ? above : (size.height - estimatedHeight) / 2);
    final left = hole.left
        .clamp(margin, (size.width - width - margin).clamp(margin, size.width));

    return Positioned(
      top: top.clamp(margin, size.height - margin),
      left: left,
      width: width,
      child: _Card(
        stop: stop,
        index: _index,
        total: widget.stops.length,
        last: last,
        onNext: _next,
        onSkip: widget.onFinished,
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.stop,
    required this.index,
    required this.total,
    required this.last,
    required this.onNext,
    required this.onSkip,
  });

  final TourStop stop;
  final int index;
  final int total;
  final bool last;
  final VoidCallback onNext;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) => Material(
        color: VdColors.panel,
        elevation: 12,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 18, 14, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: VdColors.line),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(stop.title,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(stop.body,
                  style: const TextStyle(color: VdColors.dim, height: 1.4)),
              const SizedBox(height: 10),
              Row(
                children: [
                  Text('${index + 1} of $total',
                      style: const TextStyle(
                          fontSize: 11, color: VdColors.dim)),
                  const Spacer(),
                  if (!last)
                    TextButton(
                      onPressed: onSkip,
                      child: const Text('Skip tour'),
                    ),
                  FilledButton(
                    onPressed: onNext,
                    child: Text(last ? 'Start editing' : 'Next'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
}

/// Everything but the hole, dimmed.
///
/// Public, with [hole] on it, because where the hole is *is* the tour's only
/// observable output: the cards are text anybody can find, and a highlight
/// over the wrong panel would look exactly like a highlight over the right
/// one to every other kind of assertion.
class TourScrimPainter extends CustomPainter {
  const TourScrimPainter({required this.hole});

  final Rect? hole;

  static const _radius = Radius.circular(10);

  @override
  void paint(Canvas canvas, Size size) {
    final full = Offset.zero & size;
    final scrim = Paint()..color = const Color(0xB3000000);

    if (hole == null) {
      canvas.drawRect(full, scrim);
      return;
    }

    final cut = RRect.fromRectAndRadius(hole!, _radius);
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(full),
        Path()..addRRect(cut),
      ),
      scrim,
    );
    canvas.drawRRect(
      cut,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = VdColors.accent,
    );
  }

  @override
  bool shouldRepaint(TourScrimPainter old) => old.hole != hole;
}
