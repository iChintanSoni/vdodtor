#include "vdodtor/vd_sticker.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include <CoreVideo/CoreVideo.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>

#include "vdodtor/vd_probe.h"
#include "vdodtor/vd_raster.h"

// Sixty-four megabytes of decoded RGBA, which is a 480x480 animation about
// seventy frames long — comfortably more than the stickers people actually
// use, and small enough that several on one timeline still fit in the engine's
// budget. Past it the animation is decoded smaller rather than shorter.
#define VD_STICKER_DEFAULT_BYTES (64 * 1024 * 1024)

// What a frame is on screen for when the file will not say: neither its own
// timestamps nor the container's rate were usable. A tenth of a second is
// GIF's own default delay, so this is the number the format itself falls back
// to.
#define VD_STICKER_FALLBACK_TICKS (VD_TICKS_PER_SECOND / 10)

// A file claiming more frames than this is not a sticker, whatever its codec
// says. The count comes from demuxing, so it is exact rather than a container
// claim — but a budget spread over a hundred thousand frames would decode each
// one at a pixel or two across, and a shape nobody can see is worse than a
// file that would not open.
#define VD_STICKER_MAX_FRAMES 20000

typedef struct {
  // Start of this frame's interval, in project ticks, measured from the start
  // of the animation. The interval ends where the next one starts.
  VdTick pts;
  VdTick duration;
} VdStickerFrame;

struct VdSticker {
  int32_t width;
  int32_t height;
  int32_t frame_count;
  VdTick duration;

  // Every frame's pixels, premultiplied BGRA, back to back. One allocation
  // rather than one per frame: the frames are the same size and they all live
  // and die together, so there is nothing an array of pointers would buy.
  uint8_t* pixels;
  size_t frame_bytes;
  VdStickerFrame* frames;

  // The one buffer the compositor is ever handed, and which frame is in it.
  // -1 before the first lookup.
  CVPixelBufferRef current;
  int32_t current_index;
};

VdStickerOptions vd_sticker_default_options(void) {
  VdStickerOptions options = {.max_bytes = VD_STICKER_DEFAULT_BYTES,
                              .max_side = 0};
  return options;
}

bool vd_sticker_is_sticker_codec(const char* codec) {
  if (!codec || !*codec) return false;
  // `webp` covers both the still and the animated decoder, which is deliberate
  // — see the note in vd_sticker.h. A still WebP is a one-frame animation and
  // draws as one, keeping its alpha on the way, which is more than the video
  // path would do for it.
  return strcmp(codec, "gif") == 0 || strcmp(codec, "apng") == 0 ||
         strcmp(codec, "webp") == 0 || strcmp(codec, "webp_anim") == 0;
}

// --- opening ---------------------------------------------------------------

// How many video packets `path` holds, or -1. Demuxed rather than read off the
// container: `nb_frames` is right for GIF and absent for APNG, and a budget
// that has to be spent before the first pixel is written cannot be based on a
// field two of the three formats leave empty.
static int32_t count_frames(const char* path, int32_t* out_stream) {
  AVFormatContext* fmt = NULL;
  if (avformat_open_input(&fmt, path, NULL, NULL) < 0) return -1;
  if (avformat_find_stream_info(fmt, NULL) < 0) {
    avformat_close_input(&fmt);
    return -1;
  }
  const int stream = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
  if (stream < 0) {
    avformat_close_input(&fmt);
    return -1;
  }
  *out_stream = stream;

  int32_t count = 0;
  AVPacket* packet = av_packet_alloc();
  while (packet && av_read_frame(fmt, packet) >= 0) {
    if (packet->stream_index == stream) count++;
    av_packet_unref(packet);
    if (count > VD_STICKER_MAX_FRAMES) break;
  }
  av_packet_free(&packet);
  avformat_close_input(&fmt);
  return count;
}

