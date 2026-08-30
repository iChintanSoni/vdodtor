// vd_compositor.h — decoded frames in, one composited frame out.
//
// There is exactly one compositor. Preview and export both come through here
// and differ only in what drives the clock and where the output goes; if they
// ever diverge, the thing the user sees while editing stops predicting the
// thing they get when they export, which is the single most corrosive bug a
// video editor can have.
//
// Everything here is synchronous and owns no clock. Layers in, frame out.

#ifndef VD_COMPOSITOR_H
#define VD_COMPOSITOR_H

#include <stdbool.h>
#include <stdint.h>

#include "vdodtor/vd_decoder.h"
#include "vdodtor/vd_time.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VdCompositor VdCompositor;

// How a source that does not match the output aspect is placed.
typedef enum {
  VD_FIT_CONTAIN = 0,  // whole frame visible, letterboxed
  VD_FIT_COVER = 1,    // fills the output, edges cropped
  VD_FIT_STRETCH = 2,  // ignores aspect
} VdFitMode;

typedef struct {
  // CVPixelBufferRef from vd_decoder_frame_at. Borrowed for the duration of
  // the call; the compositor does not retain it.
  void* pixel_buffer;
  VdPixelFormat format;

  // Clockwise degrees to rotate for display: 0, 90, 180, 270.
  int32_t rotation_degrees;

  // Copied straight from the VdFrame the buffer came out of.
  VdColorMatrix color_matrix;
  bool full_range;

  VdFitMode fit;
  float opacity;  // 0..1
} VdLayer;

// Creates a compositor rendering `width` x `height` BGRA frames.
// `out_result` may be NULL.
VD_EXPORT VdCompositor* vd_compositor_create(int32_t width, int32_t height,
                                             int32_t* out_result);
VD_EXPORT void vd_compositor_destroy(VdCompositor* compositor);

VD_EXPORT int32_t vd_compositor_width(const VdCompositor* compositor);
VD_EXPORT int32_t vd_compositor_height(const VdCompositor* compositor);

// Composites `layers` bottom-to-top onto black and publishes the result.
// Blocks until the GPU is done, so the frame is ready to hand to Flutter or an
// encoder the moment this returns.
VD_EXPORT int32_t vd_compositor_render(VdCompositor* compositor,
                                       const VdLayer* layers,
                                       int32_t layer_count);

// The most recent composited frame, retained. Caller releases with
// CVPixelBufferRelease. NULL before the first render.
VD_EXPORT void* vd_compositor_copy_output(VdCompositor* compositor);

// Milliseconds of GPU time the last render took.
VD_EXPORT double vd_compositor_last_gpu_ms(const VdCompositor* compositor);

// Writes the last composited frame to `path` as PNG. This is how the
// compositor gets checked on pixels rather than on timings.
VD_EXPORT int32_t vd_compositor_dump_png(VdCompositor* compositor,
                                         const char* path);

// Reads one pixel of the last composited frame, as 8-bit BGRA. Out of range
// returns false. For tests: an assertion on colour is worth more than an
// assertion on frame count.
VD_EXPORT bool vd_compositor_read_pixel(VdCompositor* compositor, int32_t x,
                                        int32_t y, uint8_t* out_bgra);

// Copies the last composited frame into `out` as tightly packed BGRA —
// width * height * 4 bytes, no row padding. The output buffer the GPU writes
// into is padded to a stride of its own choosing, and every consumer outside
// this file (Flutter's decodeImageFromPixels, an encoder, a PNG writer) wants
// it packed, so the unpacking happens once, here.
//
// Returns VD_ERR_INVALID_ARG if `capacity` is short of that. A compositor
// that has not rendered yet copies out black, the same thing it would show.
VD_EXPORT int32_t vd_compositor_copy_pixels(VdCompositor* compositor,
                                            uint8_t* out, int64_t capacity);

#ifdef __cplusplus
}
#endif
#endif  // VD_COMPOSITOR_H
