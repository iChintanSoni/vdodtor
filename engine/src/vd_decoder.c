#include "vdodtor/vd_decoder.h"

#include <stdlib.h>
#include <string.h>

#include <CoreVideo/CoreVideo.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>

// Frames held for reuse. Sized so a scrub that jogs back and forth across
// about a second of 30 fps footage never re-decodes, while the memory stays
// bounded: 32 4K frames of NV12 is roughly 400 MB of IOSurface, which is why
// this is deliberately not larger.
#define VD_DEFAULT_CACHE 32
#define VD_MAX_CACHE 128

// How far ahead it is worth decoding rather than seeking. Seeking costs a
// keyframe jump plus every frame from there, so for short hops forward the
// straight-line decode is cheaper and, more importantly, does not throw away
// the frames already in flight.
#define VD_FORWARD_WINDOW_TICKS (VD_TICKS_PER_SECOND / 2)

typedef struct {
  AVFrame* frame;   // ref-counted; NULL when the slot is empty
  VdTick pts;
  VdTick duration;
  int64_t used;     // LRU stamp
} VdCacheSlot;

struct VdDecoder {
  AVFormatContext* fmt;
  AVCodecContext* codec;
  AVBufferRef* hw_device;
  AVPacket* packet;
  AVFrame* frame;
  AVFrame* sw_frame;      // scratch for the software path

  int stream_index;
  VdRational stream_tb;
  VdProbeInfo info;
  VdTick nominal_duration;  // one frame at the nominal rate

  // Where the decoder currently sits: the pts of the next frame it will
  // produce if simply asked to continue. VD_UNKNOWN_POS before the first
  // decode and after a seek.
  VdTick position;
  bool position_known;
  bool eof;

  VdTick* keyframes;
  int32_t keyframe_count;

  VdCacheSlot* cache;
  int32_t cache_capacity;
  int64_t clock;

  VdDecoderStats stats;
};

// --- helpers ---------------------------------------------------------------

static VdRational rational_of(AVRational r) {
  VdRational out = {r.num, r.den};
  if (out.den < 0) {
    out.num = -out.num;
    out.den = -out.den;
  }
  return out;
}

static VdTick ticks_of(const VdDecoder* d, int64_t stream_ts) {
  return vd_ticks_from_stream_time(stream_ts, d->stream_tb);
}

static int64_t stream_ts_of(const VdDecoder* d, VdTick t) {
  return vd_stream_time_from_ticks(t, d->stream_tb);
}

static enum AVPixelFormat pick_hw_format(AVCodecContext* ctx,
                                         const enum AVPixelFormat* formats) {
  (void)ctx;
  for (const enum AVPixelFormat* p = formats; *p != AV_PIX_FMT_NONE; p++) {
    if (*p == AV_PIX_FMT_VIDEOTOOLBOX) return *p;
  }
  // No hardware format offered: let the decoder fall back to whatever it
  // planned to do, rather than failing the open.
  return formats[0];
}

// --- keyframe index --------------------------------------------------------

static void build_keyframe_index(VdDecoder* d) {
  AVStream* stream = d->fmt->streams[d->stream_index];  // the index API is non-const
  int count = avformat_index_get_entries_count(stream);
  if (count <= 0) return;

  VdTick* list = calloc((size_t)count, sizeof(VdTick));
  if (!list) return;

  int32_t kept = 0;
  for (int i = 0; i < count; i++) {
    const AVIndexEntry* entry = avformat_index_get_entry(stream, i);
    if (!entry || !(entry->flags & AVINDEX_KEYFRAME)) continue;
    if (entry->timestamp == AV_NOPTS_VALUE) continue;
    VdTick t = ticks_of(d, entry->timestamp);
    // Index entries are DTS-based, so the first can be negative on a stream
    // with B-frames. Nothing can seek before the start, so 0 is the honest
    // answer; the dedup below folds several negatives into one entry.
    if (t < 0) t = 0;
    // The index is ordered, but be defensive: a duplicate or out-of-order
    // entry would break the binary search that reads this.
    if (kept > 0 && t <= list[kept - 1]) continue;
    list[kept++] = t;
  }

  if (kept == 0) {
    free(list);
    return;
  }
  d->keyframes = list;
  d->keyframe_count = kept;
}

