// vd_engine.h — the thing the app drives.
//
// Everything below this line is synchronous and testable: decode a frame,
// composite some layers. This is where a clock finally enters, and it is the
// only place one does. The engine holds a copy of the timeline, a position,
// and a thread that renders at the right moments.
//
// The document stays in Dart. What crosses over is a *render list*: flat
// clips with source paths and times. The engine does not know about undo,
// media bins or track names, and keeping it that way is what lets a WebCodecs
// backend implement the same contract later.

#ifndef VD_ENGINE_H
#define VD_ENGINE_H

#include <stdbool.h>
#include <stdint.h>

#include "vdodtor/vd_anim.h"
#include "vdodtor/vd_color.h"
#include "vdodtor/vd_compositor.h"
#include "vdodtor/vd_eq.h"
#include "vdodtor/vd_lut.h"
#include "vdodtor/vd_shape.h"
#include "vdodtor/vd_sticker.h"
#include "vdodtor/vd_text.h"
#include "vdodtor/vd_transition.h"
#include "vdodtor/vd_time.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VdEngine VdEngine;
struct VdAudioRenderer;

typedef enum {
  VD_STATE_IDLE = 0,
  VD_STATE_PLAYING = 1,
  VD_STATE_PAUSED = 2,
  VD_STATE_ENDED = 3,
} VdPlaybackState;

// The shape a fade ramps in. Four of them, each with a job:
//
//   VD_FADE_LINEAR       a straight line in amplitude. The handle position
//                        means what it looks like it means, and it is what
//                        every project written before this existed has.
//   VD_FADE_SMOOTH       a raised cosine: no corner at either end, which is
//                        what a fade over music or a held shot wants.
//   VD_FADE_EQUAL_POWER  a quarter of a sine, which holds *power* constant.
//                        Two clips overlapping on two lanes cross through it
//                        without the 3 dB dip a pair of linear ramps leaves in
//                        the middle — the one shape that is about a crossfade
//                        rather than about a fade.
//   VD_FADE_EXPONENTIAL  t squared: starts almost silent and arrives late,
//                        which is the shape a long musical fade-in wants.
//
// One curve per clip rather than one per fade: two shapes on one clip is a
// distinction nobody makes, and it would double the field, the picker, the
// file format and the table for nothing.
//
// Mirrored by `FadeCurve` in app/lib/model/clip.dart and `EngineFadeCurve` in
// the plugin. The index crosses the FFI boundary, so append only. Zero is
// linear, which is what makes this a field a caller may leave at whatever a
// memset gave it.
typedef enum {
  VD_FADE_LINEAR = 0,
  VD_FADE_SMOOTH = 1,
  VD_FADE_EQUAL_POWER = 2,
  VD_FADE_EXPONENTIAL = 3,
} VdFadeCurve;

// One point on a clip's volume line.
//
// `source_time` is in the source's own time — the same coordinate as
// `source_in` — rather than an offset into the clip, so that trimming a clip
// slides the window over the automation instead of dragging the automation
// along with it. A duck stays on the word it was drawn for.
typedef struct {
  VdTick source_time;
  float value;
} VdVolumePoint;

