// Text, checked on the pixels it produces.
//
// Deliberately not a golden frame. The compositor is pinned by goldens because
// its output is arithmetic on textures, and two Apple GPUs agree on that to
// within a count or two. Glyph rasterisation is not: hinting, stem darkening
// and subpixel positioning are the parts of Core Text most likely to be
// tuned in a macOS release, and a reference PNG of a sentence would go red on
// an OS upgrade while the renderer was still perfectly correct.
//
// So the assertions here are about *where the ink is*, not which pixels it
// covers. Every one of them is a property that has to survive any amount of
// rasteriser drift and that breaks the moment the layout is wrong: alignment
// moves the block, letter spacing widens it, line spacing heightens it, the
// box sits behind it, the shadow falls below and to the right of it. That is
// the whole of what this file can be wrong about.
#include "vd_check.h"
#include "vdodtor/vd_probe.h"
#include "vdodtor/vd_text.h"

#include <math.h>
#include <stdlib.h>

#include <CoreVideo/CoreVideo.h>

#define WIDTH 640
#define HEIGHT 360

// --- reading a raster ------------------------------------------------------

// Where the ink is, in pixels, origin top left. Empty when nothing was drawn.
typedef struct {
  int32_t left, top, right, bottom;
  int64_t coverage;  // sum of alpha over the frame
  bool empty;
} Ink;

static int32_t ink_width(const Ink* ink) {
  return ink->empty ? 0 : ink->right - ink->left + 1;
}
static int32_t ink_height(const Ink* ink) {
  return ink->empty ? 0 : ink->bottom - ink->top + 1;
}
static int32_t ink_centre_x(const Ink* ink) {
  return ink->empty ? 0 : (ink->left + ink->right) / 2;
}
static int32_t ink_centre_y(const Ink* ink) {
  return ink->empty ? 0 : (ink->top + ink->bottom) / 2;
}

// Anything faint enough to be antialiasing rather than a mark someone would
// see. Measuring the bounds against a threshold rather than against zero is
// what makes the numbers below stable across rasterisers.
#define INK_THRESHOLD 40

static Ink measure(CVPixelBufferRef buffer) {
  Ink ink = {0, 0, 0, 0, 0, true};
  if (!buffer) return ink;

  CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
  const uint8_t* base = (const uint8_t*)CVPixelBufferGetBaseAddress(buffer);
  const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
  const int32_t w = (int32_t)CVPixelBufferGetWidth(buffer);
  const int32_t h = (int32_t)CVPixelBufferGetHeight(buffer);

  for (int32_t y = 0; y < h; y++) {
    const uint8_t* row = base + (size_t)y * stride;
    for (int32_t x = 0; x < w; x++) {
      const uint8_t alpha = row[(size_t)x * 4 + 3];
      ink.coverage += alpha;
      if (alpha < INK_THRESHOLD) continue;
      if (ink.empty) {
        ink.left = ink.right = x;
        ink.top = ink.bottom = y;
        ink.empty = false;
        continue;
      }
      if (x < ink.left) ink.left = x;
      if (x > ink.right) ink.right = x;
      if (y < ink.top) ink.top = y;
      if (y > ink.bottom) ink.bottom = y;
    }
  }
  CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
  return ink;
}

// BGRA, straight out of the buffer.
static void pixel_at(CVPixelBufferRef buffer, int32_t x, int32_t y,
                     uint8_t out[4]) {
  CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
  const uint8_t* base = (const uint8_t*)CVPixelBufferGetBaseAddress(buffer);
  const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
  memcpy(out, base + (size_t)y * stride + (size_t)x * 4, 4);
  CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
}

static CVPixelBufferRef render(const VdTextSpec* spec) {
  int32_t result = VD_OK;
  CVPixelBufferRef buffer =
      (CVPixelBufferRef)vd_text_render(spec, WIDTH, HEIGHT, &result);
  VD_CHECK_EQ(result, VD_OK);
  VD_CHECK(buffer != NULL);
  return buffer;
}