int32_t vd_decoder_keyframe_count(const VdDecoder* d) {
  return d ? d->keyframe_count : 0;
}

VdTick vd_decoder_keyframe_at_or_before(const VdDecoder* d, VdTick t) {
  if (!d || d->keyframe_count == 0) return 0;
  int32_t lo = 0;
  int32_t hi = d->keyframe_count - 1;
  VdTick best = d->keyframes[0];
  while (lo <= hi) {
    int32_t mid = (lo + hi) / 2;
    if (d->keyframes[mid] <= t) {
      best = d->keyframes[mid];
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return best;
}

// --- cache -----------------------------------------------------------------

static void cache_clear(VdDecoder* d) {
  for (int32_t i = 0; i < d->cache_capacity; i++) {
    if (d->cache[i].frame) av_frame_free(&d->cache[i].frame);
    d->cache[i].pts = 0;
    d->cache[i].duration = 0;
    d->cache[i].used = 0;
  }
}

static VdCacheSlot* cache_find(VdDecoder* d, VdTick t) {
  for (int32_t i = 0; i < d->cache_capacity; i++) {
    VdCacheSlot* slot = &d->cache[i];
    if (!slot->frame) continue;
    if (t >= slot->pts && t < slot->pts + slot->duration) {
      slot->used = ++d->clock;
      return slot;
    }
  }
  return NULL;
}

// The frame with the largest pts <= t. Used at EOF, where "the frame covering
// t" does not exist because t is past the end.
static VdCacheSlot* cache_latest_at_or_before(VdDecoder* d, VdTick t) {
  VdCacheSlot* best = NULL;
  for (int32_t i = 0; i < d->cache_capacity; i++) {
    VdCacheSlot* slot = &d->cache[i];
    if (!slot->frame || slot->pts > t) continue;
    if (!best || slot->pts > best->pts) best = slot;
  }
  if (best) best->used = ++d->clock;
  return best;
}

static void cache_put(VdDecoder* d, AVFrame* frame, VdTick pts, VdTick dur) {
  VdCacheSlot* victim = NULL;
  for (int32_t i = 0; i < d->cache_capacity; i++) {
    VdCacheSlot* slot = &d->cache[i];
    if (slot->frame && slot->pts == pts) {
      // Already held. Refresh it rather than keeping two of the same frame.
      av_frame_free(&slot->frame);
      victim = slot;
      break;
    }
    if (!slot->frame) {
      victim = slot;
      break;
    }
    if (!victim || slot->used < victim->used) victim = slot;
  }
  if (!victim) return;
  if (victim->frame) av_frame_free(&victim->frame);

  victim->frame = av_frame_clone(frame);
  if (!victim->frame) return;
  victim->pts = pts;
  victim->duration = dur;
  victim->used = ++d->clock;
}

// --- frame export ----------------------------------------------------------

// Wraps a software-decoded YUV420P frame in a CVPixelBuffer so callers see one
// shape regardless of which decoder produced it. This copies; the hardware
// path does not, which is the whole reason the hardware path exists.
static CVPixelBufferRef pixel_buffer_from_sw(const AVFrame* frame) {
  CVPixelBufferRef buffer = NULL;
  const OSType type = kCVPixelFormatType_420YpCbCr8Planar;
  CFDictionaryRef empty = CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0,
                                             &kCFTypeDictionaryKeyCallBacks,
                                             &kCFTypeDictionaryValueCallBacks);
  CFMutableDictionaryRef options = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 1, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(options, kCVPixelBufferIOSurfacePropertiesKey, empty);

  CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, frame->width,
                                        frame->height, type, options, &buffer);
  CFRelease(options);
  CFRelease(empty);
  if (status != kCVReturnSuccess || !buffer) return NULL;

  CVPixelBufferLockBaseAddress(buffer, 0);
  for (int plane = 0; plane < 3; plane++) {
    uint8_t* dst = CVPixelBufferGetBaseAddressOfPlane(buffer, (size_t)plane);
    size_t dst_stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, (size_t)plane);
    size_t height = CVPixelBufferGetHeightOfPlane(buffer, (size_t)plane);
    size_t width = CVPixelBufferGetWidthOfPlane(buffer, (size_t)plane);
    const uint8_t* src = frame->data[plane];
    size_t src_stride = (size_t)frame->linesize[plane];
    for (size_t row = 0; row < height; row++) {
      memcpy(dst + row * dst_stride, src + row * src_stride, width);
    }
  }
  CVPixelBufferUnlockBaseAddress(buffer, 0);
  return buffer;
}

