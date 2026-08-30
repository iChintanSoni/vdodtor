// vd_probe.h — what is in a media file.
//
// Probing is separate from decoding on purpose: the media bin needs duration,
// dimensions and rotation to lay a clip out long before anything decodes a
// frame, and the answers get cached in the project file so a reopened project
// does not re-probe every asset.

#ifndef VD_PROBE_H
#define VD_PROBE_H

#include <stdbool.h>
#include <stdint.h>

#include "vdodtor/vd_time.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
  VD_OK = 0,
  VD_ERR_OPEN = -1,          // could not open the file at all
  VD_ERR_NO_STREAMS = -2,    // opened, but nothing playable inside
  VD_ERR_INVALID_ARG = -3,
  VD_ERR_UNSUPPORTED = -4,
  VD_ERR_DECODE = -5,        // opened, but a frame could not be produced
} VdResult;

typedef struct {
  bool    has_video;
  bool    has_audio;

  // Duration of the longest stream, in project ticks. 0 when the container
  // does not say — a stream, or a damaged file.
  VdTick  duration;

  // Coded dimensions, before rotation.
  int32_t width;
  int32_t height;

  // Display rotation from the container: 0, 90, 180 or 270.
  int32_t rotation_degrees;

  // Nominal frame rate. When `variable_frame_rate` is set this is the average,
  // and individual frames will not land on it — they are normalised to the
  // project timebase at decode time.
  VdRational frame_rate;
  bool    variable_frame_rate;

  int32_t audio_channels;
  int32_t audio_sample_rate;

  // Sample aspect ratio; {1,1} for square pixels.
  VdRational pixel_aspect;

  char    video_codec[32];
  char    audio_codec[32];
  char    format_name[64];
} VdProbeInfo;

// Fills `out` from `path`. Returns VD_OK, or a negative VdResult.
// Never partially fills: on failure `out` is zeroed.
VD_EXPORT int32_t vd_probe_file(const char* path, VdProbeInfo* out);

// Human-readable form of a VdResult, for logs and error surfaces.
VD_EXPORT const char* vd_result_string(int32_t result);

#ifdef __cplusplus
}
#endif
#endif  // VD_PROBE_H