static VdTextSpec caption(const char* text) {
  VdTextSpec spec = vd_text_spec_default();
  spec.text = text;
  spec.font = "Inter";
  return spec;
}

// --- fonts -----------------------------------------------------------------

static bool register_bundled(const char* file) {
  char path[1024];
  snprintf(path, sizeof(path), "%s/%s", VD_FONT_DIR, file);
  FILE* f = fopen(path, "rb");
  if (!f) {
    fprintf(stderr, "no font at %s\n", path);
    return false;
  }
  fseek(f, 0, SEEK_END);
  const long size = ftell(f);
  fseek(f, 0, SEEK_SET);
  void* data = malloc((size_t)size);
  const bool read = data && fread(data, 1, (size_t)size, f) == (size_t)size;
  fclose(f);
  const bool ok = read && vd_text_register_font(data, size) == VD_OK;
  free(data);
  return ok;
}

// The app ships these five and writes the family names down a second time, in
// `BundledFonts.faces` in app/lib/media/fonts.dart, because a font picker has
// to list the faces before an engine exists to ask — a widget test has none at
// all. This is the check on that copy: what each file actually calls itself.
//
// Getting it wrong is silent. A caption asking for a family nothing is
// registered under falls back to the system's face and draws perfectly well in
// the wrong one, which looks like somebody's decision rather than a bug.
static const struct {
  const char* file;
  const char* family;
} kBundled[] = {
    {"Inter.ttf", "Inter"},
    {"Anton.ttf", "Anton"},
    {"PlayfairDisplay.ttf", "Playfair Display"},
    {"Caveat.ttf", "Caveat"},
    {"SpaceMono.ttf", "Space Mono"},
};
#define BUNDLED_COUNT (sizeof(kBundled) / sizeof(kBundled[0]))

static void test_the_bundled_fonts_register(void) {
  for (size_t i = 0; i < BUNDLED_COUNT; i++) {
    VD_CHECK(register_bundled(kBundled[i].file));
  }

  // The catalogue is what the files call themselves, not what they are
  // called on disk — a spec asks for a family, and the family is the only
  // name that survives being renamed.
  for (size_t i = 0; i < BUNDLED_COUNT; i++) {
    bool found = false;
    for (int32_t j = 0; j < vd_text_font_count(); j++) {
      const char* name = vd_text_font_name(j);
      if (name && strcmp(name, kBundled[i].family) == 0) found = true;
    }
    vd_checks++;
    if (!found) {
      vd_failures++;
      fprintf(stderr, "FAIL %s does not report the family \"%s\"\n",
              kBundled[i].file, kBundled[i].family);
    }
  }

  // Registered in the order they were handed over, which is the order a font
  // picker offers them in.
  VD_CHECK_EQ(vd_text_font_count(), (int32_t)BUNDLED_COUNT);
  for (size_t i = 0; i < BUNDLED_COUNT; i++) {
    VD_CHECK_STR(vd_text_font_name((int32_t)i), kBundled[i].family);
  }

  // Registering the same face again is what happens when the app restarts an
  // engine. It succeeds, and it does not list the family twice.
  const int32_t before = vd_text_font_count();
  VD_CHECK(register_bundled("Inter.ttf"));
  VD_CHECK_EQ(vd_text_font_count(), before);

  VD_CHECK_EQ(vd_text_register_font(NULL, 0), VD_ERR_INVALID_ARG);
  VD_CHECK_EQ(vd_text_register_font("not a font", 10), VD_ERR_UNSUPPORTED);
}

static void test_an_unknown_family_still_draws(void) {
  // A project made with a pack installed has to open on a machine without it,
  // showing the words in some other face rather than showing nothing.
  VdTextSpec spec = caption("Fallback");
  spec.font = "No Such Family At All";
  CVPixelBufferRef buffer = render(&spec);
  const Ink ink = measure(buffer);
  VD_CHECK(!ink.empty);
  CVPixelBufferRelease(buffer);
}

