// Shapes, checked on where their marks land.
//
// Same method as vd_text_test.c and for a weaker version of the same reason:
// the exact alpha Core Graphics puts along the edge of a circle is not a
// contract, so a golden PNG of one would go red on an OS upgrade with nothing
// wrong behind it. What *is* a contract is the geometry — a box centred in the
// frame, both dimensions scaled by the output's height, a corner that rounds,
// a stroke that grows outwards, a shadow below and to the right, an arrow with
// its head on the right — and every check below is one of those.
//
// The numbers have slack in them on purpose. Antialiasing moves an edge by up
// to a pixel and the ink threshold moves it back, so the assertions are
// inequalities and tolerances rather than exact bounds wherever an exact one
// would be asserting something about a rasteriser instead of about a shape.
#include "vd_check.h"
#include "vd_ink.h"
#include "vdodtor/vd_probe.h"
#include "vdodtor/vd_shape.h"

#include <math.h>
#include <stdlib.h>

#include <CoreVideo/CoreVideo.h>

#define WIDTH 640
#define HEIGHT 360

// A pixel either side of where an edge should be, which is as close as
// antialiasing and the ink threshold together allow.
#define EDGE_SLACK 2

static CVPixelBufferRef render(const VdShapeSpec* spec) {
  int32_t result = VD_OK;
  CVPixelBufferRef buffer =
      (CVPixelBufferRef)vd_shape_render(spec, WIDTH, HEIGHT, &result);
  VD_CHECK_EQ(result, VD_OK);
  VD_CHECK(buffer != NULL);
  return buffer;
}

static VdShapeSpec shape_of(VdShapeKind kind) {
  VdShapeSpec spec = vd_shape_spec_default();
  spec.kind = kind;
  return spec;
}

static bool near(int32_t a, int32_t b, int32_t slack) {
  return labs((long)a - (long)b) <= slack;
}

// --- the box ---------------------------------------------------------------

static void test_a_shape_is_centred_in_the_frame(void) {
  VdShapeSpec spec = shape_of(VD_SHAPE_RECT);
  CVPixelBufferRef buffer = render(&spec);
  const Ink ink = measure(buffer);

  VD_CHECK(!ink.empty);
  VD_CHECK(near(ink_centre_x(&ink), WIDTH / 2, EDGE_SLACK));
  VD_CHECK(near(ink_centre_y(&ink), HEIGHT / 2, EDGE_SLACK));
  CVPixelBufferRelease(buffer);
}

// The whole reason both dimensions are fractions of the *height*: equal
// numbers have to be equal lengths, or a circle is only round at one aspect
// ratio and the shape someone drew changes when they change the format.
static void test_both_sides_are_measured_against_the_height(void) {
  VdShapeSpec spec = shape_of(VD_SHAPE_RECT);
  spec.width = 0.5f;
  spec.height = 0.5f;
  CVPixelBufferRef buffer = render(&spec);
  const Ink ink = measure(buffer);

  const int32_t expected = (int32_t)(0.5f * HEIGHT);
  VD_CHECK(near(ink_width(&ink), expected, EDGE_SLACK));
  VD_CHECK(near(ink_height(&ink), expected, EDGE_SLACK));
  // And so a square really is square, on a frame that is not.
  VD_CHECK(near(ink_width(&ink), ink_height(&ink), EDGE_SLACK));
  CVPixelBufferRelease(buffer);
}

static void test_the_box_is_the_size_it_says(void) {
  VdShapeSpec spec = shape_of(VD_SHAPE_RECT);
  spec.width = 0.8f;
  spec.height = 0.3f;
  CVPixelBufferRef buffer = render(&spec);
  const Ink ink = measure(buffer);

  VD_CHECK(near(ink_width(&ink), (int32_t)(0.8f * HEIGHT), EDGE_SLACK));
  VD_CHECK(near(ink_height(&ink), (int32_t)(0.3f * HEIGHT), EDGE_SLACK));
  CVPixelBufferRelease(buffer);
}

