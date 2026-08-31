#include "vdodtor/vd_shape.h"

#include <CoreVideo/CoreVideo.h>

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "vdodtor/vd_probe.h"
#include "vdodtor/vd_raster.h"

// A shape big enough to see on a frame nobody has sized it for.
#define VD_SHAPE_DEFAULT_WIDTH 0.5f
#define VD_SHAPE_DEFAULT_HEIGHT 0.28f
#define VD_SHAPE_DEFAULT_HEAD 0.25f

VdShapeSpec vd_shape_spec_default(void) {
  VdShapeSpec spec;
  memset(&spec, 0, sizeof(spec));
  spec.kind = VD_SHAPE_RECT;
  spec.width = VD_SHAPE_DEFAULT_WIDTH;
  spec.height = VD_SHAPE_DEFAULT_HEIGHT;
  spec.corner = 0.0f;
  spec.fill_color = 0xFFFFFFFFu;
  spec.stroke_color = 0xFF000000u;
  spec.stroke_width = 0.0f;
  spec.shadow_color = 0x00000000u;
  spec.shadow_dx = 0.0f;
  spec.shadow_dy = 0.0f;
  spec.shadow_blur = 0.0f;
  spec.head_size = VD_SHAPE_DEFAULT_HEAD;
  return spec;
}

bool vd_shape_spec_equal(const VdShapeSpec* a, const VdShapeSpec* b) {
  if (a == b) return true;
  if (!a || !b) return false;
  return a->kind == b->kind && a->width == b->width && a->height == b->height &&
         a->corner == b->corner && a->fill_color == b->fill_color &&
         a->stroke_color == b->stroke_color &&
         a->stroke_width == b->stroke_width &&
         a->shadow_color == b->shadow_color && a->shadow_dx == b->shadow_dx &&
         a->shadow_dy == b->shadow_dy && a->shadow_blur == b->shadow_blur &&
         a->head_size == b->head_size;
}

VdShapeSpec* vd_shape_spec_copy(const VdShapeSpec* spec) {
  if (!spec) return NULL;
  VdShapeSpec* copy = (VdShapeSpec*)malloc(sizeof(VdShapeSpec));
  if (!copy) return NULL;
  *copy = *spec;
  return copy;
}

void vd_shape_spec_free(VdShapeSpec* spec) { free(spec); }

// --- geometry --------------------------------------------------------------

// The box, in pixels, centred in a `width` x `height` frame.
//
// Both dimensions are scaled by the frame's *height*, which is the whole of
// why a circle stays round: the two numbers share a unit, so equal numbers are
// equal lengths whatever shape the frame is.
static CGRect box_for(const VdShapeSpec* spec, int32_t width, int32_t height) {
  const CGFloat unit = (CGFloat)height;
  CGFloat w = (CGFloat)spec->width * unit;
  CGFloat h = (CGFloat)spec->height * unit;
  if (w < 0) w = 0;
  if (h < 0) h = 0;
  return CGRectMake(((CGFloat)width - w) * 0.5, (unit - h) * 0.5, w, h);
}

// The outline of a rectangle, an ellipse or a line. NULL for an arrow, which
// is two pieces and is drawn by draw_arrow below.
static CGPathRef path_for(const VdShapeSpec* spec, CGRect box) {
  switch (spec->kind) {
    case VD_SHAPE_ELLIPSE:
      return CGPathCreateWithEllipseInRect(box, NULL);
    case VD_SHAPE_LINE: {
      CGMutablePathRef path = CGPathCreateMutable();
      CGPathMoveToPoint(path, NULL, CGRectGetMinX(box), CGRectGetMidY(box));
      CGPathAddLineToPoint(path, NULL, CGRectGetMaxX(box), CGRectGetMidY(box));
      return path;
    }
    case VD_SHAPE_ARROW:
      return NULL;
    case VD_SHAPE_RECT:
    default: {
      // A proportion of the shorter side's half, so 1 is as round as the box
      // allows: a pill on an oblong, a circle on a square.
      CGFloat corner = (CGFloat)spec->corner;
      if (corner < 0) corner = 0;
      if (corner > 1) corner = 1;
      const CGFloat radius =
          corner * MIN(CGRectGetWidth(box), CGRectGetHeight(box)) * 0.5;
      if (radius <= 0) return CGPathCreateWithRect(box, NULL);
      return CGPathCreateWithRoundedRect(box, radius, radius, NULL);
    }
  }
}

