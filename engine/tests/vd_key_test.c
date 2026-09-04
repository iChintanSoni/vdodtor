// The matte, checked as arithmetic.
//
// Same method as vd_color_test.c beside it: state the property that makes a
// decision that decision, rather than the number today's coefficients happen
// to produce. So "a shadow on the screen keys with the lit part of it" is
// asserted and the exact alpha at a given distance is not — the first is the
// promise the whole design rests on, the second is a curve.
//
// This is also the whole of what a compositor test cannot reach. Deciding what
// is background is arithmetic; the shader doing it is a distance and a mix.
// Only the first can be wrong in an interesting way — and
// vd_compositor_test.c checks the GPU against *this*, so the two cannot drift.
#include "vd_check.h"
#include "vdodtor/vd_key.h"

#include <math.h>

#include "vdodtor/vd_color.h"

static bool near(float a, float b) { return fabsf(a - b) < 0.002f; }

static float luma(const float rgb[3]) {
  return VD_LUMA_R * rgb[0] + VD_LUMA_G * rgb[1] + VD_LUMA_B * rgb[2];
}

// A key on a colour, with the defaults the inspector opens on.
static VdChromaKey key_on(uint32_t color) {
  VdChromaKey key = vd_key_none();
  key.color = color;
  key.tolerance = 0.2f;
  key.softness = 0.15f;
  key.spill = 1.0f;
  return key;
}

// How opaque `rgb` comes out under `key`. The triple is copied, so a caller
// that only wants the alpha does not have to care that this despills.
static float alpha_of(VdChromaKey key, float r, float g, float b) {
  const VdKeyMatte matte = vd_key_matte(&key);
  float rgb[3] = {r, g, b};
  return vd_key_apply(&matte, rgb);
}

#define GREEN 0x0000FF00u
#define BLUE 0x000000FFu

// --- off, and the two ways of being off -------------------------------------

// A zeroed struct is a key that removes nothing. Every caller that has never
// heard of chroma keying can memset its clips and never learn this file
// exists — and every golden frame taken before this file existed still holds,
// which is what makes that an assertion rather than a hope.
static void test_a_zeroed_key_is_off(void) {
  const VdChromaKey none = vd_key_none();
  VD_CHECK(vd_key_is_off(&none));
  VD_CHECK(vd_key_is_off(NULL));

  VdChromaKey zeroed;
  memset(&zeroed, 0, sizeof(zeroed));
  VD_CHECK(vd_key_is_off(&zeroed));

  const VdKeyMatte matte = vd_key_matte(&none);
  VD_CHECK(vd_key_matte_is_off(&matte));
}

// Tolerance is the on switch as well as the amount, which is what lets the
// document carry no separate flag that could disagree with it.
static void test_no_tolerance_keys_nothing(void) {
  VdChromaKey key = key_on(GREEN);
  key.tolerance = 0.0f;
  VD_CHECK(vd_key_is_off(&key));
  VD_CHECK(near(alpha_of(key, 0.0f, 1.0f, 0.0f), 1.0f));
}

// And a grey key is off however large the tolerance, because there is no hue
// to be near. Without this, a key on black at a wide tolerance would remove
// every unsaturated colour in the shot — a saturation threshold, not a key.
static void test_a_grey_key_keys_nothing(void) {
  for (uint32_t grey = 0; grey <= 0xFFu; grey += 0x55u) {
    VdChromaKey key = key_on((grey << 16) | (grey << 8) | grey);
    key.tolerance = 1.0f;
    VD_CHECK(vd_key_is_off(&key));
    VD_CHECK(near(alpha_of(key, 0.0f, 1.0f, 0.0f), 1.0f));
    VD_CHECK(near(alpha_of(key, 0.5f, 0.5f, 0.5f), 1.0f));
  }
}

// An off key leaves the colour exactly as it arrived, not merely opaque. A
// despill that ran anyway would grade every clip in the project.
static void test_an_off_key_leaves_the_colour_alone(void) {
  const VdChromaKey none = vd_key_none();
  const VdKeyMatte matte = vd_key_matte(&none);
  float rgb[3] = {0.1f, 0.7f, 0.3f};
  VD_CHECK(near(vd_key_apply(&matte, rgb), 1.0f));
  VD_CHECK(near(rgb[0], 0.1f));
  VD_CHECK(near(rgb[1], 0.7f));
  VD_CHECK(near(rgb[2], 0.3f));
}