// A shape wider than the frame is clipped by it rather than shrunk to fit.
// Nothing here fits anything: the raster is the output's size, and where the
// shape sits inside it is the clip transform's business.
static void test_a_shape_larger_than_the_frame_is_clipped(void) {
  VdShapeSpec spec = shape_of(VD_SHAPE_RECT);
  spec.width = 4.0f;
  spec.height = 4.0f;
  CVPixelBufferRef buffer = render(&spec);
  const Ink ink = measure(buffer);

  VD_CHECK_EQ(ink.left, 0);
  VD_CHECK_EQ(ink.top, 0);
  VD_CHECK_EQ(ink.right, WIDTH - 1);
  VD_CHECK_EQ(ink.bottom, HEIGHT - 1);
  CVPixelBufferRelease(buffer);
}

// --- nothing to draw -------------------------------------------------------

static void test_an_invisible_fill_draws_nothing(void) {
  VdShapeSpec spec = shape_of(VD_SHAPE_RECT);
  spec.fill_color = 0x00FFFFFFu;  // white, no alpha
  CVPixelBufferRef buffer = render(&spec);
  const Ink ink = measure(buffer);

  VD_CHECK(ink.empty);
  VD_CHECK_EQ(ink.coverage, 0);
  CVPixelBufferRelease(buffer);
}

// A line has no interior, so a fill colour says nothing about it and a line
// with no stroke width is a line nobody can see. Same rule as a rectangle with
// no fill, one field along.
static void test_a_line_without_a_stroke_draws_nothing(void) {
  VdShapeSpec spec = shape_of(VD_SHAPE_LINE);
  spec.stroke_width = 0.0f;
  spec.fill_color = 0xFFFFFFFFu;
  CVPixelBufferRef buffer = render(&spec);
  const Ink ink = measure(buffer);

  VD_CHECK(ink.empty);
  CVPixelBufferRelease(buffer);
}

static void test_a_zero_sized_shape_draws_nothing(void) {
  VdShapeSpec spec = shape_of(VD_SHAPE_RECT);
  spec.width = 0.0f;
  spec.height = 0.0f;
  CVPixelBufferRef buffer = render(&spec);
  const Ink ink = measure(buffer);

  VD_CHECK(ink.empty);
  CVPixelBufferRelease(buffer);
}

static void test_bad_arguments_are_refused(void) {
  VdShapeSpec spec = shape_of(VD_SHAPE_RECT);
  int32_t result = VD_OK;

  VD_CHECK(vd_shape_render(NULL, WIDTH, HEIGHT, &result) == NULL);
  VD_CHECK_EQ(result, VD_ERR_INVALID_ARG);

  VD_CHECK(vd_shape_render(&spec, 0, HEIGHT, &result) == NULL);
  VD_CHECK_EQ(result, VD_ERR_INVALID_ARG);

  VD_CHECK(vd_shape_render(&spec, WIDTH, -1, &result) == NULL);
  VD_CHECK_EQ(result, VD_ERR_INVALID_ARG);
}

// --- the raster ------------------------------------------------------------

static void test_the_fill_colour_is_the_one_asked_for(void) {
  VdShapeSpec spec = shape_of(VD_SHAPE_RECT);
  spec.fill_color = 0xFF3366CCu;
  CVPixelBufferRef buffer = render(&spec);

  uint8_t bgra[4];
  pixel_at(buffer, WIDTH / 2, HEIGHT / 2, bgra);
  VD_CHECK(near(bgra[2], 0x33, 2));  // R
  VD_CHECK(near(bgra[1], 0x66, 2));  // G
  VD_CHECK(near(bgra[0], 0xCC, 2));  // B
  VD_CHECK_EQ(bgra[3], 0xFF);
  CVPixelBufferRelease(buffer);
}

