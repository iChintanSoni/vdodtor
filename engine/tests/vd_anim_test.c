// In/out animation presets, checked as the arithmetic they are.
//
// This is the one part of the picture with no GPU and no typeface in it: a
// preset is a pure function from "how far through" to an offset, a scale, a
// turn and an opacity. So it gets tested the way pure functions should be —
// on the properties that make each preset the thing it is, and on the two
// boundaries every one of them shares.
//
// What is deliberately *not* asserted is the shape of the easing between the
// ends. A curve is a design decision, and pinning its midpoint to three
// decimal places would make every future adjustment a red test with nothing
// wrong behind it.
#include "vd_check.h"
#include "vdodtor/vd_anim.h"

#include <math.h>

#define SECOND VD_TICKS_PER_SECOND

static bool near_enough(float a, float b) { return fabsf(a - b) < 0.001f; }

static void check_is_rest(VdAnimValue v, const char* what) {
  vd_checks++;
  if (!near_enough(v.offset_x, 0.0f) || !near_enough(v.offset_y, 0.0f) ||
      !near_enough(v.scale, 1.0f) || !near_enough(v.rotation_degrees, 0.0f) ||
      !near_enough(v.opacity, 1.0f) || !near_enough(v.reveal, 1.0f)) {
    vd_failures++;
    fprintf(stderr,
            "FAIL %s is not at rest\n  offset %.3f,%.3f scale %.3f rot %.1f "
            "opacity %.3f reveal %.3f\n",
            what, v.offset_x, v.offset_y, v.scale, v.rotation_degrees,
            v.opacity, v.reveal);
  }
}

// Every preset that is not "none", for the tests that hold for all of them.
static const VdAnimPreset kPresets[] = {
    VD_ANIM_FADE,       VD_ANIM_SLIDE_UP, VD_ANIM_SLIDE_DOWN,
    VD_ANIM_SLIDE_LEFT, VD_ANIM_SLIDE_RIGHT, VD_ANIM_POP,
    VD_ANIM_ZOOM,       VD_ANIM_SPIN,     VD_ANIM_TYPEWRITER,
};
#define PRESET_COUNT (sizeof(kPresets) / sizeof(kPresets[0]))

static void test_the_ends_are_the_ends(void) {
  // The property that makes an animation an animation rather than a
  // permanent transform: at t=1 every preset leaves the clip exactly where
  // the document put it. A preset that settled a percent short would move
  // every animated clip on the timeline, quietly and forever.
  for (size_t i = 0; i < PRESET_COUNT; i++) {
    check_is_rest(vd_anim_value(kPresets[i], 1.0f), "a finished animation");
  }
  check_is_rest(vd_anim_value(VD_ANIM_NONE, 0.0f), "no animation at all");
  check_is_rest(vd_anim_value(VD_ANIM_NONE, 0.5f), "no animation, mid-way");
  check_is_rest(vd_anim_rest(), "vd_anim_rest");
}

static void test_every_preset_starts_away_from_rest(void) {
  // And the other end: at t=0 every preset has to be doing *something*, or it
  // is a menu entry that looks like it did nothing.
  for (size_t i = 0; i < PRESET_COUNT; i++) {
    const VdAnimValue v = vd_anim_value(kPresets[i], 0.0f);
    const bool moved = !near_enough(v.offset_x, 0.0f) ||
                       !near_enough(v.offset_y, 0.0f) ||
                       !near_enough(v.scale, 1.0f) ||
                       !near_enough(v.rotation_degrees, 0.0f) ||
                       !near_enough(v.opacity, 1.0f) ||
                       !near_enough(v.reveal, 1.0f);
    vd_checks++;
    if (!moved) {
      vd_failures++;
      fprintf(stderr, "FAIL preset %d does nothing at t=0\n", (int)kPresets[i]);
    }
  }
}

static void test_out_of_range_is_clamped(void) {
  // A caller doing its own arithmetic on ticks must not be able to produce a
  // frame nobody designed.
  check_is_rest(vd_anim_value(VD_ANIM_POP, 2.0f), "t past the end");
  check_is_rest(vd_anim_value(VD_ANIM_POP, INFINITY), "t at infinity");
  // NaN lands at rest rather than at zero on purpose: it decides only what a
  // bug looks like, and a clip that still shows beats one that vanishes.
  check_is_rest(vd_anim_value(VD_ANIM_POP, NAN), "t of NaN");

  const VdAnimValue before = vd_anim_value(VD_ANIM_FADE, -1.0f);
  VD_CHECK(near_enough(before.opacity, 0.0f));
}

