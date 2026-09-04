/// The render list, in native memory.
///
/// One definition of how a timeline crosses the boundary, because there are
/// now two things that send one: the preview engine and the exporter. A second
/// copy of this would be a second place for a field to be forgotten, and a
/// field forgotten here is a property that silently reads back whatever the
/// arena happened to hold — a caption in a colour nobody chose, a clip at a
/// speed nobody set.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings.g.dart';
import 'engine.dart';

/// One caption in native memory, borrowed from [arena] for the length of the
/// call. Field for field with `VdTextSpec`, and deliberately not clever about
/// it.
Pointer<VdTextSpec> nativeTextSpec(Arena arena, EngineText text) {
  final spec = arena<VdTextSpec>();
  spec.ref
    ..text = text.text.toNativeUtf8(allocator: arena).cast<Char>()
    ..font = text.font.toNativeUtf8(allocator: arena).cast<Char>()
    ..size = text.size
    ..color = text.color
    ..stroke_color = text.strokeColor
    ..stroke_width = text.strokeWidth
    ..shadow_color = text.shadowColor
    ..shadow_dx = text.shadowDx
    ..shadow_dy = text.shadowDy
    ..shadow_blur = text.shadowBlur
    ..box_color = text.boxColor
    ..box_padding = text.boxPadding
    ..box_radius = text.boxRadius
    ..letter_spacing = text.letterSpacing
    ..line_spacing = text.lineSpacing
    ..max_width = text.maxWidth
    ..alignAsInt = text.alignment.index;
  return spec;
}

/// One shape in native memory, on the same terms and with the same warning.
Pointer<VdShapeSpec> nativeShapeSpec(Arena arena, EngineShape shape) {
  final spec = arena<VdShapeSpec>();
  spec.ref
    ..kindAsInt = shape.kind.index
    ..width = shape.width
    ..height = shape.height
    ..corner = shape.corner
    ..fill_color = shape.fillColor
    ..stroke_color = shape.strokeColor
    ..stroke_width = shape.strokeWidth
    ..shadow_color = shape.shadowColor
    ..shadow_dx = shape.shadowDx
    ..shadow_dy = shape.shadowDy
    ..shadow_blur = shape.shadowBlur
    ..head_size = shape.headSize;
  return spec;
}

/// The whole render list in native memory, allocated from [arena].
///
/// Everything the engine keeps — paths, caption strings, look names, volume
/// points — is copied on the other side before the call returns, so the arena
/// may be released the moment it does.
Pointer<VdTimeline> nativeTimeline(Arena arena, EngineTimeline timeline) {
  final clips = arena<VdTimelineClip>(timeline.clips.length.clamp(1, 1 << 20));
  for (var i = 0; i < timeline.clips.length; i++) {
    final clip = timeline.clips[i];
    final entry = clips[i];
    entry.path = clip.path == null
        ? nullptr
        : clip.path!.toNativeUtf8(allocator: arena).cast<Char>();
    entry.text = clip.text == null ? nullptr : nativeTextSpec(arena, clip.text!);
    entry.shape =
        clip.shape == null ? nullptr : nativeShapeSpec(arena, clip.shape!);
    entry.sticker = clip.sticker;
    entry.start = clip.startTicks;
    entry.duration = clip.durationTicks;
    entry.source_in = clip.sourceInTicks;
    entry.speed = clip.speed;
    entry.pitch_shift = clip.pitchShift;
    entry.track = clip.track;
    entry.opacity = clip.opacity;
    entry.fitAsInt = clip.fit.index;
    entry.has_video = clip.hasVideo;
    entry.gain = clip.gain;
    entry.fade_in = clip.fadeInTicks;
    entry.fade_out = clip.fadeOutTicks;
    entry.fade_curveAsInt = clip.fadeCurve.index;
    entry.eqAsInt = clip.eq.index;

    if (clip.volumePoints.isEmpty) {
      entry.volume_points = nullptr;
      entry.volume_point_count = 0;
    } else {
      final points = arena<VdVolumePoint>(clip.volumePoints.length);
      for (var p = 0; p < clip.volumePoints.length; p++) {
        points[p].source_time = clip.volumePoints[p].sourceTicks;
        points[p].value = clip.volumePoints[p].value;
      }
      entry.volume_points = points;
      entry.volume_point_count = clip.volumePoints.length;
    }

    final transform = clip.transform;
    entry.transform.offset_x = transform.offsetX;
    entry.transform.offset_y = transform.offsetY;
    entry.transform.scale = transform.scale;
    entry.transform.rotation_degrees = transform.rotationDegrees;
    entry.transform.crop_x = transform.cropX;
    entry.transform.crop_y = transform.cropY;
    entry.transform.crop_w = transform.cropWidth;
    entry.transform.crop_h = transform.cropHeight;
    entry.transform.flip_h = transform.flipHorizontal;
    entry.transform.flip_v = transform.flipVertical;

    final color = clip.color;
    entry.color.brightness = color.brightness;
    entry.color.contrast = color.contrast;
    entry.color.saturation = color.saturation;
    entry.color.temperature = color.temperature;
    entry.color.tint = color.tint;
    entry.look = color.look.isEmpty
        ? nullptr
        : color.look.toNativeUtf8(allocator: arena).cast<Char>();
    entry.look_strength = color.lookStrength;

    final key = clip.key;
    entry.key.color = key.color;
    entry.key.tolerance = key.tolerance;
    entry.key.softness = key.softness;
    entry.key.spill = key.spill;

    final animation = clip.animation;
    entry.anim.in_presetAsInt = animation.inPreset.index;
    entry.anim.in_duration = animation.inTicks;
    entry.anim.out_presetAsInt = animation.outPreset.index;
    entry.anim.out_duration = animation.outTicks;

    final transition = clip.transition;
    entry.transition.presetAsInt = transition.preset.index;
    entry.transition.duration = transition.ticks;
  }

  final native = arena<VdTimeline>();
  native.ref.width = timeline.width;
  native.ref.height = timeline.height;
  native.ref.frame_rate.num = timeline.frameRateNumerator;
  native.ref.frame_rate.den = timeline.frameRateDenominator;
  native.ref.clips = timeline.clips.isEmpty ? nullptr : clips;
  native.ref.clip_count = timeline.clips.length;
  return native;
}
