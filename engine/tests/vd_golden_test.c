// Golden frames: whole composited frames, compared against committed
// references pixel for pixel.
//
// vd_compositor_test.c samples points — the centre of the picture, a spot in
// the bar, the corner that should be orange. That catches the failures someone
// thought of in advance. It cannot catch the ones nobody sampled: a seam a few
// pixels wide at a fit boundary, a blur kernel that quietly changed radius, a
// layer that stopped being drawn in a region no probe visits. A golden frame
// asserts on every pixel at once, which is the only assertion that covers the
// parts of the frame the author never considered.
//
// The cost is that a golden fails whenever the picture changes, including when
// it changes for the better. That is the intended trade: an intentional change
// is one command to re-approve (see VD_UPDATE_GOLDENS below), and an
// unintentional one now has to be looked at.
//
//   VD_UPDATE_GOLDENS=1 ctest --test-dir build/engine -R vd_golden_test
//
// rewrites every reference from what the compositor currently produces, and
// then `git diff` shows what actually moved. Approving a golden means looking
// at that diff, not at a number.
#include "vd_check.h"
#include "vdodtor/vd_compositor.h"
#include "vdodtor/vd_decoder.h"

#include <stdlib.h>
#include <sys/stat.h>

#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>
#include <ImageIO/ImageIO.h>

// How far a single channel may drift before the frame counts as changed.
//
// Not zero, and deliberately so. The compositor samples textures with linear
// filtering and blurs in floating point, and neither is promised to give the
// same last bit on two different Apple GPU generations. Four counts absorbs
// that while still being far below the failures worth catching: a wrong YCbCr
// matrix moves green by about 25, a fit rectangle off by a pixel puts a full
// black-to-picture step where it does not belong, and a dropped layer changes
// everything.
#define GOLDEN_CHANNEL_TOLERANCE 4

// And the same again for the frame as a whole, because the per-pixel bound has
// a blind spot: a change that darkens *every* pixel by three counts passes it
// while being obviously a regression. Uniform drift of a single count is the
// most a filtering difference should produce, so this catches anything
// systematic without failing on hardware noise.
#define GOLDEN_MEAN_TOLERANCE 1.0

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

// --- PNG in and out --------------------------------------------------------
// Both directions go through ImageIO in sRGB with alpha skipped, which makes
// them exact inverses: 8-bit sRGB to 8-bit sRGB is a copy, not a conversion,
// and skipping alpha keeps premultiplication out of it entirely. The
// compositor's output is opaque, so nothing is lost by ignoring it — and
// test_the_harness_round_trips below is what proves the pair actually agree
// rather than being wrong in the same direction.

static CFURLRef url_of(const char* path) {
  CFStringRef s = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
  if (!s) return NULL;
  CFURLRef url =
      CFURLCreateWithFileSystemPath(NULL, s, kCFURLPOSIXPathStyle, false);
  CFRelease(s);
  return url;
}

// Reads `path` as tightly packed BGRA. Caller frees. NULL if the file is
// missing or not an image.
static uint8_t* read_png(const char* path, int32_t* out_w, int32_t* out_h) {
  CFURLRef url = url_of(path);
  if (!url) return NULL;
  CGImageSourceRef source = CGImageSourceCreateWithURL(url, NULL);
  CFRelease(url);
  if (!source) return NULL;

  CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
  CFRelease(source);
  if (!image) return NULL;

  const int32_t w = (int32_t)CGImageGetWidth(image);
  const int32_t h = (int32_t)CGImageGetHeight(image);
  uint8_t* pixels = calloc((size_t)w * (size_t)h * 4, 1);
  CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef context = pixels && space
      ? CGBitmapContextCreate(pixels, (size_t)w, (size_t)h, 8, (size_t)w * 4,
                              space, kCGImageAlphaNoneSkipFirst |
                                         kCGBitmapByteOrder32Little)
      : NULL;
  if (context) {
    CGContextDrawImage(context, CGRectMake(0, 0, w, h), image);
    CGContextRelease(context);
  } else {
    free(pixels);
    pixels = NULL;
  }
  if (space) CGColorSpaceRelease(space);
  CGImageRelease(image);

  if (pixels) {
    *out_w = w;
    *out_h = h;
  }
  return pixels;
}

static bool write_png(const char* path, const uint8_t* bgra, int32_t w,
                      int32_t h) {
  CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef context =
      space ? CGBitmapContextCreate((void*)bgra, (size_t)w, (size_t)h, 8,
                                    (size_t)w * 4, space,
                                    kCGImageAlphaNoneSkipFirst |
                                        kCGBitmapByteOrder32Little)
            : NULL;
  CGImageRef image = context ? CGBitmapContextCreateImage(context) : NULL;

  bool ok = false;
  CFURLRef url = url_of(path);
  if (image && url) {
    CGImageDestinationRef dest =
        CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    if (dest) {
      CGImageDestinationAddImage(dest, image, NULL);
      ok = CGImageDestinationFinalize(dest);
      CFRelease(dest);
    }
  }
  if (url) CFRelease(url);
  if (image) CGImageRelease(image);
  if (context) CGContextRelease(context);
  if (space) CGColorSpaceRelease(space);
  return ok;
}

// --- the comparison --------------------------------------------------------

static bool updating(void) {
  const char* v = getenv("VD_UPDATE_GOLDENS");
  return v && *v && strcmp(v, "0") != 0;
}

static void path_in(char* out, size_t cap, const char* dir, const char* name,
                    const char* suffix) {
  snprintf(out, cap, "%s/%s%s.png", dir, name, suffix);
}

