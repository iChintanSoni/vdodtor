// vd_lut.h — the grade that cannot be a matrix.
//
// `vd_color.h` composes five sliders into one 3x3 and an offset, because every
// one of them is affine on RGB. A look is precisely what is left over: an
// arbitrary map from colour to colour, which is why it arrives as a lookup
// table and not as five numbers. A split-tone that pushes shadows towards teal
// while leaving highlights orange cannot be written as a matrix at all — the
// two ends of the ramp move in different directions.
//
// So this file reads a `.cube`, samples it, and bakes it into the one shape a
// GPU can sample. Everything a look *means* is here, in plain C with no
// platform dependency and no GPU in the room — the bargain `vd_color.c`,
// `vd_anim.c` and `vd_transition.c` all take, and what is left in Metal is a
// texture fetch a test could tell you nothing about.
//
// **A look runs in the signal, not in light.** A `.cube` file declares a
// lattice and a domain and says nothing whatever about what colour space its
// input is in, so the only thing that decides is convention — and the
// convention for the creative looks anybody will actually load is Rec.709 as
// it comes off the wire, which is exactly what `ycbcr_to_rgb` produces and
// exactly where `vd_color_transform` already works. Sampling one of those
// after a linearising transfer gives a crushed picture that is nobody's look.
// A LUT authored for linear input exists, in ACES pipelines, and is not what
// arrives through a file panel.
//
// **The sliders run first and the look runs last.** That is the order a
// colourist works in — correct the shot, then style it — and it is the order
// the LUT was authored expecting: a look built against a neutral, properly
// exposed Rec.709 frame should be handed one. It is also why the inspector
// puts the look at the *bottom* of the colour panel, under the five sliders,
// the way that panel already puts temperature above saturation.

#ifndef VD_LUT_H
#define VD_LUT_H

#include <stdbool.h>
#include <stdint.h>

#include "vdodtor/vd_time.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VdLut VdLut;

// The largest lattice a `.cube` may declare, per axis.
//
// The format allows 256 and nothing creative goes past 64: a 64-cube is a
// quarter of a million entries and three megabytes, and the looks people
// actually ship are 17, 25 and 33. A file asking for more is refused rather
// than quietly downsampled, because a look silently at half its authored
// resolution is a bug that shows up as banding in somebody's sky.
#define VD_LUT_MAX_3D_SIZE 64

// And for a one-dimensional file, where a curve genuinely wants resolution
// and costs almost nothing to keep — three floats per entry rather than three
// per *cube* entry.
#define VD_LUT_MAX_1D_SIZE 65536

// Reads a `.cube` from memory. `text` need not be NUL terminated; `length` is
// what is read.
//
// Bytes rather than a path is the primary door, for the reason
// `vd_text_register_font` takes bytes: the looks the app ships live inside a
// signed bundle where the only address anybody has for them is an asset key.
VD_EXPORT VdLut* vd_lut_parse(const char* text, int64_t length,
                              int32_t* out_result);

// The same, from a file — which is how a user's own `.cube` arrives.
VD_EXPORT VdLut* vd_lut_open(const char* path, int32_t* out_result);

VD_EXPORT void vd_lut_close(VdLut* lut);

// What the file called itself, or "" when it did not say. Never NULL.
VD_EXPORT const char* vd_lut_title(const VdLut* lut);

// Entries per axis, as the file declared it: the cube's side for a 3D file,
// the curve's length for a 1D one.
VD_EXPORT int32_t vd_lut_size(const VdLut* lut);

// False for a file that is three independent curves rather than a cube. Kept
// as it was written rather than expanded on the way in: a 1D file is usually
// sized in the thousands *because* it is a curve that needs the resolution,
// and turning one into a 33-cube at the door would throw that away before
// anything had a chance to ask.
VD_EXPORT bool vd_lut_is_3d(const VdLut* lut);