// What matrix was this encoded with?
//
// Most files say. The ones that do not are overwhelmingly old SD content,
// which is BT.601, and HD content, which is BT.709 — that height split is the
// same guess every player makes, and guessing is better than picking one and
// being wrong half the time.
static VdColorMatrix matrix_of(const AVFrame* frame) {
  switch (frame->colorspace) {
    case AVCOL_SPC_BT470BG:
    case AVCOL_SPC_SMPTE170M:
    case AVCOL_SPC_SMPTE240M:
      return VD_MATRIX_BT601;
    case AVCOL_SPC_BT709:
      return VD_MATRIX_BT709;
    case AVCOL_SPC_BT2020_NCL:
    case AVCOL_SPC_BT2020_CL:
      return VD_MATRIX_BT2020;
    default:
      return frame->height > 576 ? VD_MATRIX_BT709 : VD_MATRIX_BT601;
  }
}

static bool export_frame(const VdDecoder* d, AVFrame* frame, VdTick pts,
                         VdTick duration, VdFrame* out) {
  memset(out, 0, sizeof(*out));
  out->pts = pts;
  out->duration = duration;
  out->width = frame->width;
  out->height = frame->height;
  out->color_matrix = matrix_of(frame);
  out->full_range = frame->color_range == AVCOL_RANGE_JPEG;

  if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX && frame->data[3]) {
    out->pixel_buffer = CVPixelBufferRetain((CVPixelBufferRef)frame->data[3]);
    out->format = VD_PIXEL_NV12;
    out->hardware = true;
    return out->pixel_buffer != NULL;
  }

  if (frame->format != AV_PIX_FMT_YUV420P) {
    // Every codec this ships with decodes to one of these two. Anything else
    // is a gap to close deliberately, not to paper over with a guess.
    return false;
  }
  out->pixel_buffer = pixel_buffer_from_sw(frame);
  out->format = VD_PIXEL_YUV420P;
  out->hardware = false;
  (void)d;
  return out->pixel_buffer != NULL;
}

void vd_frame_release(VdFrame* frame) {
  if (!frame) return;
  if (frame->pixel_buffer) {
    CVPixelBufferRelease((CVPixelBufferRef)frame->pixel_buffer);
  }
  memset(frame, 0, sizeof(*frame));
}

// --- open / close ----------------------------------------------------------

VdDecoderOptions vd_decoder_default_options(void) {
  VdDecoderOptions options = {.hardware = 1, .cache_capacity = 0};
  return options;
}

static void fail(VdDecoder* d, int32_t code, int32_t* out_result) {
  if (out_result) *out_result = code;
  vd_decoder_close(d);
}