// The compositor is handed this as a premultiplied BGRA layer, so a channel
// brighter than its own alpha would come out as a bright fringe wherever the
// shape is soft — which is every edge it has.
static void test_the_raster_is_premultiplied(void) {
  VdShapeSpec spec = shape_of(VD_SHAPE_ELLIPSE);
  spec.fill_color = 0xFFFFFFFFu;
  CVPixelBufferRef buffer = render(&spec);

  CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
  const uint8_t* base = (const uint8_t*)CVPixelBufferGetBaseAddress(buffer);
  const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
  int violations = 0;
  for (int32_t y = 0; y < HEIGHT; y++) {
    const uint8_t* row = base + (size_t)y * stride;
    for (int32_t x = 0; x < WIDTH; x++) {
      const uint8_t* p = row + (size_t)x * 4;
      const uint8_t a = p[3];
      if (p[0] > a || p[1] > a || p[2] > a) violations++;
    }
  }
  CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
  VD_CHECK_EQ(violations, 0);
  CVPixelBufferRelease(buffer);
}

// --- rectangles and ellipses ----------------------------------------------

// The corner is a proportion, so the same value has to round the same amount
// of a big rectangle as of a small one — which is what makes it survive a
// resize. Measured as area, because a rounded corner takes ink away from the
// box without moving any of its edges.
static void test_a_corner_rounds_without_moving_the_edges(void) {
  VdShapeSpec square = shape_of(VD_SHAPE_RECT);
  square.width = 0.5f;
  square.height = 0.5f;
  VdShapeSpec pill = square;
  pill.corner = 1.0f;

  CVPixelBufferRef a = render(&square);
  CVPixelBufferRef b = render(&pill);
  const Ink sharp = measure(a);
  const Ink round = measure(b);

  VD_CHECK(near(ink_width(&sharp), ink_width(&round), EDGE_SLACK));
  VD_CHECK(near(ink_height(&sharp), ink_height(&round), EDGE_SLACK));
  VD_CHECK(round.coverage < sharp.coverage);
  // A fully rounded square is a circle: pi/4 of the box, give or take the
  // edge. Loose enough to be about the geometry rather than about the
  // rasteriser.
  const double ratio = (double)round.coverage / (double)sharp.coverage;
  VD_CHECK(ratio > 0.74 && ratio < 0.82);

  CVPixelBufferRelease(a);
  CVPixelBufferRelease(b);
}

// A fully rounded rectangle and an ellipse in the same box are the same shape
// when the box is square, which is the whole reason there is no separate
// "circle" kind to choose from.
static void test_a_fully_rounded_square_is_a_circle(void) {
  VdShapeSpec pill = shape_of(VD_SHAPE_RECT);
  pill.width = pill.height = 0.5f;
  pill.corner = 1.0f;
  VdShapeSpec circle = shape_of(VD_SHAPE_ELLIPSE);
  circle.width = circle.height = 0.5f;

  CVPixelBufferRef a = render(&pill);
  CVPixelBufferRef b = render(&circle);
  const Ink rounded = measure(a);
  const Ink ellipse = measure(b);

  VD_CHECK(near(ink_width(&rounded), ink_width(&ellipse), EDGE_SLACK));
  VD_CHECK(near(ink_height(&rounded), ink_height(&ellipse), EDGE_SLACK));
  const double ratio = (double)rounded.coverage / (double)ellipse.coverage;
  VD_CHECK(ratio > 0.98 && ratio < 1.02);

  CVPixelBufferRelease(a);
  CVPixelBufferRelease(b);
}

