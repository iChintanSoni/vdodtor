import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../commands/document_store.dart';
import '../commands/edits.dart';
import '../media/fonts.dart';
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

  void _setText(Clip clip, ClipText text) =>
      _store.run(SetClipText(clip.id, text), fromGestureStart: true);

  void _setAnimation(Clip clip, ClipAnimation animation) =>
      _store.run(SetClipAnimation(clip.id, animation), fromGestureStart: true);

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
    final caption = clip.text;
    final showsPicture = caption != null ||
        ((track?.kind.isVisual ?? true) && (asset?.probe.hasVideo ?? true));
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
            clip.label.isEmpty ? (caption?.label ?? 'Clip') : clip.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: VdColors.text),
          ),
          const SizedBox(height: 12),
          // Before the transform, because what a caption *says* is the first
          // thing anybody wants to change about it and where it sits is the
          // second.
          if (caption != null)
            _TextControls(
              key: ValueKey(clip.id),
              text: caption,
              onChanged: (t) => _setText(clip, t),
              onCommit: _commit,
            ),
          if (showsPicture)
            _TransformControls(
              clip: clip,
              onChanged: (t) => _set(clip, t),
              onCommit: _commit,
            ),
          // Where a clip sits, and then how it gets there. In that order
          // because the resting position is what an animation animates to,
          // and choosing it first is how anybody works.
          if (showsPicture)
            _AnimationControls(
              clip: clip,
              onChanged: (a) => _setAnimation(clip, a),
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

    // A caption has no source to fit, crop or mirror: its raster is made at
    // the size of the frame, so a fit mode would do nothing and a crop would
    // cut the words off. What is left is where it sits and how big it is.
    final hasSource = !clip.isText;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasSource) ...[
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
        ] else
          const _SectionLabel('PLACE'),
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
        if (hasSource) ...[
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
      ],
    );
  }
}

/// What a caption says and how it looks.
///
/// Stateful only for the text field: a [TextEditingController] owns the cursor,
/// and rebuilding one from the document on every keystroke would send the caret
/// back to the end of the line every time somebody edited the middle of a word.
/// Everything else here is a function of the document, as usual.
class _TextControls extends StatefulWidget {
  const _TextControls({
    super.key,
    required this.text,
    required this.onChanged,
    required this.onCommit,
  });

  final ClipText text;
  final ValueChanged<ClipText> onChanged;
  final VoidCallback onCommit;

  @override
  State<_TextControls> createState() => _TextControlsState();
}

