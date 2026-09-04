// Golden frames through the compositor: layers built by hand, one composited
// frame out, compared against a committed reference pixel for pixel.
//
// The harness — the PNG round trip, the tolerances and the failure output —
// lives in vd_golden.h, because there is one reference set and two files of
// scenes over it. This one pins the *compositor*: what a fit rectangle looks
// like, what the blur fill puts in the bars, where a transform lands a layer.
// vd_parity_test.c pins the two drivers above it, and the reason the two are
// separate files is that these scenes cost milliseconds and those cost an
// encode.
//
//   VD_UPDATE_GOLDENS=1 ctest --test-dir build/engine -R 'golden|parity'
//
// re-approves both. Approving means reading `git diff` on the PNGs.
#include "vd_golden.h"

#include "vdodtor/vd_compositor.h"
#include "vdodtor/vd_decoder.h"
#include "vdodtor/vd_key.h"

// 30 fps, so frame 10 sits here. Every scene decodes at a fixed tick rather
// than taking whatever frame comes out first: the fixture animates, and a
// golden of "some frame" is a golden of nothing.
#define TICK_FRAME_10 40000

static const char* fixture(const char* name) {
  static char paths[8][1024];
  static int next = 0;
  char* path = paths[next];
  next = (next + 1) % 8;
  snprintf(path, sizeof(paths[0]), "%s/%s", VD_TEST_MEDIA_DIR, name);
  return path;
}

// Copies the last rendered frame out as packed BGRA. Caller frees.
static uint8_t* frame_pixels(VdCompositor* c, int32_t* out_w, int32_t* out_h) {
  const int32_t w = vd_compositor_width(c);
  const int32_t h = vd_compositor_height(c);
  const int64_t bytes = (int64_t)w * h * 4;
  uint8_t* pixels = malloc((size_t)bytes);
  if (!pixels) return NULL;
  if (vd_compositor_copy_pixels(c, pixels, bytes) != VD_OK) {
    free(pixels);
    return NULL;
  }
  *out_w = w;
  *out_h = h;
  return pixels;
}

// This file owns its references, so it is the one allowed to approve them.
static void check_golden(VdCompositor* c, const char* name) {
  int32_t w = 0, h = 0;
  uint8_t* actual = frame_pixels(c, &w, &h);
  vd_golden_check(actual, w, h, name, NULL, VD_GOLDEN_SAME_RENDERER);
  free(actual);
}

// --- scene building --------------------------------------------------------

// The frame covering `t`, not "the first frame". Every scene names its own
// timestamp so the same bytes come out on every run.
static bool frame_at_with_info(const char* name, VdTick t, VdFrame* out,
                               VdProbeInfo* info) {
  VdDecoderOptions options = vd_decoder_default_options();
  int32_t result = 0;
  VdDecoder* d = vd_decoder_open(fixture(name), options, &result);
  if (!d) {
    vd_failures++;
    fprintf(stderr, "FAIL could not open %s (%d)\n", name, result);
    return false;
  }
  if (info) vd_decoder_info(d, info);
  const bool ok = vd_decoder_frame_at(d, t, out) == VD_OK;
  if (!ok) {
    vd_failures++;
    fprintf(stderr, "FAIL could not decode %s at tick %lld\n", name,
            (long long)t);
  }
  vd_decoder_close(d);
  return ok;
}

static bool frame_at(const char* name, VdTick t, VdFrame* out) {
  return frame_at_with_info(name, t, out, NULL);
}

static VdLayer layer_of(const VdFrame* frame, VdFitMode fit, float opacity) {
  VdLayer layer;
  memset(&layer, 0, sizeof(layer));
  layer.pixel_buffer = frame->pixel_buffer;
  layer.format = frame->format;
  layer.color_matrix = frame->color_matrix;
  layer.full_range = frame->full_range;
  layer.fit = fit;
  layer.opacity = opacity;
  return layer;
}

// --- the harness checks itself ---------------------------------------------

