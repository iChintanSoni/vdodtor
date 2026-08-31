#include "vdodtor/vd_thumbnail.h"

#include <stdlib.h>
#include <string.h>

#include "vdodtor/vd_compositor.h"
#include "vdodtor/vd_decoder.h"
#include "vdodtor/vd_probe.h"

// Thumbnails are drawn at a handful of points; they are not a video signal, so
// there is nothing to gain from keeping decoded frames around after the one
// frame we came for.
#define VD_THUMB_CACHE_FRAMES 2

// Rounded down to even, floored at 2. The compositor's output is a 4:2:0-
// friendly BGRA buffer everywhere else in the engine, and a 1-pixel-wide
// thumbnail is not a thing anyone wants either way.
static int32_t even_at_least_two(double value) {
  int32_t v = (int32_t)(value + 0.5);
  if (v < 2) return 2;
  return v - (v % 2);
}

// The size the source wants to be shown at, before it is fitted into a box:
// coded dimensions with the sample aspect and then the rotation applied.
static void display_size(const VdProbeInfo* info, double* out_w,
                         double* out_h) {
  double w = (double)info->width;
  double h = (double)info->height;

  if (info->pixel_aspect.num > 0 && info->pixel_aspect.den > 0) {
    w *= (double)info->pixel_aspect.num / (double)info->pixel_aspect.den;
  }
  if (info->rotation_degrees % 180 != 0) {
    const double swap = w;
    w = h;
    h = swap;
  }
  *out_w = w;
  *out_h = h;
}

int32_t vd_thumbnail_render(const char* path, VdTick t, int32_t max_width,
                            int32_t max_height, VdThumbnail* out) {
  if (out) memset(out, 0, sizeof(*out));
  if (!path || !out || max_width < 2 || max_height < 2) {
    return VD_ERR_INVALID_ARG;
  }

  VdDecoderOptions options = vd_decoder_default_options();
  options.cache_capacity = VD_THUMB_CACHE_FRAMES;

  int32_t result = VD_OK;
  VdDecoder* decoder = vd_decoder_open(path, options, &result);
  if (!decoder) return result == VD_OK ? VD_ERR_OPEN : result;

  VdProbeInfo info;
  result = vd_decoder_info(decoder, &info);
  if (result != VD_OK || !info.has_video || info.width <= 0 ||
      info.height <= 0) {
    vd_decoder_close(decoder);
    return result == VD_OK ? VD_ERR_DECODE : result;
  }

  double source_w = 0;
  double source_h = 0;
  display_size(&info, &source_w, &source_h);

  double scale = (double)max_width / source_w;
  const double scale_h = (double)max_height / source_h;
  if (scale_h < scale) scale = scale_h;
  // Never upscale: a 160x120 clip in a 320-wide bin should stay sharp and
  // small rather than become a blurry 320.
  if (scale > 1.0) scale = 1.0;

  const int32_t width = even_at_least_two(source_w * scale);
  const int32_t height = even_at_least_two(source_h * scale);

  VdFrame frame;
  memset(&frame, 0, sizeof(frame));
  result = vd_decoder_frame_at(decoder, t, &frame);
  if (result != VD_OK || !frame.pixel_buffer) {
    vd_frame_release(&frame);
    vd_decoder_close(decoder);
    return result == VD_OK ? VD_ERR_DECODE : result;
  }

  VdCompositor* compositor = vd_compositor_create(width, height, &result);
  if (!compositor) {
    vd_frame_release(&frame);
    vd_decoder_close(decoder);
    return result == VD_OK ? VD_ERR_UNSUPPORTED : result;
  }

  // Contain, into a box that already has the source's own aspect: the fit is
  // a formality here, and picking it anyway means a source whose sample aspect
  // the probe got wrong is letterboxed rather than stretched.
  VdLayer layer;
  memset(&layer, 0, sizeof(layer));
  layer.pixel_buffer = frame.pixel_buffer;
  layer.format = frame.format;
  layer.rotation_degrees = info.rotation_degrees;
  layer.pixel_aspect = info.pixel_aspect;
  layer.color_matrix = frame.color_matrix;
  layer.full_range = frame.full_range;
  layer.fit = VD_FIT_CONTAIN;
  layer.opacity = 1.0f;

  result = vd_compositor_render(compositor, &layer, 1);
  vd_frame_release(&frame);
  vd_decoder_close(decoder);

  if (result != VD_OK) {
    vd_compositor_destroy(compositor);
    return result;
  }

  const int64_t bytes = (int64_t)width * height * 4;
  uint8_t* pixels = (uint8_t*)malloc((size_t)bytes);
  if (!pixels) {
    vd_compositor_destroy(compositor);
    return VD_ERR_UNSUPPORTED;
  }

  result = vd_compositor_copy_pixels(compositor, pixels, bytes);
  vd_compositor_destroy(compositor);
  if (result != VD_OK) {
    free(pixels);
    return result;
  }

  out->width = width;
  out->height = height;
  out->pixels = pixels;
  return VD_OK;
}

void vd_thumbnail_free(VdThumbnail* thumb) {
  if (!thumb) return;
  free(thumb->pixels);
  memset(thumb, 0, sizeof(*thumb));
}
