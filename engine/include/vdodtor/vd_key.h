// vd_key.h — the grade that decides whether a pixel is there at all.
//
// `vd_color.h` is every affine operation on RGB, which is exactly why five
// sliders fold into one 3x3. `vd_lut.h` is the arbitrary map left over, which
// is why it arrives as a lattice. A chroma key is neither, and the difference
// is not one of degree: both of those change what colour a pixel *is*, and
// this one changes whether it is **there**. It produces alpha, and the two
// beside it never touch it.
//
// So it is its own module, with its own document object and its own inspector
// section rather than four more fields on a grade — and it takes the same
// bargain the two beside it take. What a key *means* is here, in plain C with
// no platform dependency and no GPU in the room, testable with three floats in
// an array; what is left in Metal is a distance and a mix that a test could
// tell you nothing about. Not mirrored in Dart, for `vd_anim.c`'s reason:
// nothing in the app draws a matte.
//
// **The key runs on chroma, and on chroma divided by brightness.** Both halves
// of that are needed and neither is obvious.
//
// A distance measured in RGB is a distance that grows with exposure, so the
// matte becomes a function of how well that corner of the screen was lit: the
// shadow at the bottom of the cyclorama stays and the subject's lit shoulder
// goes. Projecting onto (Cb, Cr) is the usual answer and it is only half of
// one — Cb and Cr are *differences*, so they shrink with the picture. A screen
// at a third of the key light's brightness sits a third of the way in towards
// grey, which is further from the sampled green than most of the subject is.
// Every simple keyer has this failure and it is why they only work on a
// perfectly, evenly lit screen.
//
// Dividing the chroma through by the pixel's own luma removes it. In a
// gamma-encoded signal a shadow is still very nearly a uniform scaling of all
// three channels — a power law takes a scale to a scale — so chroma over luma
// is what does not move when the light does. What is left is the only thing
// anybody meant by "this colour": its hue, and how far from grey it is.
//
// And the distance is then divided by the key's own: **`tolerance` is the
// fraction of the way from the key colour to grey that still counts as
// background**, 0 at the key colour and 1 at grey, whatever colour the key is
// on. Without that last division the same slider means one thing for a green
// screen and another for a blue one, because blue carries a fifth of green's
// luma and its coordinates are an order of magnitude larger.
//
// The weights are the BT.709 ones `vd_color.h` declares, and deliberately
// *not* the source's own `kr`/`kb`. By the time a key runs the picture is RGB,
// and it is the project's idea of hue that has to decide — two shots from two
// cameras keying to two different greens is a bug nobody would ever find. It
// is the argument saturation already makes, one file along.
//
// **A key is measured on the shot as it was shot**, before the five sliders
// and before the look. The other order makes every control in the colour panel
// above it secretly a keying control: turn up the contrast and the matte
// closes over, drag saturation and the fringe comes back. The despill runs
// there too, so what the grade is handed is a corrected plate.

#ifndef VD_KEY_H
#define VD_KEY_H

#include <stdbool.h>
#include <stdint.h>

#include "vdodtor/vd_time.h"