// Everything below trusts read_png and write_png to be exact inverses of the
// compositor's own output. If they flipped the picture vertically, or swapped
// red and blue, every golden would still be self-consistent — written wrong,
// read wrong, compared equal — and the whole suite would be green while
// testing nothing. So the pair gets checked against the compositor directly,
// on a scene that is asymmetric in both axes and in colour.
static void test_the_harness_round_trips(void) {
  VdFrame frame;
  if (!frame_at("cfr_30fps_stereo.mp4", TICK_FRAME_10, &frame)) return;

  VdCompositor* c = vd_compositor_create(320, 180, NULL);
  if (c) {
    VdLayer layer = layer_of(&frame, VD_FIT_CONTAIN, 1.0f);
    // Pushed off centre so a vertical or horizontal flip cannot come out
    // looking like the original.
    layer.transform.scale = 0.6f;
    layer.transform.offset_x = 0.2f;
    layer.transform.offset_y = -0.25f;
    VD_CHECK_EQ(vd_compositor_render(c, &layer, 1), VD_OK);

    int32_t w = 0, h = 0;
    uint8_t* expected = frame_pixels(c, &w, &h);

    char path[1024];
    snprintf(path, sizeof(path), "%s/harness-round-trip.png",
             vd_golden_failure_dir());
    VD_CHECK_EQ(vd_compositor_dump_png(c, path), VD_OK);

    int32_t rw = 0, rh = 0;
    uint8_t* readback = vd_golden_read_png(path, &rw, &rh);
    VD_CHECK(readback != NULL);
    VD_CHECK_EQ(rw, w);
    VD_CHECK_EQ(rh, h);

    if (expected && readback && rw == w && rh == h) {
      // PNG is lossless and both ends are 8-bit sRGB, so this one is exact:
      // any difference at all means the two paths disagree about the picture.
      int32_t max_delta = 0;
      int32_t at_x = 0, at_y = 0;
      for (int32_t y = 0; y < h; y++) {
        for (int32_t x = 0; x < w; x++) {
          const size_t i = ((size_t)y * w + x) * 4;
          for (int ch = 0; ch < 3; ch++) {
            int32_t d = (int32_t)expected[i + ch] - (int32_t)readback[i + ch];
            if (d < 0) d = -d;
            if (d > max_delta) {
              max_delta = d;
              at_x = x;
              at_y = y;
            }
          }
        }
      }
      vd_checks++;
      if (max_delta != 0) {
        vd_failures++;
        fprintf(stderr,
                "FAIL the PNG round trip is not exact: delta %d at (%d,%d)\n"
                "  dump_png and copy_pixels disagree, or read_png is not the\n"
                "  inverse of write_png — every golden below is meaningless\n"
                "  until this passes\n",
                max_delta, at_x, at_y);
      }

      // And the picture really is asymmetric, so the check above could have
      // failed. Without this, a black frame would round-trip perfectly and
      // prove nothing.
      const size_t top_right = ((size_t)(h / 4) * w + (w * 3 / 4)) * 4;
      const size_t bottom_left = ((size_t)(h * 3 / 4) * w + (w / 4)) * 4;
      VD_CHECK(memcmp(&expected[top_right], &expected[bottom_left], 3) != 0);
    }

    free(expected);
    free(readback);
    remove(path);
    vd_compositor_destroy(c);
  }
  vd_frame_release(&frame);
}

// --- the scenes ------------------------------------------------------------

// 4:3 in 16:9. Covers a full-colour source through the YCbCr conversion, the
// contain rectangle, and the pillars either side of it.
static void scene_pattern_contain(void) {
  VdFrame frame;
  if (!frame_at("cfr_30fps_stereo.mp4", TICK_FRAME_10, &frame)) return;

  VdCompositor* c = vd_compositor_create(640, 360, NULL);
  if (c) {
    VdLayer layer = layer_of(&frame, VD_FIT_CONTAIN, 1.0f);
    VD_CHECK_EQ(vd_compositor_render(c, &layer, 1), VD_OK);
    check_golden(c, "pattern_contain");
    vd_compositor_destroy(c);
  }
  vd_frame_release(&frame);
}

