#include "vdodtor/vd_color.h"

#include <string.h>

// How far a full-throw slider leans the blue-orange axis, and how far it leans
// the green-magenta one.
//
// The two are not the same number on purpose. The eye's sharpest colour
// discrimination is in the greens, so the same travel on that axis reads as a
// much larger change — a tint slider matched to the temperature one would go
// from "corrected" to "seasick" in the first third of its throw. These are the
// *ratios* between the channels; the normalisation below throws the overall
// level away, so only the numbers relative to each other matter.
static const float kWarmth = 0.30f;
static const float kGreen = 0.20f;

static float clamp_unit(float v) {
  // NaN lands at neutral rather than at an end: a grade nobody can see is a
  // better failure than a frame nobody can.
  if (v != v) return 0.0f;
  if (v < -1.0f) return -1.0f;
  return v > 1.0f ? 1.0f : v;
}

static float clamp01(float v) {
  if (!(v > 0.0f)) return 0.0f;  // NaN lands here too
  return v > 1.0f ? 1.0f : v;
}

// out = a * b, both row-major 3x3, and the offsets with them: applying `b`
// and then `a` is one map, `(a*b)x + (a*b_offset + a_offset)`.
static void compose(const float a[9], const float a_offset[3],
                    VdColorTransform* into) {
  float m[9];
  float offset[3];
  for (int row = 0; row < 3; row++) {
    for (int col = 0; col < 3; col++) {
      m[row * 3 + col] = a[row * 3 + 0] * into->m[0 * 3 + col] +
                         a[row * 3 + 1] * into->m[1 * 3 + col] +
                         a[row * 3 + 2] * into->m[2 * 3 + col];
    }
    offset[row] = a[row * 3 + 0] * into->offset[0] +
                  a[row * 3 + 1] * into->offset[1] +
                  a[row * 3 + 2] * into->offset[2] + a_offset[row];
  }
  memcpy(into->m, m, sizeof(m));
  memcpy(into->offset, offset, sizeof(offset));
}

// A per-channel gain, which is what both halves of a white balance are.
static void compose_diagonal(float r, float g, float b,
                             VdColorTransform* into) {
  const float m[9] = {r, 0.0f, 0.0f, 0.0f, g, 0.0f, 0.0f, 0.0f, b};
  const float offset[3] = {0.0f, 0.0f, 0.0f};
  compose(m, offset, into);
}

VdColorAdjust vd_color_neutral(void) {
  VdColorAdjust adjust;
  memset(&adjust, 0, sizeof(adjust));
  return adjust;
}

bool vd_color_is_neutral(const VdColorAdjust* a) {
  if (!a) return true;
  // Exactly zero, not nearly: the caller that matters is the compositor
  // deciding whether to take the ungraded path, and "nearly neutral" there
  // would silently discard the first pixel of somebody's slider.
  return a->brightness == 0.0f && a->contrast == 0.0f &&
         a->saturation == 0.0f && a->temperature == 0.0f && a->tint == 0.0f;
}

VdColorTransform vd_color_transform(const VdColorAdjust* adjust) {
  VdColorTransform t;
  memset(&t, 0, sizeof(t));
  t.m[0] = 1.0f;
  t.m[4] = 1.0f;
  t.m[8] = 1.0f;
  if (!adjust) return t;

  const float temperature = clamp_unit(adjust->temperature);
  const float tint = clamp_unit(adjust->tint);
  const float brightness = clamp_unit(adjust->brightness);
  const float contrast = clamp_unit(adjust->contrast);
  const float saturation = clamp_unit(adjust->saturation);

  // --- white balance, first -------------------------------------------------
  // The light before anything else: an exposure or a contrast judged under the
  // wrong colour of light is a judgement that has to be made twice.
  if (temperature != 0.0f || tint != 0.0f) {
    float r = 1.0f + kWarmth * temperature;
    float g = 1.0f - kGreen * tint;
    float b = 1.0f - kWarmth * temperature;

    // **Warming a shot must not also brighten it.** Raising red and lowering
    // blue by the same amount raises the picture's luma, because red weighs
    // three times what blue does — so a temperature slider built out of
    // channel gains alone is an exposure slider wearing a hat, and the user
    // ends up fighting it with the brightness one. Dividing the whole set by
    // the luma of the white it produces leaves the *colour* of the light
    // changed and its level exactly where it was.
    const float luma = VD_LUMA_R * r + VD_LUMA_G * g + VD_LUMA_B * b;
    if (luma > 0.0f) {
      r /= luma;
      g /= luma;
      b /= luma;
    }
    compose_diagonal(r, g, b, &t);
  }

  // --- brightness -----------------------------------------------------------
  if (brightness != 0.0f) {
    const float gain = 1.0f + brightness;
    compose_diagonal(gain, gain, gain, &t);
  }

  // --- contrast -------------------------------------------------------------
  // (rgb - pivot) * scale + pivot, which is a scale and a lift.
  if (contrast != 0.0f) {
    const float scale = 1.0f + contrast;
    const float pivot = 0.5f;
    const float m[9] = {scale, 0.0f, 0.0f, 0.0f, scale,
                        0.0f,  0.0f, 0.0f, scale};
    const float lift = pivot - pivot * scale;
    const float offset[3] = {lift, lift, lift};
    compose(m, offset, &t);
  }

  // --- saturation, last -----------------------------------------------------
  // Judged against the contrast the picture ended up with, which is the order
  // anybody works in: a shot looks more colourful the moment you add contrast
  // to it, so setting saturation first means setting it twice.
  //
  // grey + (rgb - grey) * s, with grey the BT.709 luma — a matrix, because
  // grey is itself a linear function of rgb.
  if (saturation != 0.0f) {
    const float s = 1.0f + saturation;
    const float rest = 1.0f - s;
    const float m[9] = {
        rest * VD_LUMA_R + s, rest * VD_LUMA_G,     rest * VD_LUMA_B,
        rest * VD_LUMA_R,     rest * VD_LUMA_G + s, rest * VD_LUMA_B,
        rest * VD_LUMA_R,     rest * VD_LUMA_G,     rest * VD_LUMA_B + s,
    };
    const float offset[3] = {0.0f, 0.0f, 0.0f};
    compose(m, offset, &t);
  }

  return t;
}

void vd_color_apply(const VdColorTransform* transform, float rgb[3]) {
  if (!transform || !rgb) return;
  const float r = rgb[0];
  const float g = rgb[1];
  const float b = rgb[2];
  for (int row = 0; row < 3; row++) {
    rgb[row] = clamp01(transform->m[row * 3 + 0] * r +
                       transform->m[row * 3 + 1] * g +
                       transform->m[row * 3 + 2] * b + transform->offset[row]);
  }
}
