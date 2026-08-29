// The compositor is checked on pixels. Timings say it ran; only colour says it
// ran correctly, and a wrong YCbCr matrix or a wrong fit rectangle produces
// output that looks entirely plausible until someone compares it to another
// editor.
#include "vd_check.h"
#include "vdodtor/vd_compositor.h"
#include "vdodtor/vd_decoder.h"

#include <stdlib.h>

#include <CoreVideo/CoreVideo.h>

// Rotates through a few buffers, so building a timeline out of two fixture
// paths does not end up with both pointing at the same string.
static const char* fixture(const char* name) {
  static char paths[8][1024];
  static int next = 0;
  char* path = paths[next];
  next = (next + 1) % 8;
  snprintf(path, sizeof(paths[0]), "%s/%s", VD_TEST_MEDIA_DIR, name);
  return path;
}

// The flat colour in solid_sd_601.mp4 and solid_hd_709.mp4, as ffmpeg's own
// decoder renders it. Decoding either with the wrong matrix puts green near
// 175 instead of 200, so this tolerance is tight enough to catch that and
// loose enough to ignore encoder rounding.
#define SOLID_R 0
#define SOLID_G 200
#define SOLID_B 100
#define COLOUR_TOLERANCE 8

static bool near_enough(int actual, int expected) {
  int delta = actual - expected;
  if (delta < 0) delta = -delta;
  return delta <= COLOUR_TOLERANCE;
}

static void check_pixel_is(VdCompositor* c, int32_t x, int32_t y, int r, int g,
                           int b, const char* what) {
  uint8_t bgra[4] = {0, 0, 0, 0};
  if (!vd_compositor_read_pixel(c, x, y, bgra)) {
    vd_failures++;
    fprintf(stderr, "FAIL %s: pixel (%d,%d) out of range\n", what, x, y);
    return;
  }
  vd_checks++;
  if (!near_enough(bgra[2], r) || !near_enough(bgra[1], g) ||
      !near_enough(bgra[0], b)) {
    vd_failures++;
    fprintf(stderr,
            "FAIL %s at (%d,%d)\n  expected RGB (%d, %d, %d)\n"
            "  actual   RGB (%d, %d, %d)\n",
            what, x, y, r, g, b, bgra[2], bgra[1], bgra[0]);
  }
}

// Decodes the first frame of `name` and hands back a layer pointing at it.
// The frame must be released by the caller.
static bool first_frame(const char* name, VdFrame* out) {
  VdDecoderOptions options = vd_decoder_default_options();
  int32_t result = 0;
  VdDecoder* d = vd_decoder_open(fixture(name), options, &result);
  if (!d) {
    vd_failures++;
    fprintf(stderr, "FAIL could not open %s (%d)\n", name, result);
    return false;
  }
  bool ok = vd_decoder_frame_at(d, 0, out) == VD_OK;
  vd_decoder_close(d);
  return ok;
}

static VdLayer layer_of(const VdFrame* frame, VdFitMode fit, float opacity) {
  VdLayer layer;
  memset(&layer, 0, sizeof(layer));
  layer.pixel_buffer = frame->pixel_buffer;
  layer.format = frame->format;
  layer.rotation_degrees = 0;
  layer.color_matrix = frame->color_matrix;
  layer.full_range = frame->full_range;
  layer.fit = fit;
  layer.opacity = opacity;
  return layer;
}

static void test_lifecycle(void) {
  int32_t result = 999;
  VdCompositor* c = vd_compositor_create(640, 360, &result);
  VD_CHECK_EQ(result, VD_OK);
  VD_CHECK(c != NULL);
  if (!c) return;
  VD_CHECK_EQ(vd_compositor_width(c), 640);
  VD_CHECK_EQ(vd_compositor_height(c), 360);
  vd_compositor_destroy(c);

  VD_CHECK(vd_compositor_create(0, 100, &result) == NULL);
  VD_CHECK_EQ(result, VD_ERR_INVALID_ARG);
  VD_CHECK(vd_compositor_create(-4, -4, NULL) == NULL);
  vd_compositor_destroy(NULL);

  VD_CHECK_EQ(vd_compositor_width(NULL), 0);
  VD_CHECK_EQ(vd_compositor_height(NULL), 0);
}