// Maps one straight — not premultiplied — RGB triple through the look, in
// place, clamped to 0..1.
//
// Trilinear between the eight lattice points around the colour, or linear
// along each curve for a 1D file. This is the arithmetic the shader's texture
// fetch does, which is what lets a look be asserted on numbers.
VD_EXPORT void vd_lut_sample(const VdLut* lut, float rgb[3]);

// The same, mixed back towards the colour it started from: 0 leaves the shot
// alone, 1 is the look at full strength. Out of range is clamped.
//
// A mix rather than a second, weaker LUT, because that is the one operation
// that works for every look — halfway to a monochrome is a desaturated shot,
// halfway to a split-tone is a gentler split-tone — and because it is what the
// shader can do in one instruction with the ungraded value already in hand.
VD_EXPORT void vd_lut_apply(const VdLut* lut, float strength, float rgb[3]);

// A look, in the shape the compositor wants it.
//
// `lattice` is `size` * `size` * `size` straight RGB triples with **red
// varying fastest**, which is the order a `.cube` writes its rows in and the
// order a 3D texture wants its slices. `size` is 0 for a clip with no look on
// it, and then nothing else here is read.
typedef struct {
  const float* lattice;

  // Entries per axis of `lattice`, or 0 for no look.
  int32_t size;

  // Unique to one open LUT for as long as it is open, and never 0 when there
  // is a look. The compositor keys its texture cache on this rather than on
  // the pointer: a lattice freed and another allocated at the same address
  // would be a cache hit on the wrong picture, and a look that is wrong only
  // sometimes is the worst kind.
  uint64_t id;

  // 0..1.
  float strength;
} VdColorLook;

// The look `lut` bakes down to, at `strength`.
//
// The lattice is baked on the first ask and then kept, so every clip wearing
// the same look shares one — a timeline of twenty shots with one look on them
// holds one cube, not twenty. A 1D file bakes into a cube here rather than at
// the door, because a cube is what a GPU samples and this is the moment that
// stops being avoidable; the curve itself stays as it was read.
//
// A NULL `lut` is the look that does nothing, which is the answer for a clip
// nobody put one on.
VD_EXPORT VdColorLook vd_lut_look(const VdLut* lut, float strength);

// Side of the cube `vd_lut_look` bakes into: the file's own size for a 3D
// look, and 33 for a 1D one — the size the looks people ship are written at,
// and enough that a smooth curve interpolates back to itself.
VD_EXPORT int32_t vd_lut_bake_size(const VdLut* lut);

// --- the catalogue ---------------------------------------------------------
//
// Looks are registered by name and referred to by name, exactly as fonts are,
// and for the same two reasons: the ones the app ships have no path inside a
// bundle, and a document that names a look reads like the edit that made it
// rather than like one machine's filesystem. A project that names a look this
// installation does not have draws ungraded, which is the same bargain a
// caption in a missing face already takes.
//
// Registered looks live for the life of the process. There is no unregister:
// a look is a few hundred kilobytes, a session has a handful, and a clip
// holding a pointer to one that had been freed underneath it is a class of
// bug worth spending the memory to make unreachable.

// Registers `data` — the contents of a `.cube` — under `name`.
//
// Registering a name that is already there replaces nothing and is not an
// error: it is what happens when the app restarts an engine, and the second
// registration is quietly ignored so that every clip already pointing at the
// first keeps pointing at something.
VD_EXPORT int32_t vd_lut_register(const char* name, const void* data,
                                  int64_t size);

// The looks registered so far, in the order they arrived — which is the order
// they were handed over, and therefore the order a picker should offer them.
VD_EXPORT int32_t vd_lut_count(void);
VD_EXPORT const char* vd_lut_name(int32_t index);

// The registered look called `name`, or NULL for a name nothing was registered
// under — including NULL and "", which is how "no look" spells itself all the
// way down from the document. Borrowed: the catalogue owns it.
VD_EXPORT const VdLut* vd_lut_find(const char* name);

#ifdef __cplusplus
}
#endif
#endif  // VD_LUT_H