// --- the empty cases -------------------------------------------------------

static void test_nothing_typed_draws_nothing(void) {
  VdTextSpec spec = caption("");
  CVPixelBufferRef buffer = render(&spec);
  Ink ink = measure(buffer);
  VD_CHECK(ink.empty);
  // And it is *transparent*, not black: a caption nobody has typed into must
  // not black out the picture underneath it.
  VD_CHECK_EQ(ink.coverage, 0);
  CVPixelBufferRelease(buffer);

  spec.text = NULL;
  buffer = render(&spec);
  ink = measure(buffer);
  VD_CHECK(ink.empty);
  CVPixelBufferRelease(buffer);
}

static void test_bad_arguments_are_refused(void) {
  VdTextSpec spec = caption("x");
  int32_t result = VD_OK;
  VD_CHECK(vd_text_render(&spec, 0, HEIGHT, &result) == NULL);
  VD_CHECK_EQ(result, VD_ERR_INVALID_ARG);
  VD_CHECK(vd_text_render(NULL, WIDTH, HEIGHT, &result) == NULL);
  VD_CHECK_EQ(result, VD_ERR_INVALID_ARG);
}

// --- layout ----------------------------------------------------------------

static void test_a_line_is_centred_in_the_frame(void) {
  VdTextSpec spec = caption("Centre");
  CVPixelBufferRef buffer = render(&spec);
  const Ink ink = measure(buffer);
  VD_CHECK(!ink.empty);

  // Within a few pixels: the block is centred on its typographic bounds, and
  // the ink of a particular word is not perfectly symmetric inside those.
  VD_CHECK(abs(ink_centre_x(&ink) - WIDTH / 2) <= 8);
  VD_CHECK(abs(ink_centre_y(&ink) - HEIGHT / 2) <= 8);
  CVPixelBufferRelease(buffer);
}

static void test_alignment_moves_a_single_line(void) {
  // The case that decides the whole layout: a text box that hugged the words
  // would leave "align left" doing nothing at all to one line, which is when
  // it is asked for most. The block is laid out in a box as wide as wrapping
  // allows, so alignment has somewhere to move the line to.
  VdTextSpec spec = caption("Edge");

  spec.align = VD_TEXT_ALIGN_LEFT;
  CVPixelBufferRef left_buffer = render(&spec);
  const Ink left = measure(left_buffer);

  spec.align = VD_TEXT_ALIGN_CENTER;
  CVPixelBufferRef centre_buffer = render(&spec);
  const Ink centre = measure(centre_buffer);

  spec.align = VD_TEXT_ALIGN_RIGHT;
  CVPixelBufferRef right_buffer = render(&spec);
  const Ink right = measure(right_buffer);

  VD_CHECK(!left.empty && !centre.empty && !right.empty);
  VD_CHECK(left.left < centre.left);
  VD_CHECK(centre.left < right.left);
  // The same words, so the same amount of ink wherever it lands.
  VD_CHECK(abs(ink_width(&left) - ink_width(&right)) <= 2);
  // And the margin the default max width leaves is real.
  VD_CHECK(left.left > 0);
  VD_CHECK(right.right < WIDTH - 1);

  CVPixelBufferRelease(left_buffer);
  CVPixelBufferRelease(centre_buffer);
  CVPixelBufferRelease(right_buffer);
}