class _TextControlsState extends State<_TextControls> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.text.text);
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Leaving the field ends the edit, so the next thing typed is its own undo
    // entry rather than a continuation of a sentence finished minutes ago.
    _focus.addListener(() {
      if (!_focus.hasFocus) widget.onCommit();
    });
  }

  @override
  void didUpdateWidget(_TextControls old) {
    super.didUpdateWidget(old);
    // Undo, redo and anything else that rewrites the caption from outside has
    // to reach the field. Guarded on the value so ordinary typing — where the
    // field is already the source — leaves the selection alone.
    if (widget.text.text != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.text.text,
        selection:
            TextSelection.collapsed(offset: widget.text.text.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  ClipText get _t => widget.text;

  /// A change made by a click rather than a drag: it opens and closes its own
  /// undo entry, so it cannot fold into whatever was dragged before it.
  void _tap(ClipText next) {
    widget.onCommit();
    widget.onChanged(next);
    widget.onCommit();
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionLabel('TEXT'),
        TextField(
          controller: _controller,
          focusNode: _focus,
          maxLines: 4,
          minLines: 2,
          style: const TextStyle(fontSize: 12, color: VdColors.text),
          decoration: const InputDecoration(
            isDense: true,
            hintText: 'Type a caption',
            hintStyle: TextStyle(fontSize: 12, color: VdColors.dim),
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            border: OutlineInputBorder(),
          ),
          onChanged: (value) => widget.onChanged(t.copyWith(text: value)),
        ),
        const SizedBox(height: 8),
        _FontPicker(
          family: t.font,
          onChanged: (font) => _tap(t.copyWith(font: font)),
        ),
        const SizedBox(height: 6),
        _AlignPicker(
          alignment: t.alignment,
          onChanged: (a) => _tap(t.copyWith(alignment: a)),
        ),
        _Slider(
          label: 'Size',
          value: t.size,
          min: ClipText.minSize,
          max: ClipText.maxSize,
          format: _percentOfFrame,
          onChanged: (v) => widget.onChanged(t.copyWith(size: v)),
          onCommit: widget.onCommit,
        ),
        _Swatches(
          label: 'Colour',
          value: t.color,
          options: _fillPalette,
          onChanged: (c) => _tap(t.copyWith(color: c)),
        ),

        const _SectionLabel('OUTLINE'),
        _Slider(
          label: 'Width',
          value: t.strokeWidth,
          min: 0,
          max: ClipText.maxStrokeWidth,
          format: _percentOfSize,
          onChanged: (v) => widget.onChanged(t.copyWith(strokeWidth: v)),
          onCommit: widget.onCommit,
        ),
        // Only worth a colour once there is an outline to colour, and the
        // slider above is where one comes from.
        if (t.strokeWidth > 0)
          _Swatches(
            label: 'Colour',
            value: t.strokeColor,
            options: _fillPalette,
            onChanged: (c) => _tap(t.copyWith(strokeColor: c)),
          ),

        const _SectionLabel('SHADOW'),
        _Swatches(
          label: 'Colour',
          value: t.shadowColor,
          options: _shadowPalette,
          allowNone: true,
          onChanged: (c) => _tap(t.copyWith(shadowColor: c)),
        ),
        if (t.hasShadow) ...[
          _Slider(
            label: 'X',
            value: t.shadowOffsetX,
            min: -ClipText.maxShadowOffset,
            max: ClipText.maxShadowOffset,
            format: _percentOfSize,
            onChanged: (v) => widget.onChanged(t.copyWith(shadowOffsetX: v)),
            onCommit: widget.onCommit,
          ),
          _Slider(
            label: 'Y',
            value: t.shadowOffsetY,
            min: -ClipText.maxShadowOffset,
            max: ClipText.maxShadowOffset,
            format: _percentOfSize,
            onChanged: (v) => widget.onChanged(t.copyWith(shadowOffsetY: v)),
            onCommit: widget.onCommit,
          ),
          _Slider(
            label: 'Blur',
            value: t.shadowBlur,
            min: 0,
            max: ClipText.maxShadowBlur,
            format: _percentOfSize,
            onChanged: (v) => widget.onChanged(t.copyWith(shadowBlur: v)),
            onCommit: widget.onCommit,
          ),
        ],

        const _SectionLabel('BOX'),
        _Swatches(
          label: 'Colour',
          value: t.boxColor,
          options: _boxPalette,
          allowNone: true,
          onChanged: (c) => _tap(t.copyWith(boxColor: c)),
        ),
        if (t.hasBox) ...[
          _Slider(
            label: 'Padding',
            value: t.boxPadding,
            min: 0,
            max: ClipText.maxBoxPadding,
            format: _percentOfSize,
            onChanged: (v) => widget.onChanged(t.copyWith(boxPadding: v)),
            onCommit: widget.onCommit,
          ),
          _Slider(
            label: 'Corner',
            value: t.boxRadius,
            min: 0,
            max: ClipText.maxBoxRadius,
            format: _percentOfSize,
            onChanged: (v) => widget.onChanged(t.copyWith(boxRadius: v)),
            onCommit: widget.onCommit,
          ),
        ],

        const _SectionLabel('SPACING'),
        _Slider(
          label: 'Letter',
          value: t.letterSpacing,
          min: ClipText.minLetterSpacing,
          max: ClipText.maxLetterSpacing,
          format: _percentOfSize,
          onChanged: (v) => widget.onChanged(t.copyWith(letterSpacing: v)),
          onCommit: widget.onCommit,
        ),
        _Slider(
          label: 'Line',
          value: t.lineSpacing,
          min: ClipText.minLineSpacing,
          max: ClipText.maxLineSpacing,
          format: (v) => '${v.toStringAsFixed(2)}×',
          onChanged: (v) => widget.onChanged(t.copyWith(lineSpacing: v)),
          onCommit: widget.onCommit,
        ),
        _Slider(
          label: 'Width',
          value: t.maxWidth,
          min: ClipText.minMaxWidth,
          max: 1,
          format: _percentOfFrame,
          onChanged: (v) => widget.onChanged(t.copyWith(maxWidth: v)),
          onCommit: widget.onCommit,
        ),
      ],
    );
  }
}

/// The typefaces the app ships, previewed in themselves.
///
/// A list of names set in one face is a list nobody can choose from — the
/// whole question is what the words will look like, and the only honest answer
/// is to show them.
class _FontPicker extends StatelessWidget {
  const _FontPicker({required this.family, required this.onChanged});

