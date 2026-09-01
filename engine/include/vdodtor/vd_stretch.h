// vd_stretch.h — playing sound faster or slower than it was recorded.
//
// A clip at 2x consumes two seconds of its source for every second of
// timeline. The picture side of that is free — ask the decoder for a source
// time that moves twice as fast and it hands back the frame covering it — but
// sound cannot be sampled at an instant. Twice as many samples have to become
// half as many, and *how* is the whole of this file.
//
// There are exactly two honest answers and this module is both of them:
//
//   pitch preserved   the recording still sounds like itself, only shorter.
//                     Overlapping windows of the source are laid down at the
//                     output's rate, each one slid to wherever it continues
//                     the last one best — WSOLA. A voice stays that voice.
//
//   pitch shifted     the samples are simply played faster, the way a tape
//                     does it. Everything rises in pitch together. This is a
//                     sound effect and the user has to ask for it, which is
//                     why the document carries a toggle rather than the
//                     engine picking.
//
// Both consume `rate` input frames per output frame, so the caller feeds and
// takes and never has to know which is running.
//
// Plain C with no platform dependency, on `vd_color.c`'s terms and for the
// same reason: what a speed change *means* is asserted against numbers, with
// no file, no device and no clock in the room. The whole module is testable
// with a sine wave in an array.

#ifndef VD_STRETCH_H
#define VD_STRETCH_H

#include <stdbool.h>
#include <stdint.h>

#include "vdodtor/vd_time.h"

#ifdef __cplusplus
extern "C" {
#endif

// The slowest and the fastest a clip may play. Below a tenth the overlap
// search has nothing left to correlate against — every output window is the
// same few milliseconds repeated — and above ten there is less than a pitch
// period of new material per window, so the two ends are where the method
// stops meaning anything rather than where a product decision was made.
//
// Mirrored by ClipSpeed.minRate / maxRate in app/lib/model/clip.dart.
#define VD_SPEED_MIN 0.1
#define VD_SPEED_MAX 10.0

// Stereo, in practice: the engine mixes everything to it. Kept as a parameter
// rather than baked in so this module can be exercised on one channel, which
// is what makes a test of the *arithmetic* readable.
#define VD_STRETCH_MAX_CHANNELS 2

// `speed` clamped to what a clip may play at, with zero and anything negative
// read as 1 — which is what lets VdTimelineClip::speed be the one field on
// that struct a caller may leave at whatever a memset gave it.
//
// Here rather than in vd_engine.c because the range belongs to the method: it
// is where the overlap search stops having anything to correlate, not a
// product decision, and the mixer and the compositor have to agree about it.
VD_EXPORT double vd_speed_clamp(double speed);

typedef struct VdStretch VdStretch;

// `rate` is source seconds per output second: 2 plays twice as fast, 0.5 half
// as fast. Clamped to [VD_SPEED_MIN, VD_SPEED_MAX]. Returns NULL on a bad
// argument or a failed allocation.
//
// A rate of exactly 1 is legal and passes audio through unchanged, but the
// caller is better off not creating one at all — see vd_audio_renderer.c,
// which keeps the stretcher NULL for a clip nobody retimed so the common path
// is the path it always was.
VD_EXPORT VdStretch* vd_stretch_create(int32_t sample_rate, int32_t channels,
                                       double rate, bool pitch_shift);
VD_EXPORT void vd_stretch_destroy(VdStretch* stretch);

// True when this stretcher was made for exactly these settings, so a caller
// holding one across an edit knows whether it may keep it.
VD_EXPORT bool vd_stretch_matches(const VdStretch* stretch, double rate,
                                  bool pitch_shift);

// Throws away everything buffered and forgets what it last emitted. Called on
// a seek: the material either side of one does not join up, and crossfading
// across the discontinuity would smear the frames before the seek into the
// ones after it.
VD_EXPORT void vd_stretch_reset(VdStretch* stretch);

// Input frames it can take right now. Zero means it is full and the caller
// should read before writing again.
VD_EXPORT int32_t vd_stretch_wanted(const VdStretch* stretch);

// Feeds interleaved frames. Returns how many were taken, which is at most
// vd_stretch_wanted.
VD_EXPORT int32_t vd_stretch_write(VdStretch* stretch, const float* in,
                                   int32_t frames);

// Takes interleaved frames out. Returns how many were written; fewer than
// asked for means it needs more input, not that the source ended — that is
// something only the caller knows.
VD_EXPORT int32_t vd_stretch_read(VdStretch* stretch, float* out,
                                  int32_t frames);

// How much input it has to see before it can emit anything at all: one
// analysis window, plus the room the overlap search needs. Worth knowing
// because it is also the latency — at 0.1x it is 55 ms of source and at 10x
// it is a third of a second of it.
VD_EXPORT int32_t vd_stretch_priming_frames(const VdStretch* stretch);

#ifdef __cplusplus
}
#endif
#endif  // VD_STRETCH_H
