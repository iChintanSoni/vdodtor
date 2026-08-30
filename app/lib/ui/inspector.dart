import 'package:flutter/material.dart';

import '../commands/document_store.dart';
import '../commands/edits.dart';
import '../model/clip.dart';
import 'theme.dart';
import 'timeline/timeline_controller.dart';

/// What the selected clip is doing inside the frame.
///
/// Only shown for a single selection. Every control here is a property of one
/// clip, and averaging four clips' rotations into one slider would be a lie
/// that is hard to notice and harder to undo.
class Inspector extends StatelessWidget {
  const Inspector({super.key, required this.timeline});

  final TimelineController timeline;

  static const double width = 224;

  DocumentStore get _store => timeline.store;

  void _set(Clip clip, ClipTransform transform) =>
      _store.run(SetClipTransform(clip.id, transform), fromGestureStart: true);

  /// Ends the gesture, so the next drag is a new undo entry rather than a
  /// continuation of this one.
  void _commit() => _store.endGesture();

  @override
  Widget build(BuildContext context) {
    final clip = timeline.selectedClip;

    return Container(
      width: width,
      color: VdColors.rail,
      child: clip == null
          ? const _NothingSelected()
          : _TransformControls(
              clip: clip,
              onChanged: (t) => _set(clip, t),
              onCommit: _commit,
              onReset: () {
                _commit();
                _store.run(
                    SetClipTransform(clip.id, ClipTransform.identity));
                _commit();
              },
            ),
    );
  }
}

class _NothingSelected extends StatelessWidget {
  const _NothingSelected();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.fromLTRB(16, 24, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ADJUST',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w600,
                  color: VdColors.dim,
                )),
            SizedBox(height: 12),
            Text(
              'Select one clip to move, scale, rotate or crop it.',
              style: TextStyle(fontSize: 12, color: VdColors.dim, height: 1.4),
            ),
          ],
        ),
      );
}

class _TransformControls extends StatelessWidget {
  const _TransformControls({
    required this.clip,
    required this.onChanged,
    required this.onCommit,
    required this.onReset,
  });

  final Clip clip;
  final ValueChanged<ClipTransform> onChanged;
  final VoidCallback onCommit;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final t = clip.transform;

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 10, 20),
      children: [
        Row(
          children: [
            const Text('ADJUST',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w600,
                  color: VdColors.dim,
                )),
            const Spacer(),
            if (!t.isIdentity)
              TextButton(
                onPressed: onReset,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('Reset', style: TextStyle(fontSize: 11)),
              ),
          ],
        ),
        Text(
          clip.label.isEmpty ? 'Clip' : clip.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: VdColors.text),
        ),
        const SizedBox(height: 14),
        _Slider(
          label: 'Scale',
          value: t.scale,
          min: 0.05,
          max: 4,
          format: (v) => '${(v * 100).round()}%',
          onChanged: (v) => onChanged(t.copyWith(scale: v)),
          onCommit: onCommit,
        ),
        _Slider(
          label: 'Rotation',
          value: t.rotationDegrees,
          min: -180,
          max: 180,
          format: (v) => '${v.round()}°',
          onChanged: (v) => onChanged(t.copyWith(rotationDegrees: v)),
          onCommit: onCommit,
        ),
        _Slider(
          label: 'Opacity',
          value: t.opacity,
          min: 0,
          max: 1,
          format: (v) => '${(v * 100).round()}%',
          onChanged: (v) => onChanged(t.copyWith(opacity: v)),
          onCommit: onCommit,
        ),
        const _SectionLabel('POSITION'),
        _Slider(
          label: 'X',
          value: t.offsetX,
          min: -1,
          max: 1,
          format: _percentOfFrame,
          onChanged: (v) => onChanged(t.copyWith(offsetX: v)),
          onCommit: onCommit,
        ),
        _Slider(
          label: 'Y',
          value: t.offsetY,
          min: -1,
          max: 1,
          format: _percentOfFrame,
          onChanged: (v) => onChanged(t.copyWith(offsetY: v)),
          onCommit: onCommit,
        ),
        const _SectionLabel('CROP'),
        _Slider(
          label: 'Left',
          value: t.cropLeft,
          min: 0,
          max: 0.9,
          format: _percentOfFrame,
          onChanged: (v) => onChanged(t.copyWith(cropLeft: v)),
          onCommit: onCommit,
        ),
        _Slider(
          label: 'Right',
          value: t.cropRight,
          min: 0,
          max: 0.9,
          format: _percentOfFrame,
          onChanged: (v) => onChanged(t.copyWith(cropRight: v)),
          onCommit: onCommit,
        ),
        _Slider(
          label: 'Top',
          value: t.cropTop,
          min: 0,
          max: 0.9,
          format: _percentOfFrame,
          onChanged: (v) => onChanged(t.copyWith(cropTop: v)),
          onCommit: onCommit,
        ),
        _Slider(
          label: 'Bottom',
          value: t.cropBottom,
          min: 0,
          max: 0.9,
          format: _percentOfFrame,
          onChanged: (v) => onChanged(t.copyWith(cropBottom: v)),
          onCommit: onCommit,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _FlipButton(
              label: 'Flip H',
              icon: Icons.swap_horiz,
              on: t.flipHorizontal,
              onTap: () {
                onCommit();
                onChanged(t.copyWith(flipHorizontal: !t.flipHorizontal));
                onCommit();
              },
            ),
            const SizedBox(width: 8),
            _FlipButton(
              label: 'Flip V',
              icon: Icons.swap_vert,
              on: t.flipVertical,
              onTap: () {
                onCommit();
                onChanged(t.copyWith(flipVertical: !t.flipVertical));
                onCommit();
              },
            ),
          ],
        ),
      ],
    );
  }
}

String _percentOfFrame(double v) => '${(v * 100).round()}%';

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 2),
        child: Text(text,
            style: const TextStyle(
              fontSize: 10,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w600,
              color: VdColors.dim,
            )),
      );
}

class _Slider extends StatelessWidget {
  const _Slider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.format,
    required this.onChanged,
    required this.onCommit,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String Function(double) format;
  final ValueChanged<double> onChanged;
  final VoidCallback onCommit;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(label,
                  style:
                      const TextStyle(fontSize: 11, color: VdColors.text)),
              const Spacer(),
              Text(format(value),
                  style: vdMono.copyWith(fontSize: 10, color: VdColors.dim)),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
              // The whole drag is one undo entry; this is where it closes.
              onChangeEnd: (_) => onCommit(),
            ),
          ),
        ],
      );
}

class _FlipButton extends StatelessWidget {
  const _FlipButton({
    required this.label,
    required this.icon,
    required this.on,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
        child: OutlinedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 15),
          label: Text(label, style: const TextStyle(fontSize: 11)),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            foregroundColor: on ? VdColors.accent : VdColors.dim,
            side: BorderSide(
                color: on ? VdColors.accent : VdColors.line),
          ),
        ),
      );
}