VdDecoder* vd_decoder_open(const char* path, VdDecoderOptions options,
                           int32_t* out_result) {
  if (out_result) *out_result = VD_OK;
  if (!path) {
    if (out_result) *out_result = VD_ERR_INVALID_ARG;
    return NULL;
  }

  VdDecoder* d = calloc(1, sizeof(VdDecoder));
  if (!d) {
    if (out_result) *out_result = VD_ERR_OPEN;
    return NULL;
  }

  d->cache_capacity = options.cache_capacity > 0
                          ? (options.cache_capacity > VD_MAX_CACHE
                                 ? VD_MAX_CACHE
                                 : options.cache_capacity)
                          : VD_DEFAULT_CACHE;
  d->cache = calloc((size_t)d->cache_capacity, sizeof(VdCacheSlot));
  d->packet = av_packet_alloc();
  d->frame = av_frame_alloc();
  d->sw_frame = av_frame_alloc();
  if (!d->cache || !d->packet || !d->frame || !d->sw_frame) {
    fail(d, VD_ERR_OPEN, out_result);
    return NULL;
  }

  if (vd_probe_file(path, &d->info) != VD_OK) {
    fail(d, VD_ERR_OPEN, out_result);
    return NULL;
  }
  if (!d->info.has_video) {
    fail(d, VD_ERR_UNSUPPORTED, out_result);
    return NULL;
  }

  if (avformat_open_input(&d->fmt, path, NULL, NULL) < 0) {
    fail(d, VD_ERR_OPEN, out_result);
    return NULL;
  }
  if (avformat_find_stream_info(d->fmt, NULL) < 0) {
    fail(d, VD_ERR_NO_STREAMS, out_result);
    return NULL;
  }

  const AVCodec* codec = NULL;
  d->stream_index =
      av_find_best_stream(d->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
  if (d->stream_index < 0 || !codec) {
    fail(d, VD_ERR_NO_STREAMS, out_result);
    return NULL;
  }

  AVStream* stream = d->fmt->streams[d->stream_index];
  d->stream_tb = rational_of(stream->time_base);

  d->codec = avcodec_alloc_context3(codec);
  if (!d->codec) {
    fail(d, VD_ERR_OPEN, out_result);
    return NULL;
  }
  if (avcodec_parameters_to_context(d->codec, stream->codecpar) < 0) {
    fail(d, VD_ERR_OPEN, out_result);
    return NULL;
  }
  d->codec->pkt_timebase = stream->time_base;

  if (options.hardware) {
    // Ask for VideoToolbox. A failure here is not fatal: the software decoder
    // is slower but correct, and reporting "cannot open this file" for a codec
    // the machine simply cannot hardware-decode would be wrong.
    if (av_hwdevice_ctx_create(&d->hw_device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                               NULL, NULL, 0) == 0) {
      d->codec->hw_device_ctx = av_buffer_ref(d->hw_device);
      d->codec->get_format = pick_hw_format;
    }
  }

  // Frame-level threading keeps latency low for the seek-heavy access pattern
  // scrubbing produces.
  d->codec->thread_count = 0;

  if (avcodec_open2(d->codec, codec, NULL) < 0) {
    fail(d, VD_ERR_UNSUPPORTED, out_result);
    return NULL;
  }

  VdRational rate = d->info.frame_rate;
  int64_t per_frame = (rate.num > 0 && rate.den > 0)
                          ? vd_ticks_per_frame(rate)
                          : 0;
  // A rate the project timebase cannot express exactly (VFR averages often
  // are not) still needs a fallback duration, so scale it rather than refuse.
  if (per_frame <= 0 && rate.num > 0) {
    per_frame = vd_scale(VD_TICKS_PER_SECOND, rate.den, rate.num);
  }
  d->nominal_duration = per_frame > 0 ? per_frame : VD_TICKS_PER_SECOND / 30;

  build_keyframe_index(d);
  d->position = 0;
  d->position_known = false;

  return d;
}

void vd_decoder_close(VdDecoder* d) {
  if (!d) return;
  if (d->cache) {
    cache_clear(d);
    free(d->cache);
  }
  free(d->keyframes);
  if (d->frame) av_frame_free(&d->frame);
  if (d->sw_frame) av_frame_free(&d->sw_frame);
  if (d->packet) av_packet_free(&d->packet);
  if (d->codec) avcodec_free_context(&d->codec);
  if (d->hw_device) av_buffer_unref(&d->hw_device);
  if (d->fmt) avformat_close_input(&d->fmt);
  free(d);
}

int32_t vd_decoder_info(const VdDecoder* d, VdProbeInfo* out) {
  if (!d || !out) return VD_ERR_INVALID_ARG;
  *out = d->info;
  return VD_OK;
}

void vd_decoder_stats(const VdDecoder* d, VdDecoderStats* out) {
  if (!d || !out) return;
  *out = d->stats;
}

void vd_decoder_reset_stats(VdDecoder* d) {
  if (!d) return;
  memset(&d->stats, 0, sizeof(d->stats));
}

// --- decoding --------------------------------------------------------------

static VdTick frame_duration(const VdDecoder* d, const AVFrame* frame) {
  if (frame->duration > 0) {
    VdTick t = ticks_of(d, frame->duration);
    if (t > 0) return t;
  }
  return d->nominal_duration;
}

static VdTick frame_pts(const VdDecoder* d, const AVFrame* frame) {
  int64_t ts = frame->best_effort_timestamp;
  if (ts == AV_NOPTS_VALUE) ts = frame->pts;
  if (ts == AV_NOPTS_VALUE) return d->position_known ? d->position : 0;
  return ticks_of(d, ts);
}

// Pulls exactly one decoded frame into d->frame. Returns VD_OK, VD_ERR_EOF
// signalled as VD_ERR_DECODE with eof set, or a negative code on error.
static int32_t decode_next(VdDecoder* d) {
  for (;;) {
    int ret = avcodec_receive_frame(d->codec, d->frame);
    if (ret == 0) {
      d->stats.frames_decoded++;
      return VD_OK;
    }
    if (ret == AVERROR_EOF) {
      d->eof = true;
      return VD_ERR_DECODE;
    }
    if (ret != AVERROR(EAGAIN)) {
      d->stats.decode_errors++;
      return VD_ERR_DECODE;
    }

    // Needs more input.
    int read = av_read_frame(d->fmt, d->packet);
    if (read == AVERROR_EOF) {
      avcodec_send_packet(d->codec, NULL);  // flush
      continue;
    }
    if (read < 0) {
      d->stats.decode_errors++;
      return VD_ERR_DECODE;
    }
    if (d->packet->stream_index != d->stream_index) {
      av_packet_unref(d->packet);
      continue;
    }
    int sent = avcodec_send_packet(d->codec, d->packet);
    av_packet_unref(d->packet);
    if (sent < 0 && sent != AVERROR(EAGAIN)) {
      d->stats.decode_errors++;
      return VD_ERR_DECODE;
    }
  }
}

static int32_t seek_to(VdDecoder* d, VdTick t) {
  int64_t ts = stream_ts_of(d, t);
  int ret = av_seek_frame(d->fmt, d->stream_index, ts, AVSEEK_FLAG_BACKWARD);
  if (ret < 0) {
    // Some containers refuse a backward seek to before the first frame.
    ret = av_seek_frame(d->fmt, d->stream_index, 0, AVSEEK_FLAG_BACKWARD);
    if (ret < 0) return VD_ERR_DECODE;
  }
  avcodec_flush_buffers(d->codec);
  d->eof = false;
  d->position_known = false;
  d->stats.seeks++;
  return VD_OK;
}

int32_t vd_decoder_frame_at(VdDecoder* d, VdTick t, VdFrame* out) {
  if (!d || !out) return VD_ERR_INVALID_ARG;
  memset(out, 0, sizeof(*out));
  if (t < 0) t = 0;

  VdCacheSlot* hit = cache_find(d, t);
  if (hit) {
    d->stats.cache_hits++;
    return export_frame(d, hit->frame, hit->pts, hit->duration, out)
               ? VD_OK
               : VD_ERR_DECODE;
  }
  d->stats.cache_misses++;

  // Decide between continuing forward and seeking. Continuing is only valid
  // when the decoder is already positioned at or before the target, and close
  // enough that the walk is cheaper than a keyframe jump.
  const bool can_continue = d->position_known && !d->eof &&
                            d->position <= t &&
                            (t - d->position) <= VD_FORWARD_WINDOW_TICKS;
  if (!can_continue) {
    if (seek_to(d, t) != VD_OK) return VD_ERR_DECODE;
  }

  for (;;) {
    if (decode_next(d) != VD_OK) break;

    VdTick pts = frame_pts(d, d->frame);
    VdTick duration = frame_duration(d, d->frame);
    d->position = pts + duration;
    d->position_known = true;

    cache_put(d, d->frame, pts, duration);

    if (t < pts + duration) {
      // This frame covers t — or, if t fell before the first frame, this is
      // the first frame and clamping is the right answer.
      return export_frame(d, d->frame, pts, duration, out) ? VD_OK
                                                           : VD_ERR_DECODE;
    }
  }

  // Ran out of frames: t is past the end, so clamp to the last one there is.
  // It comes from the cache rather than from d->frame, which avcodec has
  // already unreffed by the time it reports EOF.
  VdCacheSlot* fallback = cache_latest_at_or_before(d, t);
  if (fallback) {
    return export_frame(d, fallback->frame, fallback->pts, fallback->duration,
                        out)
               ? VD_OK
               : VD_ERR_DECODE;
  }
  return VD_ERR_DECODE;
}