// --- what the matte removes -------------------------------------------------

// The key colour itself is gone, and its complement is not. The floor of the
// whole feature.
static void test_the_key_colour_is_removed(void) {
  const VdChromaKey key = key_on(GREEN);
  VD_CHECK(near(alpha_of(key, 0.0f, 1.0f, 0.0f), 0.0f));
  VD_CHECK(near(alpha_of(key, 1.0f, 0.0f, 1.0f), 1.0f));  // magenta
}

// **The one that decides the design.** A green screen is never one green: it
// is lit unevenly, it has a shadow at the bottom and a hot spot where the key
// light lands. Measured in RGB those are far apart and only the exposure the
// user happened to sample would key. Measured in chroma they are the same
// colour, which is what makes a key on a real screen work at a tolerance a
// person would choose.
static void test_a_screen_keys_at_every_brightness(void) {
  const VdChromaKey key = key_on(GREEN);
  // Down to a sixth of the light the key colour was sampled at, which is more
  // than the fall-off across a badly lit screen. A matte measured on plain
  // Cb/Cr keeps only the top of this range — that is the bug this whole file
  // is arranged around.
  for (float level = 0.15f; level <= 1.0f; level += 0.05f) {
    VD_CHECK(near(alpha_of(key, 0.0f, level, 0.0f), 0.0f));
  }
}

// And a screen is never fully saturated either — paint, bounce and a camera's
// own matrix all pull it towards grey. A tolerance a person would choose has
// to cover that too.
static void test_a_realistic_screen_keys(void) {
  const VdChromaKey key = key_on(0x0033CC33u);
  VD_CHECK(near(alpha_of(key, 0.20f, 0.80f, 0.20f), 0.0f));
  VD_CHECK(near(alpha_of(key, 0.16f, 0.62f, 0.18f), 0.0f));
  VD_CHECK(near(alpha_of(key, 0.28f, 0.90f, 0.30f), 0.0f));
  // Skin and hair on the same screen stay.
  VD_CHECK(alpha_of(key, 0.86f, 0.66f, 0.54f) > 0.99f);
  VD_CHECK(alpha_of(key, 0.15f, 0.12f, 0.10f) > 0.99f);
}

// Grey is kept whatever the key is on, because a key is about hue: a white
// shirt in front of a green screen is not background.
static void test_grey_survives_a_key(void) {
  const VdChromaKey green = key_on(GREEN);
  const VdChromaKey blue = key_on(BLUE);
  for (float level = 0.0f; level <= 1.0f; level += 0.25f) {
    VD_CHECK(alpha_of(green, level, level, level) > 0.99f);
    VD_CHECK(alpha_of(blue, level, level, level) > 0.99f);
  }
}

// Blue keys on blue and green keys on green, and neither takes the other. A
// distance that had collapsed the two axes would pass every test above.
static void test_the_key_colour_is_the_one_removed(void) {
  VD_CHECK(near(alpha_of(key_on(GREEN), 0.0f, 1.0f, 0.0f), 0.0f));
  VD_CHECK(alpha_of(key_on(GREEN), 0.0f, 0.0f, 1.0f) > 0.99f);
  VD_CHECK(near(alpha_of(key_on(BLUE), 0.0f, 0.0f, 1.0f), 0.0f));
  VD_CHECK(alpha_of(key_on(BLUE), 0.0f, 1.0f, 0.0f) > 0.99f);
}

// --- the shape of the edge --------------------------------------------------

// Alpha only ever grows with distance from the key. A matte that dipped
// somewhere would punch a hole in the middle of a subject.
static void test_alpha_grows_with_distance(void) {
  const VdChromaKey key = key_on(GREEN);
  const VdKeyMatte matte = vd_key_matte(&key);
  float previous = -1.0f;
  // Walk from the key colour towards its complement, which crosses the whole
  // ramp: green, through grey, to magenta.
  for (float t = 0.0f; t <= 1.0f; t += 0.05f) {
    float rgb[3] = {t, 1.0f - t, t};
    const float alpha = vd_key_apply(&matte, rgb);
    VD_CHECK(alpha >= previous - 0.001f);
    previous = alpha;
  }
  VD_CHECK(near(previous, 1.0f));
}