// The shaft and the head, in the stroke's colour.
//
// An arrow is the one kind that is not one path: its shaft wants stroking and
// its head wants filling, and a stroked triangle would put a rounded stub
// where the point should be. They are drawn as two operations inside whatever
// transparency layer the caller opened, so the shadow still sees one
// silhouette.
static void draw_arrow(CGContextRef ctx, const VdShapeSpec* spec, CGRect box,
                       CGFloat stroke) {
  const CGFloat length = CGRectGetWidth(box);
  const CGFloat mid = CGRectGetMidY(box);

  CGFloat head = (CGFloat)spec->head_size * length;
  if (head < 0) head = 0;
  if (head > length) head = length;  // an arrow that is all head

  const CGFloat tip = CGRectGetMaxX(box);
  const CGFloat base = tip - head;

  // The shaft stops halfway into the head rather than at its base: a butt cap
  // meeting a triangle leaves a hairline of background between them wherever
  // antialiasing rounds the two edges apart.
  const CGFloat shaft_end = base + head * 0.5;
  if (shaft_end > CGRectGetMinX(box) && stroke > 0) {
    CGContextSetLineWidth(ctx, stroke);
    CGContextMoveToPoint(ctx, CGRectGetMinX(box), mid);
    CGContextAddLineToPoint(ctx, shaft_end, mid);
    CGContextStrokePath(ctx);
  }

  if (head > 0) {
    // As wide as it is long, which is the proportion that reads as an arrow
    // rather than as a needle or a wedge.
    const CGFloat half = head * 0.5;
    CGContextMoveToPoint(ctx, tip, mid);
    CGContextAddLineToPoint(ctx, base, mid + half);
    CGContextAddLineToPoint(ctx, base, mid - half);
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);
  }
}

// --- rendering -------------------------------------------------------------

void* vd_shape_render(const VdShapeSpec* spec, int32_t width, int32_t height,
                      int32_t* out_result) {
  if (out_result) *out_result = VD_OK;
  if (!spec) {
    if (out_result) *out_result = VD_ERR_INVALID_ARG;
    return NULL;
  }

  void* buffer = vd_raster_create(width, height, out_result);
  if (!buffer) return NULL;

  CGContextRef ctx = vd_raster_begin(buffer);
  if (!ctx) {
    CVPixelBufferRelease((CVPixelBufferRef)buffer);
    if (out_result) *out_result = VD_ERR_UNSUPPORTED;
    return NULL;
  }

  const CGRect box = box_for(spec, width, height);
  const bool line = spec->kind == VD_SHAPE_LINE || spec->kind == VD_SHAPE_ARROW;

  CGFloat stroke = (CGFloat)spec->stroke_width * (CGFloat)height;
  if (stroke < 0) stroke = 0;
  const bool stroked = stroke > 0 && vd_raster_visible(spec->stroke_color);
  // A line has no interior to fill, so its fill colour says nothing about it.
  const bool filled = !line && vd_raster_visible(spec->fill_color);

  if ((filled || stroked) && CGRectGetWidth(box) > 0 &&
      (CGRectGetHeight(box) > 0 || line)) {
    const bool shadowed = vd_raster_visible(spec->shadow_color);
    if (shadowed) {
      CGColorRef colour = vd_raster_color(spec->shadow_color);
      // The spec's +y is down, the way a light above the frame throws it;
      // Core Graphics' is up.
      CGContextSetShadowWithColor(
          ctx,
          CGSizeMake((CGFloat)spec->shadow_dx * (CGFloat)height,
                     -(CGFloat)spec->shadow_dy * (CGFloat)height),
          (CGFloat)spec->shadow_blur * (CGFloat)height, colour);
      CGColorRelease(colour);
      // One shadow for the whole shape rather than one per drawing operation.
      // Without the layer a stroked shape casts two — the fill's and the
      // stroke's — and they show through each other wherever the shape is not
      // opaque, which looks like a rendering bug because it is one.
      CGContextBeginTransparencyLayer(ctx, NULL);
      CGContextSetShadowWithColor(ctx, CGSizeZero, 0, NULL);
    }

    if (spec->kind == VD_SHAPE_ARROW) {
      CGColorRef colour = vd_raster_color(spec->stroke_color);
      CGContextSetStrokeColorWithColor(ctx, colour);
      CGContextSetFillColorWithColor(ctx, colour);
      CGColorRelease(colour);
      if (stroked || spec->head_size > 0) {
        draw_arrow(ctx, spec, box, stroked ? stroke : 0);
      }
    } else {
      CGPathRef path = path_for(spec, box);
      if (path) {
        if (filled) {
          CGColorRef colour = vd_raster_color(spec->fill_color);
          CGContextSetFillColorWithColor(ctx, colour);
          CGColorRelease(colour);
          CGContextAddPath(ctx, path);
          CGContextFillPath(ctx);
        }
        // Over the fill rather than under it, which is what every drawing
        // program does: a stroke straddles the edge, so drawing it second is
        // what keeps a filled shape the size its box says it is.
        if (stroked) {
          CGColorRef colour = vd_raster_color(spec->stroke_color);
          CGContextSetStrokeColorWithColor(ctx, colour);
          CGColorRelease(colour);
          CGContextSetLineWidth(ctx, stroke);
          CGContextAddPath(ctx, path);
          CGContextStrokePath(ctx);
        }
        CGPathRelease(path);
      }
    }

    if (shadowed) CGContextEndTransparencyLayer(ctx);
  }

  vd_raster_finish(buffer, ctx);
  return buffer;
}