static void test_no_layers_is_black(void) {
  VdCompositor* c = vd_compositor_create(320, 180, NULL);
  if (!c) return;

  VD_CHECK_EQ(vd_compositor_render(c, NULL, 0), VD_OK);
  // A gap in the timeline is black, not transparent and not stale.
  check_pixel_is(c, 0, 0, 0, 0, 0, "empty render, top left");
  check_pixel_is(c, 160, 90, 0, 0, 0, "empty render, centre");
  check_pixel_is(c, 319, 179, 0, 0, 0, "empty render, bottom right");

  uint8_t bgra[4];
  VD_CHECK(vd_compositor_read_pixel(c, 160, 90, bgra));
  VD_CHECK_EQ(bgra[3], 255);  // opaque

  vd_compositor_destroy(c);
}

// The heart of it: a flat colour must come out the colour it went in, from a
// file that says which matrix it used and from one that does not.
static void test_colour_survives_the_round_trip(void) {
  const char* files[] = {"solid_sd_601.mp4", "solid_hd_709.mp4"};
  const VdColorMatrix expected[] = {VD_MATRIX_BT601, VD_MATRIX_BT709};

  for (int i = 0; i < 2; i++) {
    VdFrame frame;
    if (!first_frame(files[i], &frame)) continue;

    // The untagged SD file has to fall back to 601; the tagged HD file must
    // be believed.
    VD_CHECK_EQ(frame.color_matrix, expected[i]);
    VD_CHECK(!frame.full_range);

    VdCompositor* c = vd_compositor_create(320, 180, NULL);
    if (c) {
      VdLayer layer = layer_of(&frame, VD_FIT_STRETCH, 1.0f);
      VD_CHECK_EQ(vd_compositor_render(c, &layer, 1), VD_OK);
      check_pixel_is(c, 160, 90, SOLID_R, SOLID_G, SOLID_B, files[i]);
      check_pixel_is(c, 8, 8, SOLID_R, SOLID_G, SOLID_B, files[i]);
      vd_compositor_destroy(c);
    }
    vd_frame_release(&frame);
  }
}

static void test_contain_letterboxes(void) {
  VdFrame frame;
  if (!first_frame("solid_hd_709.mp4", &frame)) return;  // 16:9

  // Into a square output, 16:9 leaves bars top and bottom.
  VdCompositor* c = vd_compositor_create(400, 400, NULL);
  if (c) {
    VdLayer layer = layer_of(&frame, VD_FIT_CONTAIN, 1.0f);
    VD_CHECK_EQ(vd_compositor_render(c, &layer, 1), VD_OK);

    check_pixel_is(c, 200, 200, SOLID_R, SOLID_G, SOLID_B, "contain centre");
    check_pixel_is(c, 200, 5, 0, 0, 0, "contain top bar");
    check_pixel_is(c, 200, 395, 0, 0, 0, "contain bottom bar");
    // 16:9 in a square is 400x225, so the image spans y 87..312. The sides are
    // full width.
    check_pixel_is(c, 2, 200, SOLID_R, SOLID_G, SOLID_B, "contain left edge");
    check_pixel_is(c, 397, 200, SOLID_R, SOLID_G, SOLID_B, "contain right edge");
    vd_compositor_destroy(c);
  }
  vd_frame_release(&frame);
}

static void test_cover_fills_every_pixel(void) {
  VdFrame frame;
  if (!first_frame("solid_hd_709.mp4", &frame)) return;

  VdCompositor* c = vd_compositor_create(400, 400, NULL);
  if (c) {
    VdLayer layer = layer_of(&frame, VD_FIT_COVER, 1.0f);
    VD_CHECK_EQ(vd_compositor_render(c, &layer, 1), VD_OK);

    // Nothing is left showing through.
    const int32_t probes[][2] = {{2, 2}, {200, 2}, {397, 2},   {2, 200},
                                 {200, 200}, {397, 200}, {2, 397}, {397, 397}};
    for (size_t i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
      check_pixel_is(c, probes[i][0], probes[i][1], SOLID_R, SOLID_G, SOLID_B,
                     "cover fills");
    }
    vd_compositor_destroy(c);
  }
  vd_frame_release(&frame);
}

static void test_stretch_ignores_aspect(void) {
  VdFrame frame;
  if (!first_frame("solid_sd_601.mp4", &frame)) return;

  VdCompositor* c = vd_compositor_create(500, 120, NULL);
  if (c) {
    VdLayer layer = layer_of(&frame, VD_FIT_STRETCH, 1.0f);
    VD_CHECK_EQ(vd_compositor_render(c, &layer, 1), VD_OK);
    check_pixel_is(c, 2, 2, SOLID_R, SOLID_G, SOLID_B, "stretch corner");
    check_pixel_is(c, 497, 117, SOLID_R, SOLID_G, SOLID_B, "stretch corner");
    vd_compositor_destroy(c);
  }
  vd_frame_release(&frame);
}