// A wider tolerance removes more, and never less.
static void test_tolerance_widens_the_matte(void) {
  const float rgb[3] = {0.25f, 0.55f, 0.30f};  // a desaturated green
  VdChromaKey narrow = key_on(GREEN);
  narrow.tolerance = 0.05f;
  narrow.softness = 0.0f;
  VdChromaKey wide = narrow;
  wide.tolerance = 0.6f;
  VD_CHECK(alpha_of(narrow, rgb[0], rgb[1], rgb[2]) >
           alpha_of(wide, rgb[0], rgb[1], rgb[2]) - 0.001f);
  VD_CHECK(near(alpha_of(wide, rgb[0], rgb[1], rgb[2]), 0.0f));
  VD_CHECK(near(alpha_of(narrow, rgb[0], rgb[1], rgb[2]), 1.0f));
}

// No softness is a hard edge: every pixel is all the way in or all the way
// out, and nothing lands between.
static void test_no_softness_is_a_hard_edge(void) {
  VdChromaKey key = key_on(GREEN);
  key.softness = 0.0f;
  const VdKeyMatte matte = vd_key_matte(&key);
  for (float t = 0.0f; t <= 1.0f; t += 0.02f) {
    float rgb[3] = {t, 1.0f - t, t};
    const float alpha = vd_key_apply(&matte, rgb);
    VD_CHECK(near(alpha, 0.0f) || near(alpha, 1.0f));
  }
}

// And softness puts something in between, which is the only reason it exists.
static void test_softness_makes_an_edge(void) {
  VdChromaKey key = key_on(GREEN);
  key.tolerance = 0.2f;
  key.softness = 0.5f;
  const VdKeyMatte matte = vd_key_matte(&key);
  int partial = 0;
  for (float t = 0.0f; t <= 1.0f; t += 0.02f) {
    float rgb[3] = {t, 1.0f - t, t};
    const float alpha = vd_key_apply(&matte, rgb);
    if (alpha > 0.01f && alpha < 0.99f) partial++;
  }
  VD_CHECK(partial > 3);
}

// The ramp is smoothstepped rather than linear, so it arrives at solid with no
// corner — the corner is the bright line everybody recognises as a bad key.
// Asserted as the property rather than the polynomial: the curve leaves both
// ends flat, so it sits *under* the straight line early and *over* it late.
static void test_the_edge_has_no_corner(void) {
  VdChromaKey key = key_on(GREEN);
  key.tolerance = 0.0001f;
  key.softness = 1.0f;
  const VdKeyMatte matte = vd_key_matte(&key);

  // Desaturating the key colour towards grey holds its luma, so a colour a
  // fraction `t` of the way there is at distance exactly `t` — which is what
  // "tolerance is a fraction of the way to grey" means, and worth pinning
  // here since every other test in this file relies on it.
  for (float t = 0.2f; t < 0.9f; t += 0.1f) {
    float rgb[3] = {0.0f, 1.0f, 0.0f};
    const float y = luma(rgb);
    for (int i = 0; i < 3; i++) rgb[i] = y + (rgb[i] - y) * (1.0f - t);
    const float alpha = vd_key_apply(&matte, rgb);
    if (t < 0.5f) {
      VD_CHECK(alpha <= t + 0.001f);
    } else {
      VD_CHECK(alpha >= t - 0.001f);
    }
  }
}

// --- the despill ------------------------------------------------------------

