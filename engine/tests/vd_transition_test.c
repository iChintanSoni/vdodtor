// Transitions, checked as arithmetic.
//
// Same method as vd_anim_test.c and for the same reason: every preset's two
// ends are a contract, and the curve between them is a design decision. So the
// ends are pinned exactly, the properties that make each preset *itself* are
// pinned as inequalities, and the easing in the middle is deliberately not
// asserted — pinning a midpoint would turn every future adjustment into a red
// test with nothing wrong behind it.
#include "vd_check.h"
#include "vdodtor/vd_transition.h"

#include <math.h>

#define SECOND VD_TICKS_PER_SECOND

static bool near(float a, float b) { return fabsf(a - b) < 0.001f; }

// Every preset except the one that does nothing.
static const VdTransitionPreset kPresets[] = {
    VD_TRANSITION_DISSOLVE, VD_TRANSITION_FADE_BLACK, VD_TRANSITION_FADE_WHITE,
    VD_TRANSITION_SLIDE,    VD_TRANSITION_PUSH,       VD_TRANSITION_WIPE,
};
#define PRESET_COUNT (sizeof(kPresets) / sizeof(kPresets[0]))

// --- the ends --------------------------------------------------------------

// At t=0 the outgoing clip is untouched and the incoming one is not there; at
// t=1 the reverse. Every preset, without exception — a transition that did not
// start at the old clip and end at the new one would be a cut with a flicker
// on it.
static void test_every_preset_starts_on_the_old_clip(void) {
  for (size_t i = 0; i < PRESET_COUNT; i++) {
    const VdTransitionValue v = vd_transition_value(kPresets[i], 0.0f);
    VD_CHECK(near(v.out_opacity, 1.0f));
    VD_CHECK(near(v.out_offset_x, 0.0f));
    VD_CHECK(near(v.out_offset_y, 0.0f));
    VD_CHECK(near(v.flash, 0.0f));
    // The incoming clip is invisible, hidden, or entirely off the frame.
    const bool absent = near(v.in_opacity, 0.0f) ||
                        near(v.in_hide_right, 1.0f) ||
                        fabsf(v.in_offset_x) >= 1.0f;
    VD_CHECK(absent);
  }
}

static void test_every_preset_ends_on_the_new_clip(void) {
  for (size_t i = 0; i < PRESET_COUNT; i++) {
    const VdTransitionValue v = vd_transition_value(kPresets[i], 1.0f);
    VD_CHECK(near(v.in_opacity, 1.0f));
    VD_CHECK(near(v.in_offset_x, 0.0f));
    VD_CHECK(near(v.in_offset_y, 0.0f));
    VD_CHECK(near(v.in_hide_left, 0.0f));
    VD_CHECK(near(v.in_hide_right, 0.0f));
    VD_CHECK(near(v.in_hide_top, 0.0f));
    VD_CHECK(near(v.in_hide_bottom, 0.0f));
    VD_CHECK(near(v.flash, 0.0f));
  }
}

static void test_a_time_outside_the_window_is_clamped(void) {
  for (size_t i = 0; i < PRESET_COUNT; i++) {
    const VdTransitionValue before = vd_transition_value(kPresets[i], -3.0f);
    const VdTransitionValue start = vd_transition_value(kPresets[i], 0.0f);
    VD_CHECK(near(before.in_opacity, start.in_opacity));
    VD_CHECK(near(before.in_offset_x, start.in_offset_x));

    const VdTransitionValue after = vd_transition_value(kPresets[i], 9.0f);
    const VdTransitionValue end = vd_transition_value(kPresets[i], 1.0f);
    VD_CHECK(near(after.in_opacity, end.in_opacity));
    VD_CHECK(near(after.out_opacity, end.out_opacity));
  }
}

static void test_rest_is_both_clips_untouched(void) {
  const VdTransitionValue v = vd_transition_rest();
  VD_CHECK(near(v.out_opacity, 1.0f));
  VD_CHECK(near(v.in_opacity, 1.0f));
  VD_CHECK(near(v.flash, 0.0f));
  VD_CHECK(near(v.in_hide_right, 0.0f));

  // A zeroed struct is not it: that has both clips invisible, which is the
  // frame between two clips rather than either of them.
  VD_CHECK(!near(v.out_opacity, 0.0f));
}

static void test_none_does_nothing_at_any_time(void) {
  for (float t = 0.0f; t <= 1.0f; t += 0.1f) {
    const VdTransitionValue v = vd_transition_value(VD_TRANSITION_NONE, t);
    VD_CHECK(near(v.out_opacity, 1.0f));
    VD_CHECK(near(v.in_opacity, 1.0f));
    VD_CHECK(near(v.flash, 0.0f));
  }
}

// --- what makes each preset itself -----------------------------------------

