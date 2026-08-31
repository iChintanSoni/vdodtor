// vd_anim.h — how a clip arrives and how it leaves.
//
// An in/out animation is a pure function of one number: how far through the
// entrance (or the exit) the playhead is. Everything it produces is something
// the compositor can already do — an offset, a scale, a turn, an opacity — so
// nothing here draws anything. The engine evaluates it once per layer per
// frame and folds the result into the transform the clip already had.
//
// That is the whole design, and it is what makes an animation cost nothing:
// there is no keyframe list to walk, no state to carry between frames, and a
// seek anywhere in the clip produces exactly the frame playback would. A
// rendered frame stays a pure function of (document, time).
//
// **The engine owns this and Dart does not mirror it.** The audio envelopes
// are written twice because the app has to *draw* them on a waveform; nothing
// in the app draws an animation curve, so a second copy would be a second
// thing to keep in step for no reader. If the inspector ever previews a curve,
// that is the moment to port it — and to add the shared table, the way
// vd_time.c and time.dart have one.
//
// This file is plain C with no platform dependency, on purpose: it is the part
// of the picture that can be tested without a GPU or a typeface.

#ifndef VD_ANIM_H
#define VD_ANIM_H

#include <stdbool.h>
#include <stdint.h>

#include "vdodtor/vd_time.h"

#ifdef __cplusplus
extern "C" {
#endif

// The presets, in the order a picker offers them.
//
// **A preset names the direction the clip travels, not the edge it comes
// from.** `VD_ANIM_SLIDE_UP` moves upwards both times: on the way in it rises
// into place from below, and on the way out it carries on and leaves through
// the top. One rule for both halves, where "in from the left, out to the left"
// would be two — and the second one nobody can predict.
//
// Values cross the FFI boundary as integers, so these may be appended to and
// never reordered.
typedef enum {
  VD_ANIM_NONE = 0,
  // Opacity alone. The one that suits anything.
  VD_ANIM_FADE = 1,
  VD_ANIM_SLIDE_UP = 2,
  VD_ANIM_SLIDE_DOWN = 3,
  VD_ANIM_SLIDE_LEFT = 4,
  VD_ANIM_SLIDE_RIGHT = 5,
  // Overshoots and settles back. The only preset that is ever larger than its
  // resting size, which is what makes it read as a pop rather than a grow.
  VD_ANIM_POP = 6,
  // Grows from small. Like pop without the overshoot.
  VD_ANIM_ZOOM = 7,
  // A turn and a grow together.
  VD_ANIM_SPIN = 8,
  // Reveals the text a character at a time. Does nothing at all to a clip that
  // has no text — it is in this list rather than in a list of its own because
  // it is chosen from the same menu, and a preset that quietly does nothing on
  // a video clip is better than a menu that changes shape depending on what is
  // selected.
  VD_ANIM_TYPEWRITER = 9,
} VdAnimPreset;

// What a preset produces at one instant.
//
// Everything here **composes with** what the clip already asked for rather
// than replacing it: offsets add, scale multiplies, rotation adds, opacity
// multiplies. A caption parked at the bottom of the frame that slides up has
// to slide up from below *its own* position, not from below the middle.
typedef struct {
  // Added to the clip's own offset, as a fraction of the output's width and
  // height — the same units VdTransform uses.
  float offset_x;
  float offset_y;

  // Multiplied into the clip's own scale. 1 is at rest.
  float scale;

  // Added to the clip's own rotation.
  float rotation_degrees;

  // Multiplied into the clip's own opacity. 1 is at rest.
  float opacity;

  // How much of the text to show, 0..1. 1 is all of it, which is what every
  // preset but the typewriter produces.
  float reveal;
} VdAnimValue;

// A clip at rest: the identity for every field. Not a zeroed struct — a zeroed
// one is invisible, unscaled and empty, which is what a clip looks like
// *before* it arrives rather than after.
VD_EXPORT VdAnimValue vd_anim_rest(void);

// One preset at `t`, where 0 is fully away and 1 is at rest.
//
// The easing lives in here rather than in a curve the caller picks, because a
// preset is a whole gesture: "pop" is the overshoot as much as it is the
// scale, and letting the two be chosen separately would offer a thousand
// combinations to get one of them right.
//
// `t` outside 0..1 is clamped, so a caller doing its own arithmetic on ticks
// cannot produce a frame nobody designed.
VD_EXPORT VdAnimValue vd_anim_value(VdAnimPreset preset, float t);

// The in and out animations on one clip.
typedef struct {
  VdAnimPreset in_preset;
  VdTick in_duration;
  VdAnimPreset out_preset;
  VdTick out_duration;
} VdClipAnim;

// A clip nobody has animated.
VD_EXPORT VdClipAnim vd_clip_anim_none(void);

// Where a clip is `offset` ticks into a `duration`-long life.
//
// Works out which half applies and evaluates it. When both halves reach the
// same instant — a clip shorter than its own animations — the one that is
// *further from rest* wins rather than the two being combined: composing two
// entrances produces a motion neither preset describes, and the more extreme
// of the two is the one somebody asked for.
VD_EXPORT VdAnimValue vd_anim_at(const VdClipAnim* anim, VdTick offset,
                                 VdTick duration);

// True when nothing about this animation would change a frame. The engine uses
// it to keep a caption's raster: a clip whose animation is only ever transform
// and opacity never needs re-drawing, and one with a typewriter on it does.
VD_EXPORT bool vd_anim_reveals_text(const VdClipAnim* anim);

#ifdef __cplusplus
}
#endif
#endif  // VD_ANIM_H