// The size to decode at, given how many frames there are and what may be
// spent on them. Never smaller than 1x1, and never larger than the file.
static void fit_budget(int32_t src_w, int32_t src_h, int32_t frames,
                       const VdStickerOptions* options, int32_t* out_w,
                       int32_t* out_h) {
  double scale = 1.0;

  if (options->max_side > 0) {
    const int32_t longest = src_w > src_h ? src_w : src_h;
    if (longest > options->max_side) {
      scale = (double)options->max_side / (double)longest;
    }
  }

  const int64_t max_bytes =
      options->max_bytes > 0 ? options->max_bytes : VD_STICKER_DEFAULT_BYTES;
  const double bytes = (double)src_w * (double)src_h * 4.0 * (double)frames *
                       scale * scale;
  if (bytes > (double)max_bytes) {
    // Area scales with the square of the side, so the side scales with the
    // square root of the ratio. One multiply rather than a loop that halves
    // until it fits, which would throw away up to three quarters of the
    // budget on the last step.
    scale *= sqrt((double)max_bytes / bytes);
  }

  int32_t w = (int32_t)lround((double)src_w * scale);
  int32_t h = (int32_t)lround((double)src_h * scale);
  if (w < 1) w = 1;
  if (h < 1) h = 1;
  if (w > src_w) w = src_w;
  if (h > src_h) h = src_h;
  *out_w = w;
  *out_h = h;
}

// Straight alpha to premultiplied, in place.
//
// swscale converts the pixels and not the alpha convention, and the compositor
// takes premultiplied — the same thing a caption's raster arrives as. Skipped
// where a scanline is opaque, which is most of most stickers.
static void premultiply(uint8_t* row, int32_t width) {
  for (int32_t x = 0; x < width; x++) {
    uint8_t* p = row + (size_t)x * 4;
    const uint32_t a = p[3];
    if (a == 255) continue;
    if (a == 0) {
      p[0] = p[1] = p[2] = 0;
      continue;
    }
    // +127 rather than truncation: rounding down here darkens every soft edge
    // in the sticker by half a level, which is visible on a gradient.
    p[0] = (uint8_t)((p[0] * a + 127) / 255);
    p[1] = (uint8_t)((p[1] * a + 127) / 255);
    p[2] = (uint8_t)((p[2] * a + 127) / 255);
  }
}

// Turns the timestamps collected while decoding into intervals that tile the
// animation with no gaps.
//
// A frame is on screen until the next one starts — the same rule vd_decoder
// follows and for the same reason, except that here every frame is already in
// hand, so there is nothing to confirm later. The last frame is the only one
// with no successor, and it keeps whatever the container said it was worth.
static void resolve_intervals(VdSticker* s, const VdTick* pts,
                              VdTick last_duration) {
  bool monotonic = true;
  for (int32_t i = 1; i < s->frame_count; i++) {
    if (pts[i] <= pts[i - 1]) {
      monotonic = false;
      break;
    }
  }

  if (!monotonic || pts[0] != 0) {
    // Timestamps that do not advance say nothing about when frames change, so
    // the file gets an even cadence instead of a nonsense one. Better a
    // sticker that plays evenly than one that shows every frame at once.
    const VdTick step =
        last_duration > 0 ? last_duration : VD_STICKER_FALLBACK_TICKS;
    for (int32_t i = 0; i < s->frame_count; i++) {
      s->frames[i].pts = (VdTick)i * step;
      s->frames[i].duration = step;
    }
    s->duration = (VdTick)s->frame_count * step;
    return;
  }

  for (int32_t i = 0; i < s->frame_count; i++) {
    s->frames[i].pts = pts[i];
    s->frames[i].duration = i + 1 < s->frame_count
                                ? pts[i + 1] - pts[i]
                                : (last_duration > 0 ? last_duration
                                                     : VD_STICKER_FALLBACK_TICKS);
  }
  s->duration = s->frames[s->frame_count - 1].pts +
                s->frames[s->frame_count - 1].duration;
}