// The same frame and the same bars, filled instead of black. This is the scene
// a golden earns the most on: the point tests can say the bars are not black
// and that the blur is blurry, but only a whole frame can say it is the *same*
// blur — the same radius, the same downsample, the same cover fit underneath.
static void scene_pattern_blur_fill(void) {
  VdFrame frame;
  if (!frame_at("cfr_30fps_stereo.mp4", TICK_FRAME_10, &frame)) return;

  VdCompositor* c = vd_compositor_create(640, 360, NULL);
  if (c) {
    VdLayer layer = layer_of(&frame, VD_FIT_BLUR, 1.0f);
    VD_CHECK_EQ(vd_compositor_render(c, &layer, 1), VD_OK);
    check_golden(c, "pattern_blur_fill");
    vd_compositor_destroy(c);
  }
  vd_frame_release(&frame);
}

// The shape M2 exits on: a background filling the frame with a small inset
// picture over it. Covers layer order, and the fit-then-scale-then-offset
// order that decides where the inset lands.
static void scene_picture_in_picture(void) {
  VdFrame background, inset;
  if (!frame_at("solid_hd_709.mp4", 0, &background)) return;
  if (!frame_at("cfr_30fps_stereo.mp4", TICK_FRAME_10, &inset)) {
    vd_frame_release(&background);
    return;
  }

  VdCompositor* c = vd_compositor_create(640, 360, NULL);
  if (c) {
    VdLayer layers[2];
    layers[0] = layer_of(&background, VD_FIT_COVER, 1.0f);
    layers[1] = layer_of(&inset, VD_FIT_CONTAIN, 1.0f);
    layers[1].transform.scale = 0.35f;
    layers[1].transform.offset_x = 0.28f;
    layers[1].transform.offset_y = -0.26f;
    VD_CHECK_EQ(vd_compositor_render(c, layers, 2), VD_OK);
    check_golden(c, "picture_in_picture");
    vd_compositor_destroy(c);
  }
  vd_frame_release(&inset);
  vd_frame_release(&background);
}

// A clip shot upright, in a landscape project, with the bars filled — which is
// what happens the first time anyone drops a phone video into a 16:9 timeline,
// and so the single most-seen frame in this file.
//
// It is here because rotation and blur fill meet, and nothing else checks that
// they do. The point tests can say a quarter turn moves the bars to the sides
// and that the bars are not black; only a whole frame can say the backdrop
// behind a *turned* picture is the turned picture — a blur pass that sampled
// the source in its coded orientation would fill the pillars with a sideways
// wash and look, at a glance, entirely convincing.
static void scene_upright_clip_blur_filled(void) {
  VdFrame frame;
  VdProbeInfo info;
  if (!frame_at_with_info("rotated_cw90.mp4", TICK_FRAME_10, &frame, &info)) {
    return;
  }
  VD_CHECK_EQ(info.rotation_degrees, 90);

  VdCompositor* c = vd_compositor_create(640, 360, NULL);
  if (c) {
    VdLayer layer = layer_of(&frame, VD_FIT_BLUR, 1.0f);
    // Read from the file rather than written here: the golden is then a
    // picture of what the container asked for, not of what the test asked for.
    layer.rotation_degrees = info.rotation_degrees;
    VD_CHECK_EQ(vd_compositor_render(c, &layer, 1), VD_OK);
    check_golden(c, "upright_clip_blur_filled");
    vd_compositor_destroy(c);
  }
  vd_frame_release(&frame);
}

// Crop, scale, rotation and flip at once. Each of these has a point test of
// its own; what none of them covers is the *order*, which the header pins down
// and which nothing would notice changing — a rotation applied before the fit
// instead of after still produces a picture, just not this one.
static void scene_transform_stack(void) {
  VdFrame frame;
  if (!frame_at("cfr_30fps_stereo.mp4", TICK_FRAME_10, &frame)) return;

  VdCompositor* c = vd_compositor_create(640, 360, NULL);
  if (c) {
    VdLayer layer = layer_of(&frame, VD_FIT_CONTAIN, 1.0f);
    layer.transform.crop_x = 0.1f;
    layer.transform.crop_y = 0.2f;
    layer.transform.crop_w = 0.6f;
    layer.transform.crop_h = 0.5f;
    layer.transform.scale = 0.8f;
    layer.transform.rotation_degrees = 17.0f;
    layer.transform.offset_x = -0.1f;
    layer.transform.flip_h = true;
    VD_CHECK_EQ(vd_compositor_render(c, &layer, 1), VD_OK);
    check_golden(c, "transform_stack");
    vd_compositor_destroy(c);
  }
  vd_frame_release(&frame);
}

