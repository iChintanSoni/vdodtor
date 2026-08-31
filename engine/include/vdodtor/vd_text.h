// vd_text.h — a string, and the pixels it turns into.
//
// Text is a *source*, not a compositing mode. A caption is rasterised once
// into a BGRA frame the size of the output and then handed to the compositor
// as an ordinary layer, which is why the clip's transform, opacity and fit all
// work on it without anything here knowing they exist. The alternative — a
// glyph pass inside the compositor — would make text the one thing preview and
// export could disagree about, which is the bug this whole engine is shaped to
// avoid.
//
// It lives in the engine rather than in Flutter for the same reason. A frame
// is a pure function of (document, time), and that has to stay true with no UI
// attached: an export driven by a frame counter with no widget tree alive must
// produce the same caption the preview showed. Rasterising in Dart would make
// text the exception, and the exception is exactly where preview and export
// drift apart.
//
// **Nothing here is measured in pixels.** Sizes, offsets, padding and spacing
// are all fractions — of the output height, or of the font size they hang off
// — so a project cut at 1080p and exported at 4K puts the same caption in the
// same place at the same size. A point size stored in the document would be
// wrong at every resolution but the one it was typed at.

#ifndef VD_TEXT_H
#define VD_TEXT_H

#include <stdbool.h>
#include <stdint.h>

#include "vdodtor/vd_time.h"

#ifdef __cplusplus
extern "C" {
#endif

// Where each line sits inside the text block. The block itself is centred in
// the frame and moved by the clip's transform; this only decides what happens
// to a short line next to a long one.
typedef enum {
  VD_TEXT_ALIGN_LEFT = 0,
  VD_TEXT_ALIGN_CENTER = 1,
  VD_TEXT_ALIGN_RIGHT = 2,
} VdTextAlign;

// Everything about how one caption looks.
//
// Colours are 0xAARRGGBB, straight (not premultiplied) — the document writes
// them and a human reads them, and premultiplied colour is neither. Alpha 0
// means *off* for the two optional parts: a shadow colour with no alpha casts
// no shadow, a box colour with no alpha draws no box. That is one rule rather
// than two booleans nobody would keep in step with the colours beside them.
typedef struct {
  // UTF-8, NUL terminated. NULL or empty renders a transparent frame, which
  // is what a caption someone has not typed into yet should look like.
  const char* text;

  // Family name as the font file reports it — "Inter", "Playfair Display".
  // NULL, empty, or a family nothing was registered under falls back to the
  // system's own, so a project made on a machine with a pack installed still
  // opens somewhere it is not.
  const char* font;

  // Cap height of the type as a fraction of the output height. 0.08 is a
  // readable caption on a 16:9 frame.
  float size;

  uint32_t color;

  // An outline, drawn under the fill so only its outer half shows. Width is a
  // fraction of the font size, which is also how CoreText expresses it.
  uint32_t stroke_color;
  float stroke_width;

  // Cast by the ink — the fill and its outline together — onto whatever is
  // behind it, including the box. Offsets and blur are fractions of the font
  // size; +y is down, the direction a light above the frame throws it.
  uint32_t shadow_color;
  float shadow_dx;
  float shadow_dy;
  float shadow_blur;

  // A rounded rectangle behind the whole block, inset by `box_padding` on
  // every side. Padding and corner radius are fractions of the font size, so
  // the box keeps its proportions as the type grows.
  uint32_t box_color;
  float box_padding;
  float box_radius;

  // Extra space between glyphs, as a fraction of the font size. Negative
  // tightens.
  float letter_spacing;

  // Multiple of the font's own line height. 0 and 1 both mean "as the font
  // asked for".
  float line_spacing;

  // How much of the output's width the block may fill before it wraps, as a
  // fraction. 0 means the default, which leaves a margin — text that touches
  // the edge of the frame reads as a mistake.
  float max_width;

  VdTextAlign align;
} VdTextSpec;

// A caption with nothing said about it: white, unstroked, unboxed, centred,
// at a readable size. Not a zeroed struct — a zeroed one is transparent type
// with no size, which is not a default anybody wants.
VD_EXPORT VdTextSpec vd_text_spec_default(void);

// True when two specs would rasterise to the same pixels. This is what lets
// the engine keep a raster across an edit that did not touch the text.
VD_EXPORT bool vd_text_spec_equal(const VdTextSpec* a, const VdTextSpec* b);

// A copy that owns its own strings, and the matching free. The engine holds a
// spec for as long as a clip is on the timeline; the caller that handed it
// over keeps its own.
VD_EXPORT VdTextSpec* vd_text_spec_copy(const VdTextSpec* spec);
VD_EXPORT void vd_text_spec_free(VdTextSpec* spec);

// Registers a font from memory, for this process only. `data` is the contents
// of a .ttf or .otf; it is copied, so the caller may free it on return.
//
// Bytes rather than a path because the fonts ship inside the app bundle, where
// the only address anybody has for them is an asset key. Registering the same
// face twice is not an error — it is what happens when the app restarts an
// engine — and the second registration is quietly ignored.
VD_EXPORT int32_t vd_text_register_font(const void* data, int64_t size);

// The families registered so far, in the order they arrived. For tests and for
// telling a UI what it may offer.
VD_EXPORT int32_t vd_text_font_count(void);
VD_EXPORT const char* vd_text_font_name(int32_t index);

// Rasterises `spec` into a new `width` x `height` CVPixelBufferRef: 32BGRA,
// **premultiplied**, transparent everywhere the ink is not. IOSurface-backed
// and Metal-compatible, so the compositor wraps it without a copy.
//
// The block is laid out centred in the frame; moving it is the clip
// transform's job, not this function's. Caller releases with
// CVPixelBufferRelease. NULL on failure, with `out_result` — which may be
// NULL — set to a negative VdResult.
VD_EXPORT void* vd_text_render(const VdTextSpec* spec, int32_t width,
                               int32_t height, int32_t* out_result);

#ifdef __cplusplus
}
#endif
#endif  // VD_TEXT_H
