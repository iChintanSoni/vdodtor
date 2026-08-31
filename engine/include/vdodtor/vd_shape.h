// vd_shape.h — a rectangle, an ellipse, a line, an arrow.
//
// The second source the engine draws rather than decodes, and it works on
// exactly the terms the first one does: a shape is rasterised once into a BGRA
// frame the size of the output and handed to the compositor as an ordinary
// layer, so the clip's transform, opacity, z-order and in/out animation all
// work on it without anything here knowing they exist. See vd_text.h — every
// word of its argument for living in the engine rather than in Flutter applies
// unchanged, because the thing being argued about is that a frame stays a pure
// function of (document, time) with no UI attached.
//
// **Every length here is a fraction of the output height.** Not of the width,
// and not one of each: a shape measured half against the width and half
// against the height changes shape when the project's aspect does, and then a
// circle is only round at 16:9. One unit for all four numbers also makes them
// comparable by eye — a shape 0.4 tall with a 0.02 stroke is a shape with a
// stroke a twentieth of its height, and you can see that from the numbers.
//
// This differs from vd_text.h, where the size is a fraction of the output and
// everything else is a fraction of the *font size*. A caption has one size to
// hang the rest off; a shape has two, so there is no single one to choose and
// picking either would make the other axis surprising.

#ifndef VD_SHAPE_H
#define VD_SHAPE_H

#include <stdbool.h>
#include <stdint.h>

#include "vdodtor/vd_time.h"

#ifdef __cplusplus
extern "C" {
#endif

// What gets drawn inside the box.
//
// **One box, four shapes.** Every kind is drawn inside the same rectangle —
// `width` by `height`, centred in the frame — which is what makes the two size
// numbers mean the same thing in all of them. A rectangle fills the box, an
// ellipse is inscribed in it, and a line runs across it from the middle of the
// left edge to the middle of the right.
//
// A rounded rectangle is `VD_SHAPE_RECT` with a `corner`, and a circle is
// `VD_SHAPE_ELLIPSE` with equal sides, rather than kinds of their own: both
// are one slider away from the shape beside them, and a picker with six
// entries where four would do makes the reader look for a difference that is
// not there.
//
// Values cross the FFI boundary as integers, so these may be appended to and
// never reordered.
typedef enum {
  VD_SHAPE_RECT = 0,
  VD_SHAPE_ELLIPSE = 1,
  // The stroke *is* the shape: a line has no interior, so `fill_color` says
  // nothing about it and a line with no stroke width draws nothing — the same
  // rule a rectangle with no fill already follows.
  VD_SHAPE_LINE = 2,
  // A line with a head on its right end. Right, because that is the direction
  // the clip's own rotation turns towards, so "which way does it point" has
  // one answer and it is the transform's.
  VD_SHAPE_ARROW = 3,
} VdShapeKind;

// Everything about how one shape looks.
//
// All scalars, unlike VdTextSpec — there is no string in a rectangle — which
// is why the copy below is a memcpy and the comparison is worth reading.
//
// Colours are 0xAARRGGBB, straight (not premultiplied). Alpha 0 means *off*:
// a fill with no alpha draws no fill, a stroke with none draws no outline, a
// shadow colour with none casts no shadow. One rule rather than three booleans
// nobody would keep in step with the colours beside them.
typedef struct {
  VdShapeKind kind;

  // The box, as fractions of the output height. Equal values are a square —
  // and so a circle, for an ellipse — in a 16:9 project and in a 9:16 one.
  float width;
  float height;

  // How round the corners of a rectangle are: 0 is square, 1 is as round as
  // the box allows, which is a pill on an oblong and a circle on a square. A
  // proportion rather than a length, so a rectangle keeps its corners when it
  // is resized. Ignored by every kind but VD_SHAPE_RECT.
  float corner;

  // Ignored by VD_SHAPE_LINE and VD_SHAPE_ARROW, which have no interior.
  uint32_t fill_color;

  // Drawn over the fill, straddling the edge, which is what every drawing
  // program does and what keeps a filled shape the size it says it is.
  uint32_t stroke_color;
  float stroke_width;

  // Cast by the whole shape — fill and stroke together, as one silhouette —
  // onto whatever is behind it. +y is down, the direction a light above the
  // frame throws it.
  uint32_t shadow_color;
  float shadow_dx;
  float shadow_dy;
  float shadow_blur;

  // How much of an arrow is head, as a fraction of its length. A proportion
  // for the same reason `corner` is one: an arrow that is lengthened should
  // still look like an arrow. Ignored by every kind but VD_SHAPE_ARROW.
  float head_size;
} VdShapeSpec;

// A shape with nothing said about it: an opaque white rectangle, unstroked,
// unshadowed, square-cornered, big enough to see. Not a zeroed struct — a
// zeroed one is a transparent shape with no size, which is not a default
// anybody wants.
VD_EXPORT VdShapeSpec vd_shape_spec_default(void);

// True when two specs would rasterise to the same pixels. Field by field
// rather than a memcmp: a struct with a mix of enums and floats has padding
// in it, and padding is whatever was on the stack.
//
// The fields a kind ignores are compared anyway. A rectangle's `head_size`
// cannot change its pixels, so calling two rectangles different over it costs
// one redraw of one shape on the edit that changed it — where getting the
// exception wrong the other way round would leave a stale raster on screen.
VD_EXPORT bool vd_shape_spec_equal(const VdShapeSpec* a, const VdShapeSpec* b);

// A heap copy, and the matching free. The engine holds a spec for as long as
// a clip is on the timeline; the caller that handed it over keeps its own.
// Both accept NULL, which is a clip that is not a shape.
VD_EXPORT VdShapeSpec* vd_shape_spec_copy(const VdShapeSpec* spec);
VD_EXPORT void vd_shape_spec_free(VdShapeSpec* spec);

// Rasterises `spec` into a new `width` x `height` CVPixelBufferRef: 32BGRA,
// **premultiplied**, transparent everywhere the shape is not. IOSurface-backed
// and Metal-compatible, so the compositor wraps it without a copy.
//
// The box is centred in the frame; moving it is the clip transform's job, not
// this function's. Caller releases with CVPixelBufferRelease. NULL on failure,
// with `out_result` — which may be NULL — set to a negative VdResult.
VD_EXPORT void* vd_shape_render(const VdShapeSpec* spec, int32_t width,
                                int32_t height, int32_t* out_result);

#ifdef __cplusplus
}
#endif
#endif  // VD_SHAPE_H
