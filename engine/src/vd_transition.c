#include "vdodtor/vd_transition.h"

#include <string.h>

// How far a slide or a push travels: the whole frame, because a transition
// has to *replace* the picture. This is the difference between a transition
// and an entrance — vd_anim's slide moves a third of the frame and lands, and
// one that only came a third of the way here would leave the old clip showing
// down one side for ever.
static const float kTravel = 1.0f;

static float clamp01(float t) {
  // NaN lands at the end rather than the start, matching vd_anim: a
  // transition that has finished shows the incoming clip, and a clip that is
  // on screen is a better failure than a frame that is not.
  if (t != t) return 1.0f;
  if (t < 0.0f) return 0.0f;
  return t > 1.0f ? 1.0f : t;
}

// Slow, fast, slow. A move that starts and stops abruptly reads as a jump cut
// with extra steps; the dissolve and the wipe stay linear, because a blend
// that eases is a blend that lingers in the middle where it looks least like
// either clip.
static float ease_in_out(float t) {
  return t < 0.5f ? 2.0f * t * t : 1.0f - 2.0f * (1.0f - t) * (1.0f - t);
}

// 0 at the ends, 1 in the middle. The shape of a dip to a colour.
static float triangle(float t) {
  const float up = t * 2.0f;
  return t < 0.5f ? up : 2.0f - up;
}

VdTransitionValue vd_transition_rest(void) {
  VdTransitionValue v;
  memset(&v, 0, sizeof(v));
  v.out_opacity = 1.0f;
  v.in_opacity = 1.0f;
  return v;
}

VdClipTransition vd_clip_transition_none(void) {
  VdClipTransition t;
  t.preset = VD_TRANSITION_NONE;
  t.duration = 0;
  return t;
}

bool vd_transition_active(const VdClipTransition* transition) {
  return transition != NULL && transition->preset != VD_TRANSITION_NONE &&
         transition->duration > 0;
}

VdTransitionValue vd_transition_value(VdTransitionPreset preset, float raw) {
  const float t = clamp01(raw);
  VdTransitionValue v = vd_transition_rest();

  switch (preset) {
    case VD_TRANSITION_DISSOLVE:
      // The outgoing clip stays fully opaque and the incoming one fades up
      // over it. That is not a shortcut for a crossfade, it *is* one: with
      // premultiplied over-blending, B at alpha t over A at alpha 1 gives
      // exactly B*t + A*(1-t). Turning A down as well would let the black
      // behind them show through the middle of every dissolve.
      v.in_opacity = t;
      break;

    case VD_TRANSITION_FADE_BLACK:
    case VD_TRANSITION_FADE_WHITE:
      // A true dip: the frame goes to the colour and comes back out of it.
      // The clips swap under the cover of the flash at the midpoint rather
      // than cross-fading through it, which would show both of them at half
      // strength under a half-strength colour — a muddle rather than a dip.
      v.out_opacity = t < 0.5f ? 1.0f : 0.0f;
      v.in_opacity = t < 0.5f ? 0.0f : 1.0f;
      v.flash = triangle(t);
      v.flash_color =
          preset == VD_TRANSITION_FADE_WHITE ? 0xFFFFFFFFu : 0xFF000000u;
      break;

    case VD_TRANSITION_SLIDE:
      // In from the right, over a clip that stays where it is.
      v.in_offset_x = (1.0f - ease_in_out(t)) * kTravel;
      break;

    case VD_TRANSITION_PUSH:
      // The same arrival, and the old clip is shoved out ahead of it. The two
      // offsets are one frame apart at every instant, which is what makes the
      // pair read as one sheet of film moving rather than as two clips that
      // happen to be sliding.
      v.in_offset_x = (1.0f - ease_in_out(t)) * kTravel;
      v.out_offset_x = -ease_in_out(t) * kTravel;
      break;

    case VD_TRANSITION_WIPE:
      // A hard edge left to right. Linear, and deliberately: an eased wipe
      // looks like the edge is being dragged by hand.
      v.in_hide_right = 1.0f - t;
      break;

    case VD_TRANSITION_NONE:
    default:
      break;
  }

  return v;
}

bool vd_transition_window(const VdClipTransition* transition, VdTick cut,
                          VdTick out_clip_start, VdTick in_clip_end,
                          VdTick* out_from, VdTick* out_to) {
  if (!vd_transition_active(transition)) return false;
  if (in_clip_end <= cut || cut <= out_clip_start) return false;

  VdTick half = transition->duration / 2;

  // Never further than either clip reaches. A transition longer than the clip
  // it is joining would dissolve into a clip that is not on screen yet, and
  // clamping is better than refusing: the duration is a slider, and a slider
  // that stops moving at some length nobody can see is a slider that looks
  // broken.
  const VdTick before = cut - out_clip_start;
  const VdTick after = in_clip_end - cut;
  if (half > before) half = before;
  if (half > after) half = after;
  if (half <= 0) return false;

  if (out_from) *out_from = cut - half;
  if (out_to) *out_to = cut + half;
  return true;
}