static void test_an_ellipse_is_inscribed_in_its_box(void) {
  VdShapeSpec rect = shape_of(VD_SHAPE_RECT);
  rect.width = 0.6f;
  rect.height = 0.4f;
  VdShapeSpec ellipse = rect;
  ellipse.kind = VD_SHAPE_ELLIPSE;

  CVPixelBufferRef a = render(&rect);
  CVPixelBufferRef b = render(&ellipse);
  const Ink box = measure(a);
  const Ink oval = measure(b);

  // Same bounds — it touches all four sides — and less of them filled.
  VD_CHECK(near(ink_width(&box), ink_width(&oval), EDGE_SLACK));
  VD_CHECK(near(ink_height(&box), ink_height(&oval), EDGE_SLACK));
  VD_CHECK(oval.coverage < box.coverage);

  // The corners are outside it: a rectangle marks them, an ellipse does not.
  uint8_t corner[4];
  pixel_at(b, box.left + 1, box.top + 1, corner);
  VD_CHECK(corner[3] < INK_THRESHOLD);

  CVPixelBufferRelease(a);
  CVPixelBufferRelease(b);
}

// --- strokes ---------------------------------------------------------------

// A stroke straddles the edge, so it grows the shape by half its width in
// every direction and does not move it.
static void test_a_stroke_grows_the_shape_about_its_centre(void) {
  VdShapeSpec plain = shape_of(VD_SHAPE_RECT);
  plain.width = 0.5f;
  plain.height = 0.3f;
  VdShapeSpec stroked = plain;
  stroked.stroke_width = 0.04f;
  stroked.stroke_color = 0xFF000000u;

  CVPixelBufferRef a = render(&plain);
  CVPixelBufferRef b = render(&stroked);
  const Ink bare = measure(a);
  const Ink outlined = measure(b);

  const int32_t half = (int32_t)(0.04f * HEIGHT / 2);
  VD_CHECK(near(ink_width(&outlined), ink_width(&bare) + 2 * half, EDGE_SLACK));
  VD_CHECK(
      near(ink_height(&outlined), ink_height(&bare) + 2 * half, EDGE_SLACK));
  VD_CHECK(near(ink_centre_x(&outlined), ink_centre_x(&bare), EDGE_SLACK));
  VD_CHECK(near(ink_centre_y(&outlined), ink_centre_y(&bare), EDGE_SLACK));

  CVPixelBufferRelease(a);
  CVPixelBufferRelease(b);
}

// Over the fill rather than under it, which is what keeps a filled shape the
// size its box says it is: the stroke's inner half covers the fill's edge
// instead of the fill covering the stroke's.
static void test_the_stroke_is_drawn_over_the_fill(void) {
  VdShapeSpec spec = shape_of(VD_SHAPE_RECT);
  spec.width = 0.5f;
  spec.height = 0.3f;
  spec.fill_color = 0xFFFFFFFFu;
  spec.stroke_color = 0xFFFF0000u;
  spec.stroke_width = 0.04f;
  CVPixelBufferRef buffer = render(&spec);
  const Ink ink = measure(buffer);

  // A pixel just inside the outer edge is stroke; the middle is fill.
  uint8_t edge[4], centre[4];
  pixel_at(buffer, ink_centre_x(&ink), ink.top + 3, edge);
  pixel_at(buffer, ink_centre_x(&ink), ink_centre_y(&ink), centre);
  VD_CHECK(edge[2] > 200 && edge[1] < 60 && edge[0] < 60);  // red
  VD_CHECK(centre[0] > 200 && centre[1] > 200 && centre[2] > 200);  // white
  CVPixelBufferRelease(buffer);
}

static void test_an_unfilled_shape_is_only_its_outline(void) {
  VdShapeSpec spec = shape_of(VD_SHAPE_RECT);
  spec.width = 0.5f;
  spec.height = 0.3f;
  spec.fill_color = 0x00FFFFFFu;  // no alpha: no fill
  spec.stroke_color = 0xFFFFFFFFu;
  spec.stroke_width = 0.02f;
  CVPixelBufferRef buffer = render(&spec);
  const Ink ink = measure(buffer);

  VD_CHECK(!ink.empty);
  uint8_t centre[4];
  pixel_at(buffer, ink_centre_x(&ink), ink_centre_y(&ink), centre);
  VD_CHECK(centre[3] < INK_THRESHOLD);
  CVPixelBufferRelease(buffer);
}

