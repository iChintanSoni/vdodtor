// vd_eq.h — what a clip sounds like, as a short list of things people ask for.
//
// Presets rather than a parametric equaliser, and that is the whole design.
// Three bands with frequency, gain and Q each is nine numbers, a panel nobody
// can read at a glance, and — for the people this product is for — a way to
// make a recording worse with great precision. What they actually want is
// "make this voice sound like a voice", and that is a preset.
//
// Each one below has a job it was built for, and none of them is a taste:
//
//   voice      lifts a spoken recording out of room rumble and forward
//   music      a gentle smile, the polish a bed under a voice-over wants
//   bass       more weight, for a track that was mixed thin
//   bright     more air, for one that was mixed dull
//   telephone  a deliberate effect: the band a phone line passes and no more
//
// Every one is a cascade of biquads with the coefficients out of the RBJ
// cookbook, run in double and stored per channel. Plain C with no platform
// dependency, on `vd_color.c`'s and `vd_stretch.c`'s terms: what a preset
// *does* is asserted by pushing sine waves through it and reading the level
// that comes out, with no file, no device and no clock in the room.
//
// **Not mirrored in Dart**, for `vd_anim`'s reason: nothing in the app draws a
// response curve. The document carries the preset's *name* and the engine owns
// what it means, exactly as it owns what a transition preset means.

#ifndef VD_EQ_H
#define VD_EQ_H

#include <stdbool.h>
#include <stdint.h>

#include "vdodtor/vd_time.h"

#ifdef __cplusplus
extern "C" {
#endif

// The presets, in the order the document knows them.
//
// Mirrored by `EqPreset` in app/lib/model/clip.dart and `EngineEqPreset` in
// the plugin. The index is what crosses the FFI boundary, so this list may be
// appended to and never reordered — an entry inserted in the middle would
// silently re-EQ every clip in every project on disk.
typedef enum {
  VD_EQ_NONE = 0,
  VD_EQ_VOICE = 1,
  VD_EQ_MUSIC = 2,
  VD_EQ_BASS = 3,
  VD_EQ_BRIGHT = 4,
  VD_EQ_TELEPHONE = 5,
} VdEqPreset;

// Stereo, in practice. A parameter rather than a constant so the maths can be
// exercised on one channel, which is what makes a test of it readable.
#define VD_EQ_MAX_CHANNELS 2

typedef struct VdEq VdEq;

// Returns NULL for VD_EQ_NONE, which is not a failure: a clip nobody equalised
// keeps no filter at all, and the mixer's common path stays the path it was.
// Callers must therefore decide on the *preset* and not on the pointer — see
// vd_audio_renderer.c, where getting that backwards would make a failed
// allocation indistinguishable from "nothing asked for".
//
// Also NULL on a bad argument or a failed allocation.
VD_EXPORT VdEq* vd_eq_create(VdEqPreset preset, int32_t sample_rate,
                             int32_t channels);
VD_EXPORT void vd_eq_destroy(VdEq* eq);

// True when this filter was built for exactly this preset, so a caller holding
// one across an edit knows whether it may keep it.
VD_EXPORT bool vd_eq_matches(const VdEq* eq, VdEqPreset preset);

// Forgets everything the filter is carrying. Called on a seek: a biquad's
// state is the last two samples it saw, and material from before a seek
// ringing into the material after it is a click at exactly the moment the
// listener is paying attention.
VD_EXPORT void vd_eq_reset(VdEq* eq);

// Filters `frames` of interleaved audio in place.
VD_EXPORT void vd_eq_process(VdEq* eq, float* frames, int32_t frames_count);

// How many decibels this preset does to a steady tone at `hz`, worked out from
// the coefficients rather than by pushing a signal through.
//
// For tests, and for nothing else: an assertion that reads a response off the
// filter it is testing would agree with it whatever either of them did, so the
// signal tests are the real ones. This is here to say *which* frequencies are
// worth pushing a signal at.
VD_EXPORT double vd_eq_response_db(const VdEq* eq, double hz);

#ifdef __cplusplus
}
#endif
#endif  // VD_EQ_H