static void test_size_is_a_fraction_of_the_output(void) {
  VdTextSpec small = caption("Height");
  small.size = 0.06f;
  VdTextSpec large = small;
  large.size = 0.12f;

  CVPixelBufferRef a = render(&small);
  CVPixelBufferRef b = render(&large);
  const Ink small_ink = measure(a);
  const Ink large_ink = measure(b);
  VD_CHECK(!small_ink.empty && !large_ink.empty);

  // Twice the size, twice the ink in each direction — within the slop a
  // hinted rasteriser is allowed at these sizes.
  const double height_ratio =
      (double)ink_height(&large_ink) / (double)ink_height(&small_ink);
  const double width_ratio =
      (double)ink_width(&large_ink) / (double)ink_width(&small_ink);
  VD_CHECK(height_ratio > 1.8 && height_ratio < 2.2);
  VD_CHECK(width_ratio > 1.8 && width_ratio < 2.2);

  CVPixelBufferRelease(a);
  CVPixelBufferRelease(b);
}

static void test_letter_spacing_widens_without_heightening(void) {
  VdTextSpec tight = caption("SPACING");
  VdTextSpec loose = tight;
  loose.letter_spacing = 0.2f;

  CVPixelBufferRef a = render(&tight);
  CVPixelBufferRef b = render(&loose);
  const Ink tight_ink = measure(a);
  const Ink loose_ink = measure(b);

  VD_CHECK(ink_width(&loose_ink) > ink_width(&tight_ink));
  VD_CHECK(abs(ink_height(&loose_ink) - ink_height(&tight_ink)) <= 2);
  // Still centred: tracking grows the line about its middle, not off one end.
  VD_CHECK(abs(ink_centre_x(&loose_ink) - ink_centre_x(&tight_ink)) <= 12);

  CVPixelBufferRelease(a);
  CVPixelBufferRelease(b);
}

static void test_line_spacing_heightens_without_widening(void) {
  VdTextSpec single = caption("Two\nLines");
  VdTextSpec doubled = single;
  doubled.line_spacing = 2.0f;

  CVPixelBufferRef a = render(&single);
  CVPixelBufferRef b = render(&doubled);
  const Ink single_ink = measure(a);
  const Ink doubled_ink = measure(b);

  VD_CHECK(ink_height(&doubled_ink) > ink_height(&single_ink));
  VD_CHECK(abs(ink_width(&doubled_ink) - ink_width(&single_ink)) <= 2);
  // Both blocks stay centred on the frame, so the extra space is shared
  // between the top and the bottom rather than pushing the words downwards.
  VD_CHECK(abs(ink_centre_y(&doubled_ink) - HEIGHT / 2) <= 10);

  CVPixelBufferRelease(a);
  CVPixelBufferRelease(b);
}

static void test_a_long_line_wraps_inside_the_frame(void) {
  VdTextSpec spec = caption(
      "A caption long enough that it cannot possibly fit on one line of a "
      "frame this wide, and so has to wrap");
  CVPixelBufferRef buffer = render(&spec);
  const Ink ink = measure(buffer);

  VD_CHECK(!ink.empty);
  // Inside the margin the default max width asks for, on both edges.
  VD_CHECK(ink.left >= (int32_t)(WIDTH * 0.04));
  VD_CHECK(ink.right <= (int32_t)(WIDTH * 0.96));
  // And it wrapped rather than being clipped: several lines tall.
  VD_CHECK(ink_height(&ink) > (int32_t)(HEIGHT * 0.08f * 2));

  CVPixelBufferRelease(buffer);
}

static void test_max_width_is_the_thing_that_wraps(void) {
  const char* words = "one two three four five six seven eight nine ten";
  VdTextSpec wide = caption(words);
  VdTextSpec narrow = wide;
  narrow.max_width = 0.4f;

  CVPixelBufferRef a = render(&wide);
  CVPixelBufferRef b = render(&narrow);
  const Ink wide_ink = measure(a);
  const Ink narrow_ink = measure(b);

  VD_CHECK(ink_width(&narrow_ink) < ink_width(&wide_ink));
  VD_CHECK(ink_width(&narrow_ink) <= (int32_t)(WIDTH * 0.4) + 2);
  // Narrower means more lines, so the same words are taller.
  VD_CHECK(ink_height(&narrow_ink) > ink_height(&wide_ink));

  CVPixelBufferRelease(a);
  CVPixelBufferRelease(b);
}