typedef struct {
  // Absolute path to the source file, or NULL for a clip that generates its
  // own picture — see `text` and `shape`. Copied on set_timeline; the caller
  // keeps ownership of its own string.
  const char* path;

  // A caption instead of a file. NULL for every clip that has a `path`, and
  // the three are exclusive: a clip is a window onto a source, or it is one of
  // the two things the engine draws, and never two of them at once.
  //
  // The spec is copied on set_timeline, strings and all, and the raster it
  // produces is kept for as long as the clip's spec is unchanged — the same
  // bargain `path` gets with its decoder, and for the same reason: nudging a
  // clip must not cost a re-layout of every caption on the timeline.
  const VdTextSpec* text;

  // A rectangle, an ellipse, a line or an arrow instead of a file. Copied and
  // cached on exactly the terms `text` is: a shape whose spec did not change
  // keeps the pixels it already had. See vd_shape.h.
  const VdShapeSpec* shape;

  // True when `path` is an animated overlay — a GIF, an animated WebP, an
  // APNG — rather than video. It is decoded whole and looped instead of being
  // seeked in, which is a different enough thing to be a different module: see
  // vd_sticker.h.
  //
  // The caller is told to say rather than the engine probing to find out, for
  // the same reason `has_video` is: the document already knows, and a sticker
  // should not cost a file open on every edit to establish what it is.
  bool sticker;

  VdTick start;      // position on the timeline
  VdTick duration;   // length on the timeline
  VdTick source_in;  // offset into the source

  // Source seconds per timeline second: 2 plays twice as fast, 0.5 half as
  // fast, and 1 is every clip nobody retimed. Clamped to [0.1, 10]; zero and
  // anything negative are read as 1, which is what makes `speed` the one field
  // on this struct a caller may leave at whatever a memset gave it.
  //
  // `duration` is still the clip's length *on the timeline*, so this says
  // nothing about where the clip sits or how long it lasts — only how fast the
  // window over the source travels while it is on screen. The source window it
  // implies is `duration * speed`, and the document is the one that decides
  // both: retiming a clip is a change of length, not something the engine can
  // work out on its own.
  double speed;

  // True when a retimed clip should sound like a tape played fast: everything
  // in it rises in pitch together. False — the default, and what a memset
  // gives — keeps the pitch it was recorded at and stretches time instead.
  //
  // A toggle rather than a rule, because both are right: a slow-motion shot
  // usually wants the voice in it to still be that voice, and a comedy speed-up
  // usually wants the chipmunk. Ignored at `speed` 1, where the two agree.
  // See vd_stretch.h.
  bool pitch_shift;

  // Compositing order: lower renders first, so 0 is the main track.
  int32_t track;

  float opacity;
  VdFitMode fit;

  // Where this clip sits inside the frame. A zeroed transform is the identity,
  // so a caller with nothing to say about it can leave the field alone.
  VdTransform transform;

  // What it does to its own colour. A zeroed VdColorAdjust is the neutral
  // grade, so this is another field a caller can ignore.
  //
  // Handed to the compositor untouched, unlike the animation and the
  // transition beside it: those are functions of *time* and have to be
  // evaluated per frame, where a grade is the same five numbers at every
  // instant of the clip. Nothing about it belongs in the render loop, which is
  // why it is composed into a matrix down in the compositor and not here.
  // See vd_color.h.
  VdColorAdjust color;

  // The look on this clip: a name registered with vd_lut_register, or NULL for
  // a clip nobody put one on. Copied on set_timeline; the caller keeps
  // ownership of its own string.
  //
  // A name rather than a path or a lattice, exactly as `VdTextSpec::font` is a
  // family name: the looks the app ships have no path inside a signed bundle,
  // and a document that names one reads like the edit that made it rather than
  // like one machine's filesystem. A name nothing was registered under draws
  // ungraded, which is the bargain a caption in a missing face already takes.
  const char* look;

  // 0..1: how far towards the look to go. Only read when `look` names one.
  float look_strength;

  // How this clip joins the one before it on the same track. A zeroed
  // VdClipTransition is "a plain cut", so this is a field a caller can ignore.
  //
  // It belongs to the *incoming* clip and names only its own head, so there is
  // one place a transition is written down and no way for the two sides of a
  // cut to disagree about it. The engine finds the outgoing clip itself — the
  // one on the same track whose end is exactly this clip's start — once per
  // edit rather than once per frame. See vd_transition.h.
  VdClipTransition transition;

  // How it arrives and how it leaves. A zeroed VdClipAnim is "no animation",
  // so this is another field a caller can ignore.
  //
  // Evaluated per frame and composed with `transform` rather than replacing
  // it: a caption parked at the bottom that slides up slides up from below
  // its own position. See vd_anim.h.
  VdClipAnim anim;

  // False for a clip that contributes only sound: one on an audio lane, or a
  // file with no picture in it. The compositor skips it rather than opening a
  // decoder that will never yield a frame and holding a cache slot with it.
  //
  // The caller is told to say, rather than the engine probing to find out,
  // because the document already knows — and a music bed should not cost a
  // file open on every edit to establish that it has no video.
  bool has_video;

  // Linear gain on this clip's sound, 0 for silent. Mute is spelled 0 here:
  // the document keeps the difference between "muted" and "turned down",
  // because unmuting has to give the level back, but by the time it reaches
  // the engine that distinction has been decided and only the number matters.
  float gain;

  // Ramps from silence over `fade_in` at the head and to silence over
  // `fade_out` at the tail. Ticks, like every other length that crosses here.
  VdTick fade_in;
  VdTick fade_out;

  // The shape both of those ramps take. Zero is linear, which is the shape
  // every fade had before there was a choice — so an existing project sounds
  // bit for bit as it did. See VdFadeCurve.
  VdFadeCurve fade_curve;

  // What this clip sounds like: one of a short list of corrections and one
  // effect, or VD_EQ_NONE for the clips nobody touched, which is almost all of
  // them. A name rather than a set of bands, for the reason `look` is a name
  // rather than a lattice — see vd_eq.h.
  VdEqPreset eq;

  // The volume line: gain over the source, sorted by `source_time`, and a
  // multiplier on `gain` rather than a replacement for it. NULL and 0 mean a
  // clip nobody has automated, which is almost all of them.
  //
  // The only thing on this struct that is not a scalar, because it is the only
  // thing whose length the document decides. Copied on set_timeline, like
  // `path`; the caller keeps ownership of its own array.
  const VdVolumePoint* volume_points;
  int32_t volume_point_count;
} VdTimelineClip;