static void test_a_fade_is_only_opacity(void) {
  const VdAnimValue v = vd_anim_value(VD_ANIM_FADE, 0.5f);
  VD_CHECK(v.opacity > 0.0f && v.opacity < 1.0f);
  VD_CHECK(near_enough(v.offset_x, 0.0f));
  VD_CHECK(near_enough(v.offset_y, 0.0f));
  VD_CHECK(near_enough(v.scale, 1.0f));
  VD_CHECK(near_enough(v.rotation_degrees, 0.0f));
  VD_CHECK(near_enough(v.reveal, 1.0f));

  // Monotonic, because a fade that dipped would flicker.
  float last = -1.0f;
  for (int i = 0; i <= 10; i++) {
    const float o = vd_anim_value(VD_ANIM_FADE, (float)i / 10.0f).opacity;
    VD_CHECK(o >= last);
    last = o;
  }
}

static void test_a_slide_travels_the_way_it_is_named(void) {
  // A preset names the direction the clip *travels*, so an entrance starts on
  // the opposite side. Up starts below, and offset_y grows downwards.
  VD_CHECK(vd_anim_value(VD_ANIM_SLIDE_UP, 0.0f).offset_y > 0.0f);
  VD_CHECK(vd_anim_value(VD_ANIM_SLIDE_DOWN, 0.0f).offset_y < 0.0f);
  VD_CHECK(vd_anim_value(VD_ANIM_SLIDE_LEFT, 0.0f).offset_x > 0.0f);
  VD_CHECK(vd_anim_value(VD_ANIM_SLIDE_RIGHT, 0.0f).offset_x < 0.0f);

  // Each moves on one axis only.
  VD_CHECK(near_enough(vd_anim_value(VD_ANIM_SLIDE_UP, 0.0f).offset_x, 0.0f));
  VD_CHECK(near_enough(vd_anim_value(VD_ANIM_SLIDE_LEFT, 0.0f).offset_y, 0.0f));

  // And closes on rest without overshooting past it, which a slide that used
  // a back curve would.
  float last = 1e9f;
  for (int i = 0; i <= 10; i++) {
    const float y = vd_anim_value(VD_ANIM_SLIDE_UP, (float)i / 10.0f).offset_y;
    VD_CHECK(y >= 0.0f);
    VD_CHECK(y <= last);
    last = y;
  }
}

static void test_only_pop_goes_past_its_resting_size(void) {
  // The whole difference between a pop and a zoom, and the thing that makes
  // one read as a flinch and the other as a grow.
  float peak = 0.0f;
  for (int i = 0; i <= 100; i++) {
    const float s = vd_anim_value(VD_ANIM_POP, (float)i / 100.0f).scale;
    if (s > peak) peak = s;
  }
  VD_CHECK(peak > 1.0f);
  VD_CHECK(peak < 1.2f);  // a flinch, not a bounce

  for (int i = 0; i <= 100; i++) {
    const float t = (float)i / 100.0f;
    VD_CHECK(vd_anim_value(VD_ANIM_ZOOM, t).scale <= 1.0f + 0.001f);
    VD_CHECK(vd_anim_value(VD_ANIM_SPIN, t).scale <= 1.0f + 0.001f);
  }

  // Both start smaller than they finish, and neither starts at nothing — a
  // scale of zero is a first frame with nothing on it.
  VD_CHECK(vd_anim_value(VD_ANIM_ZOOM, 0.0f).scale > 0.0f);
  VD_CHECK(vd_anim_value(VD_ANIM_ZOOM, 0.0f).scale < 1.0f);
  VD_CHECK(vd_anim_value(VD_ANIM_POP, 0.0f).scale > 0.0f);
  VD_CHECK(vd_anim_value(VD_ANIM_POP, 0.0f).scale < 1.0f);
}

static void test_a_spin_turns_and_lands_square(void) {
  const VdAnimValue start = vd_anim_value(VD_ANIM_SPIN, 0.0f);
  VD_CHECK(fabsf(start.rotation_degrees) > 30.0f);
  // Less than a full turn: a revolution takes the eye with it and loses the
  // words.
  VD_CHECK(fabsf(start.rotation_degrees) < 360.0f);
  VD_CHECK(near_enough(vd_anim_value(VD_ANIM_SPIN, 1.0f).rotation_degrees,
                       0.0f));
}