// --- ink -------------------------------------------------------------------

static void test_the_fill_colour_is_the_one_asked_for(void) {
  VdTextSpec spec = caption("Solid");
  spec.color = 0xFFFF0000u;  // opaque red
  CVPixelBufferRef buffer = render(&spec);
  const Ink ink = measure(buffer);
  VD_CHECK(!ink.empty);

  // The densest pixel in the block, which for a solid fill is fully opaque
  // and therefore exactly the colour that was asked for. Premultiplied, so
  // an opaque red is (0, 0, 255) in BGR.
  uint8_t best[4] = {0, 0, 0, 0};
  CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
  const uint8_t* base = (const uint8_t*)CVPixelBufferGetBaseAddress(buffer);
  const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
  for (int32_t y = ink.top; y <= ink.bottom; y++) {
    const uint8_t* row = base + (size_t)y * stride;
    for (int32_t x = ink.left; x <= ink.right; x++) {
      if (row[(size_t)x * 4 + 3] > best[3]) memcpy(best, row + (size_t)x * 4, 4);
    }
  }
  CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);

  VD_CHECK_EQ(best[3], 255);
  VD_CHECK(best[2] > 245);  // red
  VD_CHECK(best[1] < 10);   // green
  VD_CHECK(best[0] < 10);   // blue
  CVPixelBufferRelease(buffer);
}

static void test_the_raster_is_premultiplied(void) {
  // The compositor's texture pass assumes it. Straight alpha would show up as
  // haloed edges over a dark background and nowhere else, which is the kind
  // of bug that ships.
  VdTextSpec spec = caption("Edges");
  spec.color = 0xFFFFFFFFu;
  CVPixelBufferRef buffer = render(&spec);

  int32_t violations = 0;
  CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
  const uint8_t* base = (const uint8_t*)CVPixelBufferGetBaseAddress(buffer);
  const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
  for (int32_t y = 0; y < HEIGHT; y++) {
    const uint8_t* row = base + (size_t)y * stride;
    for (int32_t x = 0; x < WIDTH; x++) {
      const uint8_t* p = row + (size_t)x * 4;
      // No channel may exceed alpha; that is what premultiplied means.
      if (p[0] > p[3] + 1 || p[1] > p[3] + 1 || p[2] > p[3] + 1) violations++;
    }
  }
  CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
  VD_CHECK_EQ(violations, 0);
  CVPixelBufferRelease(buffer);
}

static void test_a_stroke_thickens_the_ink(void) {
  VdTextSpec plain = caption("Outline");
  VdTextSpec stroked = plain;
  stroked.stroke_width = 0.12f;
  stroked.stroke_color = 0xFF000000u;

  CVPixelBufferRef a = render(&plain);
  CVPixelBufferRef b = render(&stroked);
  const Ink plain_ink = measure(a);
  const Ink stroked_ink = measure(b);

  // The outline is drawn under the fill and centred on the glyph outline, so
  // it grows the block in every direction and adds coverage without moving it.
  VD_CHECK(ink_width(&stroked_ink) > ink_width(&plain_ink));
  VD_CHECK(ink_height(&stroked_ink) > ink_height(&plain_ink));
  VD_CHECK(stroked_ink.coverage > plain_ink.coverage);
  VD_CHECK(abs(ink_centre_x(&stroked_ink) - ink_centre_x(&plain_ink)) <= 4);

  // A stroke with no width does nothing, whatever colour it is.
  VdTextSpec unstroked = plain;
  unstroked.stroke_color = 0xFFFF00FFu;
  CVPixelBufferRef c = render(&unstroked);
  const Ink unstroked_ink = measure(c);
  VD_CHECK_EQ(ink_width(&unstroked_ink), ink_width(&plain_ink));

  CVPixelBufferRelease(a);
  CVPixelBufferRelease(b);
  CVPixelBufferRelease(c);
}