// A clip with nothing said about it: fully opaque, full volume, contained,
// carrying a picture, and with no volume line — for which a zeroed pointer and
// count happen to be exactly right.
//
// Worth the four lines it costs. Unlike VdTransform, this struct cannot make a
// zeroed value mean "no opinion" — gain 0 is silence and opacity 0 is
// invisible, and both are things a caller might legitimately ask for, so
// neither can double as "unset". A caller that memsets and fills in three
// fields would get a silent, invisible clip, which is a bug that looks like
// nothing happening at all.
VD_EXPORT VdTimelineClip vd_timeline_clip_default(void);

typedef struct {
  int32_t width;
  int32_t height;
  VdRational frame_rate;

  const VdTimelineClip* clips;
  int32_t clip_count;
} VdTimeline;

typedef struct {
  // 0 to skip opening an output device. The audio path still decodes and
  // mixes, and vd_engine_audio_renderer can still be pulled — which is how
  // the tests exercise A/V sync without making a noise, and how a headless
  // export will avoid touching the sound card.
  int32_t audio_output;
} VdEngineOptions;

VD_EXPORT VdEngineOptions vd_engine_default_options(void);

VD_EXPORT VdEngine* vd_engine_create(int32_t* out_result);
VD_EXPORT VdEngine* vd_engine_create_with_options(VdEngineOptions options,
                                                  int32_t* out_result);

// The engine's audio renderer, for pulling frames when no device is attached.
// Owned by the engine; valid until vd_engine_destroy.
VD_EXPORT struct VdAudioRenderer* vd_engine_audio_renderer(VdEngine* engine);

// Stops the render thread, waits for it, and only then tears anything down.
// The S1 spike freed the engine while GPU completion handlers still held it,
// and it presented as gradual slowdown rather than a crash.
VD_EXPORT void vd_engine_destroy(VdEngine* engine);

// Replaces the render list. Safe to call while playing: the current position
// is kept, and the next rendered frame reflects the new timeline. Reopening
// decoders is avoided where a clip's source is unchanged.
VD_EXPORT int32_t vd_engine_set_timeline(VdEngine* engine,
                                         const VdTimeline* timeline);

VD_EXPORT void vd_engine_play(VdEngine* engine);
VD_EXPORT void vd_engine_pause(VdEngine* engine);

// Moves the playhead. Renders one frame even when paused, which is what makes
// scrubbing show anything.
VD_EXPORT void vd_engine_seek(VdEngine* engine, VdTick position);