static void test_a_typewriter_reveals_and_nothing_else(void) {
  // It cannot be expressed as a transform, so it must not pretend to be one:
  // anything it moved would be moving for a second reason.
  for (int i = 0; i <= 10; i++) {
    const VdAnimValue v = vd_anim_value(VD_ANIM_TYPEWRITER, (float)i / 10.0f);
    VD_CHECK(near_enough(v.offset_x, 0.0f));
    VD_CHECK(near_enough(v.offset_y, 0.0f));
    VD_CHECK(near_enough(v.scale, 1.0f));
    VD_CHECK(near_enough(v.rotation_degrees, 0.0f));
    // And it does not fade. Characters appearing *are* the entrance; fading
    // them as well makes the early ones look like a mistake.
    VD_CHECK(near_enough(v.opacity, 1.0f));
  }

  VD_CHECK(near_enough(vd_anim_value(VD_ANIM_TYPEWRITER, 0.0f).reveal, 0.0f));
  VD_CHECK(near_enough(vd_anim_value(VD_ANIM_TYPEWRITER, 1.0f).reveal, 1.0f));
  // Linear: characters arrive at a steady rate, because that is what typing
  // is. Easing would make the last half of a sentence appear at once.
  VD_CHECK(near_enough(vd_anim_value(VD_ANIM_TYPEWRITER, 0.5f).reveal, 0.5f));
  VD_CHECK(near_enough(vd_anim_value(VD_ANIM_TYPEWRITER, 0.25f).reveal, 0.25f));

  // Every other preset leaves the text alone.
  for (size_t i = 0; i < PRESET_COUNT; i++) {
    if (kPresets[i] == VD_ANIM_TYPEWRITER) continue;
    VD_CHECK(near_enough(vd_anim_value(kPresets[i], 0.0f).reveal, 1.0f));
  }
}

// --- placing it on a clip --------------------------------------------------

static VdClipAnim anim_of(VdAnimPreset in, VdTick in_len, VdAnimPreset out,
                          VdTick out_len) {
  VdClipAnim a = vd_clip_anim_none();
  a.in_preset = in;
  a.in_duration = in_len;
  a.out_preset = out;
  a.out_duration = out_len;
  return a;
}

static void test_a_clip_with_no_animation_never_moves(void) {
  const VdClipAnim none = vd_clip_anim_none();
  for (int i = 0; i <= 10; i++) {
    check_is_rest(vd_anim_at(&none, (VdTick)i * SECOND / 10, SECOND),
                  "an unanimated clip");
  }
  check_is_rest(vd_anim_at(NULL, 0, SECOND), "a NULL animation");
  // A zero-length clip has nowhere to be, and dividing by it would be worse.
  check_is_rest(vd_anim_at(&none, 0, 0), "a clip with no length");
}

static void test_the_entrance_owns_the_head_and_nothing_else(void) {
  const VdClipAnim anim = anim_of(VD_ANIM_FADE, SECOND, VD_ANIM_NONE, 0);

  VD_CHECK(near_enough(vd_anim_at(&anim, 0, 4 * SECOND).opacity, 0.0f));
  VD_CHECK(vd_anim_at(&anim, SECOND / 2, 4 * SECOND).opacity > 0.4f);
  VD_CHECK(vd_anim_at(&anim, SECOND / 2, 4 * SECOND).opacity < 0.6f);

  // Past its own length it is at rest, and stays there for the whole of the
  // rest of the clip.
  check_is_rest(vd_anim_at(&anim, SECOND, 4 * SECOND), "just past the entrance");
  check_is_rest(vd_anim_at(&anim, 2 * SECOND, 4 * SECOND), "the middle");
  check_is_rest(vd_anim_at(&anim, 4 * SECOND - 1, 4 * SECOND), "the last tick");
}

static void test_the_exit_is_measured_from_the_far_edge(void) {
  // The same reasoning as the audio fades: the last tick of a clip has to be
  // as far from rest as the first, or the exit finishes a tick early and the
  // clip snaps back into place for one frame before it goes.
  const VdClipAnim anim = anim_of(VD_ANIM_NONE, 0, VD_ANIM_FADE, SECOND);

  check_is_rest(vd_anim_at(&anim, 0, 4 * SECOND), "the head");
  check_is_rest(vd_anim_at(&anim, 3 * SECOND, 4 * SECOND), "the exit's start");
  VD_CHECK(vd_anim_at(&anim, 3 * SECOND + SECOND / 2, 4 * SECOND).opacity <
           0.6f);
  VD_CHECK(near_enough(vd_anim_at(&anim, 4 * SECOND, 4 * SECOND).opacity,
                       0.0f));
}

static void test_both_halves_on_one_clip(void) {
  const VdClipAnim anim =
      anim_of(VD_ANIM_SLIDE_UP, SECOND, VD_ANIM_SLIDE_LEFT, SECOND);

  // Each half runs its own preset, and the middle is at rest.
  VD_CHECK(vd_anim_at(&anim, 0, 4 * SECOND).offset_y > 0.0f);
  VD_CHECK(near_enough(vd_anim_at(&anim, 0, 4 * SECOND).offset_x, 0.0f));
  check_is_rest(vd_anim_at(&anim, 2 * SECOND, 4 * SECOND), "the middle");
  VD_CHECK(vd_anim_at(&anim, 4 * SECOND, 4 * SECOND).offset_x > 0.0f);
  VD_CHECK(near_enough(vd_anim_at(&anim, 4 * SECOND, 4 * SECOND).offset_y,
                       0.0f));
}

