#include "vdodtor/vd_thumbnail.h"

#include <stdlib.h>
#include <string.h>

#include "vdodtor/vd_compositor.h"
#include "vdodtor/vd_decoder.h"
#include "vdodtor/vd_probe.h"
#include "vdodtor/vd_sticker.h"

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

// Everything after "which pixels", which is the same for both kinds of source:
// composite the one layer into a `width` x `height` frame and copy it out.
static int32_t finish(VdCompositor* compositor, const VdLayer* layer,
                      int32_t width, int32_t height, VdThumbnail* out);

// An animated overlay's first frame.
//
// A branch of its own rather than a decoder that copes, because vd_decoder
// cannot open one of these at all: it exports VideoToolbox or YUV420P and a
// GIF is neither. Without this every sticker in the bin is a blank rectangle.
static int32_t render_sticker(const char* path, VdTick t, int32_t width,
                              int32_t height, const VdProbeInfo* info,
                              VdThumbnail* out) {
  VdStickerOptions options = vd_sticker_default_options();
  // A thumbnail needs no more pixels than it has, and this is the whole
  // animation being decoded to show one frame of it.
  options.max_side = width > height ? width : height;

  int32_t result = VD_OK;
  VdSticker* sticker = vd_sticker_open(path, options, &result);
  if (!sticker) return result == VD_OK ? VD_ERR_OPEN : result;

  void* buffer = vd_sticker_frame_at(sticker, t, NULL);
  if (!buffer) {
    vd_sticker_close(sticker);
    return VD_ERR_DECODE;
  }

  VdCompositor* compositor = vd_compositor_create(width, height, &result);
  if (!compositor) {
    vd_sticker_close(sticker);
    return result == VD_OK ? VD_ERR_UNSUPPORTED : result;
  }

  VdLayer layer;
  memset(&layer, 0, sizeof(layer));
  layer.pixel_buffer = buffer;
  layer.format = VD_PIXEL_BGRA;
  layer.rotation_degrees = info->rotation_degrees;
  layer.pixel_aspect = info->pixel_aspect;
  layer.fit = VD_FIT_CONTAIN;
  layer.opacity = 1.0f;

  result = finish(compositor, &layer, width, height, out);
  vd_sticker_close(sticker);
  return result;
}

int32_t vd_thumbnail_render(const char* path, VdTick t, int32_t max_width,
                            int32_t max_height, VdThumbnail* out) {
  if (out) memset(out, 0, sizeof(*out));
  if (!path || !out || max_width < 2 || max_height < 2) {
    return VD_ERR_INVALID_ARG;
  }

  // Probed before anything is opened, because what a file *is* decides how to
  // open it and the two kinds of source have nothing in common below this
  // line. It costs one more file open on a path that is already going to
  // decode a frame and build a Metal compositor.
  VdProbeInfo info;
  int32_t result = vd_probe_file(path, &info);
  if (result != VD_OK) return result;
  // A file with no picture says so specifically, and differently from one that
  // would not open at all: the bin draws a waveform icon for the first and an
  // error for the second, and it can only tell them apart if this does.
  if (!info.has_video) return VD_ERR_UNSUPPORTED;
  if (info.width <= 0 || info.height <= 0) return VD_ERR_DECODE;

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

  if (vd_sticker_is_sticker_codec(info.video_codec)) {
    return render_sticker(path, t, width, height, &info, out);
  }

  VdDecoderOptions options = vd_decoder_default_options();
  options.cache_capacity = VD_THUMB_CACHE_FRAMES;

  VdDecoder* decoder = vd_decoder_open(path, options, &result);
  if (!decoder) return result == VD_OK ? VD_ERR_OPEN : result;

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

  // The frame is copied into the compositor's own output by the render, so it
  // is released here rather than after — and the decoder with it, because
  // nothing below this line reads either.
  result = finish(compositor, &layer, width, height, out);
  vd_frame_release(&frame);
  vd_decoder_close(decoder);
  return result;
}

// Destroys `compositor` on every path, including the failing ones.
static int32_t finish(VdCompositor* compositor, const VdLayer* layer,
                      int32_t width, int32_t height, VdThumbnail* out) {
  int32_t result = vd_compositor_render(compositor, layer, 1);
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
