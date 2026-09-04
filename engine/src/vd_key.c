#include "vdodtor/vd_key.h"

#include <math.h>
#include <string.h>

#include "vdodtor/vd_color.h"

// The two constants that turn a colour difference into a chroma coordinate:
// 2(1 - Kr) and 2(1 - Kb) for BT.709. Derived from the luma weights rather
// than written out, so a file that changed one and not the other cannot exist.
#define VD_CHROMA_R (2.0f * (1.0f - VD_LUMA_R))
#define VD_CHROMA_B (2.0f * (1.0f - VD_LUMA_B))

static float clamp01(float v) {
  if (!(v > 0.0f)) return 0.0f;  // NaN lands here too
  return v > 1.0f ? 1.0f : v;
}

static float luma(const float rgb[3]) {
  return VD_LUMA_R * rgb[0] + VD_LUMA_G * rgb[1] + VD_LUMA_B * rgb[2];
}

VdChromaKey vd_key_none(void) {
  VdChromaKey key = {0};
  return key;
}

VdChroma vd_key_chroma(const float rgb[3]) {
  VdChroma c = {0.0f, 0.0f};
  if (!rgb) return c;
  const float y = luma(rgb);
  c.cb = (rgb[2] - y) / VD_CHROMA_B;
  c.cr = (rgb[0] - y) / VD_CHROMA_R;
  return c;
}

VdChroma vd_key_chroma_of_color(uint32_t color) {
  const float rgb[3] = {
      (float)((color >> 16) & 0xFFu) / 255.0f,
      (float)((color >> 8) & 0xFFu) / 255.0f,
      (float)(color & 0xFFu) / 255.0f,
  };
  return vd_key_chroma(rgb);
}

// The darkest a pixel may be before its luma stops being divided into its
// chroma.
//
// Dividing is what makes the matte independent of exposure, and near black
// there is nothing to divide by: an eighth of a count of chroma noise over a
// luma of nothing is any hue at all, at any saturation. Flooring the divisor
// makes a very dark pixel read as *less* saturated than it measures, so it
// falls towards grey and is **kept** — which is the safe direction. Black is
// not the screen, whatever the noise in it says.
//
// Two hundredths of full scale in the signal, which is about five counts of
// eight-bit video: under any exposure a screen could be lit at, and over the
// noise floor of the shadow the subject stands in.
#define VD_KEY_MIN_LUMA 0.02f

// Far enough from grey, per unit of its own brightness, to have a hue worth
// keying on.
//
// Below this there is no axis for a despill to run along but the way the
// rounding went, and nothing to measure a fraction of: `tolerance` is a
// fraction of the distance from the key colour to grey, and for a grey key
// that distance is zero. Measured on the *normalised* chroma so that a dark
// saturated colour is judged by its hue rather than by its exposure, like
// everything else in this file. Two hundredths is a colour a hundredth of the
// way to being one — a grey with a count of tint in it, not a screen.
#define VD_KEY_MIN_CHROMATICITY 0.02f

// A colour's chroma per unit of its own luma, which is the space the matte is
// measured in.
static VdChroma chromaticity(const float rgb[3]) {
  const float y = luma(rgb);
  const float divisor = y > VD_KEY_MIN_LUMA ? y : VD_KEY_MIN_LUMA;
  const VdChroma c = vd_key_chroma(rgb);
  VdChroma out = {c.cb / divisor, c.cr / divisor};
  return out;
}

static VdChroma chromaticity_of_color(uint32_t color) {
  const float rgb[3] = {
      (float)((color >> 16) & 0xFFu) / 255.0f,
      (float)((color >> 8) & 0xFFu) / 255.0f,
      (float)(color & 0xFFu) / 255.0f,
  };
  return chromaticity(rgb);
}

bool vd_key_is_off(const VdChromaKey* key) {
  if (!key) return true;
  if (!(key->tolerance > 0.0f)) return true;  // NaN is off, too
  const VdChroma c = chromaticity_of_color(key->color);
  return sqrtf(c.cb * c.cb + c.cr * c.cr) < VD_KEY_MIN_CHROMATICITY;
}

VdKeyMatte vd_key_matte(const VdChromaKey* key) {
  VdKeyMatte matte;
  memset(&matte, 0, sizeof(matte));
  if (vd_key_is_off(key)) return matte;

  matte.chromaticity = chromaticity_of_color(key->color);
  const float length = sqrtf(matte.chromaticity.cb * matte.chromaticity.cb +
                             matte.chromaticity.cr * matte.chromaticity.cr);
  matte.axis.cb = matte.chromaticity.cb / length;
  matte.axis.cr = matte.chromaticity.cr / length;
  matte.inv_length = 1.0f / length;
  matte.tolerance = clamp01(key->tolerance);
  matte.softness = clamp01(key->softness);
  matte.spill = clamp01(key->spill);
  return matte;
}

bool vd_key_matte_is_off(const VdKeyMatte* matte) {
  return !matte || !(matte->tolerance > 0.0f);
}

float vd_key_apply(const VdKeyMatte* matte, float rgb[3]) {
  if (!rgb || vd_key_matte_is_off(matte)) return 1.0f;

  const float y = luma(rgb);
  const VdChroma c = vd_key_chroma(rgb);
  const VdChroma n = chromaticity(rgb);

  // How far this pixel is from the key colour, as a fraction of the way from
  // that colour to grey: 0 is exactly it, 1 is grey, and past 1 is the other
  // side of the plane. Brightness is out of both terms, so the shadow at the
  // bottom of the screen and the hot spot under the key light are the same
  // distance from it.
  const float dcb = n.cb - matte->chromaticity.cb;
  const float dcr = n.cr - matte->chromaticity.cr;
  const float distance = sqrtf(dcb * dcb + dcr * dcr) * matte->inv_length;

  float alpha;
  if (!(matte->softness > 0.0f)) {
    // A hard edge, and the comparison is >= so that a pixel exactly on the
    // threshold is kept — the same side "outside the key" is on everywhere
    // else in this function.
    alpha = distance >= matte->tolerance ? 1.0f : 0.0f;
  } else {
    const float t = clamp01((distance - matte->tolerance) / matte->softness);
    // Smoothstep. A linear ramp has a corner where it meets solid, and that
    // corner is the bright line everybody recognises as a bad key.
    alpha = t * t * (3.0f - 2.0f * t);
  }

  // The despill: take out however much of this pixel leans along the key's own
  // chroma axis, and put nothing back. `p` is negative for a colour on the
  // other side of grey — the complement of the screen, which is the one thing
  // in the shot that must not be touched — so it is left alone rather than
  // pushed further out.
  const float p = c.cb * matte->axis.cb + c.cr * matte->axis.cr;
  if (matte->spill > 0.0f && p > 0.0f) {
    const float take = matte->spill * p;
    const float cb = c.cb - take * matte->axis.cb;
    const float cr = c.cr - take * matte->axis.cr;

    // Back to RGB at the luma it arrived with. Holding Y is the whole trick:
    // pulling green out by taking it off the green channel darkens every edge
    // pixel it touches, which trades a green halo for a grey one.
    const float r = y + VD_CHROMA_R * cr;
    const float b = y + VD_CHROMA_B * cb;
    const float g = (y - VD_LUMA_R * r - VD_LUMA_B * b) / VD_LUMA_G;
    rgb[0] = clamp01(r);
    rgb[1] = clamp01(g);
    rgb[2] = clamp01(b);
  }

  return alpha;
}