// The outgoing clip stays fully opaque throughout. With premultiplied
// over-blending that *is* a crossfade — B at alpha t over A gives
// B*t + A*(1-t) — and turning A down as well would let the black behind them
// show through the middle of every dissolve.
static void test_a_dissolve_never_dims_the_outgoing_clip(void) {
  for (float t = 0.0f; t <= 1.0f; t += 0.05f) {
    const VdTransitionValue v = vd_transition_value(VD_TRANSITION_DISSOLVE, t);
    VD_CHECK(near(v.out_opacity, 1.0f));
    VD_CHECK(near(v.flash, 0.0f));
    VD_CHECK(near(v.in_offset_x, 0.0f));
  }
  // And the incoming one rises the whole way, monotonically.
  float previous = -1.0f;
  for (float t = 0.0f; t <= 1.0f; t += 0.05f) {
    const float now = vd_transition_value(VD_TRANSITION_DISSOLVE, t).in_opacity;
    VD_CHECK(now >= previous);
    previous = now;
  }
}

// The frame goes to the colour and comes back out of it, and the clips swap
// underneath at the midpoint rather than cross-fading through it — which would
// show both at half strength under a half-strength colour.
static void test_a_fade_dips_all_the_way_to_the_colour(void) {
  const VdTransitionValue middle =
      vd_transition_value(VD_TRANSITION_FADE_BLACK, 0.5f);
  VD_CHECK(near(middle.flash, 1.0f));
  VD_CHECK_EQ(middle.flash_color, 0xFF000000u);

  const VdTransitionValue white =
      vd_transition_value(VD_TRANSITION_FADE_WHITE, 0.5f);
  VD_CHECK(near(white.flash, 1.0f));
  VD_CHECK_EQ(white.flash_color, 0xFFFFFFFFu);

  // Only one clip is on at a time, either side of the midpoint.
  const VdTransitionValue early =
      vd_transition_value(VD_TRANSITION_FADE_BLACK, 0.25f);
  VD_CHECK(near(early.out_opacity, 1.0f));
  VD_CHECK(near(early.in_opacity, 0.0f));

  const VdTransitionValue late =
      vd_transition_value(VD_TRANSITION_FADE_BLACK, 0.75f);
  VD_CHECK(near(late.out_opacity, 0.0f));
  VD_CHECK(near(late.in_opacity, 1.0f));
}

// A slide brings the new clip across a frame that is standing still. A
// transition's travel is the *whole* frame, unlike an entrance's third: one
// that only came part of the way would leave the old clip showing down one
// side for ever.
static void test_a_slide_crosses_the_whole_frame(void) {
  const VdTransitionValue start =
      vd_transition_value(VD_TRANSITION_SLIDE, 0.0f);
  VD_CHECK(near(start.in_offset_x, 1.0f));
  VD_CHECK(near(start.out_offset_x, 0.0f));

  for (float t = 0.0f; t <= 1.0f; t += 0.05f) {
    const VdTransitionValue v = vd_transition_value(VD_TRANSITION_SLIDE, t);
    // The clip under it never moves and never dims.
    VD_CHECK(near(v.out_offset_x, 0.0f));
    VD_CHECK(near(v.out_opacity, 1.0f));
    // And the arriving clip is never faded — a slide is a move, not a blend.
    VD_CHECK(near(v.in_opacity, 1.0f));
  }
}

// A push is a slide that takes the old clip with it. The two are one frame
// apart at every instant, which is what makes the pair read as one sheet of
// film moving rather than as two clips that happen to be sliding.
static void test_a_push_moves_both_clips_together(void) {
  for (float t = 0.0f; t <= 1.0f; t += 0.05f) {
    const VdTransitionValue v = vd_transition_value(VD_TRANSITION_PUSH, t);
    VD_CHECK(near(v.in_offset_x - v.out_offset_x, 1.0f));
  }
  const VdTransitionValue end = vd_transition_value(VD_TRANSITION_PUSH, 1.0f);
  VD_CHECK(near(end.out_offset_x, -1.0f));
  VD_CHECK(near(end.in_offset_x, 0.0f));
}

// A wipe is the one preset a transform cannot express: an edge crossing a
// picture that is not moving.
static void test_a_wipe_moves_an_edge_and_nothing_else(void) {
  float previous = 2.0f;
  for (float t = 0.0f; t <= 1.0f; t += 0.05f) {
    const VdTransitionValue v = vd_transition_value(VD_TRANSITION_WIPE, t);
    VD_CHECK(near(v.in_opacity, 1.0f));
    VD_CHECK(near(v.out_opacity, 1.0f));
    VD_CHECK(near(v.in_offset_x, 0.0f));
    VD_CHECK(near(v.in_hide_left, 0.0f));
    // The edge only ever travels one way.
    VD_CHECK(v.in_hide_right <= previous);
    previous = v.in_hide_right;
  }
  // Linear, because an eased wipe looks like the edge is being dragged by hand.
  VD_CHECK(near(vd_transition_value(VD_TRANSITION_WIPE, 0.25f).in_hide_right,
                0.75f));
  VD_CHECK(near(vd_transition_value(VD_TRANSITION_WIPE, 0.5f).in_hide_right,
                0.5f));
}