VdSticker* vd_sticker_open(const char* path, VdStickerOptions options,
                           int32_t* out_result) {
  if (out_result) *out_result = VD_OK;
  if (!path || !*path) {
    if (out_result) *out_result = VD_ERR_INVALID_ARG;
    return NULL;
  }

  int32_t stream_index = -1;
  const int32_t expected = count_frames(path, &stream_index);
  if (expected <= 0 || expected > VD_STICKER_MAX_FRAMES) {
    if (out_result) {
      *out_result = expected == 0 ? VD_ERR_NO_STREAMS
                                  : (expected < 0 ? VD_ERR_OPEN
                                                  : VD_ERR_UNSUPPORTED);
    }
    return NULL;
  }

  AVFormatContext* fmt = NULL;
  AVCodecContext* codec_ctx = NULL;
  AVPacket* packet = NULL;
  AVFrame* frame = NULL;
  struct SwsContext* sws = NULL;
  VdTick* pts = NULL;
  VdSticker* s = NULL;
  int32_t result = VD_ERR_OPEN;

  if (avformat_open_input(&fmt, path, NULL, NULL) < 0) goto fail;
  if (avformat_find_stream_info(fmt, NULL) < 0) {
    result = VD_ERR_NO_STREAMS;
    goto fail;
  }

  const AVCodec* codec = NULL;
  stream_index = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
  if (stream_index < 0 || !codec) {
    result = VD_ERR_NO_STREAMS;
    goto fail;
  }
  AVStream* stream = fmt->streams[stream_index];

  codec_ctx = avcodec_alloc_context3(codec);
  if (!codec_ctx) goto fail;
  if (avcodec_parameters_to_context(codec_ctx, stream->codecpar) < 0) goto fail;
  if (avcodec_open2(codec_ctx, codec, NULL) < 0) {
    result = VD_ERR_UNSUPPORTED;
    goto fail;
  }

  const int32_t src_w = codec_ctx->width;
  const int32_t src_h = codec_ctx->height;
  if (src_w <= 0 || src_h <= 0) {
    result = VD_ERR_UNSUPPORTED;
    goto fail;
  }

  s = (VdSticker*)calloc(1, sizeof(VdSticker));
  if (!s) goto fail;
  s->current_index = -1;
  fit_budget(src_w, src_h, expected, &options, &s->width, &s->height);
  s->frame_bytes = (size_t)s->width * (size_t)s->height * 4u;

  s->pixels = (uint8_t*)malloc(s->frame_bytes * (size_t)expected);
  s->frames = (VdStickerFrame*)calloc((size_t)expected, sizeof(VdStickerFrame));
  pts = (VdTick*)calloc((size_t)expected, sizeof(VdTick));
  if (!s->pixels || !s->frames || !pts) goto fail;

  packet = av_packet_alloc();
  frame = av_frame_alloc();
  if (!packet || !frame) goto fail;

  const VdRational stream_tb = {stream->time_base.num, stream->time_base.den};
  VdTick last_duration = 0;
  VdTick first_pts = 0;
  bool have_first = false;

  // One decode pass. `expected` came from counting packets, so a frame that
  // arrives after the array is full is a decoder emitting more frames than it
  // was given packets — it cannot happen for these codecs, and the bound is
  // here so that it cannot matter if it ever does.
  while (s->frame_count < expected && av_read_frame(fmt, packet) >= 0) {
    if (packet->stream_index != stream_index) {
      av_packet_unref(packet);
      continue;
    }
    const int sent = avcodec_send_packet(codec_ctx, packet);
    const VdTick packet_duration =
        packet->duration > 0
            ? vd_ticks_from_stream_time(packet->duration, stream_tb)
            : 0;
    av_packet_unref(packet);
    if (sent < 0) continue;

    while (s->frame_count < expected &&
           avcodec_receive_frame(codec_ctx, frame) == 0) {
      if (!sws) {
        sws = sws_getContext(frame->width, frame->height, frame->format,
                             s->width, s->height, AV_PIX_FMT_BGRA,
                             SWS_BILINEAR, NULL, NULL, NULL);
        if (!sws) {
          av_frame_unref(frame);
          result = VD_ERR_UNSUPPORTED;
          goto fail;
        }
      }

      uint8_t* dst = s->pixels + s->frame_bytes * (size_t)s->frame_count;
      uint8_t* dst_planes[4] = {dst, NULL, NULL, NULL};
      int dst_stride[4] = {s->width * 4, 0, 0, 0};
      sws_scale(sws, (const uint8_t* const*)frame->data, frame->linesize, 0,
                frame->height, dst_planes, dst_stride);
      for (int32_t y = 0; y < s->height; y++) {
        premultiply(dst + (size_t)y * (size_t)s->width * 4u, s->width);
      }

      const int64_t stamp =
          frame->best_effort_timestamp != AV_NOPTS_VALUE
              ? frame->best_effort_timestamp
              : (frame->pts != AV_NOPTS_VALUE ? frame->pts : 0);
      if (!have_first) {
        first_pts = vd_ticks_from_stream_time(stamp, stream_tb);
        have_first = true;
      }
      // Measured from the first frame rather than from zero: a container that
      // starts its timestamps somewhere else must not put an empty gap at the
      // head of every loop.
      pts[s->frame_count] = vd_ticks_from_stream_time(stamp, stream_tb) - first_pts;
      if (packet_duration > 0) last_duration = packet_duration;
      s->frame_count++;
      av_frame_unref(frame);
    }
  }

  if (s->frame_count == 0) {
    result = VD_ERR_DECODE;
    goto fail;
  }

  resolve_intervals(s, pts, last_duration);
  if (s->duration <= 0) s->duration = VD_STICKER_FALLBACK_TICKS;

  s->current = (CVPixelBufferRef)vd_raster_create(s->width, s->height, NULL);
  if (!s->current) {
    result = VD_ERR_OPEN;
    goto fail;
  }

  free(pts);
  sws_freeContext(sws);
  av_frame_free(&frame);
  av_packet_free(&packet);
  avcodec_free_context(&codec_ctx);
  avformat_close_input(&fmt);
  return s;

fail:
  free(pts);
  if (sws) sws_freeContext(sws);
  if (frame) av_frame_free(&frame);
  if (packet) av_packet_free(&packet);
  if (codec_ctx) avcodec_free_context(&codec_ctx);
  if (fmt) avformat_close_input(&fmt);
  vd_sticker_close(s);
  if (out_result) *out_result = result;
  return NULL;
}