// --- lines and arrows ------------------------------------------------------

static void test_a_line_runs_across_the_middle_of_its_box(void) {
  VdShapeSpec spec = shape_of(VD_SHAPE_LINE);
  spec.width = 0.8f;
  spec.height = 0.4f;
  spec.stroke_color = 0xFFFFFFFFu;
  spec.stroke_width = 0.02f;
  CVPixelBufferRef buffer = render(&spec);
  const Ink ink = measure(buffer);

  // As long as the box is wide, and only as tall as it is thick.
  VD_CHECK(near(ink_width(&ink), (int32_t)(0.8f * HEIGHT), EDGE_SLACK));
  VD_CHECK(near(ink_height(&ink), (int32_t)(0.02f * HEIGHT), EDGE_SLACK));
  VD_CHECK(near(ink_centre_y(&ink), HEIGHT / 2, EDGE_SLACK));
  CVPixelBufferRelease(buffer);
}

// The box's height does not change a line, which is the honest consequence of
// one box for four kinds: a line uses the width for its length and the height
// for nothing at all.
static void test_a_lines_length_is_its_boxs_width(void) {
  VdShapeSpec thin = shape_of(VD_SHAPE_LINE);
  thin.width = 0.8f;
  thin.height = 0.1f;
  thin.stroke_color = 0xFFFFFFFFu;
  thin.stroke_width = 0.02f;
  VdShapeSpec tall = thin;
  tall.height = 0.9f;

  CVPixelBufferRef a = render(&thin);
  CVPixelBufferRef b = render(&tall);
  const Ink first = measure(a);
  const Ink second = measure(b);

  VD_CHECK(near(ink_width(&first), ink_width(&second), EDGE_SLACK));
  VD_CHECK(near(ink_height(&first), ink_height(&second), EDGE_SLACK));
  VD_CHECK(near(ink_centre_y(&first), ink_centre_y(&second), EDGE_SLACK));

  CVPixelBufferRelease(a);
  CVPixelBufferRelease(b);
}

// The head is on the right end, because right is where the clip's own
// rotation turns towards — so "which way does it point" has one answer and it
// belongs to the transform.
static void test_an_arrow_has_its_head_on_the_right(void) {
  VdShapeSpec spec = shape_of(VD_SHAPE_ARROW);
  spec.width = 0.8f;
  spec.height = 0.4f;
  spec.stroke_color = 0xFFFFFFFFu;
  spec.stroke_width = 0.01f;
  spec.head_size = 0.3f;
  CVPixelBufferRef buffer = render(&spec);
  const Ink ink = measure(buffer);

  // Thicker at the head than at the tail: a column near the right end covers
  // many rows, one near the left end covers only the shaft.
  int32_t at_head = 0, at_tail = 0;
  for (int32_t y = 0; y < HEIGHT; y++) {
    uint8_t p[4];
    pixel_at(buffer, ink.right - 4, y, p);
    if (p[3] >= INK_THRESHOLD) at_head++;
    pixel_at(buffer, ink.left + 4, y, p);
    if (p[3] >= INK_THRESHOLD) at_tail++;
  }
  VD_CHECK(at_head > at_tail);
  VD_CHECK(at_tail > 0);
  // And the head is what makes the arrow taller than its shaft.
  VD_CHECK(ink_height(&ink) > (int32_t)(0.01f * HEIGHT) * 2);
  CVPixelBufferRelease(buffer);
}