static void test_a_clip_too_short_for_both_takes_the_nearer_one(void) {
  // A one-second clip with a one-second entrance and a one-second exit. They
  // overlap everywhere, and combining them would produce a motion neither
  // preset describes — so the half the playhead is deepest inside wins.
  const VdClipAnim anim =
      anim_of(VD_ANIM_SLIDE_UP, SECOND, VD_ANIM_SLIDE_LEFT, SECOND);

  // The first quarter is well inside the entrance and only just inside the
  // exit, so the entrance wins.
  const VdAnimValue early = vd_anim_at(&anim, SECOND / 4, SECOND);
  VD_CHECK(early.offset_y > 0.0f);
  VD_CHECK(near_enough(early.offset_x, 0.0f));

  const VdAnimValue late = vd_anim_at(&anim, 3 * SECOND / 4, SECOND);
  VD_CHECK(late.offset_x > 0.0f);
  VD_CHECK(near_enough(late.offset_y, 0.0f));

  // Neither end is ever at rest on a clip like this, which is the honest
  // outcome: there was never room for both animations to finish.
  VD_CHECK(vd_anim_at(&anim, 0, SECOND).opacity < 0.1f);
  VD_CHECK(vd_anim_at(&anim, SECOND, SECOND).opacity < 0.1f);
}

static void test_an_animation_longer_than_its_clip_still_ends_somewhere(void) {
  // Nothing clamps the durations down here — the document does that — so this
  // is about not producing nonsense when it has not.
  const VdClipAnim anim = anim_of(VD_ANIM_ZOOM, 10 * SECOND, VD_ANIM_NONE, 0);
  for (int i = 0; i <= 10; i++) {
    const VdAnimValue v = vd_anim_at(&anim, (VdTick)i * SECOND / 10, SECOND);
    VD_CHECK(v.scale > 0.0f && v.scale <= 1.0f);
    VD_CHECK(v.opacity >= 0.0f && v.opacity <= 1.0f);
  }
}

static void test_a_zero_length_animation_is_no_animation(void) {
  // Which is what a preset chosen and then dragged to nothing amounts to, and
  // it must not divide by it.
  const VdClipAnim anim = anim_of(VD_ANIM_POP, 0, VD_ANIM_POP, 0);
  check_is_rest(vd_anim_at(&anim, 0, SECOND), "a zero-length entrance");
  check_is_rest(vd_anim_at(&anim, SECOND, SECOND), "a zero-length exit");
}

static void test_which_animations_touch_the_text(void) {
  // The engine asks this to decide whether a caption's raster can outlive the
  // frame it was drawn for.
  VdClipAnim anim = anim_of(VD_ANIM_TYPEWRITER, SECOND, VD_ANIM_NONE, 0);
  VD_CHECK(vd_anim_reveals_text(&anim));

  anim = anim_of(VD_ANIM_NONE, 0, VD_ANIM_TYPEWRITER, SECOND);
  VD_CHECK(vd_anim_reveals_text(&anim));

  // A typewriter with no time to run in is not a typewriter.
  anim = anim_of(VD_ANIM_TYPEWRITER, 0, VD_ANIM_NONE, 0);
  VD_CHECK(!vd_anim_reveals_text(&anim));

  anim = anim_of(VD_ANIM_POP, SECOND, VD_ANIM_FADE, SECOND);
  VD_CHECK(!vd_anim_reveals_text(&anim));

  const VdClipAnim none = vd_clip_anim_none();
  VD_CHECK(!vd_anim_reveals_text(&none));
  VD_CHECK(!vd_anim_reveals_text(NULL));
}

int main(void) {
  test_the_ends_are_the_ends();
  test_every_preset_starts_away_from_rest();
  test_out_of_range_is_clamped();
  test_a_fade_is_only_opacity();
  test_a_slide_travels_the_way_it_is_named();
  test_only_pop_goes_past_its_resting_size();
  test_a_spin_turns_and_lands_square();
  test_a_typewriter_reveals_and_nothing_else();
  test_a_clip_with_no_animation_never_moves();
  test_the_entrance_owns_the_head_and_nothing_else();
  test_the_exit_is_measured_from_the_far_edge();
  test_both_halves_on_one_clip();
  test_a_clip_too_short_for_both_takes_the_nearer_one();
  test_an_animation_longer_than_its_clip_still_ends_somewhere();
  test_a_zero_length_animation_is_no_animation();
  test_which_animations_touch_the_text();
  return VD_REPORT();
}