#ifdef __cplusplus
extern "C" {
#endif

// What a clip removes from itself: a colour, how much of it to take, how
// softly, and how much of its spill to pull out of what is left.
//
// **A zeroed struct is no key, twice over.** `tolerance` 0 means nothing is
// within zero of the key colour, so nothing is removed; and the zeroed
// `color` is black, which is grey, which has no hue to be near in the first
// place. Either alone would do — having both is what makes this a field a
// caller can `memset` and never learn about, on `VdTransform`'s terms.
typedef struct {
  // The colour to remove: 0xAARRGGBB, straight, alpha ignored — the
  // convention `VdTextSpec` already writes colours in, because the document
  // writes them and a human reads them.
  //
  // A **grey** key removes nothing, whatever the other three fields say.
  // There is no hue to be near and nothing to measure a fraction of: the
  // distance below would be taken from the middle of the chroma plane and
  // divided by nothing, which is not a key but a saturation threshold wearing
  // one's clothes.
  uint32_t color;

  // How far from the key colour still counts as background, as a **fraction
  // of the way from that colour to grey**: 0 removes only the colour itself
  // and is what a zeroed struct says, 1 removes everything that leans that way
  // at all. See the head of this file for why it is a fraction rather than a
  // distance.
  //
  // This is the on switch as well as the amount. A separate `enabled` flag
  // would be a second thing that can disagree with it, and a document that
  // records what *happens* has no room for the difference between a key
  // turned off and a key set to remove nothing.
  float tolerance;

  // The width of the ramp from gone to kept, measured outwards from
  // `tolerance` in the same fractions. 0 is a hard edge.
  //
  // Smoothstepped rather than linear: a linear ramp leaves a corner where the
  // matte meets solid, and that corner reads as a bright line drawn around
  // the subject — the one artefact everybody recognises as a bad key.
  float softness;

  // How much of the key's own colour to pull out of what is left: 0 leaves
  // the fringe as it was shot, 1 takes all of it.
  //
  // Green bounces off a screen onto everything in front of it, so the edge of
  // a subject is green even where it is opaque. The removal happens along the
  // same chroma axis the matte is measured on — one space paying for both
  // halves of the feature — and **at constant luma**, which is the whole
  // trick: taking green off the green *channel* darkens every edge pixel it
  // touches and trades a green halo for a grey one. See `vd_key_apply`.
  float spill;
} VdChromaKey;

// The key that removes nothing. Equivalent to a zeroed struct; this exists so
// callers can say what they mean.
VD_EXPORT VdChromaKey vd_key_none(void);

// True when this key would leave every pixel exactly as it found it — a
// tolerance of nothing, or a colour with no hue to key on. The compositor asks
// before it does anything, so an unkeyed fragment takes the arithmetic it took
// before this file existed, bit for bit, and the golden frames cannot move for
// a feature nobody used.
VD_EXPORT bool vd_key_is_off(const VdChromaKey* key);

// A colour's position in the chroma plane: how far it is from grey, and in
// which direction. Grey is {0, 0}.
//
// BT.709, whatever matrix the source was coded in — see the head of this file.
typedef struct {
  float cb;
  float cr;
} VdChroma;

// Where a straight — not premultiplied — RGB triple sits in the chroma plane.
//
// The plain coordinates, with the brightness still in them. The matte divides
// them through by luma and the despill does not: a despill is a subtraction
// from the colour that is actually there, at the level it is actually at.
VD_EXPORT VdChroma vd_key_chroma(const float rgb[3]);

// The same, for a 0xAARRGGBB colour, which is how the key itself arrives.
VD_EXPORT VdChroma vd_key_chroma_of_color(uint32_t color);

// The key resolved into what the shader actually needs: the chroma point to
// measure from, the unit vector to despill along, and the two thresholds.
//
// Worked out once per layer on the CPU rather than once per fragment on the
// GPU — the same division of labour `vd_color_transform` makes, for the same
// reason: the part that decides what the control *means* is the part worth
// testing, and a normalise per pixel is a normalise of a constant.
typedef struct {
  // The key colour's chroma divided by its own luma: where it sits once its
  // brightness has been taken out. Distances are measured from here, against
  // pixels treated the same way.
  VdChroma chromaticity;

  // `chromaticity` normalised: the axis a despill subtracts along. {0, 0} when
  // the key is grey, which is one of the two ways a key is off.
  VdChroma axis;

  // One over the length of `chromaticity`, which is what turns a distance into
  // a fraction of the way from the key colour to grey — so `tolerance` means
  // the same thing on a blue screen as on a green one.
  float inv_length;

  float tolerance;
  float softness;
  float spill;
} VdKeyMatte;

// Resolves a key. A NULL or off key gives a matte that keeps everything, which
// `vd_key_matte_is_off` reports and the compositor short-circuits on.
VD_EXPORT VdKeyMatte vd_key_matte(const VdChromaKey* key);

VD_EXPORT bool vd_key_matte_is_off(const VdKeyMatte* matte);

// How opaque a straight — not premultiplied — RGB triple is under this matte,
// and the triple despilled in place.
//
// 1 is kept exactly as it arrived, 0 is gone. This is the arithmetic the
// shader does, which is what lets a key be asserted on numbers rather than on
// pixels — and what makes `vd_compositor_test.c` able to check that the GPU
// agrees with it, the way it already checks the look against `vd_lut_sample`.
//
// The despill runs whatever the alpha came out as. A pixel that was removed
// has no colour anybody will see, and branching on it would cost a divergence
// per fragment to save arithmetic that is already free.
VD_EXPORT float vd_key_apply(const VdKeyMatte* matte, float rgb[3]);

#ifdef __cplusplus
}
#endif
#endif  // VD_KEY_H
