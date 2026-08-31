// vd_decoder.h — decoding one media file, addressed by time.
//
// The document model says a rendered frame is a pure function of
// (document, time). This is the piece that makes that true for a single
// source: ask for a time, get the frame that covers it. No transport, no
// clock, no threads — those belong to the layers above, and keeping them out
// is what lets seek and cache behaviour be tested exactly rather than
// approximately.
//
// Times in and out are project ticks (VD_TICKS_PER_SECOND), never seconds and
// never the stream's own timebase; the conversion happens inside.

#ifndef VD_DECODER_H
#define VD_DECODER_H

#include <stdbool.h>
#include <stdint.h>

#include "vdodtor/vd_probe.h"
#include "vdodtor/vd_time.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VdDecoder VdDecoder;

typedef enum {
  // Zero-copy from VideoToolbox: an IOSurface-backed NV12 buffer, ready for
  // the Metal compositor to sample directly.
  VD_PIXEL_NV12 = 0,
  // Software decode, copied into a planar buffer. Slower, and the compositor
  // has to sample it differently.
  VD_PIXEL_YUV420P = 1,
} VdPixelFormat;

typedef struct {
  // 1 to try VideoToolbox. Falls back to software if the codec cannot be
  // hardware-decoded; check VdFrame::hardware to see what actually happened.
  int32_t hardware;
  // Decoded frames to retain. 0 picks a default sized for scrubbing back and
  // forth across a second or so of footage.
  int32_t cache_capacity;
} VdDecoderOptions;

VD_EXPORT VdDecoderOptions vd_decoder_default_options(void);

// The YCbCr matrix a source was encoded with. Getting this wrong does not
// look broken, it looks *slightly off* — which is worse, because nobody
// reports it and every export inherits it.
typedef enum {
  VD_MATRIX_BT601 = 0,
  VD_MATRIX_BT709 = 1,
  VD_MATRIX_BT2020 = 2,
} VdColorMatrix;

typedef struct {
  // CVPixelBufferRef, retained. Release with vd_frame_release, always, on
  // every path — the cache holds its own reference and does not care about
  // yours.
  void*   pixel_buffer;
  VdPixelFormat format;

  // The presentation interval this frame covers: [pts, pts + duration).
  //
  // `duration` runs to the presentation time of the frame that follows, which
  // is not always what the container claims — muxers write per-frame durations
  // in decode order, so with B-frames they land on the wrong frames, and on a
  // variable-rate source the difference is frames from the future rather than
  // a rounding error. The last frame of a source is the exception: nothing
  // follows it, so it carries the nominal duration and queries past it clamp.
  VdTick  pts;
  VdTick  duration;

  int32_t width;
  int32_t height;
  bool    hardware;

  VdColorMatrix color_matrix;
  // True for 0-255 luma, false for the 16-235 video range most sources use.
  bool    full_range;
} VdFrame;

// Opens `path` for decoding. `out_result` receives VD_OK or a negative
// VdResult; it may be NULL. Returns NULL on failure.
VD_EXPORT VdDecoder* vd_decoder_open(const char* path, VdDecoderOptions options,
                                     int32_t* out_result);
VD_EXPORT void vd_decoder_close(VdDecoder* decoder);

// What probing the same file would have said. Free — it is read at open.
VD_EXPORT int32_t vd_decoder_info(const VdDecoder* decoder, VdProbeInfo* out);

// The frame whose presentation interval contains `t`.
//
// Clamps: a `t` before the first frame returns the first, and a `t` past the
// end returns the last. That is what a timeline wants — a clip trimmed a tick
// past its source should show the last frame, not a black hole.
//
// Returns VD_OK, or VD_ERR_DECODE if the file has no decodable video.
VD_EXPORT int32_t vd_decoder_frame_at(VdDecoder* decoder, VdTick t,
                                      VdFrame* out);

// Releases the frame's buffer and zeroes it. Safe on an already-released or
// zeroed frame.
VD_EXPORT void vd_frame_release(VdFrame* frame);

// --- keyframe index --------------------------------------------------------
// Built at open from the container's index. Seeking anywhere means landing on
// one of these and decoding forward, so the distance between them is the real
// cost of a scrub.

VD_EXPORT int32_t vd_decoder_keyframe_count(const VdDecoder* decoder);

// The latest keyframe at or before `t`, or 0 when the container has no index.
VD_EXPORT VdTick vd_decoder_keyframe_at_or_before(const VdDecoder* decoder,
                                                  VdTick t);

// --- telemetry -------------------------------------------------------------

typedef struct {
  int64_t frames_decoded;
  int64_t cache_hits;
  int64_t cache_misses;
  int64_t seeks;
  int64_t decode_errors;
} VdDecoderStats;

VD_EXPORT void vd_decoder_stats(const VdDecoder* decoder, VdDecoderStats* out);
VD_EXPORT void vd_decoder_reset_stats(VdDecoder* decoder);

#ifdef __cplusplus
}
#endif
#endif  // VD_DECODER_H
