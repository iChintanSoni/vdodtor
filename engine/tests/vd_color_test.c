// The grade, checked as arithmetic.
//
// Same method as vd_anim_test.c and vd_transition_test.c, and for the same
// reason: what a slider *means* is a design decision, and the way to pin a
// decision is to state the property that makes it that decision rather than
// the number it happens to produce today. So black staying black under
// brightness is asserted, and the exact grey a half-desaturated red lands on
// is not — the first is the promise, the second is a coefficient.
//
// This file is also the whole of what a compositor test cannot reach. Five
// sliders composing into one matrix is arithmetic; the shader multiplying by
// it is a multiply. Only the first can be wrong in an interesting way.
#include "vd_check.h"
#include "vdodtor/vd_color.h"

#include <math.h>

static bool near(float a, float b) { return fabsf(a - b) < 0.002f; }

// One straight RGB triple through a grade, for reading results back.
typedef struct {
  float r, g, b;
} Rgb;

static Rgb graded(VdColorAdjust adjust, float r, float g, float b) {
  const VdColorTransform t = vd_color_transform(&adjust);
  float rgb[3] = {r, g, b};
  vd_color_apply(&t, rgb);
  Rgb out = {rgb[0], rgb[1], rgb[2]};
  return out;
}

static float luma(Rgb c) {
  return VD_LUMA_R * c.r + VD_LUMA_G * c.g + VD_LUMA_B * c.b;
}

// A handful of colours to run every property over. A grade that is right for
// mid-grey and wrong for a saturated red is a grade nobody would notice was
// wrong until they graded something with a face in it.
static const Rgb kSwatches[] = {
    {0.0f, 0.0f, 0.0f}, {1.0f, 1.0f, 1.0f}, {0.5f, 0.5f, 0.5f},
    {0.8f, 0.2f, 0.1f}, {0.1f, 0.6f, 0.3f}, {0.2f, 0.3f, 0.9f},
    {0.6f, 0.6f, 0.2f},
};
#define SWATCH_COUNT (sizeof(kSwatches) / sizeof(kSwatches[0]))

// --- the neutral grade ------------------------------------------------------

// A zeroed struct is the grade that changes nothing. This is the invariant the
// whole design rests on: every caller that has never heard of colour can
// memset its layers, and the compositor's ungraded fast path is decided by it.
static void test_a_zeroed_adjust_is_neutral(void) {
  VdColorAdjust zeroed;
  memset(&zeroed, 0, sizeof(zeroed));
  VD_CHECK(vd_color_is_neutral(&zeroed));
  VD_CHECK(vd_color_is_neutral(NULL));

  const VdColorAdjust spelled = vd_color_neutral();
  VD_CHECK(vd_color_is_neutral(&spelled));
  VD_CHECK(memcmp(&spelled, &zeroed, sizeof(zeroed)) == 0);
}