// Where the actual frame and an amplified difference go when a golden fails.
// A red CI run that only prints a number tells whoever reads it to reproduce
// the failure locally; one that leaves the two pictures behind does not.
static const char* failure_dir(void) {
  static bool made = false;
  if (!made) {
    mkdir(VD_GOLDEN_OUT_DIR, 0755);
    made = true;
  }
  return VD_GOLDEN_OUT_DIR;
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

// Compares the compositor's last frame against golden/<name>.png.
static void check_golden(VdCompositor* c, const char* name) {
  int32_t w = 0, h = 0;
  uint8_t* actual = frame_pixels(c, &w, &h);
  if (!actual) {
    vd_failures++;
    fprintf(stderr, "FAIL golden %s: could not read the composited frame\n",
            name);
    return;
  }

  char reference_path[1024];
  path_in(reference_path, sizeof(reference_path), VD_GOLDEN_DIR, name, "");

  if (updating()) {
    mkdir(VD_GOLDEN_DIR, 0755);
    vd_checks++;
    if (write_png(reference_path, actual, w, h)) {
      fprintf(stderr, "WROTE golden %s (%dx%d)\n", name, w, h);
    } else {
      vd_failures++;
      fprintf(stderr, "FAIL golden %s: could not write %s\n", name,
              reference_path);
    }
    free(actual);
    return;
  }

  int32_t rw = 0, rh = 0;
  uint8_t* reference = read_png(reference_path, &rw, &rh);
  if (!reference) {
    // A missing reference is a failure, never a pass. A golden suite that goes
    // green with nothing to compare against is worse than no suite at all,
    // because it reports coverage it does not have.
    vd_checks++;
    vd_failures++;
    fprintf(stderr,
            "FAIL golden %s: no reference at %s\n"
            "  run with VD_UPDATE_GOLDENS=1 to create it, then look at it\n",
            name, reference_path);
    free(actual);
    return;
  }

  vd_checks++;
  if (rw != w || rh != h) {
    vd_failures++;
    fprintf(stderr,
            "FAIL golden %s: size changed\n  expected %dx%d\n  actual   %dx%d\n",
            name, rw, rh, w, h);
    free(actual);
    free(reference);
    return;
  }

  int32_t max_delta = 0, worst_x = 0, worst_y = 0;
  int64_t total_delta = 0, differing = 0;
  uint8_t* diff = calloc((size_t)w * h * 4, 1);

  for (int32_t y = 0; y < h; y++) {
    for (int32_t x = 0; x < w; x++) {
      const size_t i = ((size_t)y * w + x) * 4;
      int32_t worst_here = 0;
      for (int ch = 0; ch < 3; ch++) {  // B, G, R — alpha is not stored
        int32_t d = (int32_t)actual[i + ch] - (int32_t)reference[i + ch];
        if (d < 0) d = -d;
        total_delta += d;
        if (d > worst_here) worst_here = d;
      }
      if (worst_here > 0) differing++;
      if (worst_here > max_delta) {
        max_delta = worst_here;
        worst_x = x;
        worst_y = y;
      }
      if (diff) {
        // Amplified 8x and clamped, so a two-count drift is visible to a human
        // rather than being a black rectangle that says "something, somewhere".
        int32_t v = worst_here * 8;
        if (v > 255) v = 255;
        diff[i + 0] = diff[i + 1] = diff[i + 2] = (uint8_t)v;
        diff[i + 3] = 255;
      }
    }
  }

  const double mean_delta = (double)total_delta / ((double)w * h * 3.0);
  const bool ok =
      max_delta <= GOLDEN_CHANNEL_TOLERANCE && mean_delta <= GOLDEN_MEAN_TOLERANCE;

  if (!ok) {
    vd_failures++;
    const size_t worst = ((size_t)worst_y * w + worst_x) * 4;
    fprintf(stderr,
            "FAIL golden %s\n"
            "  max channel delta %d (tolerance %d) at (%d,%d)\n"
            "    expected BGR (%d, %d, %d)\n"
            "    actual   BGR (%d, %d, %d)\n"
            "  mean delta %.3f (tolerance %.3f)\n"
            "  %lld of %lld pixels differ\n",
            name, max_delta, GOLDEN_CHANNEL_TOLERANCE, worst_x, worst_y,
            reference[worst + 0], reference[worst + 1], reference[worst + 2],
            actual[worst + 0], actual[worst + 1], actual[worst + 2], mean_delta,
            GOLDEN_MEAN_TOLERANCE, (long long)differing, (long long)w * h);

    char out[1024];
    const char* dir = failure_dir();
    path_in(out, sizeof(out), dir, name, "-actual");
    if (write_png(out, actual, w, h)) fprintf(stderr, "  wrote %s\n", out);
    if (diff) {
      path_in(out, sizeof(out), dir, name, "-diff");
      if (write_png(out, diff, w, h)) fprintf(stderr, "  wrote %s\n", out);
    }
  }

  free(diff);
  free(actual);
  free(reference);
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
    path_in(path, sizeof(path), failure_dir(), "harness-round-trip", "");
    VD_CHECK_EQ(vd_compositor_dump_png(c, path), VD_OK);

    int32_t rw = 0, rh = 0;
    uint8_t* readback = read_png(path, &rw, &rh);
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

int main(void) {
  test_the_harness_round_trips();
  scene_pattern_contain();
  scene_pattern_blur_fill();
  scene_upright_clip_blur_filled();
  scene_picture_in_picture();
  scene_transform_stack();
  scene_three_layer_blend();
  if (updating()) {
    fprintf(stderr,
            "\nVD_UPDATE_GOLDENS was set: references were REWRITTEN, not\n"
            "checked. This run proves nothing. Look at `git diff` before\n"
            "committing them.\n");
  }
  return VD_REPORT();
}
