// Golden frames: a whole picture, compared against a committed reference.
//
// The point tests sample. vd_compositor_test.c asks about the centre of the
// picture, a spot in the bar, the corner that should be orange — which catches
// the failures someone thought of in advance and cannot catch the ones nobody
// sampled: a seam a few pixels wide at a fit boundary, a blur kernel that
// quietly changed radius, a layer that stopped being drawn in a region no probe
// visits. A golden frame asserts on every pixel at once, which is the only
// assertion that covers the parts of the frame the author never considered.
//
// The cost is that a golden fails whenever the picture changes, including when
// it changes for the better. That is the intended trade: an intentional change
// is one command to re-approve,
//
//   VD_UPDATE_GOLDENS=1 ctest --test-dir build/engine -R 'golden|parity'
//
// which rewrites every reference from what the renderer currently produces, and
// then `git diff` shows what actually moved. Approving a golden means looking
// at that diff, not at a number.
//
// This header is the harness rather than the scenes, because there are two
// files of scenes and one reference set. vd_golden_test.c pins the compositor
// with layers it builds by hand; vd_parity_test.c pins the two *drivers* over
// it — the preview clock and the export clock — against one reference each, so
// a divergence between them has nowhere to hide. A reference belongs to
// exactly one driver, which is the one allowed to approve it; every other
// driver is measured against a picture it did not write. See `through`.
#ifndef VD_GOLDEN_H
#define VD_GOLDEN_H

#include "vd_check.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>

// How far two renderings of the same picture may be apart.
//
// Three numbers rather than one, because a single bound cannot express both
// of the questions worth asking. `channel` and `outliers` together say "no
// pixel is badly wrong, except for at most this few"; `mean` says "and the
// frame as a whole did not drift". Either alone has a blind spot: a bound on
// the worst pixel passes a frame darkened by three counts everywhere, and a
// bound on the average passes a frame with a hole in it.
typedef struct {
  // A channel may differ by this much...
  int32_t channel;
  // ...on at most this fraction of the frame's pixels. 0 allows none, which
  // makes `channel` a hard bound on the worst pixel in the picture.
  double outliers;
  // And the mean absolute channel delta over the whole frame must be under
  // this.
  double mean;
} VdGoldenTolerance;

// Two renderings by the same code on the same machine.
//
// Not zero, and deliberately so. The compositor samples textures with linear
// filtering and blurs in floating point, and neither is promised to give the
// same last bit on two different Apple GPU generations. Four counts absorbs
// that while still being far below the failures worth catching: a wrong YCbCr
// matrix moves green by about 25, a fit rectangle off by a pixel puts a full
// black-to-picture step where it does not belong, and a dropped layer changes
// everything. Uniform drift of a single count is the most a filtering
// difference should produce, so the mean bound catches anything systematic
// without failing on hardware noise.
#define VD_GOLDEN_SAME_RENDERER \
  ((VdGoldenTolerance){.channel = 4, .outliers = 0.0, .mean = 1.0})

// What a comparison found. Every field is reported on a failure, because the
// first question about a red golden is which kind of wrong it is: a max delta
// with almost no pixels behind it is a seam, a mean delta with every pixel
// behind it is a shift, and both at once is a different picture.
typedef struct {
  int32_t max;         // the worst channel delta anywhere in the frame
  int32_t at_x, at_y;  // and where it was
  int64_t over;        // pixels whose worst channel is past tolerance.channel
  int64_t differing;   // pixels that differ at all
  double outlier_ratio;
  double mean;
  bool ok;
} VdGoldenDelta;

