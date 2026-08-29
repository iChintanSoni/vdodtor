// vd_engine.h — S1 spike: C ABI for the native preview engine.
//
// Architecture under test:
//   FFmpeg demux -> VideoToolbox hw decode (CVPixelBuffer, NV12)
//     -> Metal composite pass (YUV->RGB + N layers) -> BGRA CVPixelBuffer
//       -> Flutter external texture
//
// Everything here is plain C so Dart can call it over dart:ffi.

#ifndef VD_ENGINE_H
#define VD_ENGINE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VD_EXPORT __attribute__((visibility("default"))) __attribute__((used))

typedef struct VdEngine VdEngine;

// Snapshot of engine counters. Mirrored by VdStats in Dart (same field order).
typedef struct {
  int64_t frames_decoded;
  int64_t frames_presented;
  int64_t frames_dropped;     // decoded but never shown (arrived past deadline)
  double  decode_ms_avg;      // rolling mean, per frame
  double  composite_ms_avg;   // rolling mean, per frame (GPU wall time)
  double  present_fps;        // measured over the last second
  int64_t position_ns;
  int64_t duration_ns;
  int32_t width;              // source dimensions
  int32_t height;
  int32_t out_width;          // composite output dimensions
  int32_t out_height;
  int32_t state;              // 0 idle, 1 playing, 2 paused, 3 eof, -1 error
  int32_t layers;
  double  last_seek_ms;       // scrub latency: seek call -> frame on screen
  double  cpu_percent;        // whole-process, sampled
} VdStats;

VD_EXPORT VdEngine* vd_engine_create(void);
VD_EXPORT void      vd_engine_destroy(VdEngine* e);

// Opens `path` and starts the decode thread. Returns 0 on success.
// out_w/out_h set the composite output size (0 = match source).
VD_EXPORT int32_t   vd_engine_open(VdEngine* e, const char* path,
                                   int32_t out_w, int32_t out_h);

VD_EXPORT void      vd_engine_play(VdEngine* e);
VD_EXPORT void      vd_engine_pause(VdEngine* e);
VD_EXPORT void      vd_engine_seek_ns(VdEngine* e, int64_t position_ns);
VD_EXPORT void      vd_engine_set_layers(VdEngine* e, int32_t layers);
VD_EXPORT void      vd_engine_stats(VdEngine* e, VdStats* out);

// Frame-ready notification. The plugin hooks this up to
// -[FlutterTextureRegistry textureFrameAvailable:].
typedef void (*VdFrameCallback)(void* ctx);
VD_EXPORT void vd_engine_set_frame_callback(VdEngine* e, VdFrameCallback cb, void* ctx);

// Returns the most recently composited frame, +1 retained (caller releases).
// Declared void* so this header stays C-only; it is a CVPixelBufferRef.
VD_EXPORT void* vd_engine_copy_output(VdEngine* e);

// Writes the latest composited frame to `path` as PNG. Verification aid:
// proves the Metal path produced a correct image, not just fast timings.
// Returns 0 on success.
VD_EXPORT int32_t vd_engine_dump_png(VdEngine* e, const char* path);

#ifdef __cplusplus
}
#endif
#endif  // VD_ENGINE_H