// Renders the current position once, synchronously, on the calling thread.
// For tests and for the first frame after a timeline change.
VD_EXPORT int32_t vd_engine_render_now(VdEngine* engine);

VD_EXPORT VdTick vd_engine_position(VdEngine* engine);
VD_EXPORT VdTick vd_engine_duration(VdEngine* engine);
VD_EXPORT int32_t vd_engine_state(VdEngine* engine);

// Called from the render thread each time a new frame is published. The
// plugin hooks this to -[FlutterTextureRegistry textureFrameAvailable:].
// Must not block and must not call back into the engine.
typedef void (*VdFrameCallback)(void* context);
VD_EXPORT void vd_engine_set_frame_callback(VdEngine* engine,
                                            VdFrameCallback callback,
                                            void* context);

// The most recently published frame as a CVPixelBufferRef, retained. NULL
// before the first render. Caller releases.
VD_EXPORT void* vd_engine_copy_output(VdEngine* engine);

// Writes the last published frame to `path` as PNG.
VD_EXPORT int32_t vd_engine_dump_png(VdEngine* engine, const char* path);

typedef struct {
  int64_t frames_presented;
  // Frames whose deadline had already passed when they were ready. This is
  // the number that says whether playback is actually keeping up.
  int64_t frames_late;
  double composite_ms_avg;
  double present_fps;
  VdTick position;
  VdTick duration;
  int32_t state;
  int32_t open_decoders;
  int32_t active_layers;
  double last_seek_ms;

  // True when the timeline has audio, and therefore when the audio clock is
  // the one driving playback.
  bool audio_available;
  // Times the device asked for audio that had not been decoded yet. Unlike a
  // late video frame, every one of these is audible.
  int64_t audio_underruns;
  int32_t audio_buffered_frames;

  // Renders that happened because something asked for one rather than because
  // the playhead reached a new frame. A seek is one; a steady stream of them
  // during playback means something is spuriously repainting.
  int64_t forced_renders;

  // Times the playhead was seen to move backwards during playback. The audio
  // clock and the wall clock do not tick at quite the same rate, so a position
  // read that falls back from one to the other can dip — and a dip across a
  // frame boundary would republish a frame that has already been shown.
  int64_t clock_regressions;

  // Captions laid out since the engine started. This is the number that says
  // whether the raster cache is working: it should tick once per caption per
  // edit that changed one, and never during playback. A steady stream of them
  // means every frame is re-running Core Text, which is the whole thing the
  // cache exists to prevent.
  int64_t text_rasters;

  // Shapes drawn, on the same terms and read the same way. A counter of its
  // own rather than a shared "generated rasters", because the two answer
  // different questions: a caption's raster is the expensive one and the one
  // an animation can invalidate per character, and folding a shape's into it
  // would blunt exactly the measurement text_rasters exists to make.
  int64_t shape_rasters;

  // Times a sticker put a *different* frame on screen. This is what says the
  // retiming is happening: a 4 fps sticker on a 60 fps timeline should tick
  // this four times a second, not sixty. A stream of them at the project's
  // rate means every frame is being copied again to show the same picture.
  int64_t sticker_frames;

  // Look cubes uploaded to the GPU since the engine started. Straight from the
  // compositor, and read the same way `text_rasters` is: a look is the same
  // few hundred kilobytes on every frame of every clip wearing it, so this
  // should tick once per look and never during playback or during a drag on
  // the strength slider.
  int64_t lut_uploads;

  // Stickers decoded whole since the engine started, and what they are
  // holding. An open is expensive and a byte is scarce, so both are worth
  // watching: a count that climbs during playback means the cache is thrashing
  // its budget, and the bytes are the budget it is thrashing.
  int64_t sticker_opens;
  int64_t sticker_bytes;
} VdEngineStats;

VD_EXPORT void vd_engine_stats(VdEngine* engine, VdEngineStats* out);

#ifdef __cplusplus
}
#endif
#endif  // VD_ENGINE_H
