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

#include "vdodtor/vd_color.h"
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
  // Whole frame visible, and the bars filled with a blurred, cover-fitted
  // copy of the same picture rather than black. Costs three extra passes, and
  // only when there are bars to fill — a clip that already fills the output
  // takes the ordinary path.
  VD_FIT_BLUR = 3,
} VdFitMode;

// What a clip does to itself before it is composited: where it sits, how big
// it is, which way up, and how much of it shows.
//
// Every field is defined so that **a zeroed struct is the identity**. A caller
// that does not care about transforms can `memset` its layers and never learn
// this field exists, which is worth more than the two lines it costs to treat
// a zero scale as one.
//
// Applied in this order, about the layer's own centre: crop, then the fit the
// mode asked for, then scale, then rotation, then offset. Crop first because
// cropping changes the aspect ratio, and a fit computed before it would letter
// box the part that was thrown away.
typedef struct {
  // Offset from the centre of the output, as a fraction of the output's own
  // width and height. {0,0} is centred; {0.5,0} is off the right edge.
  float offset_x;
  float offset_y;

  // Uniform multiplier on the fitted size. 0 and 1 both mean "as fitted".
  float scale;

  // Extra clockwise rotation in degrees, on top of whatever the source's own
  // orientation metadata already asked for. Any angle, not just quarter turns.
  float rotation_degrees;

  // The part of the *display-oriented* source to show, normalised, origin top
  // left. A zeroed width or height means the whole thing.
  float crop_x;
  float crop_y;
  float crop_w;
  float crop_h;

  // Mirrored horizontally / vertically, in display orientation.
  bool flip_h;
  bool flip_v;
} VdTransform;

// The identity, spelled out. Equivalent to a zeroed struct; this exists so
// callers can say what they mean.
VD_EXPORT VdTransform vd_transform_identity(void);

// How much of a layer to cut away from each side, as fractions of its own
// rectangle. Zeroed cuts nothing away — see VdLayer::reveal.
typedef struct {
  float left;
  float top;
  float right;
  float bottom;
} VdReveal;

typedef struct {
  // CVPixelBufferRef from vd_decoder_frame_at. Borrowed for the duration of
  // the call; the compositor does not retain it.
  void* pixel_buffer;
  VdPixelFormat format;

  // Clockwise degrees to rotate for display: 0, 90, 180, 270.
  int32_t rotation_degrees;

  // The source's sample aspect: how much wider one of its pixels is than it
  // is tall. {0,0} and {1,1} both mean square, so a caller with square pixels
  // can leave it zeroed. Applied before the rotation, because a turn swaps
  // which axis the stretch is on.
  //
  // This is what makes a 4:3 DVD frame stored as 720x480 come out 4:3 rather
  // than squeezed to 3:2. It belongs on the layer rather than being folded
  // into the coded size by the decoder, because the pixels really are 720
  // across — only the shape they are meant to be shown at differs.
  VdRational pixel_aspect;

  // Copied straight from the VdFrame the buffer came out of.
  VdColorMatrix color_matrix;
  bool full_range;

  VdFitMode fit;
  float opacity;  // 0..1

  // How much of the layer to cut away from each side, as fractions of its own
  // rectangle. A zeroed value cuts nothing away, so a caller with nothing to
  // say about it can leave the field alone.
  //
  // A hard edge rather than a fade, and in the layer's *own* space rather than
  // the output's, so it travels with the clip if the clip is also moving. This
  // is the one thing a transition needs that a transform cannot express: a
  // wipe is an edge crossing a picture that is standing still, where a crop
  // would shrink the picture and a scale would move it.
  VdReveal reveal;

  // Where this layer goes and how much of it shows. A zeroed transform is the
  // identity, so this may be ignored entirely.
  VdTransform transform;

  // What this layer does to its own colour: brightness, contrast, saturation,
  // temperature, tint. A zeroed value is the neutral grade, so this is another
  // field a caller can leave alone — see vd_color.h.
  //
  // Per layer rather than per frame, and that is the decision. A grade on the
  // frame would be an effect on the *project*, which is a different feature
  // and a worse one to have by accident: a shot that needed warming would warm
  // the caption over it and the shot on the lane beneath it too. Here it
  // travels with the clip, the way its opacity and its transform do, and a
  // blur-filled clip's backdrop is graded with it because the backdrop is the
  // same picture.
  VdColorAdjust color;
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
