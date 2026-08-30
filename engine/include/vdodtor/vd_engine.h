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

#include "vdodtor/vd_compositor.h"
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

typedef struct {
  // Absolute path to the source file. Copied on set_timeline; the caller keeps
  // ownership of its own string.
  const char* path;

  VdTick start;      // position on the timeline
  VdTick duration;   // length on the timeline
  VdTick source_in;  // offset into the source

  // Compositing order: lower renders first, so 0 is the main track.
  int32_t track;

  float opacity;
  VdFitMode fit;
} VdTimelineClip;

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
} VdEngineStats;

VD_EXPORT void vd_engine_stats(VdEngine* engine, VdEngineStats* out);

#ifdef __cplusplus
}
#endif
#endif  // VD_ENGINE_H
