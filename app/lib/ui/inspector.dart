import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../commands/document_store.dart';
import '../commands/edits.dart';
import '../model/clip.dart';
import '../model/time.dart';
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

  void _setAudio(Clip clip, ClipAudio audio) =>
      _store.run(SetClipAudio(clip.id, audio), fromGestureStart: true);

  @override
  Widget build(BuildContext context) {
    final clip = timeline.selectedClip;
    if (clip == null) {
      return const SizedBox(
        width: width,
        child: ColoredBox(color: VdColors.rail, child: _NothingSelected()),
      );
    }

    // What a clip *is* decides which controls it gets. A clip on an audio lane
    // has no picture to place, and one whose file is silent has no level to
    // set — showing either would be a control that does nothing.
    final track = timeline.project.trackOfClip(clip.id);
    final asset = timeline.project.assetFor(clip);
    final showsPicture =
        (track?.kind.isVisual ?? true) && (asset?.probe.hasVideo ?? true);
    final hasSound = asset?.probe.hasAudio ?? false;

    return Container(
      width: width,
      color: VdColors.rail,
      child: ListView(
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
              if (showsPicture && !clip.transform.isIdentity)
                TextButton(
                  onPressed: () {
                    _commit();
                    _store.run(
                        SetClipTransform(clip.id, ClipTransform.identity));
                    _commit();
                  },
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
          const SizedBox(height: 12),
          if (showsPicture)
            _TransformControls(
              clip: clip,
              onChanged: (t) => _set(clip, t),
              onCommit: _commit,
            ),
          // After the picture, because that is the order someone works in and
          // because sound is the half you check last.
          if (hasSound)
            _AudioControls(
              clip: clip,
              // Where a point would go if one were added now: null when the
              // playhead is not over this clip, which is when the button has
              // nothing to point at.
              atPlayhead: clip.span.contains(timeline.playhead)
                  ? clip.sourceTimeAt(timeline.playhead)
                  : null,
              onChanged: (a) => _setAudio(clip, a),
              onCommit: _commit,
              onAddPoint: (t) => timeline.addVolumePoint(clip.id, t),
            ),
        ],
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
  });

  final Clip clip;
  final ValueChanged<ClipTransform> onChanged;
  final VoidCallback onCommit;

  @override
  Widget build(BuildContext context) {
    final t = clip.transform;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionLabel('FILL'),
        _FitPicker(
          fit: t.fit,
          onChanged: (fit) {
            onCommit();
            onChanged(t.copyWith(fit: fit));
            onCommit();
          },
        ),
        const SizedBox(height: 6),
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

/// Volume, mute and fades for a clip that makes a sound.
///
/// The fader is marked in decibels and stored as a linear multiplier — see
/// [ClipAudio]. The ear is logarithmic, so a fader that moves linearly through
/// gain spends most of its travel in the top few dB and is unusable for the
/// quiet end, where all the useful adjustment is.
class _AudioControls extends StatelessWidget {
  const _AudioControls({
    required this.clip,
    required this.atPlayhead,
    required this.onChanged,
    required this.onCommit,
    required this.onAddPoint,
  });

  final Clip clip;

  /// The source time under the playhead, or null when the playhead is not
  /// over this clip.
  final Tick? atPlayhead;

  final ValueChanged<ClipAudio> onChanged;
  final VoidCallback onCommit;
  final ValueChanged<Tick> onAddPoint;

  /// The longest a fade may be: half the clip, so a fade in and a fade out can
  /// both be at maximum without meeting in the middle.
  Tick get _maxFade => Tick(clip.duration.raw ~/ 2);

  @override
  Widget build(BuildContext context) {
    final a = clip.audio;
    final maxFade = _maxFade.raw.toDouble();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 14),
        Row(
          children: [
            const _SectionLabel('SOUND'),
            const Spacer(),
            if (!a.isUnity)
              TextButton(
                onPressed: () {
                  onCommit();
                  onChanged(ClipAudio.unity);
                  onCommit();
                },
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('Reset', style: TextStyle(fontSize: 11)),
              ),
          ],
        ),
        _MuteButton(
          muted: a.muted,
          onTap: () {
            onCommit();
            onChanged(a.copyWith(muted: !a.muted));
            onCommit();
          },
        ),
        const SizedBox(height: 6),
        _Slider(
          label: 'Volume',
          value: a.volume,
          min: 0,
          max: ClipAudio.maxVolume,
          format: _decibels,
          onChanged: (v) => onChanged(a.copyWith(volume: v)),
          onCommit: onCommit,
        ),
        // A clip one frame long cannot be faded, and a slider whose ends meet
        // is worse than no slider.
        if (maxFade > 0) ...[
          _Slider(
            label: 'Fade in',
            value: a.fadeIn.raw.toDouble().clamp(0, maxFade),
            min: 0,
            max: maxFade,
            format: _seconds,
            onChanged: (v) => onChanged(a.copyWith(fadeIn: Tick(v.round()))),
            onCommit: onCommit,
          ),
          _Slider(
            label: 'Fade out',
            value: a.fadeOut.raw.toDouble().clamp(0, maxFade),
            min: 0,
            max: maxFade,
            format: _seconds,
            onChanged: (v) => onChanged(a.copyWith(fadeOut: Tick(v.round()))),
            onCommit: onCommit,
          ),
        ],
        _VolumeLineControls(
          points: a.points.length,
          atPlayhead: atPlayhead,
          onAdd: onAddPoint,
          onClear: () {
            onCommit();
            onChanged(a.withoutAutomation);
            onCommit();
          },
        ),
      ],
    );
  }
}

