// vd_raster.h — the frame a drawn source draws into.
//
// A caption and a shape are the same kind of thing: neither decodes anything,
// both hand the compositor an output-sized premultiplied BGRA buffer, and both
// need exactly three things to make one — an IOSurface-backed pixel buffer, a
// Core Graphics context over it, and a colour in the context's own space.
// This is that, written once, because two copies of it is two things to keep
// in step and the one that drifts is the one nobody is looking at.
//
// Engine-internal. Nothing across the FFI boundary knows this exists: the app
// asks for a caption or a shape and gets pixels, and where the pixels came
// from is not its business.
//
// Everything here draws in Core Graphics' own coordinates, origin bottom left.
// A bitmap context stores its first row as the *top* of the image and maps
// user-space y=0 to the last one, so a CVPixelBuffer drawn into this way comes
// out the right way up with no flip anywhere — and Core Text, which wants an
// unflipped context, gets one. The single place the difference shows is a
// shadow offset, where a spec's downward +y has to be negated.

#ifndef VD_RASTER_H
#define VD_RASTER_H

#include <stdbool.h>
#include <stdint.h>

#include <CoreGraphics/CoreGraphics.h>

#include "vdodtor/vd_time.h"

#ifdef __cplusplus
extern "C" {
#endif

// A new `width` x `height` CVPixelBufferRef: 32BGRA, **premultiplied**,
// IOSurface-backed and Metal-compatible, so the compositor wraps it without a
// copy. Caller releases with CVPixelBufferRelease. NULL on failure, with
// `out_result` — which may be NULL — set to a negative VdResult.
VD_EXPORT void* vd_raster_create(int32_t width, int32_t height,
                                 int32_t* out_result);

// A Core Graphics context over `pixel_buffer`, cleared to transparent and set
// up for drawing that will be composited over something else.
//
// Locks the buffer's base address; `vd_raster_finish` unlocks it. NULL if a
// context could not be made, in which case the buffer is already unlocked.
VD_EXPORT CGContextRef vd_raster_begin(void* pixel_buffer);

// Flushes `ctx`, releases it and unlocks `pixel_buffer`. The buffer itself is
// left alone — it is what the caller came for.
VD_EXPORT void vd_raster_finish(void* pixel_buffer, CGContextRef ctx);

// The colour space every raster and every colour in it is in.
VD_EXPORT CGColorSpaceRef vd_raster_srgb(void);

// 0xAARRGGBB, straight (not premultiplied) — the document writes these and a
// human reads them, and premultiplied colour is neither. Caller releases with
// CGColorRelease.
VD_EXPORT CGColorRef vd_raster_color(uint32_t argb);

// Whether a colour would mark the frame at all. Alpha 0 is how every optional
// part of a drawn source is switched off — a shadow colour with no alpha casts
// no shadow, a fill with none draws no fill — which is one rule rather than a
// boolean beside every colour that could disagree with it.
VD_EXPORT bool vd_raster_visible(uint32_t argb);

#ifdef __cplusplus
}
#endif
#endif  // VD_RASTER_H