// Green bounces off a screen onto everything in front of it, so an opaque edge
// pixel is still green. Taking it out is what the spill slider does.
static void test_spill_is_pulled_out_of_what_is_kept(void) {
  VdChromaKey key = key_on(GREEN);
  key.tolerance = 0.05f;  // narrow, so the spilled pixel is fully kept
  const VdKeyMatte matte = vd_key_matte(&key);

  float rgb[3] = {0.55f, 0.72f, 0.50f};  // hair with green bounce on it
  const VdChroma before = vd_key_chroma(rgb);
  const float alpha = vd_key_apply(&matte, rgb);
  const VdChroma after = vd_key_chroma(rgb);

  VD_CHECK(near(alpha, 1.0f));
  // Still there, and no longer leaning towards the screen.
  const float lean_before =
      before.cb * matte.axis.cb + before.cr * matte.axis.cr;
  const float lean_after = after.cb * matte.axis.cb + after.cr * matte.axis.cr;
  VD_CHECK(lean_before > 0.01f);
  VD_CHECK(near(lean_after, 0.0f));
}

// **And it holds the level.** Taking green off the green channel darkens every
// edge pixel it touches, which trades a green halo for a grey one — a fringe
// that is harder to see and just as wrong. Working in chroma keeps Y where it
// was, which is `vd_color`'s white-balance argument one file along.
static void test_a_despill_does_not_change_the_level(void) {
  VdChromaKey key = key_on(GREEN);
  key.tolerance = 0.05f;
  const VdKeyMatte matte = vd_key_matte(&key);

  const float swatches[][3] = {
      {0.55f, 0.72f, 0.50f}, {0.30f, 0.45f, 0.28f}, {0.80f, 0.88f, 0.75f},
      {0.20f, 0.30f, 0.15f}, {0.62f, 0.70f, 0.60f},
  };
  for (size_t i = 0; i < sizeof(swatches) / sizeof(swatches[0]); i++) {
    float rgb[3] = {swatches[i][0], swatches[i][1], swatches[i][2]};
    const float before = luma(rgb);
    vd_key_apply(&matte, rgb);
    VD_CHECK(near(luma(rgb), before));
  }
}

// Nothing is pushed the other way. A magenta shirt is the complement of the
// screen, and a despill that ran on it would make it more magenta.
static void test_a_despill_leaves_the_other_side_alone(void) {
  VdChromaKey key = key_on(GREEN);
  key.tolerance = 0.05f;
  const VdKeyMatte matte = vd_key_matte(&key);

  float rgb[3] = {0.80f, 0.20f, 0.75f};
  const float r = rgb[0], g = rgb[1], b = rgb[2];
  vd_key_apply(&matte, rgb);
  VD_CHECK(near(rgb[0], r));
  VD_CHECK(near(rgb[1], g));
  VD_CHECK(near(rgb[2], b));
}

// Spill at zero is a key with no despill at all, which is what somebody
// keying a coloured background out of a shot with that colour *in* it wants.
static void test_no_spill_leaves_the_colour_as_it_was(void) {
  VdChromaKey key = key_on(GREEN);
  key.tolerance = 0.05f;
  key.spill = 0.0f;
  const VdKeyMatte matte = vd_key_matte(&key);

  float rgb[3] = {0.55f, 0.72f, 0.50f};
  vd_key_apply(&matte, rgb);
  VD_CHECK(near(rgb[0], 0.55f));
  VD_CHECK(near(rgb[1], 0.72f));
  VD_CHECK(near(rgb[2], 0.50f));
}

// And it runs proportionally in between, so the slider means something at
// every position rather than being a toggle with a gap.
static void test_spill_runs_in_between(void) {
  VdChromaKey key = key_on(GREEN);
  key.tolerance = 0.05f;
  float lean_before = 0.0f;
  float previous = 1e9f;
  for (float amount = 0.0f; amount <= 1.0f; amount += 0.25f) {
    key.spill = amount;
    const VdKeyMatte matte = vd_key_matte(&key);
    float rgb[3] = {0.55f, 0.72f, 0.50f};
    if (amount == 0.0f) {
      const VdChroma c = vd_key_chroma(rgb);
      lean_before = c.cb * matte.axis.cb + c.cr * matte.axis.cr;
    }
    vd_key_apply(&matte, rgb);
    const VdChroma c = vd_key_chroma(rgb);
    const float lean = c.cb * matte.axis.cb + c.cr * matte.axis.cr;
    VD_CHECK(lean < previous + 0.001f);
    previous = lean;
  }
  VD_CHECK(lean_before > 0.01f);
  VD_CHECK(near(previous, 0.0f));
}

// --- the edges of the arithmetic --------------------------------------------

