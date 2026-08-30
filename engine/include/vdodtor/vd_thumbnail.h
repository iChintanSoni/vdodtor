// vd_thumbnail.h — one frame of a file, small, as pixels the UI can draw.
//
// The media bin needs a picture of every asset, and it has to be the same
// picture the preview would show. So this is not a second imaging path: it
// opens an ordinary decoder, asks for one frame, and runs that frame through
// the ordinary compositor at a small size. The YCbCr matrix, the rotation and
// the fit are therefore right for the same reason they are right on screen,
// rather than for a second reason that can drift away from the first.
//
// Everything here is synchronous and opens no threads. It decodes, so it is
// far from free — a long-GOP source can spend a couple of hundred milliseconds
// reaching a frame in the middle of the file. Callers belong off the UI thread.

#ifndef VD_THUMBNAIL_H
#define VD_THUMBNAIL_H

#include <stdint.h>

#include "vdodtor/vd_time.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  int32_t width;
  int32_t height;

  // Tightly packed BGRA, width * height * 4 bytes. Owned by the caller;
  // release with vd_thumbnail_free.
  uint8_t* pixels;
} VdThumbnail;

// Renders the frame covering `t` in `path`, scaled to fit inside
// `max_width` x `max_height`.
//
// The result carries the source's *display* aspect — rotation and sample
// aspect already applied — and is not letterboxed, so a caller can lay it out
// without knowing anything about the file. Both dimensions come back even,
// and at least 2.
//
// Returns VD_OK, or a negative VdResult: VD_ERR_INVALID_ARG for the arguments,
// VD_ERR_OPEN for a file that will not open, VD_ERR_UNSUPPORTED for one with
// no video stream — which is where an audio file lands, and is a fact about
// the file rather than a failure — and VD_ERR_DECODE when there is a video
// stream but no frame came out of it. `out` is zeroed on every failure.
VD_EXPORT int32_t vd_thumbnail_render(const char* path, VdTick t,
                                      int32_t max_width, int32_t max_height,
                                      VdThumbnail* out);

// Frees the pixels and zeroes the struct. Safe on a zeroed thumbnail, and
// safe twice.
VD_EXPORT void vd_thumbnail_free(VdThumbnail* thumb);

#ifdef __cplusplus
}
#endif
#endif  // VD_THUMBNAIL_H
