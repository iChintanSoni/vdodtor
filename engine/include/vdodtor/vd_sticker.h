// vd_sticker.h — an animated overlay, decoded whole and kept.
//
// A GIF, an animated WebP or an APNG is not video and must not be treated as
// video. Three differences, and each one is a reason this is not vd_decoder:
//
//   - **It has no keyframes to seek to.** Every frame is a patch on the one
//     before it, disposal method and all, so "seek to 3.4 s" means decoding
//     from the beginning whatever happens. A decoder built around seeking
//     would do that on every scrub.
//   - **It has an alpha channel, and the alpha is the point.** vd_decoder
//     hands the compositor YCbCr; a sticker over a picture has to arrive as
//     premultiplied BGRA or it is a rectangle with a sticker painted on it.
//   - **It is small enough to hold.** A whole animation is a few megabytes of
//     RGBA, which is less than the frame cache a decoder would need to scrub
//     it — so it is decoded once, at open, and then costs nothing at all.
//
// So a sticker is the opposite trade from a decoder: all the work at open,
// none of it per frame. What is left is a lookup.
//
// **Retiming to the project's rate falls out of asking by time.** Each frame
// carries the interval it is on screen for, in project ticks, and a lookup
// finds the interval containing the instant asked for — so a 4 fps sticker on
// a 60 fps timeline shows each of its frames for fifteen project frames
// without anything resampling anything. Ask at 24 fps instead and it is right
// there too. Nothing here knows the project's frame rate, and that is why.
//
// **A sticker loops.** The lookup takes its argument modulo the animation's
// own length, which is what makes a one-second GIF usable on a ten-second clip
// and is why a sticker, like a still image, has no maximum length on the
// timeline.

#ifndef VD_STICKER_H
#define VD_STICKER_H

#include <stdbool.h>
#include <stdint.h>

#include "vdodtor/vd_time.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VdSticker VdSticker;

typedef struct {
  // How much decoded RGBA one sticker may hold. 0 picks the default.
  //
  // A budget rather than a frame limit, and it *scales* rather than truncates:
  // an animation too big to hold is decoded smaller, never shorter. Losing
  // resolution on an overlay is a compromise somebody might not notice; losing
  // the second half of the animation is a bug they certainly would.
  int64_t max_bytes;

  // Longest side, in pixels, or 0 for no limit. The engine passes the
  // output's, because a sticker with more pixels than the frame it is drawn
  // into is paying for detail the compositor is about to throw away.
  int32_t max_side;
} VdStickerOptions;

VD_EXPORT VdStickerOptions vd_sticker_default_options(void);

// Decodes every frame of `path` into memory. Returns NULL on failure, with
// `out_result` — which may be NULL — set to a negative VdResult.
//
// This is the expensive call, and it is the only expensive call: it demuxes
// the file twice, once to count frames so the budget can be spent before a
// pixel is written, and once to decode them.
VD_EXPORT VdSticker* vd_sticker_open(const char* path, VdStickerOptions options,
                                     int32_t* out_result);
VD_EXPORT void vd_sticker_close(VdSticker* sticker);

// One loop, in project ticks. Always > 0 for an open sticker — a single-frame
// file is a still that loops, and a still with no length would divide by zero.
VD_EXPORT VdTick vd_sticker_duration(const VdSticker* sticker);

VD_EXPORT int32_t vd_sticker_frame_count(const VdSticker* sticker);

// The size frames actually came out at, which is the file's size unless the
// budget or `max_side` shrank it.
VD_EXPORT int32_t vd_sticker_width(const VdSticker* sticker);
VD_EXPORT int32_t vd_sticker_height(const VdSticker* sticker);

// What it is holding. For the engine's cache, which evicts on bytes rather
// than on count: a sticker's cost is memory, not a file handle.
VD_EXPORT int64_t vd_sticker_bytes(const VdSticker* sticker);

// The frame on screen at `t` ticks into the animation, looping: `t` is taken
// modulo `vd_sticker_duration`, and a negative `t` counts back from the end of
// a loop rather than clamping, so a clip trimmed to start before its source
// still shows the animation running.
//
// Returns a CVPixelBufferRef in 32BGRA, **premultiplied**, IOSurface-backed
// and Metal-compatible — the same thing a caption or a shape hands over. It
// belongs to the sticker and is valid until the next call or until close:
// **do not retain it and do not release it.** One buffer is reused for every
// frame because the alternative is an IOSurface per frame of every animation
// on the timeline, and a hundred-frame GIF would spend a hundred of them to
// show one.
//
// `out_changed`, which may be NULL, reports whether this call put a different
// frame in the buffer. That is the number worth watching: it should tick at
// the *sticker's* rate and not the project's, and a stream of them at sixty a
// second means the retiming above is not happening.
VD_EXPORT void* vd_sticker_frame_at(VdSticker* sticker, VdTick t,
                                    bool* out_changed);

// Whether `codec` — a name as vd_probe reports it — is one of the animated
// overlay formats.
//
// The *codec* rather than the extension, because a `.webp` can be either and
// the container is the thing that knows. The app asks this to decide what kind
// of media it imported, so that the answer is written down once and the engine
// is never left probing a path it was handed to find out how to open it.
VD_EXPORT bool vd_sticker_is_sticker_codec(const char* codec);

#ifdef __cplusplus
}
#endif
#endif  // VD_STICKER_H