static void test_rotation_changes_the_fit(void) {
  VdFrame frame;
  if (!first_frame("solid_hd_709.mp4", &frame)) return;  // 1280x720

  VdCompositor* c = vd_compositor_create(400, 400, NULL);
  if (c) {
    VdLayer layer = layer_of(&frame, VD_FIT_CONTAIN, 1.0f);
    layer.rotation_degrees = 90;
    VD_CHECK_EQ(vd_compositor_render(c, &layer, 1), VD_OK);

    // Turned a quarter, a 16:9 source is 9:16, so the bars move to the sides.
    check_pixel_is(c, 200, 200, SOLID_R, SOLID_G, SOLID_B, "rotated centre");
    check_pixel_is(c, 5, 200, 0, 0, 0, "rotated left bar");
    check_pixel_is(c, 395, 200, 0, 0, 0, "rotated right bar");
    check_pixel_is(c, 200, 5, SOLID_R, SOLID_G, SOLID_B, "rotated top edge");
    vd_compositor_destroy(c);
  }
  vd_frame_release(&frame);
}

static void test_opacity_blends_towards_black(void) {
  VdFrame frame;
  if (!first_frame("solid_sd_601.mp4", &frame)) return;

  VdCompositor* c = vd_compositor_create(200, 200, NULL);
  if (c) {
    VdLayer layer = layer_of(&frame, VD_FIT_STRETCH, 0.5f);
    VD_CHECK_EQ(vd_compositor_render(c, &layer, 1), VD_OK);
    // Half opacity over black is half the colour.
    check_pixel_is(c, 100, 100, SOLID_R / 2, SOLID_G / 2, SOLID_B / 2,
                   "half opacity");

    layer.opacity = 0.0f;
    VD_CHECK_EQ(vd_compositor_render(c, &layer, 1), VD_OK);
    check_pixel_is(c, 100, 100, 0, 0, 0, "zero opacity");

    // Out-of-range opacity is clamped, not wrapped.
    layer.opacity = 4.0f;
    VD_CHECK_EQ(vd_compositor_render(c, &layer, 1), VD_OK);
    check_pixel_is(c, 100, 100, SOLID_R, SOLID_G, SOLID_B, "opacity clamped");
    vd_compositor_destroy(c);
  }
  vd_frame_release(&frame);
}

static void test_layers_stack_bottom_to_top(void) {
  VdFrame bottom, top;
  if (!first_frame("solid_sd_601.mp4", &bottom)) return;
  if (!first_frame("cfr_30fps_stereo.mp4", &top)) {
    vd_frame_release(&bottom);
    return;
  }

  VdCompositor* c = vd_compositor_create(300, 300, NULL);
  if (c) {
    // An opaque top layer covering the whole output hides the bottom one.
    VdLayer layers[2] = {layer_of(&bottom, VD_FIT_STRETCH, 1.0f),
                         layer_of(&top, VD_FIT_STRETCH, 1.0f)};
    VD_CHECK_EQ(vd_compositor_render(c, layers, 2), VD_OK);

    uint8_t covered[4];
    VD_CHECK(vd_compositor_read_pixel(c, 150, 150, covered));
    const bool still_solid = near_enough(covered[2], SOLID_R) &&
                             near_enough(covered[1], SOLID_G) &&
                             near_enough(covered[0], SOLID_B);
    VD_CHECK(!still_solid);

    // Make the top layer transparent and the bottom shows through again.
    layers[1].opacity = 0.0f;
    VD_CHECK_EQ(vd_compositor_render(c, layers, 2), VD_OK);
    check_pixel_is(c, 150, 150, SOLID_R, SOLID_G, SOLID_B,
                   "bottom layer through a transparent top");
    vd_compositor_destroy(c);
  }
  vd_frame_release(&bottom);
  vd_frame_release(&top);
}

static void test_a_null_layer_is_skipped_not_crashed(void) {
  VdCompositor* c = vd_compositor_create(160, 160, NULL);
  if (!c) return;

  VdLayer layer;
  memset(&layer, 0, sizeof(layer));
  layer.opacity = 1.0f;  // pixel_buffer is NULL
  VD_CHECK_EQ(vd_compositor_render(c, &layer, 1), VD_OK);
  check_pixel_is(c, 80, 80, 0, 0, 0, "null layer leaves black");

  VD_CHECK_EQ(vd_compositor_render(c, NULL, 3), VD_ERR_INVALID_ARG);
  VD_CHECK_EQ(vd_compositor_render(c, &layer, -1), VD_ERR_INVALID_ARG);
  VD_CHECK_EQ(vd_compositor_render(NULL, &layer, 1), VD_ERR_INVALID_ARG);

  vd_compositor_destroy(c);
}