  /// Empty means the system's face, which is what a project made with a font
  /// this build does not have falls back to.
  final String family;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final families = BundledFonts.families;
    // A caption whose face is not in this build still has to show which face
    // it is asking for, or changing anything else about it would silently
    // reset the font.
    final options = <String>[
      ...families,
      if (family.isNotEmpty && !families.contains(family)) family,
    ];
    if (options.isEmpty) return const SizedBox.shrink();

    return DropdownButtonFormField<String>(
      initialValue: options.contains(family) ? family : options.first,
      isDense: true,
      // The rail is 224 px and "Playfair Display" set in Playfair Display is
      // wider than that; without this the row overflows instead of eliding.
      isExpanded: true,
      decoration: const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        border: OutlineInputBorder(),
      ),
      style: const TextStyle(fontSize: 12, color: VdColors.text),
      items: [
        for (final option in options)
          DropdownMenuItem(
            value: option,
            child: Text(
              option,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, fontFamily: option),
            ),
          ),
      ],
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
    );
  }
}

class _AlignPicker extends StatelessWidget {
  const _AlignPicker({required this.alignment, required this.onChanged});

  final TextAlignment alignment;
  final ValueChanged<TextAlignment> onChanged;

  static const _icons = {
    TextAlignment.left: Icons.format_align_left,
    TextAlignment.center: Icons.format_align_center,
    TextAlignment.right: Icons.format_align_right,
  };

  @override
  Widget build(BuildContext context) => Row(
        children: [
          for (final option in TextAlignment.values) ...[
            Expanded(
              child: OutlinedButton(
                onPressed: () => onChanged(option),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  foregroundColor:
                      option == alignment ? VdColors.accent : VdColors.dim,
                  side: BorderSide(
                      color:
                          option == alignment ? VdColors.accent : VdColors.line),
                ),
                child: Icon(_icons[option], size: 16),
              ),
            ),
            if (option != TextAlignment.values.last) const SizedBox(width: 4),
          ],
        ],
      );
}

/// A colour, chosen from a short list.
///
/// A fixed palette rather than a colour wheel, on purpose: every one of these
/// reads on video, the choice is one click instead of a dialog, and the wheel
/// can arrive when somebody actually asks for a colour that is not here.
class _Swatches extends StatelessWidget {
  const _Swatches({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.allowNone = false,
  });

  final String label;
  final int value;
  final List<int> options;
  final ValueChanged<int> onChanged;

  /// Adds a "none" swatch, which is alpha 0 — how a shadow or a box is turned
  /// off without forgetting the shape it had.
  final bool allowNone;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(label,
                style: const TextStyle(fontSize: 11, color: VdColors.text)),
            const SizedBox(height: 5),
            Wrap(
              spacing: 5,
              runSpacing: 5,
              children: [
                if (allowNone)
                  _Swatch(
                    color: 0,
                    selected: (value >> 24) & 0xFF == 0,
                    onTap: () => onChanged(0),
                  ),
                for (final option in options)
                  _Swatch(
                    color: option,
                    selected: value == option,
                    onTap: () => onChanged(option),
                  ),
              ],
            ),
          ],
        ),
      );
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final int color;
  final bool selected;
  final VoidCallback onTap;

  bool get _isNone => (color >> 24) & 0xFF == 0;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: _isNone ? Colors.transparent : Color(color),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: selected ? VdColors.accent : VdColors.line,
              width: selected ? 2 : 1,
            ),
          ),
          // Nothing is a hard thing to draw. A stroke through the swatch is
          // what every other editor uses for it, and it reads immediately.
          child: _isNone
              ? const Icon(Icons.close, size: 12, color: VdColors.dim)
              : null,
        ),
      );
}

/// Colours that read on video: the two neutrals first, because a caption is
/// white or black far more often than it is anything else.
const List<int> _fillPalette = [
  0xFFFFFFFF,
  0xFF000000,
  0xFFE53935,
  0xFFFB8C00,
  0xFFFDD835,
  0xFF43A047,
  0xFF00ACC1,
  0xFF1E88E5,
  0xFF8E24AA,
  0xFFEC407A,
];

/// A shadow is almost always a soft black. The rest are here for the one time
/// somebody wants a glow rather than a shadow.
const List<int> _shadowPalette = [
  0xB3000000,
  0xFF000000,
  0xB3FFFFFF,
  0xFF1E88E5,
  0xFFE53935,
];