// A proportion of the length, so an arrow that is stretched still looks like
// an arrow rather than like a line with a pin on the end.
static void test_a_bigger_head_takes_more_of_the_arrow(void) {
  VdShapeSpec small = shape_of(VD_SHAPE_ARROW);
  small.width = 0.8f;
  small.height = 0.4f;
  small.stroke_color = 0xFFFFFFFFu;
  small.stroke_width = 0.01f;
  small.head_size = 0.1f;
  VdShapeSpec large = small;
  large.head_size = 0.4f;

  CVPixelBufferRef a = render(&small);
  CVPixelBufferRef b = render(&large);
  const Ink modest = measure(a);
  const Ink bold = measure(b);

  // The length is unchanged — the head grows into the shaft, not past the tip.
  VD_CHECK(near(ink_width(&modest), ink_width(&bold), EDGE_SLACK));
  VD_CHECK(ink_height(&bold) > ink_height(&modest));
  VD_CHECK(bold.coverage > modest.coverage);

  CVPixelBufferRelease(a);
  CVPixelBufferRelease(b);
}

// --- shadows ---------------------------------------------------------------

static void test_a_shadow_falls_below_and_to_the_right(void) {
  VdShapeSpec plain = shape_of(VD_SHAPE_RECT);
  plain.width = 0.4f;
  plain.height = 0.3f;
  VdShapeSpec shadowed = plain;
  shadowed.shadow_color = 0xFF000000u;
  shadowed.shadow_dx = 0.05f;
  shadowed.shadow_dy = 0.05f;
  shadowed.shadow_blur = 0.01f;

  CVPixelBufferRef a = render(&plain);
  CVPixelBufferRef b = render(&shadowed);
  const Ink bare = measure(a);
  const Ink cast = measure(b);

  // The shape itself has not moved; the ink now reaches further down and to
  // the right of it, and no further up or left.
  VD_CHECK(near(cast.left, bare.left, EDGE_SLACK));
  VD_CHECK(near(cast.top, bare.top, EDGE_SLACK));
  VD_CHECK(cast.right > bare.right + 4);
  VD_CHECK(cast.bottom > bare.bottom + 4);

  CVPixelBufferRelease(a);
  CVPixelBufferRelease(b);
}

// One shadow for the whole shape, not one per drawing operation. Two would
// show through each other wherever the shape is not opaque — the fill's cast
// under the stroke's — which looks like a rendering bug because it is one.
static void test_a_stroked_shape_casts_one_shadow(void) {
  VdShapeSpec spec = shape_of(VD_SHAPE_RECT);
  spec.width = 0.4f;
  spec.height = 0.3f;
  spec.fill_color = 0x80FFFFFFu;  // half transparent, so a double shadow shows
  spec.stroke_color = 0x80FFFFFFu;
  spec.stroke_width = 0.03f;
  spec.shadow_color = 0xFF000000u;
  spec.shadow_dx = 0.08f;
  spec.shadow_dy = 0.08f;
  spec.shadow_blur = 0.0f;

  CVPixelBufferRef buffer = render(&spec);
  const Ink ink = measure(buffer);

  // Deep inside the shadow, past the shape's own bottom-right corner. Core
  // Graphics modulates a shadow by the alpha of what casts it, so a shape at
  // half opacity casts a shadow at half opacity — and *two* shadows there
  // would come out at 1 - (1 - 0.5)^2, which is 0xBF rather than 0x80. That
  // one byte is the whole assertion.
  uint8_t p[4];
  pixel_at(buffer, ink.right - 4, ink.bottom - 4, p);
  VD_CHECK_EQ(p[3], 0x80);
  VD_CHECK(p[0] < 8 && p[1] < 8 && p[2] < 8);  // black, premultiplied

  CVPixelBufferRelease(buffer);
}

// --- the spec itself -------------------------------------------------------

// What the engine's raster cache is keyed on. A field-by-field comparison
// rather than a memcmp, because the struct has padding in it and padding is
// whatever was on the stack when the caller built one.
static void test_two_identical_specs_are_equal(void) {
  VdShapeSpec a = vd_shape_spec_default();
  VdShapeSpec b = vd_shape_spec_default();
  VD_CHECK(vd_shape_spec_equal(&a, &b));
  VD_CHECK(vd_shape_spec_equal(&a, &a));
  VD_CHECK(!vd_shape_spec_equal(&a, NULL));
  VD_CHECK(!vd_shape_spec_equal(NULL, &b));
  VD_CHECK(vd_shape_spec_equal(NULL, NULL));
}

