import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../model/clip.dart';
import '../model/media.dart';
import '../model/project.dart';

/// Turns the document into the flat render list the engine composites from.
///
/// This is the whole of "document sync". The engine never sees the scene
/// graph: it gets clips with paths and times, ordered bottom to top. Keeping
/// the boundary this narrow is what makes the engine replaceable — a WebCodecs
/// backend has to implement this contract and nothing else.
EngineTimeline engineTimelineFor(Project project) {
  final clips = <EngineClip>[];

  for (var index = 0; index < project.tracks.length; index++) {
    final track = project.tracks[index];

    for (final clip in track.clips) {
      if (!clip.enabled) continue;

      // A caption or a shape has no file to look up and nothing to decode, so
      // it goes across on its own terms: what to draw, and silence. Both are
      // rasters the size of the output, so both are stretched rather than
      // fitted — there is nothing to fit.
      if (clip.isGenerated) {
        if (track.hidden) continue;
        clips.add(EngineClip(
          text: clip.text == null ? null : _engineTextFor(clip.text!),
          shape: clip.shape == null ? null : _engineShapeFor(clip.shape!),
          startTicks: clip.start.raw,
          durationTicks: clip.duration.raw,
          track: index,
          gain: 0,
          opacity: clip.transform.opacity,
          fit: FitMode.stretch,
          transform: _engineTransformFor(clip.transform),
          animation: _engineAnimationFor(clip.animation),
          // Captions and shapes join at a cut like anything else. Two titles
          // butted together on one lane dissolve between themselves, which is
          // what the engine's "any two clips on one lane" rule already means.
          transition: _engineTransitionFor(clip.transition),
        ));
        continue;
      }

      final asset = project.assetFor(clip);
      if (asset == null) continue;

      // The lane decides which half of a file a clip contributes. A clip on an
      // audio lane is sound even when its file has a picture — that is what a
      // detached clip is — and the picture must not come back with it.
      final showsPicture =
          track.kind.isVisual && !track.hidden && asset.probe.hasVideo;

      // `hidden` and `muted` are separate switches, so they do separate
      // things: hiding a video lane leaves its sound playing, and muting it
      // leaves the picture. Folding them together would make each one a
      // surprise.
      final gain =
          asset.probe.hasAudio && !track.muted ? clip.audio.effectiveVolume : 0.0;

      // Only a clip with neither stream is left out. One that is merely silent
      // or hidden right now still goes, because it is still part of how long
      // the project is, and dropping it would make playback stop short of the
      // end the moment someone muted the last clip. The mixer decodes nothing
      // at zero gain, so silence costs a slot in the list and no more.
      if (!asset.probe.hasVideo && !asset.probe.hasAudio) continue;

      final transform = clip.transform;
      clips.add(EngineClip(
        path: asset.path,
        // How the engine opens the file, not what it does with it afterwards:
        // an animated overlay is decoded whole and looped rather than seeked
        // in. The document already knows, so the engine is told rather than
        // left probing a path it was handed. See vd_sticker.h.
        sticker: asset.probe.kind == MediaKind.sticker,
        startTicks: clip.start.raw,
        durationTicks: clip.duration.raw,
        sourceInTicks: clip.sourceIn.raw,
        // List order is z-order: the main track is first, so it renders first.
        track: index,
        hasVideo: showsPicture,
        gain: gain,
        // The fades go across as lengths rather than as a computed gain,
        // because the engine has to evaluate them per audio frame — a fade
        // resolved here, once per edit, would arrive as a staircase. The
        // volume line crosses for the same reason and in the same shape: the
        // points themselves, in the source's own time, for the mixer to
        // interpolate between.
        fadeInTicks: clip.audio.fadeIn.raw,
        fadeOutTicks: clip.audio.fadeOut.raw,
        volumePoints: [
          for (final p in clip.audio.points)
            EngineVolumePoint(p.sourceTime.raw, p.value),
        ],
        opacity: transform.opacity,
        fit: switch (transform.fit) {
          ClipFit.blurFill => FitMode.blurFill,
          ClipFit.contain => FitMode.contain,
          ClipFit.cover => FitMode.cover,
          ClipFit.stretch => FitMode.stretch,
        },
        transform: _engineTransformFor(transform),
        color: _engineColorFor(clip.color),
        animation: _engineAnimationFor(clip.animation),
        transition: _engineTransitionFor(clip.transition),
      ));
    }
  }

  return EngineTimeline(
    width: project.format.width,
    height: project.format.height,
    frameRateNumerator: project.format.frameRate.numerator,
    frameRateDenominator: project.format.frameRate.denominator,
    clips: clips,
  );
}

