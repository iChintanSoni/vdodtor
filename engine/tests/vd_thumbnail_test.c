// A thumbnail is a small picture of a file, and the two things that make it
// wrong are silent: the wrong shape (rotation or sample aspect ignored, so
// portrait footage shows up landscape) and the wrong colour (a second imaging
// path that drifted from the compositor's). Both are checked here on pixels.
#include "vd_check.h"
#include "vdodtor/vd_probe.h"
#include "vdodtor/vd_thumbnail.h"

#include <stdlib.h>

static const char* fixture(const char* name) {
  static char path[1024];
  snprintf(path, sizeof(path), "%s/%s", VD_TEST_MEDIA_DIR, name);
  return path;
}

// The flat colour in solid_sd_601.mp4, as ffmpeg's own decoder renders it —
// the same constants vd_compositor_test.c checks against.
#define SOLID_R 0
#define SOLID_G 200
#define SOLID_B 100
#define COLOUR_TOLERANCE 8

static bool near_enough(int actual, int expected) {
  const int delta = actual > expected ? actual - expected : expected - actual;
  return delta <= COLOUR_TOLERANCE;
}

static void check_pixel_is(const VdThumbnail* t, int32_t x, int32_t y, int r,
                           int g, int b, const char* what) {
  vd_checks++;
  if (!t->pixels || x >= t->width || y >= t->height) {
    vd_failures++;
    fprintf(stderr, "FAIL %s: (%d,%d) outside %dx%d\n", what, x, y, t->width,
            t->height);
    return;
  }
  const uint8_t* p = t->pixels + ((size_t)y * t->width + x) * 4;
  if (!near_enough(p[2], r) || !near_enough(p[1], g) ||
      !near_enough(p[0], b)) {
    vd_failures++;
    fprintf(stderr,
            "FAIL %s at (%d,%d)\n  expected RGB (%d, %d, %d)\n"
            "  actual   RGB (%d, %d, %d)\n",
            what, x, y, r, g, b, p[2], p[1], p[0]);
  }
}

// 320x240 square-pixel footage into a 160x160 box is 160x120: the box is a
// bound on both sides, not a size to render at.
static void test_fits_the_box_and_keeps_the_aspect(void) {
  VdThumbnail t;
  VD_CHECK_EQ(
      vd_thumbnail_render(fixture("cfr_30fps_stereo.mp4"), 0, 160, 160, &t),
      VD_OK);
  VD_CHECK_EQ(t.width, 160);
  VD_CHECK_EQ(t.height, 120);
  VD_CHECK(t.pixels != NULL);
  vd_thumbnail_free(&t);

  // A tall, narrow box is bounded by its width instead.
  VD_CHECK_EQ(
      vd_thumbnail_render(fixture("cfr_30fps_stereo.mp4"), 0, 80, 400, &t),
      VD_OK);
  VD_CHECK_EQ(t.width, 80);
  VD_CHECK_EQ(t.height, 60);
  vd_thumbnail_free(&t);
}

// Asking for a bigger picture than the file holds returns the file's size. A
// media bin drawing a 4K asset and a 320x240 one side by side should get a
// sharp small picture, not a blurry big one.
static void test_never_upscales(void) {
  VdThumbnail t;
  VD_CHECK_EQ(
      vd_thumbnail_render(fixture("cfr_30fps_stereo.mp4"), 0, 2000, 2000, &t),
      VD_OK);
  VD_CHECK_EQ(t.width, 320);
  VD_CHECK_EQ(t.height, 240);
  vd_thumbnail_free(&t);
}

// rotated_cw90.mp4 is coded 320x240 and carries a quarter turn, so it is
// portrait on screen and must be portrait in the bin. Getting this wrong is
// the single most visible thumbnail bug there is.
static void test_rotation_is_applied_to_the_shape(void) {
  VdProbeInfo info;
  VD_CHECK_EQ(vd_probe_file(fixture("rotated_cw90.mp4"), &info), VD_OK);
  VD_CHECK_EQ(info.rotation_degrees, 90);

  VdThumbnail t;
  VD_CHECK_EQ(
      vd_thumbnail_render(fixture("rotated_cw90.mp4"), 0, 160, 160, &t),
      VD_OK);
  // 240x320 display size, bounded by the height: 120x160.
  VD_CHECK_EQ(t.width, 120);
  VD_CHECK_EQ(t.height, 160);
  VD_CHECK(t.height > t.width);
  vd_thumbnail_free(&t);
}

// Non-square pixels decide the shape too, and — the part that was wrong — the
// picture has to fill the shape they decided. The box has always been sized
// from the display aspect, so a compositor that fitted the coded size drew a
// 4:3 thumbnail with the picture pillarboxed inside it: right outline, wrong
// contents, in a 60-pixel-wide picture where nobody would ever notice.
static void test_sample_aspect_is_applied_to_the_shape(void) {
  VdThumbnail t;
  VD_CHECK_EQ(
      vd_thumbnail_render(fixture("anamorphic_sar2.mp4"), 0, 160, 160, &t),
      VD_OK);
  // 320x240 on screen from 160x240 coded, bounded by the width: 160x120.
  VD_CHECK_EQ(t.width, 160);
  VD_CHECK_EQ(t.height, 120);
  // And no bars: a box already cut to the source's own shape has nothing left
  // over, so every edge is picture.
  check_pixel_is(&t, 2, 60, SOLID_R, SOLID_G, SOLID_B, "left edge");
  check_pixel_is(&t, 157, 60, SOLID_R, SOLID_G, SOLID_B, "right edge");
  check_pixel_is(&t, 80, 2, SOLID_R, SOLID_G, SOLID_B, "top edge");
  check_pixel_is(&t, 80, 117, SOLID_R, SOLID_G, SOLID_B, "bottom edge");
  vd_thumbnail_free(&t);
}