/// The volume line, from the inspector's side.
///
/// The line itself is drawn on and edited in the timeline, where the sound it
/// is shaping is. What is here is the way in — ⌥-click on a waveform is not a
/// gesture anyone guesses — and a count, so a curve dragged off the visible
/// part of a clip is not invisible as well as inaudible.
class _VolumeLineControls extends StatelessWidget {
  const _VolumeLineControls({
    required this.points,
    required this.atPlayhead,
    required this.onAdd,
    required this.onClear,
  });

  final int points;
  final Tick? atPlayhead;
  final ValueChanged<Tick> onAdd;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final at = atPlayhead;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const _SectionLabel('VOLUME LINE'),
            const Spacer(),
            if (points > 0)
              TextButton(
                onPressed: onClear,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('Clear', style: TextStyle(fontSize: 11)),
              ),
          ],
        ),
        Text(
          points == 0
              ? 'None. ⌥-click a clip to duck it.'
              : '$points point${points == 1 ? '' : 's'} · '
                  '⌥-click one to remove it',
          style: const TextStyle(fontSize: 10.5, color: VdColors.dim,
              height: 1.35),
        ),
        const SizedBox(height: 4),
        TextButton.icon(
          onPressed: at == null ? null : () => onAdd(at),
          icon: const Icon(Icons.add, size: 15),
          label: const Text('Point at playhead',
              style: TextStyle(fontSize: 11)),
          style: TextButton.styleFrom(
            foregroundColor: VdColors.dim,
            visualDensity: VisualDensity.compact,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
        ),
      ],
    );
  }
}

/// Gain as decibels, with silence spelled out rather than shown as the -inf it
/// mathematically is.
String _decibels(double gain) {
  if (gain <= 0) return 'silent';
  final db = 20 * (math.log(gain) / math.ln10);
  if (db.abs() < 0.05) return '0.0 dB';
  return '${db >= 0 ? '+' : ''}${db.toStringAsFixed(1)} dB';
}

String _seconds(double ticks) {
  final s = ticks / Timebase.project.ticksPerSecond;
  return s < 0.05 ? 'none' : '${s.toStringAsFixed(2)}s';
}

class _MuteButton extends StatelessWidget {
  const _MuteButton({required this.muted, required this.onTap});

  final bool muted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => TextButton.icon(
        onPressed: onTap,
        icon: Icon(muted ? Icons.volume_off : Icons.volume_up, size: 15),
        label: Text(muted ? 'Muted' : 'Mute', style: const TextStyle(fontSize: 11)),
        style: TextButton.styleFrom(
          foregroundColor: muted ? VdColors.accent : VdColors.dim,
          visualDensity: VisualDensity.compact,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
      );
}

String _percentOfFrame(double v) => '${(v * 100).round()}%';

/// How the picture fills a frame it does not match.
///
/// Four buttons rather than a dropdown: there are only four, the choice is
/// visual, and a menu hides three of them behind a click.
class _FitPicker extends StatelessWidget {
  const _FitPicker({required this.fit, required this.onChanged});

  final ClipFit fit;
  final ValueChanged<ClipFit> onChanged;

  static const _labels = {
    ClipFit.blurFill: 'Blur',
    ClipFit.contain: 'Fit',
    ClipFit.cover: 'Fill',
    ClipFit.stretch: 'Stretch',
  };

  static const _tooltips = {
    ClipFit.blurFill: 'The whole picture, with a blurred copy behind it',
    ClipFit.contain: 'The whole picture, on black',
    ClipFit.cover: 'Fills the frame; the edges are cropped away',
    ClipFit.stretch: 'Fills the frame by distorting the picture',
  };

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final option in ClipFit.values)
            Tooltip(
              message: _tooltips[option]!,
              waitDuration: const Duration(milliseconds: 500),
              child: GestureDetector(
                onTap: () => onChanged(option),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: option == fit
                        ? VdColors.accent.withValues(alpha: 0.18)
                        : Colors.transparent,
                    border: Border.all(
                      color: option == fit ? VdColors.accent : VdColors.line,
                    ),
                  ),
                  child: Text(
                    _labels[option]!,
                    style: TextStyle(
                      fontSize: 11,
                      color: option == fit ? VdColors.text : VdColors.dim,
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
}

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