// Compares two packed BGRA frames. Alpha is not looked at: everything compared
// here is opaque, and the PNG the reference lives in does not store it.
//
// `out_diff`, when given, is filled with the per-pixel difference amplified 8x
// and clamped — so a two-count drift is visible to a human rather than being a
// black rectangle that says "something, somewhere". It must be w * h * 4 bytes.
static inline VdGoldenDelta vd_golden_measure(const uint8_t* actual,
                                              const uint8_t* reference,
                                              int32_t w, int32_t h,
                                              VdGoldenTolerance tolerance,
                                              uint8_t* out_diff) {
  VdGoldenDelta delta;
  memset(&delta, 0, sizeof(delta));
  int64_t total = 0;

  for (int32_t y = 0; y < h; y++) {
    for (int32_t x = 0; x < w; x++) {
      const size_t i = ((size_t)y * w + x) * 4;
      int32_t worst = 0;
      for (int ch = 0; ch < 3; ch++) {  // B, G, R
        int32_t d = (int32_t)actual[i + ch] - (int32_t)reference[i + ch];
        if (d < 0) d = -d;
        total += d;
        if (d > worst) worst = d;
      }
      if (worst > 0) delta.differing++;
      if (worst > tolerance.channel) delta.over++;
      if (worst > delta.max) {
        delta.max = worst;
        delta.at_x = x;
        delta.at_y = y;
      }
      if (out_diff) {
        int32_t v = worst * 8;
        if (v > 255) v = 255;
        out_diff[i + 0] = out_diff[i + 1] = out_diff[i + 2] = (uint8_t)v;
        out_diff[i + 3] = 255;
      }
    }
  }

  const double pixels = (double)w * (double)h;
  delta.mean = (double)total / (pixels * 3.0);
  delta.outlier_ratio = (double)delta.over / pixels;
  delta.ok = delta.outlier_ratio <= tolerance.outliers &&
             delta.mean <= tolerance.mean;
  return delta;
}

// How a failed comparison reads. `what` names the two things being compared.
static inline void vd_golden_report(const VdGoldenDelta* delta,
                                    const uint8_t* actual,
                                    const uint8_t* reference, int32_t w,
                                    VdGoldenTolerance tolerance,
                                    const char* what) {
  const size_t worst = ((size_t)delta->at_y * w + delta->at_x) * 4;
  fprintf(stderr,
          "FAIL %s\n"
          "  max channel delta %d at (%d,%d)\n"
          "    expected BGR (%d, %d, %d)\n"
          "    actual   BGR (%d, %d, %d)\n"
          "  %lld pixels past %d (%.4f, tolerance %.4f)\n"
          "  mean delta %.3f (tolerance %.3f)\n"
          "  %lld pixels differ at all\n",
          what, delta->max, delta->at_x, delta->at_y, reference[worst + 0],
          reference[worst + 1], reference[worst + 2], actual[worst + 0],
          actual[worst + 1], actual[worst + 2], (long long)delta->over,
          tolerance.channel, delta->outlier_ratio, tolerance.outliers,
          delta->mean, tolerance.mean, (long long)delta->differing);
}

// --- PNG in and out --------------------------------------------------------
// Both directions go through ImageIO in sRGB with alpha skipped, which makes
// them exact inverses: 8-bit sRGB to 8-bit sRGB is a copy, not a conversion,
// and skipping alpha keeps premultiplication out of it entirely. Every frame
// compared here is opaque, so nothing is lost by ignoring it — and
// vd_golden_test.c's harness round trip is what proves the pair actually agree
// rather than being wrong in the same direction.

static inline CFURLRef vd_golden_url(const char* path) {
  CFStringRef s = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
  if (!s) return NULL;
  CFURLRef url =
      CFURLCreateWithFileSystemPath(NULL, s, kCFURLPOSIXPathStyle, false);
  CFRelease(s);
  return url;
}