/// Insets become a rectangle here rather than in the model: the document says
/// what the user dragged, the engine wants where to sample, and this is the
/// one place that knows both.
EngineTransform _engineTransformFor(ClipTransform transform) => EngineTransform(
      offsetX: transform.offsetX,
      offsetY: transform.offsetY,
      scale: transform.scale,
      rotationDegrees: transform.rotationDegrees,
      cropX: transform.cropLeft,
      cropY: transform.cropTop,
      cropWidth: transform.cropWidth,
      cropHeight: transform.cropHeight,
      flipHorizontal: transform.flipHorizontal,
      flipVertical: transform.flipVertical,
    );

/// The grade, field for field. Five numbers on the same scale on both sides,
/// so there is nothing to convert — and nothing here evaluates them: the
/// engine composes the matrix, because the engine is the one that draws.
///
/// Sent for every clip, graded or not, unlike the animation and the transition
/// below. There is no work to save by leaving a neutral grade out: a zeroed
/// struct *is* the neutral grade, and the compositor already asks whether
/// there is anything to do before it does any.
EngineColor _engineColorFor(ClipColor color) => EngineColor(
      brightness: color.brightness,
      contrast: color.contrast,
      saturation: color.saturation,
      temperature: color.temperature,
      tint: color.tint,
      // The look's name, resolved against the engine's catalogue on the other
      // side. A name it does not know draws ungraded rather than failing, so
      // there is nothing to check here.
      look: color.look,
      lookStrength: color.lookStrength,
    );

/// The entrance and the exit. Only the halves that actually run cross over —
/// a preset with no duration and a duration with no preset are both "nothing
/// happens", and the engine should not have to work that out twice.
EngineAnimation _engineAnimationFor(ClipAnimation animation) => EngineAnimation(
      inPreset: animation.hasIn
          ? EngineAnimPreset.values[animation.inPreset.index]
          : EngineAnimPreset.none,
      inTicks: animation.hasIn ? animation.inDuration.raw : 0,
      outPreset: animation.hasOut
          ? EngineAnimPreset.values[animation.outPreset.index]
          : EngineAnimPreset.none,
      outTicks: animation.hasOut ? animation.outDuration.raw : 0,
    );

/// A caption, field for field. Every number is already a fraction on both
/// sides of the boundary, so there is nothing to convert — which is the point
/// of the document storing fractions in the first place.
EngineText _engineTextFor(ClipText text) => EngineText(
      text: text.text,
      font: text.font,
      size: text.size,
      color: text.color,
      strokeColor: text.strokeColor,
      strokeWidth: text.strokeWidth,
      shadowColor: text.shadowColor,
      shadowDx: text.shadowOffsetX,
      shadowDy: text.shadowOffsetY,
      shadowBlur: text.shadowBlur,
      boxColor: text.boxColor,
      boxPadding: text.boxPadding,
      boxRadius: text.boxRadius,
      letterSpacing: text.letterSpacing,
      lineSpacing: text.lineSpacing,
      maxWidth: text.maxWidth,
      alignment: switch (text.alignment) {
        TextAlignment.left => EngineTextAlign.left,
        TextAlignment.center => EngineTextAlign.center,
        TextAlignment.right => EngineTextAlign.right,
      },
    );

/// A shape, field for field. Every number is already a fraction of the output
/// height on both sides of the boundary, so there is nothing to convert.
EngineShape _engineShapeFor(ClipShape shape) => EngineShape(
      kind: switch (shape.kind) {
        ShapeKind.rectangle => EngineShapeKind.rectangle,
        ShapeKind.ellipse => EngineShapeKind.ellipse,
        ShapeKind.line => EngineShapeKind.line,
        ShapeKind.arrow => EngineShapeKind.arrow,
      },
      width: shape.width,
      height: shape.height,
      corner: shape.corner,
      fillColor: shape.fillColor,
      strokeColor: shape.strokeColor,
      strokeWidth: shape.strokeWidth,
      shadowColor: shape.shadowColor,
      shadowDx: shape.shadowOffsetX,
      shadowDy: shape.shadowOffsetY,
      shadowBlur: shape.shadowBlur,
      headSize: shape.headSize,
    );

/// The transition at a clip's head. Only one that would change a frame crosses
/// — a preset with no length and a length with no preset are both a plain cut,
/// and the engine should not have to work that out twice.
EngineTransition _engineTransitionFor(ClipTransition transition) =>
    transition.isActive
        ? EngineTransition(
            preset: EngineTransitionPreset.values[transition.preset.index],
            ticks: transition.duration.raw,
          )
        : EngineTransition.none;