/// A caption box is usually a wash rather than a block — the picture should
/// still show through — so the translucent options come first.
const List<int> _boxPalette = [
  0x99000000,
  0xCC000000,
  0xFF000000,
  0x99FFFFFF,
  0xFFFFFFFF,
  0xFFE53935,
  0xFF1E88E5,
];

/// A fraction of the font size, which is what every caption measurement that
/// is not the size itself is in.
String _percentOfSize(double v) => '${(v * 100).round()}%';

/// How a clip arrives and how it leaves.
///
/// Two pickers and two lengths, and nothing else — the point of presets is
/// that the curve is somebody else's decision. A clip with no animation shows
/// only the two pickers, so the panel does not carry four controls for a
/// choice almost every clip declines.
class _AnimationControls extends StatelessWidget {
  const _AnimationControls({
    required this.clip,
    required this.onChanged,
    required this.onCommit,
  });

  final Clip clip;
  final ValueChanged<ClipAnimation> onChanged;
  final VoidCallback onCommit;

  /// The longest either half may be here: two seconds, or half the clip so an
  /// entrance and an exit can both be at maximum without meeting in the
  /// middle. The document clamps to the same rule — this is the slider
  /// agreeing with it rather than a second opinion.
  double get _maxDuration => math.min(
        ClipAnimation.maxDuration.raw.toDouble(),
        clip.duration.raw / 2,
      );

  @override
  Widget build(BuildContext context) {
    final a = clip.animation;
    final maxDuration = _maxDuration;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const _SectionLabel('ANIMATE'),
            const Spacer(),
            if (a.isAnimated)
              TextButton(
                onPressed: () {
                  onCommit();
                  onChanged(ClipAnimation.still);
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
        _PresetPicker(
          label: 'In',
          preset: a.inPreset,
          isText: clip.isText,
          onChanged: (p) {
            onCommit();
            onChanged(a.withInPreset(p));
            onCommit();
          },
        ),
        // A length for an animation that is not there would be a slider that
        // does nothing, and one for a clip too short to hold one would be a
        // slider whose ends meet.
        if (a.hasIn && maxDuration > 0)
          _Slider(
            label: 'In length',
            value: a.inDuration.raw.toDouble().clamp(0, maxDuration),
            min: 0,
            max: maxDuration,
            format: _seconds,
            onChanged: (v) =>
                onChanged(a.copyWith(inDuration: Tick(v.round()))),
            onCommit: onCommit,
          ),
        const SizedBox(height: 6),
        _PresetPicker(
          label: 'Out',
          preset: a.outPreset,
          isText: clip.isText,
          onChanged: (p) {
            onCommit();
            onChanged(a.withOutPreset(p));
            onCommit();
          },
        ),
        if (a.hasOut && maxDuration > 0)
          _Slider(
            label: 'Out length',
            value: a.outDuration.raw.toDouble().clamp(0, maxDuration),
            min: 0,
            max: maxDuration,
            format: _seconds,
            onChanged: (v) =>
                onChanged(a.copyWith(outDuration: Tick(v.round()))),
            onCommit: onCommit,
          ),
      ],
    );
  }
}

class _PresetPicker extends StatelessWidget {
  const _PresetPicker({
    required this.label,
    required this.preset,
    required this.isText,
    required this.onChanged,
  });

  final String label;
  final AnimationPreset preset;

  /// The typewriter is offered only where it would do something. It is the one
  /// preset that is not a transform, so on a clip with no text it is an entry
  /// that silently declines — which is fine when it is *chosen* by accident
  /// and not fine when it is the only thing in the list that looks special.
  final bool isText;

  final ValueChanged<AnimationPreset> onChanged;

  @override
  Widget build(BuildContext context) {
    final options = [
      for (final option in AnimationPreset.values)
        if (isText || option != AnimationPreset.typewriter) option,
    ];

    return Row(
      children: [
        SizedBox(
          width: 26,
          child: Text(label,
              style: const TextStyle(fontSize: 11, color: VdColors.text)),
        ),
        Expanded(
          child: DropdownButtonFormField<AnimationPreset>(
            initialValue: options.contains(preset) ? preset : options.first,
            isDense: true,
            isExpanded: true,
            decoration: const InputDecoration(
              isDense: true,
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              border: OutlineInputBorder(),
            ),
            style: const TextStyle(fontSize: 12, color: VdColors.text),
            items: [
              for (final option in options)
                DropdownMenuItem(
                  value: option,
                  child: Text(option.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12)),
                ),
            ],
            onChanged: (value) {
              if (value != null) onChanged(value);
            },
          ),
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