// Reads `path` as tightly packed BGRA. Caller frees. NULL if the file is
// missing or not an image.
static inline uint8_t* vd_golden_read_png(const char* path, int32_t* out_w,
                                          int32_t* out_h) {
  CFURLRef url = vd_golden_url(path);
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

static inline bool vd_golden_write_png(const char* path, const uint8_t* bgra,
                                       int32_t w, int32_t h) {
  CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef context =
      space ? CGBitmapContextCreate((void*)bgra, (size_t)w, (size_t)h, 8,
                                    (size_t)w * 4, space,
                                    kCGImageAlphaNoneSkipFirst |
                                        kCGBitmapByteOrder32Little)
            : NULL;
  CGImageRef image = context ? CGBitmapContextCreateImage(context) : NULL;

  bool ok = false;
  CFURLRef url = vd_golden_url(path);
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

static inline bool vd_golden_updating(void) {
  const char* v = getenv("VD_UPDATE_GOLDENS");
  return v && *v && strcmp(v, "0") != 0;
}

// Where the actual frame and an amplified difference go when a golden fails.
// A red CI run that only prints a number tells whoever reads it to reproduce
// the failure locally; one that leaves the two pictures behind does not.
static inline const char* vd_golden_failure_dir(void) {
  static bool made = false;
  if (!made) {
    mkdir(VD_GOLDEN_OUT_DIR, 0755);
    made = true;
  }
  return VD_GOLDEN_OUT_DIR;
}

// Compares packed BGRA against golden/<name>.png.
//
// `through` names the driver this frame came from, and decides which of the
// two jobs this call does. NULL means the driver the reference *belongs* to:
// under VD_UPDATE_GOLDENS it rewrites the file, and its failures are written
// out under the golden's own name. Any other name is a second driver being
// held to a reference it does not own — it never writes one, and it says which
// driver it was in both the message and the files it leaves behind. That is
// what makes a parity failure legible: "the export disagrees with the picture
// the preview approved" reads differently from "the picture changed".
static inline void vd_golden_check(const uint8_t* actual, int32_t w, int32_t h,
                                   const char* name, const char* through,
                                   VdGoldenTolerance tolerance) {
  if (!actual) {
    vd_checks++;
    vd_failures++;
    fprintf(stderr, "FAIL golden %s: no frame to compare\n", name);
    return;
  }

  char reference_path[1024];
  snprintf(reference_path, sizeof(reference_path), "%s/%s.png", VD_GOLDEN_DIR,
           name);

  if (!through && vd_golden_updating()) {
    mkdir(VD_GOLDEN_DIR, 0755);
    vd_checks++;
    if (vd_golden_write_png(reference_path, actual, w, h)) {
      fprintf(stderr, "WROTE golden %s (%dx%d)\n", name, w, h);
    } else {
      vd_failures++;
      fprintf(stderr, "FAIL golden %s: could not write %s\n", name,
              reference_path);
    }
    return;
  }

  int32_t rw = 0, rh = 0;
  uint8_t* reference = vd_golden_read_png(reference_path, &rw, &rh);
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
    return;
  }

  vd_checks++;
  if (rw != w || rh != h) {
    vd_failures++;
    fprintf(stderr,
            "FAIL golden %s: size changed\n  expected %dx%d\n  actual   %dx%d\n",
            name, rw, rh, w, h);
    free(reference);
    return;
  }

  uint8_t* diff = calloc((size_t)w * h * 4, 1);
  const VdGoldenDelta delta =
      vd_golden_measure(actual, reference, w, h, tolerance, diff);

  if (!delta.ok) {
    vd_failures++;
    char what[1024];
    snprintf(what, sizeof(what), "golden %s%s%s", name,
             through ? " through the " : "", through ? through : "");
    vd_golden_report(&delta, actual, reference, w, tolerance, what);

    char out[1024];
    const char* dir = vd_golden_failure_dir();
    const char* tag = through ? through : "";
    snprintf(out, sizeof(out), "%s/%s%s%s-actual.png", dir, name,
             through ? "-" : "", tag);
    if (vd_golden_write_png(out, actual, w, h)) fprintf(stderr, "  wrote %s\n", out);
    if (diff) {
      snprintf(out, sizeof(out), "%s/%s%s%s-diff.png", dir, name,
               through ? "-" : "", tag);
      if (vd_golden_write_png(out, diff, w, h)) fprintf(stderr, "  wrote %s\n", out);
    }
  }

  free(diff);
  free(reference);
}

// Printed at the end of a run that was approving rather than checking, because
// a green bar after VD_UPDATE_GOLDENS means nothing and looks like it means
// everything.
static inline void vd_golden_epilogue(void) {
  if (!vd_golden_updating()) return;
  fprintf(stderr,
          "\nVD_UPDATE_GOLDENS was set: references were REWRITTEN, not\n"
          "checked. This run proves nothing. Look at `git diff` before\n"
          "committing them.\n");
}

#endif  // VD_GOLDEN_H