// The colour has to be the compositor's colour, because the compositor is what
// renders it. If this ever disagrees with vd_compositor_test.c, a second
// imaging path has grown.
static void test_colour_matches_the_compositor(void) {
  VdThumbnail t;
  VD_CHECK_EQ(
      vd_thumbnail_render(fixture("solid_sd_601.mp4"), 0, 128, 128, &t),
      VD_OK);
  VD_CHECK_EQ(t.width, 128);
  VD_CHECK_EQ(t.height, 96);

  check_pixel_is(&t, t.width / 2, t.height / 2, SOLID_R, SOLID_G, SOLID_B,
                 "thumbnail centre");
  // No letterboxing: the box was fitted to the source, so the corners are the
  // picture too.
  check_pixel_is(&t, 0, 0, SOLID_R, SOLID_G, SOLID_B, "thumbnail top left");
  check_pixel_is(&t, t.width - 1, t.height - 1, SOLID_R, SOLID_G, SOLID_B,
                 "thumbnail bottom right");
  vd_thumbnail_free(&t);
}

// Well past the end clamps to the last frame rather than failing — the same
// contract vd_decoder_frame_at has, and the reason a thumbnail can be asked
// for at a time the caller only estimated.
static void test_time_past_the_end_clamps(void) {
  VdThumbnail t;
  VD_CHECK_EQ(vd_thumbnail_render(fixture("solid_sd_601.mp4"),
                                  (VdTick)VD_TICKS_PER_SECOND * 600, 64, 64,
                                  &t),
              VD_OK);
  VD_CHECK(t.pixels != NULL);
  check_pixel_is(&t, t.width / 2, t.height / 2, SOLID_R, SOLID_G, SOLID_B,
                 "clamped to the last frame");
  vd_thumbnail_free(&t);
}

static void test_failures_leave_nothing_behind(void) {
  VdThumbnail t;

  // Audio has no picture, and says so specifically. That is not an error the
  // user should see as a broken import — it is the bin's cue to draw a
  // waveform icon instead, which it can only do if it can tell this apart
  // from a file that would not open.
  memset(&t, 0xAB, sizeof(t));
  VD_CHECK_EQ(vd_thumbnail_render(fixture("audio_only.m4a"), 0, 128, 128, &t),
              VD_ERR_UNSUPPORTED);
  VD_CHECK(t.pixels == NULL);
  VD_CHECK_EQ(t.width, 0);

  memset(&t, 0xAB, sizeof(t));
  VD_CHECK(vd_thumbnail_render(fixture("not_media.txt"), 0, 128, 128, &t) < 0);
  VD_CHECK(t.pixels == NULL);

  memset(&t, 0xAB, sizeof(t));
  VD_CHECK(vd_thumbnail_render(fixture("does_not_exist.mp4"), 0, 128, 128,
                               &t) < 0);
  VD_CHECK(t.pixels == NULL);

  VD_CHECK_EQ(vd_thumbnail_render(NULL, 0, 128, 128, &t), VD_ERR_INVALID_ARG);
  VD_CHECK_EQ(vd_thumbnail_render(fixture("solid_sd_601.mp4"), 0, 0, 128, &t),
              VD_ERR_INVALID_ARG);
  VD_CHECK_EQ(vd_thumbnail_render(fixture("solid_sd_601.mp4"), 0, 128, 128,
                                  NULL),
              VD_ERR_INVALID_ARG);

  // Freeing is safe on a zeroed thumbnail and safe twice.
  memset(&t, 0, sizeof(t));
  vd_thumbnail_free(&t);
  vd_thumbnail_free(&t);
  vd_thumbnail_free(NULL);
}

// A bin scrolling through a folder renders a lot of these. Nothing may be
// retained between calls: the decoder and the compositor are both opened and
// closed inside one.
static void test_many_in_a_row(void) {
  for (int i = 0; i < 24; i++) {
    VdThumbnail t;
    if (vd_thumbnail_render(fixture("solid_sd_601.mp4"),
                            (VdTick)VD_TICKS_PER_SECOND * i / 30, 96, 96,
                            &t) == VD_OK) {
      vd_thumbnail_free(&t);
    } else {
      VD_CHECK(false);
    }
  }
  // The 24th is as right as the first.
  VdThumbnail t;
  VD_CHECK_EQ(vd_thumbnail_render(fixture("solid_sd_601.mp4"), 0, 96, 96, &t),
              VD_OK);
  check_pixel_is(&t, 10, 10, SOLID_R, SOLID_G, SOLID_B, "after 24 thumbnails");
  vd_thumbnail_free(&t);
}

int main(void) {
  test_fits_the_box_and_keeps_the_aspect();
  test_never_upscales();
  test_rotation_is_applied_to_the_shape();
  test_sample_aspect_is_applied_to_the_shape();
  test_colour_matches_the_compositor();
  test_time_past_the_end_clamps();
  test_failures_leave_nothing_behind();
  test_many_in_a_row();
  return VD_REPORT();
}