// Three layers, three fits, two of them translucent. Covers the render graph
// and the premultiplied blend where they overlap each other rather than only
// the background.
static void scene_three_layer_blend(void) {
  VdFrame back, middle, front;
  if (!frame_at("solid_hd_709.mp4", 0, &back)) return;
  if (!frame_at("solid_sd_orange.mp4", 0, &middle)) {
    vd_frame_release(&back);
    return;
  }
  if (!frame_at("cfr_30fps_stereo.mp4", TICK_FRAME_10, &front)) {
    vd_frame_release(&middle);
    vd_frame_release(&back);
    return;
  }

  VdCompositor* c = vd_compositor_create(640, 360, NULL);
  if (c) {
    VdLayer layers[3];
    layers[0] = layer_of(&back, VD_FIT_COVER, 1.0f);

    layers[1] = layer_of(&middle, VD_FIT_CONTAIN, 0.5f);
    layers[1].transform.scale = 0.7f;
    layers[1].transform.offset_x = -0.15f;

    layers[2] = layer_of(&front, VD_FIT_CONTAIN, 0.6f);
    layers[2].transform.scale = 0.5f;
    layers[2].transform.offset_x = 0.12f;
    layers[2].transform.offset_y = 0.1f;
    layers[2].transform.rotation_degrees = -8.0f;

    VD_CHECK_EQ(vd_compositor_render(c, layers, 3), VD_OK);
    check_golden(c, "three_layer_blend");
    vd_compositor_destroy(c);
  }
  vd_frame_release(&front);
  vd_frame_release(&middle);
  vd_frame_release(&back);
}


// A green screen keyed over another shot, which is the frame the whole feature
// exists to produce. Point tests can say the middle of the screen went and the
// subject stayed; only a whole frame can say what happened along the *edge*
// between them — where a matte is soft, a despill is doing its work, and 4:2:0
// chroma is half resolution, so the boundary is rebuilt over two pixels and is
// exactly where a change to any of the three would show first.
//
// The plate is 4:3 in a 16:9 output with its fit left at blur fill, so this is
// also the reference for a keyed layer containing rather than filling its bars
// with a blurred copy of the colour being removed.
static void scene_keyed_over_a_background(void) {
  VdFrame background, plate;
  if (!frame_at("cfr_30fps_stereo.mp4", TICK_FRAME_10, &background)) return;
  if (!frame_at("green_screen.mp4", 0, &plate)) {
    vd_frame_release(&background);
    return;
  }

  VdCompositor* c = vd_compositor_create(640, 360, NULL);
  if (c) {
    VdLayer layers[2];
    layers[0] = layer_of(&background, VD_FIT_COVER, 1.0f);
    layers[1] = layer_of(&plate, VD_FIT_BLUR, 1.0f);
    layers[1].key = vd_key_none();
    layers[1].key.color = 0x001F791Du;  // the middle of the screen's gradient
    layers[1].key.tolerance = 0.2f;
    layers[1].key.softness = 0.15f;
    layers[1].key.spill = 1.0f;
    VD_CHECK_EQ(vd_compositor_render(c, layers, 2), VD_OK);
    check_golden(c, "keyed_over_a_background");
    vd_compositor_destroy(c);
  }
  vd_frame_release(&plate);
  vd_frame_release(&background);
}

int main(void) {
  test_the_harness_round_trips();
  scene_pattern_contain();
  scene_pattern_blur_fill();
  scene_upright_clip_blur_filled();
  scene_picture_in_picture();
  scene_transform_stack();
  scene_three_layer_blend();
  scene_keyed_over_a_background();
  vd_golden_epilogue();
  return VD_REPORT();
}
