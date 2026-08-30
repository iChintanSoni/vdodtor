// vd_audio.h — audio decode, resample, mix, and the clock that results.
//
// Three pieces, deliberately separable so each can be tested on its own:
//
//   VdAudioSource   one file, decoded and resampled to the engine's format
//   VdAudioRing     the hand-off between a decode thread and the device
//   VdAudioRenderer the timeline, the mix, and the audio clock
//
// The shape of all of it is dictated by one fact: the audio device calls back
// on a real-time thread. That callback may not lock, allocate, or touch a
// file. So decoding happens on an ordinary thread and reaches the device
// through a lock-free ring; everything else follows from that.

#ifndef VD_AUDIO_H
#define VD_AUDIO_H

#include <stdbool.h>
#include <stdint.h>

#include "vdodtor/vd_engine.h"
#include "vdodtor/vd_probe.h"
#include "vdodtor/vd_time.h"

#ifdef __cplusplus
extern "C" {
#endif

// The engine's internal audio format. Everything is resampled to this on the
// way in and mixed here; the device gets exactly this and nothing else.
// 48 kHz because it is what every export target wants, so the common path
// resamples zero times.
#define VD_AUDIO_SAMPLE_RATE 48000
#define VD_AUDIO_CHANNELS 2

// --- one source ------------------------------------------------------------

typedef struct VdAudioSource VdAudioSource;

// Opens the audio stream of `path`. Returns NULL and sets `out_result` when
// there is no audio to decode — which is not an error the caller should treat
// as fatal, since plenty of video has no sound.
VD_EXPORT VdAudioSource* vd_audio_source_open(const char* path,
                                              int32_t* out_result);
VD_EXPORT void vd_audio_source_close(VdAudioSource* source);

// Moves to `source_time` in the file. The next read starts there.
VD_EXPORT int32_t vd_audio_source_seek(VdAudioSource* source,
                                       VdTick source_time);

// Reads up to `frames` interleaved stereo float frames. Returns the number
// actually written; fewer than asked for means the source ended.
VD_EXPORT int32_t vd_audio_source_read(VdAudioSource* source, float* out,
                                       int32_t frames);

// Source time of the next frame that will be read.
VD_EXPORT VdTick vd_audio_source_position(const VdAudioSource* source);

VD_EXPORT VdTick vd_audio_source_duration(const VdAudioSource* source);

// --- the hand-off ----------------------------------------------------------

// A single-producer, single-consumer ring of interleaved stereo frames.
//
// Lock-free because the consumer is the audio device's real-time thread:
// taking a mutex there risks priority inversion against the decode thread,
// and the symptom is a click, which users notice far more than a dropped
// video frame.
typedef struct VdAudioRing VdAudioRing;

VD_EXPORT VdAudioRing* vd_audio_ring_create(int32_t capacity_frames);
VD_EXPORT void vd_audio_ring_destroy(VdAudioRing* ring);

// Producer side. Returns frames actually written.
VD_EXPORT int32_t vd_audio_ring_write(VdAudioRing* ring, const float* frames,
                                      int32_t count);
// Consumer side. Returns frames actually read; the rest of `out` is untouched.
VD_EXPORT int32_t vd_audio_ring_read(VdAudioRing* ring, float* out,
                                     int32_t count);

VD_EXPORT int32_t vd_audio_ring_available(const VdAudioRing* ring);
VD_EXPORT int32_t vd_audio_ring_space(const VdAudioRing* ring);
VD_EXPORT int32_t vd_audio_ring_capacity(const VdAudioRing* ring);

// Drops everything buffered. Called from the producer side on a seek; the
// consumer will read silence until the ring refills.
VD_EXPORT void vd_audio_ring_clear(VdAudioRing* ring);

// --- the renderer ----------------------------------------------------------

typedef struct VdAudioRenderer VdAudioRenderer;

VD_EXPORT VdAudioRenderer* vd_audio_renderer_create(int32_t* out_result);
VD_EXPORT void vd_audio_renderer_destroy(VdAudioRenderer* renderer);

// Takes the same render list the video side gets, and picks out the clips
// whose sources actually carry audio.
VD_EXPORT int32_t vd_audio_renderer_set_timeline(VdAudioRenderer* renderer,
                                                 const VdTimelineClip* clips,
                                                 int32_t clip_count);

// True when any clip in the timeline has audio. When false the engine keeps
// using its wall clock, because there is nothing to synchronise to.
VD_EXPORT bool vd_audio_renderer_has_audio(const VdAudioRenderer* renderer);

VD_EXPORT void vd_audio_renderer_start(VdAudioRenderer* renderer,
                                       VdTick position);
VD_EXPORT void vd_audio_renderer_stop(VdAudioRenderer* renderer);
VD_EXPORT void vd_audio_renderer_seek(VdAudioRenderer* renderer,
                                      VdTick position);

// The audio clock: the timeline position the device is playing right now.
//
// This is the master clock during playback. Audio cannot be stretched or
// skipped without the listener hearing it, whereas a video frame arriving a
// millisecond late is invisible — so video follows audio, never the reverse.
VD_EXPORT VdTick vd_audio_renderer_position(const VdAudioRenderer* renderer);

// Whether that position means anything yet.
//
// An audio clock only tells the time while something is draining it. With no
// device attached, or before the first pull after starting, the counter is
// standing still — and a caller that trusted it would freeze the picture.
VD_EXPORT bool vd_audio_renderer_clock_valid(const VdAudioRenderer* renderer);

// Fills `out` with `frames` of interleaved stereo, writing silence where the
// timeline has none. This is what the device callback calls; tests call it
// directly, which is why the device is not baked into the renderer.
VD_EXPORT int32_t vd_audio_renderer_pull(VdAudioRenderer* renderer, float* out,
                                         int32_t frames);

typedef struct {
  int64_t frames_rendered;
  // Times the device asked for audio that had not been decoded yet. Any
  // number above zero here is audible.
  int64_t underruns;
  int32_t buffered_frames;
  int32_t open_sources;
} VdAudioStats;

VD_EXPORT void vd_audio_renderer_stats(const VdAudioRenderer* renderer,
                                       VdAudioStats* out);

// --- the device ------------------------------------------------------------

// Starts the default output device pulling from `renderer`. Separate from the
// renderer so the whole audio path can be tested without a sound card, and so
// a headless export never opens one.
typedef struct VdAudioDevice VdAudioDevice;

VD_EXPORT VdAudioDevice* vd_audio_device_open(VdAudioRenderer* renderer,
                                              int32_t* out_result);
VD_EXPORT void vd_audio_device_close(VdAudioDevice* device);
VD_EXPORT int32_t vd_audio_device_start(VdAudioDevice* device);
VD_EXPORT int32_t vd_audio_device_stop(VdAudioDevice* device);

#ifdef __cplusplus
}
#endif
#endif  // VD_AUDIO_H