static void test_a_shadow_falls_below_and_to_the_right(void) {
  VdTextSpec plain = caption("Shadow");
  VdTextSpec shadowed = plain;
  shadowed.shadow_color = 0xFF000000u;
  shadowed.shadow_dx = 0.15f;
  shadowed.shadow_dy = 0.15f;
  shadowed.shadow_blur = 0.02f;

  CVPixelBufferRef a = render(&plain);
  CVPixelBufferRef b = render(&shadowed);
  const Ink plain_ink = measure(a);
  const Ink shadow_ink = measure(b);

  // +y is down, the way a light above the frame throws it. Getting the sign
  // wrong is invisible in a still and obvious in a design.
  VD_CHECK(shadow_ink.right > plain_ink.right);
  VD_CHECK(shadow_ink.bottom > plain_ink.bottom);
  VD_CHECK(shadow_ink.left >= plain_ink.left - 2);
  VD_CHECK(shadow_ink.top >= plain_ink.top - 2);

  // A shadow colour with no alpha is a shadow that is switched off.
  VdTextSpec off = shadowed;
  off.shadow_color = 0x00000000u;
  CVPixelBufferRef c = render(&off);
  const Ink off_ink = measure(c);
  VD_CHECK_EQ(off_ink.right, plain_ink.right);
  VD_CHECK_EQ(off_ink.bottom, plain_ink.bottom);

  CVPixelBufferRelease(a);
  CVPixelBufferRelease(b);
  CVPixelBufferRelease(c);
}

static void test_the_box_sits_behind_the_words(void) {
  VdTextSpec spec = caption("Boxed");
  spec.box_color = 0xFF0000FFu;  // opaque blue
  spec.box_padding = 0.4f;
  spec.box_radius = 0.0f;
  CVPixelBufferRef buffer = render(&spec);
  const Ink ink = measure(buffer);
  VD_CHECK(!ink.empty);

  // The box hugs the words rather than filling the layout box, so it is
  // bounded well inside the frame — and it does not reach the corners.
  VD_CHECK(ink.left > 0 && ink.right < WIDTH - 1);
  uint8_t corner[4];
  pixel_at(buffer, 2, 2, corner);
  VD_CHECK_EQ(corner[3], 0);

  // Just inside the box's top-left corner is opaque blue, which is the box
  // and not a glyph: the padding puts it clear of the ink.
  uint8_t inside[4];
  pixel_at(buffer, ink.left + 2, ink.top + 2, inside);
  VD_CHECK_EQ(inside[3], 255);
  VD_CHECK(inside[0] > 245);  // blue
  VD_CHECK(inside[2] < 10);   // red

  // A box colour with no alpha draws no box: the ink is the words again.
  VdTextSpec off = spec;
  off.box_color = 0x00000000u;
  CVPixelBufferRef bare = render(&off);
  const Ink bare_ink = measure(bare);
  VD_CHECK(ink_width(&ink) > ink_width(&bare_ink));

  CVPixelBufferRelease(buffer);
  CVPixelBufferRelease(bare);
}

static void test_box_padding_grows_the_box(void) {
  VdTextSpec tight = caption("Pad");
  tight.box_color = 0xFF202020u;
  tight.box_padding = 0.1f;
  VdTextSpec loose = tight;
  loose.box_padding = 0.6f;

  CVPixelBufferRef a = render(&tight);
  CVPixelBufferRef b = render(&loose);
  const Ink tight_ink = measure(a);
  const Ink loose_ink = measure(b);

  VD_CHECK(ink_width(&loose_ink) > ink_width(&tight_ink));
  VD_CHECK(ink_height(&loose_ink) > ink_height(&tight_ink));
  // Padding is even, so the box stays where the words are.
  VD_CHECK(abs(ink_centre_x(&loose_ink) - ink_centre_x(&tight_ink)) <= 3);
  VD_CHECK(abs(ink_centre_y(&loose_ink) - ink_centre_y(&tight_ink)) <= 3);

  CVPixelBufferRelease(a);
  CVPixelBufferRelease(b);
}