// --- where the window sits -------------------------------------------------

static void test_the_window_straddles_the_cut(void) {
  VdClipTransition transition = {VD_TRANSITION_DISSOLVE, SECOND};
  VdTick from = 0;
  VdTick to = 0;

  // A cut at 10 s between two clips with plenty either side: half a second
  // before and half after, so the midpoint of the dissolve is the cut.
  VD_CHECK(vd_transition_window(&transition, 10 * SECOND, 0, 20 * SECOND,
                                &from, &to));
  VD_CHECK_EQ(from, 10 * SECOND - SECOND / 2);
  VD_CHECK_EQ(to, 10 * SECOND + SECOND / 2);
}

static void test_nothing_happens_without_both_a_preset_and_a_length(void) {
  VdTick from = -1;
  VdTick to = -1;

  VdClipTransition no_preset = {VD_TRANSITION_NONE, SECOND};
  VD_CHECK(!vd_transition_window(&no_preset, 10 * SECOND, 0, 20 * SECOND,
                                 &from, &to));
  VdClipTransition no_length = {VD_TRANSITION_DISSOLVE, 0};
  VD_CHECK(!vd_transition_window(&no_length, 10 * SECOND, 0, 20 * SECOND,
                                 &from, &to));
  VD_CHECK(!vd_transition_window(NULL, 10 * SECOND, 0, 20 * SECOND, &from, &to));

  // The outputs are left alone when nothing happens, so a caller that ignored
  // the return value would get a window it can see is nonsense rather than one
  // that looks plausible.
  VD_CHECK_EQ(from, -1);
  VD_CHECK_EQ(to, -1);

  VD_CHECK(!vd_transition_active(&no_preset));
  VD_CHECK(!vd_transition_active(&no_length));
  VD_CHECK(!vd_transition_active(NULL));
  VdClipTransition real = {VD_TRANSITION_DISSOLVE, SECOND};
  VD_CHECK(vd_transition_active(&real));
  VD_CHECK(!vd_transition_active(&(VdClipTransition){VD_TRANSITION_NONE, 0}));
  VD_CHECK_EQ(vd_clip_transition_none().duration, 0);
  VD_CHECK_EQ(vd_clip_transition_none().preset, VD_TRANSITION_NONE);
}

// It never reaches past either clip. A transition longer than the clip it
// joins would dissolve into a clip that is not on screen yet — and clamping
// beats refusing, because the duration is a slider and one that stops moving
// at a length nobody can see looks broken.
static void test_the_window_is_clamped_to_the_shorter_clip(void) {
  VdClipTransition transition = {VD_TRANSITION_DISSOLVE, 4 * SECOND};
  VdTick from = 0;
  VdTick to = 0;

  // The outgoing clip is only half a second long.
  VD_CHECK(vd_transition_window(&transition, SECOND / 2, 0, 20 * SECOND, &from,
                                &to));
  VD_CHECK_EQ(from, 0);
  VD_CHECK_EQ(to, SECOND);

  // And the incoming one, on the other side.
  VD_CHECK(vd_transition_window(&transition, 10 * SECOND, 0,
                                10 * SECOND + SECOND / 4, &from, &to));
  VD_CHECK_EQ(from, 10 * SECOND - SECOND / 4);
  VD_CHECK_EQ(to, 10 * SECOND + SECOND / 4);
}

static void test_a_cut_with_no_room_at_all_has_no_window(void) {
  VdClipTransition transition = {VD_TRANSITION_DISSOLVE, SECOND};
  VdTick from = 0;
  VdTick to = 0;

  // A zero-length clip on either side: there is no half to put anywhere.
  VD_CHECK(!vd_transition_window(&transition, 0, 0, 20 * SECOND, &from, &to));
  VD_CHECK(!vd_transition_window(&transition, 10 * SECOND, 0, 10 * SECOND,
                                 &from, &to));
}

int main(void) {
  test_every_preset_starts_on_the_old_clip();
  test_every_preset_ends_on_the_new_clip();
  test_a_time_outside_the_window_is_clamped();
  test_rest_is_both_clips_untouched();
  test_none_does_nothing_at_any_time();

  test_a_dissolve_never_dims_the_outgoing_clip();
  test_a_fade_dips_all_the_way_to_the_colour();
  test_a_slide_crosses_the_whole_frame();
  test_a_push_moves_both_clips_together();
  test_a_wipe_moves_an_edge_and_nothing_else();

  test_the_window_straddles_the_cut();
  test_nothing_happens_without_both_a_preset_and_a_length();
  test_the_window_is_clamped_to_the_shorter_clip();
  test_a_cut_with_no_room_at_all_has_no_window();

  return VD_REPORT();
}