static void test_every_field_makes_two_specs_different(void) {
  const VdShapeSpec base = vd_shape_spec_default();

#define DIFFERS(field, value)                \
  do {                                       \
    VdShapeSpec other = base;                \
    other.field = (value);                   \
    VD_CHECK(!vd_shape_spec_equal(&base, &other)); \
  } while (0)

  DIFFERS(kind, VD_SHAPE_ELLIPSE);
  DIFFERS(width, 0.9f);
  DIFFERS(height, 0.9f);
  DIFFERS(corner, 0.5f);
  DIFFERS(fill_color, 0xFF112233u);
  DIFFERS(stroke_color, 0xFF112233u);
  DIFFERS(stroke_width, 0.05f);
  DIFFERS(shadow_color, 0xFF112233u);
  DIFFERS(shadow_dx, 0.05f);
  DIFFERS(shadow_dy, 0.05f);
  DIFFERS(shadow_blur, 0.05f);
  DIFFERS(head_size, 0.5f);
#undef DIFFERS
}

static void test_a_copy_is_equal_and_independent(void) {
  VdShapeSpec spec = vd_shape_spec_default();
  spec.kind = VD_SHAPE_ARROW;
  spec.width = 0.75f;

  VdShapeSpec* copy = vd_shape_spec_copy(&spec);
  VD_CHECK(copy != NULL);
  VD_CHECK(copy != &spec);
  VD_CHECK(vd_shape_spec_equal(copy, &spec));

  spec.width = 0.1f;
  VD_CHECK(!vd_shape_spec_equal(copy, &spec));

  vd_shape_spec_free(copy);
  vd_shape_spec_free(NULL);
  VD_CHECK(vd_shape_spec_copy(NULL) == NULL);
}

// A zeroed struct is a transparent shape with no size. The default has to be
// something someone would recognise as a shape, or every caller has to know
// which fields to fill in before it draws at all.
static void test_the_default_draws_something(void) {
  VdShapeSpec spec = vd_shape_spec_default();
  VD_CHECK_EQ(spec.kind, VD_SHAPE_RECT);
  VD_CHECK(spec.width > 0.0f);
  VD_CHECK(spec.height > 0.0f);

  CVPixelBufferRef buffer = render(&spec);
  const Ink ink = measure(buffer);
  VD_CHECK(!ink.empty);
  CVPixelBufferRelease(buffer);
}

int main(void) {
  test_a_shape_is_centred_in_the_frame();
  test_both_sides_are_measured_against_the_height();
  test_the_box_is_the_size_it_says();
  test_a_shape_larger_than_the_frame_is_clipped();

  test_an_invisible_fill_draws_nothing();
  test_a_line_without_a_stroke_draws_nothing();
  test_a_zero_sized_shape_draws_nothing();
  test_bad_arguments_are_refused();

  test_the_fill_colour_is_the_one_asked_for();
  test_the_raster_is_premultiplied();

  test_a_corner_rounds_without_moving_the_edges();
  test_a_fully_rounded_square_is_a_circle();
  test_an_ellipse_is_inscribed_in_its_box();

  test_a_stroke_grows_the_shape_about_its_centre();
  test_the_stroke_is_drawn_over_the_fill();
  test_an_unfilled_shape_is_only_its_outline();

  test_a_line_runs_across_the_middle_of_its_box();
  test_a_lines_length_is_its_boxs_width();
  test_an_arrow_has_its_head_on_the_right();
  test_a_bigger_head_takes_more_of_the_arrow();

  test_a_shadow_falls_below_and_to_the_right();
  test_a_stroked_shape_casts_one_shadow();

  test_two_identical_specs_are_equal();
  test_every_field_makes_two_specs_different();
  test_a_copy_is_equal_and_independent();
  test_the_default_draws_something();

  return VD_REPORT();
}
