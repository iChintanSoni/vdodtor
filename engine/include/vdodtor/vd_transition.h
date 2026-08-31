// vd_transition.h — how one clip becomes the next.
//
// A transition is a pure function of one number, exactly as an in/out
// animation is: given how far through the transition the playhead is, it
// produces what the *two* clips either side of the cut should look like. No
// keyframes, no state between frames, so a seek into the middle of a
// transition shows precisely the frame playback would. See vd_anim.h — the
// argument is the same one and this file is its second application.
//
// **The transition straddles the cut and nothing moves.** Half of it sits
// before the cut and half after, so the midpoint of a dissolve lands exactly
// where the two clips meet. The document keeps its clips butt-joined and
// non-overlapping — `Track` guarantees that, and `Track.clipAt` binary-searches
// on it — so the overlap a transition needs is made by the *engine*, which
// keeps the outgoing clip alive for half the transition past its end and
// starts the incoming one half a transition early.
//
// **That is also why it can never fail for lack of media.** Through its half of
// the window each clip is asked for a source time outside its own trim, and
// `vd_decoder_frame_at` already clamps: before the first frame returns the
// first, past the last returns the last. A cut between two clips trimmed to
// their very ends still dissolves — the outgoing side holds its last frame
// while the incoming one arrives. Editors usually solve this by consuming
// handles and shortening the sequence; that would move every clip downstream
// and repack the magnetic lane, which is a much larger surprise than a held
// frame at a cut nobody had trimmed.
//
// Plain C with no platform dependency, like vd_anim.c: the part of a
// transition that can be tested without a GPU is all of the arithmetic, and
// only the drawing needs Metal.

#ifndef VD_TRANSITION_H
#define VD_TRANSITION_H

#include <stdbool.h>
#include <stdint.h>

#include "vdodtor/vd_time.h"

#ifdef __cplusplus
extern "C" {
#endif

// The presets, in the order a picker offers them.
//
// One direction each. `VD_TRANSITION_WIPE` wipes left to right and
// `VD_TRANSITION_SLIDE` brings the new clip in from the right, because a
// picker with four arrows per entry is a picker with twenty entries — and the
// enum may be appended to, so the other directions can arrive as their own
// presets the way `VD_ANIM_SLIDE_*` did.
//
// Values cross the FFI boundary as integers: append only, never reorder.
typedef enum {
  VD_TRANSITION_NONE = 0,
  // The new clip fades up over the old one. The one that suits anything.
  VD_TRANSITION_DISSOLVE = 1,
  // Down to a colour and back up out of it. Black and white are two presets
  // rather than a preset and a colour, because these two are the ones anybody
  // asks for and a colour well would be a whole control for the third.
  VD_TRANSITION_FADE_BLACK = 2,
  VD_TRANSITION_FADE_WHITE = 3,
  // The new clip slides in from the right over the old one, which stays put.
  VD_TRANSITION_SLIDE = 4,
  // The same slide, but the old clip is shoved out of the frame by it.
  VD_TRANSITION_PUSH = 5,
  // A hard edge travelling left to right, the new clip behind it.
  VD_TRANSITION_WIPE = 6,
} VdTransitionPreset;

// What the two clips look like at one instant.
//
// "Out" is the clip leaving and "in" is the clip arriving. Offsets are
// fractions of the output's width and height, the same units `VdTransform`
// uses, and they are *added* to whatever transform the clip already had — a
// clip someone pushed to one side still pushes out from where they put it.
typedef struct {
  float out_opacity;
  float in_opacity;

  float out_offset_x;
  float out_offset_y;
  float in_offset_x;
  float in_offset_y;

  // How much of the incoming clip to cut away from each side, as fractions of
  // its own rectangle. Zeroed cuts nothing away. This is the one thing a
  // transition needs that a transform cannot express: a wipe is a hard edge
  // moving across a picture that is standing still, not a picture moving.
  float in_hide_left;
  float in_hide_top;
  float in_hide_right;
  float in_hide_bottom;

  // A solid colour laid over *both* clips, and how opaque it is. 0 draws
  // nothing, which is every preset but the two fades.
  //
  // A layer of its own, laid over the two clips at the cut and under anything
  // on a higher track — a caption over a fade-to-black stays legible, which is
  // what makes it a transition between two clips rather than an effect on the
  // whole frame.
  //
  // It has to be a layer. Turning the two clips' own opacity down instead
  // dips to whatever is *behind* them: black on the main track, which looks
  // right by accident, and the main track's picture on an overlay lane, which
  // does not. And there is no opacity at all that fades a clip to white.
  float flash;
  uint32_t flash_color;  // 0xAARRGGBB
} VdTransitionValue;

// The cut with no transition on it: both clips at rest, nothing hidden, no
// flash. Not a zeroed struct — a zeroed one has both clips invisible.
VD_EXPORT VdTransitionValue vd_transition_rest(void);

// One preset at `t`, where 0 is the start of the transition and 1 is its end.
// `t` outside 0..1 is clamped, so a caller doing its own arithmetic on ticks
// cannot produce a frame nobody designed.
VD_EXPORT VdTransitionValue vd_transition_value(VdTransitionPreset preset,
                                                float t);

// The transition at the head of one clip.
typedef struct {
  VdTransitionPreset preset;
  // The whole window, half of it either side of the cut. 0 is no transition,
  // whatever the preset says.
  VdTick duration;
} VdClipTransition;

// A clip nobody has put a transition on.
VD_EXPORT VdClipTransition vd_clip_transition_none(void);

// True when this would change a frame: a preset that does something, and a
// duration to do it in. A preset with no length and a length with no preset
// are both "nothing happens", and saying so once here keeps the engine from
// working it out twice.
VD_EXPORT bool vd_transition_active(const VdClipTransition* transition);

// Where the transition sits, given the cut it is at.
//
// Half either side, and clamped so it can never reach beyond the clips it
// joins: a transition longer than the shorter of the two would dissolve into a
// clip that is not on screen yet. Returns false when nothing happens, in which
// case the outputs are untouched.
VD_EXPORT bool vd_transition_window(const VdClipTransition* transition,
                                    VdTick cut, VdTick out_clip_start,
                                    VdTick in_clip_end, VdTick* out_from,
                                    VdTick* out_to);

#ifdef __cplusplus
}
#endif
#endif  // VD_TRANSITION_H
