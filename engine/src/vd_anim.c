#include "vdodtor/vd_anim.h"

#include <math.h>

// How far a slide travels, as a fraction of the output. A third of the frame
// is far enough to read as movement and short enough that the clip is still
// partly on screen for most of the trip — a slide that starts off the edge
// spends half its time invisible, which reads as a delay rather than a move.
static const float kSlideDistance = 0.35f;

// A cap on how large a pop may get, not the amount it overshoots by — that
// comes out of the back curve and lands a few per cent over resting size. The
// cap is here so that changing the curve cannot quietly turn a flinch into a
// bounce.
static const float kMaxPopScale = 1.12f;

// Where a zoom starts. Not zero — a scale of zero is a clip that is not there,
// and the first frame of an entrance should show something.
static const float kZoomFrom = 0.55f;

// A spin is barely more than a quarter turn. A full revolution takes the eye
// with it and loses the words.
static const float kSpinDegrees = 120.0f;

static float clamp01(float t) {
  // NaN lands at rest rather than at zero, deliberately. Nothing in the engine
  // can produce one — vd_anim_at checks its divisors — so this only decides
  // what a bug looks like, and a clip that shows normally is a better failure
  // than one that silently disappears.
  if (t != t) return 1.0f;
  if (t < 0.0f) return 0.0f;
  return t > 1.0f ? 1.0f : t;
}

// Fast, then settling. The curve every entrance wants: the movement is over
// before the eye finishes tracking it, and the last part is a glide into
// place rather than a stop.
static float ease_out_cubic(float t) {
  const float inv = 1.0f - t;
  return 1.0f - inv * inv * inv;
}

// The same, plus an overshoot past 1 that comes back. This is the whole of
// what makes a pop a pop.
static float ease_out_back(float t) {
  const float c1 = 1.70158f;
  const float c3 = c1 + 1.0f;
  const float inv = t - 1.0f;
  return 1.0f + c3 * inv * inv * inv + c1 * inv * inv;
}

VdAnimValue vd_anim_rest(void) {
  VdAnimValue v;
  v.offset_x = 0.0f;
  v.offset_y = 0.0f;
  v.scale = 1.0f;
  v.rotation_degrees = 0.0f;
  v.opacity = 1.0f;
  v.reveal = 1.0f;
  return v;
}

VdClipAnim vd_clip_anim_none(void) {
  VdClipAnim anim;
  anim.in_preset = VD_ANIM_NONE;
  anim.in_duration = 0;
  anim.out_preset = VD_ANIM_NONE;
  anim.out_duration = 0;
  return anim;
}

VdAnimValue vd_anim_value(VdAnimPreset preset, float t) {
  VdAnimValue v = vd_anim_rest();
  t = clamp01(t);
  if (preset == VD_ANIM_NONE) return v;

  // Everything that moves also fades. A clip that slides in at full opacity
  // reads as a clip that was always there and jumped, and every editor that
  // ships these presets fades them for the same reason. The typewriter is the
  // exception: the characters appearing *are* the entrance, and fading them
  // as well makes the early ones look like a mistake.
  const float eased = ease_out_cubic(t);
  const float travel = 1.0f - eased;  // 1 fully away, 0 at rest

  switch (preset) {
    case VD_ANIM_FADE:
      // Linear, unlike everything below it. Easing a *pure* fade front-loads
      // it — the clip is most of the way visible before it has spent half its
      // time — and there is no movement here for the curve to be settling.
      v.opacity = t;
      break;

    // Travelling upwards: below its place on the way in, above it on the way
    // out. `offset_y` grows downwards, so "below" is positive.
    case VD_ANIM_SLIDE_UP:
      v.offset_y = travel * kSlideDistance;
      v.opacity = eased;
      break;
    case VD_ANIM_SLIDE_DOWN:
      v.offset_y = -travel * kSlideDistance;
      v.opacity = eased;
      break;
    case VD_ANIM_SLIDE_LEFT:
      v.offset_x = travel * kSlideDistance;
      v.opacity = eased;
      break;
    case VD_ANIM_SLIDE_RIGHT:
      v.offset_x = -travel * kSlideDistance;
      v.opacity = eased;
      break;

    case VD_ANIM_POP: {
      // Starts small, overshoots, settles. The opacity is on the plain curve
      // rather than the overshooting one, which cannot go past 1 anyway.
      const float back = ease_out_back(t);
      v.scale = kZoomFrom + (1.0f - kZoomFrom) * back;
      if (v.scale > kMaxPopScale) v.scale = kMaxPopScale;
      v.opacity = eased;
      break;
    }

    case VD_ANIM_ZOOM:
      v.scale = kZoomFrom + (1.0f - kZoomFrom) * eased;
      v.opacity = eased;
      break;

    case VD_ANIM_SPIN:
      v.rotation_degrees = -travel * kSpinDegrees;
      v.scale = kZoomFrom + (1.0f - kZoomFrom) * eased;
      v.opacity = eased;
      break;

    case VD_ANIM_TYPEWRITER:
      // Linear, and nothing else. Characters arrive at a steady rate because
      // that is what typing is; easing it would make the last half of a
      // sentence appear all at once.
      v.reveal = t;
      break;

    case VD_ANIM_NONE:
    default:
      break;
  }
  return v;
}

VdAnimValue vd_anim_at(const VdClipAnim* anim, VdTick offset, VdTick duration) {
  if (!anim || duration <= 0) return vd_anim_rest();

  // How far into each animation the playhead is, as 0 = away and 1 = at rest.
  // Outside its own window each is 1, which is the identity — so a clip with
  // only an entrance is at rest for the whole of the rest of its life.
  float in_t = 1.0f;
  if (anim->in_preset != VD_ANIM_NONE && anim->in_duration > 0) {
    in_t = (float)((double)offset / (double)anim->in_duration);
  }

  float out_t = 1.0f;
  if (anim->out_preset != VD_ANIM_NONE && anim->out_duration > 0) {
    // Measured from the far edge, so the last tick of a clip is as far from
    // rest as the first — the same reasoning as the audio fades, and the same
    // click-at-the-end bug in a different medium.
    const VdTick remaining = duration - offset;
    out_t = (float)((double)remaining / (double)anim->out_duration);
  }

  in_t = clamp01(in_t);
  out_t = clamp01(out_t);

  // Whichever is further from rest. Composing them would produce a motion
  // neither preset describes; on a clip too short for both, the one the
  // playhead is deepest inside is the one somebody meant.
  if (out_t < in_t) return vd_anim_value(anim->out_preset, out_t);
  return vd_anim_value(anim->in_preset, in_t);
}

bool vd_anim_reveals_text(const VdClipAnim* anim) {
  if (!anim) return false;
  return (anim->in_preset == VD_ANIM_TYPEWRITER && anim->in_duration > 0) ||
         (anim->out_preset == VD_ANIM_TYPEWRITER && anim->out_duration > 0);
}
