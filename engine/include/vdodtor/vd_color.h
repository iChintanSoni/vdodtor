// vd_color.h — five sliders, one multiply-add.
//
// Brightness, contrast, saturation, temperature and tint. Every one of them is
// an *affine* operation on RGB — a scale, a lean towards grey, a lean towards
// one end of the spectrum — so all five compose into a single 3x3 matrix and a
// single offset, worked out once per layer per frame on the CPU. The shader
// then does one multiply-add per fragment and knows nothing about sliders.
//
// That is the whole reason this file exists rather than five uniforms and five
// branches in Metal. The arithmetic that decides what a grade *means* is the
// part worth testing, and putting it here makes it plain C with no platform
// dependency — testable without a GPU, exactly like vd_anim.c and
// vd_transition.c. What is left in the shader is a matrix multiply, which is
// the part a test could not tell you anything about anyway.
//
// **It also draws the line this milestone's other half will need.** A LUT is
// precisely the grade that is *not* affine: an arbitrary map from colour to
// colour, which is why it arrives as a lookup table and not as five numbers.
// Everything that can be a matrix should be one.
//
// **Every slider runs −1..1 with 0 the shot you shot.** One range for all five,
// so a zeroed struct is the neutral grade — the same bargain `VdTransform`
// makes, and worth the two lines it costs to spell saturation as `1 + s`
// rather than as `s`. A caller that memsets its layers never learns this file
// exists.

#ifndef VD_COLOR_H
#define VD_COLOR_H

#include <stdbool.h>

#include "vdodtor/vd_time.h"

#ifdef __cplusplus
extern "C" {
#endif

// What a clip does to its own colour.
//
// −1..1 each, 0 neutral, and out of range is clamped rather than believed.
// Applied in the order the fields are declared in, which is the order anybody
// grades in: fix the light, set the level, set the contrast, and judge the
// colour last against what the first three left.
typedef struct {
  // A gain rather than a lift: 1 + brightness, so black stays black.
  //
  // Adding a constant instead would raise the blacks to grey, which is the one
  // thing nobody reaches for a brightness slider to do — that is the faded
  // look, and it belongs to a control that says so.
  float brightness;

  // 1 + contrast, about a pivot of 0.5 in the signal. Mid-grey as the eye
  // sees it, which is where a picture looks like it should pivot; the
  // photometric middle is a fifth of the way up and pivoting there would make
  // every increase look like an exposure change.
  float contrast;

  // 1 + saturation towards or away from grey. −1 is monochrome, +1 is twice
  // as colourful.
  float saturation;

  // Warm at +1, cool at −1: the blue-orange axis, which is what a white
  // balance mostly is.
  float temperature;

  // Magenta at +1, green at −1: the other axis of a white balance, and the
  // one that fixes fluorescent light.
  float tint;
} VdColorAdjust;

// The affine map the five sliders compose to: `rgb' = m * rgb + offset`,
// row-major, in the encoded signal rather than in light.
//
// Grading in the signal is deliberate. A brightness slider that worked in
// linear light would move the picture much further at the top of its travel
// than at the bottom, because the encoding is a curve — and every editor a
// user has met puts these five in the signal. The LUT is the one that goes to
// linear, because a film emulation is describing what light did.
typedef struct {
  float m[9];
  float offset[3];
} VdColorTransform;

// The grade that changes nothing. Equivalent to a zeroed struct; this exists
// so callers can say what they mean.
VD_EXPORT VdColorAdjust vd_color_neutral(void);

// True when this grade would leave every pixel exactly as it found it, which
// is almost every clip. The compositor asks so that an ungraded layer takes
// the path it took before this file existed — down to the last bit, which is
// what keeps the golden frames from moving for a feature nobody used.
VD_EXPORT bool vd_color_is_neutral(const VdColorAdjust* adjust);

// Composes the five sliders into one matrix and offset. NULL is the identity.
VD_EXPORT VdColorTransform vd_color_transform(const VdColorAdjust* adjust);

// Applies one to a straight — *not* premultiplied — RGB triple in place,
// clamped to 0..1. The same arithmetic the shader does, and the reason the
// composition can be asserted on numbers instead of on pixels.
VD_EXPORT void vd_color_apply(const VdColorTransform* transform, float rgb[3]);

// The luma weights saturation measures grey with: BT.709, whatever matrix the
// source was coded in.
//
// By the time a grade runs the picture is RGB, and it is the *project's* idea
// of grey that matters rather than the camera's — two shots from two cameras
// desaturating to two different greys is a bug nobody would ever find. The
// decoder's own kr/kb are a different number for a different job: they turn
// YCbCr into RGB, and they have already been used by then.
#define VD_LUMA_R 0.2126f
#define VD_LUMA_G 0.7152f
#define VD_LUMA_B 0.0722f

#ifdef __cplusplus
}
#endif
#endif  // VD_COLOR_H