// --- the spec itself -------------------------------------------------------

static void test_the_default_spec_is_one_somebody_would_want(void) {
  const VdTextSpec spec = vd_text_spec_default();
  VD_CHECK(spec.size > 0.0f);
  VD_CHECK_EQ(spec.color, 0xFFFFFFFFu);
  VD_CHECK_EQ(spec.align, VD_TEXT_ALIGN_CENTER);
  // The optional parts are off, and still described — turning a shadow on
  // should not also mean guessing what offset and blur someone wanted.
  VD_CHECK_EQ(spec.shadow_color >> 24, 0);
  VD_CHECK_EQ(spec.box_color >> 24, 0);
  VD_CHECK(spec.shadow_blur > 0.0f);
  VD_CHECK(spec.box_padding > 0.0f);
}

static void test_equality_is_what_the_raster_depends_on(void) {
  VdTextSpec a = caption("Same");
  VdTextSpec b = caption("Same");
  VD_CHECK(vd_text_spec_equal(&a, &b));

  // Separately allocated strings with the same contents are the same spec —
  // this is what stops an edit somewhere else on the timeline from throwing
  // away a raster.
  char* copy = strdup("Same");
  b.text = copy;
  VD_CHECK(vd_text_spec_equal(&a, &b));
  free(copy);

  b = a;
  b.letter_spacing = 0.1f;
  VD_CHECK(!vd_text_spec_equal(&a, &b));
  b = a;
  b.text = "Different";
  VD_CHECK(!vd_text_spec_equal(&a, &b));
  b = a;
  b.font = NULL;
  VD_CHECK(!vd_text_spec_equal(&a, &b));

  // NULL and empty are the same nothing.
  VdTextSpec empty = vd_text_spec_default();
  VdTextSpec null = empty;
  empty.text = "";
  null.text = NULL;
  VD_CHECK(vd_text_spec_equal(&empty, &null));
}

static void test_a_copy_owns_its_strings(void) {
  char text[16];
  snprintf(text, sizeof(text), "Owned");
  VdTextSpec original = caption(text);
  VdTextSpec* copy = vd_text_spec_copy(&original);
  VD_CHECK(copy != NULL);

  // Scribbling over the caller's buffer must not change the copy: the engine
  // holds a spec for as long as a clip is on the timeline, and the string it
  // came from belongs to the edit that made it.
  snprintf(text, sizeof(text), "Gone");
  VD_CHECK_STR(copy->text, "Owned");
  VD_CHECK(copy->text != original.text);
  vd_text_spec_free(copy);
  vd_text_spec_free(NULL);
  VD_CHECK(vd_text_spec_copy(NULL) == NULL);
}

int main(void) {
  test_the_bundled_fonts_register();
  test_an_unknown_family_still_draws();
  test_nothing_typed_draws_nothing();
  test_bad_arguments_are_refused();
  test_a_line_is_centred_in_the_frame();
  test_alignment_moves_a_single_line();
  test_size_is_a_fraction_of_the_output();
  test_letter_spacing_widens_without_heightening();
  test_line_spacing_heightens_without_widening();
  test_a_long_line_wraps_inside_the_frame();
  test_max_width_is_the_thing_that_wraps();
  test_the_fill_colour_is_the_one_asked_for();
  test_the_raster_is_premultiplied();
  test_a_stroke_thickens_the_ink();
  test_a_shadow_falls_below_and_to_the_right();
  test_the_box_sits_behind_the_words();
  test_box_padding_grows_the_box();
  test_the_default_spec_is_one_somebody_would_want();
  test_equality_is_what_the_raster_depends_on();
  test_a_copy_owns_its_strings();
  return VD_REPORT();
}