// Out-of-range sliders are clamped rather than believed, so a file written by
// a version with a wider control still renders something a person can fix.
static void test_the_sliders_are_clamped(void) {
  VdChromaKey key = key_on(GREEN);
  key.tolerance = 40.0f;
  key.softness = -3.0f;
  key.spill = 12.0f;
  const VdKeyMatte matte = vd_key_matte(&key);
  VD_CHECK(near(matte.tolerance, 1.0f));
  VD_CHECK(near(matte.softness, 0.0f));
  VD_CHECK(near(matte.spill, 1.0f));
}

// A NaN tolerance is off rather than everything-or-nothing: a clip nobody can
// see is a worse failure than a key nobody applied.
static void test_a_nan_tolerance_is_off(void) {
  VdChromaKey key = key_on(GREEN);
  key.tolerance = NAN;
  VD_CHECK(vd_key_is_off(&key));
}

// The result is always a real alpha, whatever went in.
static void test_alpha_stays_in_range(void) {
  const VdChromaKey key = key_on(GREEN);
  const VdKeyMatte matte = vd_key_matte(&key);
  for (float r = 0.0f; r <= 1.0f; r += 0.25f) {
    for (float g = 0.0f; g <= 1.0f; g += 0.25f) {
      for (float b = 0.0f; b <= 1.0f; b += 0.25f) {
        float rgb[3] = {r, g, b};
        const float alpha = vd_key_apply(&matte, rgb);
        VD_CHECK(alpha >= 0.0f && alpha <= 1.0f);
        for (int i = 0; i < 3; i++) {
          VD_CHECK(rgb[i] >= 0.0f && rgb[i] <= 1.0f);
        }
      }
    }
  }
}

static void test_apply_survives_a_null(void) {
  const VdChromaKey key = key_on(GREEN);
  const VdKeyMatte matte = vd_key_matte(&key);
  VD_CHECK(near(vd_key_apply(&matte, NULL), 1.0f));
  float rgb[3] = {0.0f, 1.0f, 0.0f};
  VD_CHECK(near(vd_key_apply(NULL, rgb), 1.0f));
  VD_CHECK(near(rgb[1], 1.0f));
}

// Grey has no chroma, and the key colour's own coordinates are what the
// compositor hands the shader — so this is the one conversion worth pinning
// directly.
static void test_grey_sits_at_the_middle_of_the_plane(void) {
  float grey[3] = {0.5f, 0.5f, 0.5f};
  const VdChroma c = vd_key_chroma(grey);
  VD_CHECK(near(c.cb, 0.0f));
  VD_CHECK(near(c.cr, 0.0f));

  // And a colour and its 0xAARRGGBB spelling land in the same place.
  float green[3] = {0.0f, 1.0f, 0.0f};
  const VdChroma from_floats = vd_key_chroma(green);
  const VdChroma from_color = vd_key_chroma_of_color(GREEN);
  VD_CHECK(near(from_floats.cb, from_color.cb));
  VD_CHECK(near(from_floats.cr, from_color.cr));
}

int main(void) {
  test_a_zeroed_key_is_off();
  test_no_tolerance_keys_nothing();
  test_a_grey_key_keys_nothing();
  test_an_off_key_leaves_the_colour_alone();
  test_the_key_colour_is_removed();
  test_a_screen_keys_at_every_brightness();
  test_a_realistic_screen_keys();
  test_grey_survives_a_key();
  test_the_key_colour_is_the_one_removed();
  test_alpha_grows_with_distance();
  test_tolerance_widens_the_matte();
  test_no_softness_is_a_hard_edge();
  test_softness_makes_an_edge();
  test_the_edge_has_no_corner();
  test_spill_is_pulled_out_of_what_is_kept();
  test_a_despill_does_not_change_the_level();
  test_a_despill_leaves_the_other_side_alone();
  test_no_spill_leaves_the_colour_as_it_was();
  test_spill_runs_in_between();
  test_the_sliders_are_clamped();
  test_a_nan_tolerance_is_off();
  test_alpha_stays_in_range();
  test_apply_survives_a_null();
  test_grey_sits_at_the_middle_of_the_plane();
  return VD_REPORT();
}