static void test_output_and_png(void) {
  VdFrame frame;
  if (!first_frame("solid_hd_709.mp4", &frame)) return;

  VdCompositor* c = vd_compositor_create(320, 180, NULL);
  if (c) {
    VdLayer layer = layer_of(&frame, VD_FIT_CONTAIN, 1.0f);
    VD_CHECK_EQ(vd_compositor_render(c, &layer, 1), VD_OK);

    void* output = vd_compositor_copy_output(c);
    VD_CHECK(output != NULL);
    if (output) CFRelease(output);

    VD_CHECK(vd_compositor_last_gpu_ms(c) >= 0.0);
    VD_CHECK(vd_compositor_last_gpu_ms(c) < 500.0);

    const char* png = "/tmp/vd_compositor_test.png";
    VD_CHECK_EQ(vd_compositor_dump_png(c, png), VD_OK);
    FILE* f = fopen(png, "rb");
    VD_CHECK(f != NULL);
    if (f) {
      unsigned char header[8] = {0};
      VD_CHECK_EQ(fread(header, 1, 8, f), 8);
      VD_CHECK_EQ(header[0], 0x89);
      VD_CHECK_EQ(header[1], 'P');
      fclose(f);
      remove(png);
    }

    VD_CHECK_EQ(vd_compositor_dump_png(c, NULL), VD_ERR_INVALID_ARG);
    VD_CHECK_EQ(vd_compositor_dump_png(NULL, png), VD_ERR_INVALID_ARG);
    VD_CHECK(vd_compositor_copy_output(NULL) == NULL);

    uint8_t bgra[4];
    VD_CHECK(!vd_compositor_read_pixel(c, -1, 0, bgra));
    VD_CHECK(!vd_compositor_read_pixel(c, 0, 180, bgra));
    VD_CHECK(!vd_compositor_read_pixel(c, 0, 0, NULL));

    vd_compositor_destroy(c);
  }
  vd_frame_release(&frame);
}

static void test_repeated_renders_stay_correct(void) {
  VdFrame frame;
  if (!first_frame("solid_sd_601.mp4", &frame)) return;

  VdCompositor* c = vd_compositor_create(640, 360, NULL);
  if (c) {
    VdLayer layer = layer_of(&frame, VD_FIT_STRETCH, 1.0f);
    for (int i = 0; i < 300; i++) {
      VD_CHECK_EQ(vd_compositor_render(c, &layer, 1), VD_OK);
    }
    // The 300th frame must be exactly as right as the first: the S1 spike's
    // teardown bug showed up as decay over a run, not as a first-frame error.
    check_pixel_is(c, 320, 180, SOLID_R, SOLID_G, SOLID_B, "after 300 renders");
    vd_compositor_destroy(c);
  }
  vd_frame_release(&frame);
}

static void test_software_frames_composite_the_same(void) {
  VdDecoderOptions options = vd_decoder_default_options();
  options.hardware = 0;
  int32_t result = 0;
  VdDecoder* d =
      vd_decoder_open(fixture("solid_sd_601.mp4"), options, &result);
  if (!d) return;

  VdFrame frame;
  if (vd_decoder_frame_at(d, 0, &frame) == VD_OK) {
    VD_CHECK_EQ(frame.format, VD_PIXEL_YUV420P);
    VdCompositor* c = vd_compositor_create(320, 180, NULL);
    if (c) {
      VdLayer layer = layer_of(&frame, VD_FIT_STRETCH, 1.0f);
      VD_CHECK_EQ(vd_compositor_render(c, &layer, 1), VD_OK);
      // Same colour whichever decoder produced the pixels.
      check_pixel_is(c, 160, 90, SOLID_R, SOLID_G, SOLID_B, "software layer");
      vd_compositor_destroy(c);
    }
    vd_frame_release(&frame);
  }
  vd_decoder_close(d);
}

int main(void) {
  test_lifecycle();
  test_no_layers_is_black();
  test_colour_survives_the_round_trip();
  test_contain_letterboxes();
  test_cover_fills_every_pixel();
  test_stretch_ignores_aspect();
  test_rotation_changes_the_fit();
  test_opacity_blends_towards_black();
  test_layers_stack_bottom_to_top();
  test_a_null_layer_is_skipped_not_crashed();
  test_output_and_png();
  test_repeated_renders_stay_correct();
  test_software_frames_composite_the_same();
  return VD_REPORT();
}