static void test_the_neutral_grade_is_the_identity_matrix(void) {
  const VdColorTransform t = vd_color_transform(NULL);
  const float identity[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
  for (int i = 0; i < 9; i++) VD_CHECK(near(t.m[i], identity[i]));
  for (int i = 0; i < 3; i++) VD_CHECK(near(t.offset[i], 0.0f));
}

static void test_a_neutral_grade_leaves_every_colour_alone(void) {
  for (size_t i = 0; i < SWATCH_COUNT; i++) {
    const Rgb in = kSwatches[i];
    const Rgb out = graded(vd_color_neutral(), in.r, in.g, in.b);
    VD_CHECK(near(out.r, in.r));
    VD_CHECK(near(out.g, in.g));
    VD_CHECK(near(out.b, in.b));
  }
}

// Any slider off zero is a grade, including one so small it cannot be seen.
// "Nearly neutral" would quietly throw away the first pixel of somebody's drag.
static void test_one_slider_off_zero_is_not_neutral(void) {
  VdColorAdjust a = vd_color_neutral();
  a.brightness = 0.0001f;
  VD_CHECK(!vd_color_is_neutral(&a));

  a = vd_color_neutral();
  a.contrast = -0.0001f;
  VD_CHECK(!vd_color_is_neutral(&a));

  a = vd_color_neutral();
  a.saturation = 0.0001f;
  VD_CHECK(!vd_color_is_neutral(&a));

  a = vd_color_neutral();
  a.temperature = 0.0001f;
  VD_CHECK(!vd_color_is_neutral(&a));

  a = vd_color_neutral();
  a.tint = 0.0001f;
  VD_CHECK(!vd_color_is_neutral(&a));
}

// --- brightness -------------------------------------------------------------

// The decision this slider is: a gain, not a lift. Adding a constant would
// raise the blacks to grey, which is the faded look and not what anybody means
// by "brighter".
static void test_brightness_leaves_black_black(void) {
  VdColorAdjust a = vd_color_neutral();
  for (float b = -1.0f; b <= 1.0f; b += 0.25f) {
    a.brightness = b;
    const Rgb out = graded(a, 0.0f, 0.0f, 0.0f);
    VD_CHECK(near(out.r, 0.0f));
    VD_CHECK(near(out.g, 0.0f));
    VD_CHECK(near(out.b, 0.0f));
  }
}

static void test_brightness_moves_the_picture_the_right_way(void) {
  VdColorAdjust up = vd_color_neutral();
  up.brightness = 0.5f;
  VdColorAdjust down = vd_color_neutral();
  down.brightness = -0.5f;

  for (size_t i = 0; i < SWATCH_COUNT; i++) {
    const Rgb in = kSwatches[i];
    if (luma(in) <= 0.0f) continue;  // black has nowhere to go
    VD_CHECK(luma(graded(up, in.r, in.g, in.b)) > luma(in) - 0.001f);
    VD_CHECK(luma(graded(down, in.r, in.g, in.b)) < luma(in) + 0.001f);
  }
}

// A gain leaves the ratios between the channels alone, which is what makes it
// an exposure change rather than a wash: a red shirt stays as red as it was.
static void test_brightness_does_not_change_the_hue(void) {
  VdColorAdjust a = vd_color_neutral();
  a.brightness = 0.4f;
  const Rgb out = graded(a, 0.4f, 0.2f, 0.1f);
  VD_CHECK(near(out.r / out.g, 2.0f));
  VD_CHECK(near(out.g / out.b, 2.0f));
}

// --- contrast ---------------------------------------------------------------

// The pivot, stated: mid-grey stays exactly where it is at any contrast, and
// everything else moves away from it or towards it.
static void test_contrast_pivots_at_mid_grey(void) {
  VdColorAdjust a = vd_color_neutral();
  for (float c = -1.0f; c <= 1.0f; c += 0.25f) {
    a.contrast = c;
    const Rgb out = graded(a, 0.5f, 0.5f, 0.5f);
    VD_CHECK(near(out.r, 0.5f));
    VD_CHECK(near(out.g, 0.5f));
    VD_CHECK(near(out.b, 0.5f));
  }
}

static void test_contrast_pushes_away_from_the_pivot(void) {
  VdColorAdjust up = vd_color_neutral();
  up.contrast = 0.5f;
  const Rgb dark = graded(up, 0.3f, 0.3f, 0.3f);
  const Rgb light = graded(up, 0.7f, 0.7f, 0.7f);
  VD_CHECK(dark.r < 0.3f);
  VD_CHECK(light.r > 0.7f);

  // And all the way down is a flat mid-grey, whatever went in.
  VdColorAdjust flat = vd_color_neutral();
  flat.contrast = -1.0f;
  for (size_t i = 0; i < SWATCH_COUNT; i++) {
    const Rgb in = kSwatches[i];
    const Rgb out = graded(flat, in.r, in.g, in.b);
    VD_CHECK(near(out.r, 0.5f));
    VD_CHECK(near(out.g, 0.5f));
    VD_CHECK(near(out.b, 0.5f));
  }
}

// --- saturation -------------------------------------------------------------

// Fully down is monochrome, and the grey it lands on is the BT.709 luma of
// what went in — measured the same way whatever matrix the source was coded
// in, so two cameras desaturate to the same grey.
static void test_saturation_all_the_way_down_is_luma(void) {
  VdColorAdjust a = vd_color_neutral();
  a.saturation = -1.0f;
  for (size_t i = 0; i < SWATCH_COUNT; i++) {
    const Rgb in = kSwatches[i];
    const Rgb out = graded(a, in.r, in.g, in.b);
    VD_CHECK(near(out.r, out.g));
    VD_CHECK(near(out.g, out.b));
    VD_CHECK(near(out.r, luma(in)));
  }
}

// Grey has no colour to take away or add, so saturation cannot move it. The
// property that says the matrix is built around luma rather than around a
// channel.
static void test_saturation_leaves_grey_where_it_is(void) {
  VdColorAdjust a = vd_color_neutral();
  for (float s = -1.0f; s <= 1.0f; s += 0.25f) {
    a.saturation = s;
    for (float v = 0.0f; v <= 1.0f; v += 0.25f) {
      const Rgb out = graded(a, v, v, v);
      VD_CHECK(near(out.r, v));
      VD_CHECK(near(out.g, v));
      VD_CHECK(near(out.b, v));
    }
  }
}

// Turning it up pushes the channels further apart; turning it down brings them
// together. Stated as a spread rather than as a value, because the value is
// the coefficient and the spread is the promise.
static void test_saturation_widens_and_narrows_the_spread(void) {
  const Rgb in = {0.7f, 0.4f, 0.2f};
  const float spread = in.r - in.b;

  VdColorAdjust up = vd_color_neutral();
  up.saturation = 0.5f;
  const Rgb wider = graded(up, in.r, in.g, in.b);
  VD_CHECK(wider.r - wider.b > spread);

  VdColorAdjust down = vd_color_neutral();
  down.saturation = -0.5f;
  const Rgb narrower = graded(down, in.r, in.g, in.b);
  VD_CHECK(narrower.r - narrower.b < spread);
  VD_CHECK(narrower.r - narrower.b > 0.0f);
}

// Saturation is not brightness: it moves colour about the grey it already had,
// so the picture's luma comes out where it went in.
static void test_saturation_does_not_change_the_level(void) {
  VdColorAdjust a = vd_color_neutral();
  for (float s = -1.0f; s <= 1.0f; s += 0.5f) {
    a.saturation = s;
    // Away from the ends of the range, where the clamp has a say.
    const Rgb in = {0.55f, 0.45f, 0.4f};
    VD_CHECK(near(luma(graded(a, in.r, in.g, in.b)), luma(in)));
  }
}

// --- temperature and tint ---------------------------------------------------

// The decision that makes this a white balance rather than a wash: warming a
// shot must not also brighten it. Channel gains alone would, because red
// weighs three times what blue does — and then the user fights the temperature
// slider with the brightness one for ever.
static void test_a_white_balance_does_not_change_the_level(void) {
  VdColorAdjust a = vd_color_neutral();
  for (float v = -1.0f; v <= 1.0f; v += 0.25f) {
    a = vd_color_neutral();
    a.temperature = v;
    VD_CHECK(near(luma(graded(a, 0.5f, 0.5f, 0.5f)), 0.5f));

    a = vd_color_neutral();
    a.tint = v;
    VD_CHECK(near(luma(graded(a, 0.5f, 0.5f, 0.5f)), 0.5f));
  }
}

static void test_temperature_runs_blue_to_orange(void) {
  VdColorAdjust warm = vd_color_neutral();
  warm.temperature = 1.0f;
  const Rgb warmed = graded(warm, 0.5f, 0.5f, 0.5f);
  VD_CHECK(warmed.r > 0.5f);
  VD_CHECK(warmed.b < 0.5f);
  // Green is not on this axis at all, so it stays put but for the
  // normalisation that holds the level.
  VD_CHECK(fabsf(warmed.g - 0.5f) < fabsf(warmed.r - 0.5f));

  VdColorAdjust cool = vd_color_neutral();
  cool.temperature = -1.0f;
  const Rgb cooled = graded(cool, 0.5f, 0.5f, 0.5f);
  VD_CHECK(cooled.r < 0.5f);
  VD_CHECK(cooled.b > 0.5f);
}

static void test_tint_runs_green_to_magenta(void) {
  VdColorAdjust magenta = vd_color_neutral();
  magenta.tint = 1.0f;
  const Rgb m = graded(magenta, 0.5f, 0.5f, 0.5f);
  VD_CHECK(m.g < 0.5f);
  VD_CHECK(m.r > 0.5f);
  VD_CHECK(m.b > 0.5f);
  // The two ends of the magenta axis move together: it is one axis, not two.
  VD_CHECK(near(m.r, m.b));

  VdColorAdjust green = vd_color_neutral();
  green.tint = -1.0f;
  const Rgb g = graded(green, 0.5f, 0.5f, 0.5f);
  VD_CHECK(g.g > 0.5f);
  VD_CHECK(g.r < 0.5f);
  VD_CHECK(near(g.r, g.b));
}

// The green-magenta axis gets a shorter throw than the blue-orange one for the
// same slider travel, because the eye picks green apart far more finely than
// it does orange. A tint slider matched to the temperature one goes from
// "corrected" to "seasick" in the first third.
static void test_tint_leans_less_far_than_temperature(void) {
  VdColorAdjust warm = vd_color_neutral();
  warm.temperature = 1.0f;
  VdColorAdjust magenta = vd_color_neutral();
  magenta.tint = 1.0f;

  const Rgb w = graded(warm, 0.5f, 0.5f, 0.5f);
  const Rgb m = graded(magenta, 0.5f, 0.5f, 0.5f);
  VD_CHECK(fabsf(m.g - 0.5f) < fabsf(w.r - 0.5f));
}

// --- composition ------------------------------------------------------------

// Five sliders are one matrix, and the order they are folded in is the order
// anybody grades in: light, level, contrast, colour. This pins that the
// contrast really is applied after the brightness, which is the pair whose
// order is visible — contrast first would pivot about a grey the brightness
// then moves, and the pivot would stop being mid-grey.
static void test_contrast_is_applied_after_brightness(void) {
  VdColorAdjust both = vd_color_neutral();
  both.brightness = 0.5f;
  both.contrast = 1.0f;

  // Brightness first takes 1/3 to 1/2, and the contrast then pivots there and
  // leaves it. Contrast first would move it away from the pivot and the
  // brightness would then carry it somewhere else entirely.
  const Rgb out = graded(both, 1.0f / 3.0f, 1.0f / 3.0f, 1.0f / 3.0f);
  VD_CHECK(near(out.r, 0.5f));
}

// And that a grade is genuinely one map: applying the matrix once gives what
// applying the stages one after another would.
static void test_the_matrix_is_the_whole_grade(void) {
  VdColorAdjust all = vd_color_neutral();
  all.temperature = 0.4f;
  all.tint = -0.2f;
  all.brightness = 0.15f;
  all.contrast = 0.3f;
  all.saturation = 0.5f;

  VdColorAdjust wb = vd_color_neutral();
  wb.temperature = all.temperature;
  wb.tint = all.tint;
  VdColorAdjust bright = vd_color_neutral();
  bright.brightness = all.brightness;
  VdColorAdjust contrast = vd_color_neutral();
  contrast.contrast = all.contrast;
  VdColorAdjust saturation = vd_color_neutral();
  saturation.saturation = all.saturation;

  // A colour well inside the range, so no stage clips and the comparison is
  // about the composition rather than about the clamp.
  Rgb step = {0.45f, 0.38f, 0.30f};
  const Rgb in = step;
  step = graded(wb, step.r, step.g, step.b);
  step = graded(bright, step.r, step.g, step.b);
  step = graded(contrast, step.r, step.g, step.b);
  step = graded(saturation, step.r, step.g, step.b);

  const Rgb once = graded(all, in.r, in.g, in.b);
  VD_CHECK(near(once.r, step.r));
  VD_CHECK(near(once.g, step.g));
  VD_CHECK(near(once.b, step.b));
}

// --- the edges --------------------------------------------------------------

static void test_a_slider_past_its_end_is_clamped(void) {
  VdColorAdjust wild = vd_color_neutral();
  wild.saturation = 40.0f;
  VdColorAdjust full = vd_color_neutral();
  full.saturation = 1.0f;

  const VdColorTransform a = vd_color_transform(&wild);
  const VdColorTransform b = vd_color_transform(&full);
  for (int i = 0; i < 9; i++) VD_CHECK(near(a.m[i], b.m[i]));
}

// NaN lands at neutral rather than at an end. A grade nobody can see is a
// better failure than a frame nobody can.
static void test_a_nan_slider_grades_nothing(void) {
  VdColorAdjust broken = vd_color_neutral();
  broken.brightness = NAN;
  broken.saturation = NAN;
  const Rgb out = graded(broken, 0.4f, 0.3f, 0.2f);
  VD_CHECK(near(out.r, 0.4f));
  VD_CHECK(near(out.g, 0.3f));
  VD_CHECK(near(out.b, 0.2f));
}

// The output never leaves the range the shader can store, however far the
// sliders are pushed.
static void test_the_result_stays_in_range(void) {
  VdColorAdjust extreme = vd_color_neutral();
  extreme.brightness = 1.0f;
  extreme.contrast = 1.0f;
  extreme.saturation = 1.0f;
  extreme.temperature = 1.0f;

  for (size_t i = 0; i < SWATCH_COUNT; i++) {
    const Rgb in = kSwatches[i];
    const Rgb out = graded(extreme, in.r, in.g, in.b);
    VD_CHECK(out.r >= 0.0f && out.r <= 1.0f);
    VD_CHECK(out.g >= 0.0f && out.g <= 1.0f);
    VD_CHECK(out.b >= 0.0f && out.b <= 1.0f);
  }
}

static void test_apply_survives_a_null(void) {
  float rgb[3] = {0.25f, 0.5f, 0.75f};
  vd_color_apply(NULL, rgb);
  VD_CHECK(near(rgb[0], 0.25f));
  const VdColorTransform t = vd_color_transform(NULL);
  vd_color_apply(&t, NULL);
}

int main(void) {
  test_a_zeroed_adjust_is_neutral();
  test_the_neutral_grade_is_the_identity_matrix();
  test_a_neutral_grade_leaves_every_colour_alone();
  test_one_slider_off_zero_is_not_neutral();
  test_brightness_leaves_black_black();
  test_brightness_moves_the_picture_the_right_way();
  test_brightness_does_not_change_the_hue();
  test_contrast_pivots_at_mid_grey();
  test_contrast_pushes_away_from_the_pivot();
  test_saturation_all_the_way_down_is_luma();
  test_saturation_leaves_grey_where_it_is();
  test_saturation_widens_and_narrows_the_spread();
  test_saturation_does_not_change_the_level();
  test_a_white_balance_does_not_change_the_level();
  test_temperature_runs_blue_to_orange();
  test_tint_runs_green_to_magenta();
  test_tint_leans_less_far_than_temperature();
  test_contrast_is_applied_after_brightness();
  test_the_matrix_is_the_whole_grade();
  test_a_slider_past_its_end_is_clamped();
  test_a_nan_slider_grades_nothing();
  test_the_result_stays_in_range();
  test_apply_survives_a_null();
  return VD_REPORT();
}