void vd_sticker_close(VdSticker* s) {
  if (!s) return;
  if (s->current) CVPixelBufferRelease(s->current);
  free(s->pixels);
  free(s->frames);
  free(s);
}

// --- reading ---------------------------------------------------------------

VdTick vd_sticker_duration(const VdSticker* s) { return s ? s->duration : 0; }
int32_t vd_sticker_frame_count(const VdSticker* s) {
  return s ? s->frame_count : 0;
}
int32_t vd_sticker_width(const VdSticker* s) { return s ? s->width : 0; }
int32_t vd_sticker_height(const VdSticker* s) { return s ? s->height : 0; }

int64_t vd_sticker_bytes(const VdSticker* s) {
  return s ? (int64_t)s->frame_bytes * (int64_t)s->frame_count : 0;
}

// The frame whose interval contains `t`, which is already inside one loop.
static int32_t index_at(const VdSticker* s, VdTick t) {
  int32_t low = 0;
  int32_t high = s->frame_count - 1;
  while (low < high) {
    const int32_t mid = low + (high - low + 1) / 2;
    if (s->frames[mid].pts <= t) {
      low = mid;
    } else {
      high = mid - 1;
    }
  }
  return low;
}

void* vd_sticker_frame_at(VdSticker* s, VdTick t, bool* out_changed) {
  if (out_changed) *out_changed = false;
  if (!s || s->frame_count <= 0 || !s->current) return NULL;

  // Looping, and the same arithmetic in both directions: C's % keeps the sign
  // of the dividend, so a negative offset has to be brought back up into the
  // loop rather than clamped to its start. A clip dragged to begin before its
  // source should show the animation running, not frozen on frame one.
  VdTick into = s->duration > 0 ? t % s->duration : 0;
  if (into < 0) into += s->duration;

  const int32_t index = index_at(s, into);
  if (index == s->current_index) return s->current;

  CVPixelBufferLockBaseAddress(s->current, 0);
  uint8_t* base = (uint8_t*)CVPixelBufferGetBaseAddress(s->current);
  const size_t stride = CVPixelBufferGetBytesPerRow(s->current);
  const uint8_t* src = s->pixels + s->frame_bytes * (size_t)index;
  const size_t row = (size_t)s->width * 4u;
  // Row by row rather than in one go: a CVPixelBuffer's stride is rounded up
  // for alignment and is not the row width, so a single memcpy would shear the
  // picture on every size the allocator decided to pad.
  for (int32_t y = 0; y < s->height; y++) {
    memcpy(base + (size_t)y * stride, src + (size_t)y * row, row);
  }
  CVPixelBufferUnlockBaseAddress(s->current, 0);

  s->current_index = index;
  if (out_changed) *out_changed = true;
  return s->current;
}
