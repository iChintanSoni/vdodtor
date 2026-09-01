#include "vdodtor/vd_audio.h"

#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "vdodtor/vd_stretch.h"

// Half a second of lead. Long enough to ride out a decode that stalls behind a
// seek on a slow disk, short enough that a scrub does not feel like it is
// arguing with you.
#define VD_AUDIO_RING_FRAMES (VD_AUDIO_SAMPLE_RATE / 2)

// Decoded in one go. ~21 ms, which is about one AAC packet, so the decoder is
// not repeatedly asked for fragments of one.
#define VD_AUDIO_CHUNK_FRAMES 1024

// Six audio lanes, plus the main track and three overlays — a video clip is a
// source of sound as much as an audio one, and the ceiling has to cover the
// whole document rather than only the lanes named after audio.
#define VD_AUDIO_MAX_ACTIVE 10

typedef struct {
  char* path;
  VdTick start;
  VdTick duration;
  VdTick source_in;

  // Source time per timeline time, and whether the pitch goes with it. Both
  // clamped once here, so the mixer below never has to wonder.
  double speed;
  bool pitch_shift;

  float gain;
  VdTick fade_in;
  VdTick fade_out;

  // Owned. Copied out of the render list, because the caller's array is gone
  // the moment set_timeline returns and the decode thread reads this for as
  // long as the clip is on the timeline.
  VdVolumePoint* points;
  int32_t point_count;

  VdAudioSource* source;
  bool open_failed;

  // Turns `speed` into sound. NULL for a clip nobody retimed, which is what
  // keeps the common path exactly the path it was before speed existed — the
  // source is read straight into the mix with nothing in between.
  //
  // `stretch_failed` is what tells that apart from a stretcher that could not
  // be built: a retimed clip whose stretcher is missing must go *silent*, not
  // quietly play at 1x while the picture runs at the rate it was given. The
  // drift that would cause grows by a whole chunk every chunk and there is
  // nothing on screen to say so. It is also why one failure is remembered
  // rather than retried every 21 milliseconds, like `open_failed` beside it.
  VdStretch* stretch;
  bool stretch_failed;

  // Where the clip expects the next chunk to start, *on the timeline*, so a
  // sequential decode does not re-seek every chunk.
  //
  // The timeline rather than the source, which it was before a clip could be
  // retimed: a stretcher buffers its own input, so the source position after a
  // chunk is a window-length or so ahead of where the arithmetic says it
  // should be and comparing the two would re-seek — and reset the stretcher —
  // on every chunk of every sped-up clip.
  VdTick expected_position;
  bool positioned;
} VdAudioClip;

struct VdAudioRenderer {
  pthread_mutex_t lock;
  pthread_cond_t wake;
  pthread_t thread;
  bool thread_running;
  bool quit;

  VdAudioClip* clips;
  int32_t clip_count;
  bool has_audio;

  VdAudioRing* ring;

  bool playing;
  // Where the decoder has reached on the timeline. Ahead of what is audible
  // by however much is sitting in the ring.
  VdTick decode_position;

  // The clock: `origin` is a timeline position, and `origin_frames` is the
  // device's frame counter at the moment it was set. Everything since is
  // elapsed time, whether it was audio or silence — the device really did
  // play those seconds either way.
  VdTick origin;
  _Atomic int64_t frames_pulled;
  int64_t origin_frames;

  _Atomic int64_t underruns;

  float* mix;       // the chunk being built, VD_AUDIO_CHUNK_FRAMES
  float* clip_out;  // one clip's contribution to it, at the timeline's rate
  float* scratch;   // raw source frames on their way into a stretcher
};

// --- clip bookkeeping ------------------------------------------------------

static void free_clips(VdAudioRenderer* r) {
  for (int32_t i = 0; i < r->clip_count; i++) {
    if (r->clips[i].source) vd_audio_source_close(r->clips[i].source);
    vd_stretch_destroy(r->clips[i].stretch);
    free(r->clips[i].path);
    free(r->clips[i].points);
  }
  free(r->clips);
  r->clips = NULL;
  r->clip_count = 0;
}

// Caller holds the lock.
static VdAudioSource* source_for(VdAudioRenderer* r, VdAudioClip* clip) {
  if (clip->source) return clip->source;
  if (clip->open_failed || !clip->path) return NULL;
  int32_t result = 0;
  clip->source = vd_audio_source_open(clip->path, &result);
  if (!clip->source) {
    // Silent video is the common case here, not a failure worth retrying
    // every 21 milliseconds.
    clip->open_failed = true;
    return NULL;
  }
  (void)r;
  return clip->source;
}

// --- the fade envelope -----------------------------------------------------

float vd_audio_fade_gain(VdTick offset, VdTick duration, VdTick fade_in,
                         VdTick fade_out) {
  if (duration <= 0) return 0.0f;
  if (offset < 0 || offset >= duration) return 0.0f;

  float gain = 1.0f;
  if (fade_in > 0 && offset < fade_in) {
    gain *= (float)((double)offset / (double)fade_in);
  }
  // Measured from the far edge, so the last tick of a clip is as quiet as the
  // first. A fade out that reached zero a tick early would leave a click
  // exactly where the fade was put to prevent one.
  const VdTick remaining = duration - offset;
  if (fade_out > 0 && remaining < fade_out) {
    gain *= (float)((double)remaining / (double)fade_out);
  }
  return gain;
}

// --- the volume line -------------------------------------------------------

// The value at `t` given that `index` is the last point at or before it, or -1
// when `t` is before them all.
//
// Split out from the search because the mixer walks forward through a chunk
// and finds its segment with a cursor rather than a scan, and the *maths* is
// the part that must not exist twice.
static float automation_between(const VdVolumePoint* points, int32_t count,
                                int32_t index, VdTick t) {
  if (count <= 0) return 1.0f;
  if (index < 0) return points[0].value;
  if (index >= count - 1) return points[count - 1].value;

  const VdVolumePoint a = points[index];
  const VdVolumePoint b = points[index + 1];
  const VdTick span = b.source_time - a.source_time;
  // Two points at the same tick are a step, not a division by zero.
  if (span <= 0) return b.value;
  const double f = (double)(t - a.source_time) / (double)span;
  return (float)(a.value + (b.value - a.value) * f);
}

float vd_audio_automation_gain(const VdVolumePoint* points, int32_t count,
                               VdTick source_time) {
  if (!points || count <= 0) return 1.0f;
  int32_t index = -1;
  for (int32_t i = 0; i < count; i++) {
    if (points[i].source_time > source_time) break;
    index = i;
  }
  return automation_between(points, count, index, source_time);
}

// --- speed -----------------------------------------------------------------

// Where in the source a clip is when the playhead is at `position` — the same
// multiply the picture side does in vd_engine.c, and it has to be: a frame and
// the sound under it disagreeing about where in the file they are is the one
// bug in a video editor everybody can hear.
static VdTick source_time_at(const VdAudioClip* clip, VdTick position) {
  const VdTick offset = position - clip->start;
  if (clip->speed == 1.0) return clip->source_in + offset;
  return clip->source_in + (VdTick)llround((double)offset * clip->speed);
}

// Caller holds the lock. Called only for a retimed clip, so NULL here means
// the stretcher could not be built — see VdAudioClip::stretch.
static VdStretch* stretch_for(VdAudioClip* clip) {
  if (clip->stretch) return clip->stretch;
  if (clip->stretch_failed) return NULL;
  clip->stretch = vd_stretch_create(VD_AUDIO_SAMPLE_RATE, VD_AUDIO_CHANNELS,
                                    clip->speed, clip->pitch_shift);
  if (!clip->stretch) clip->stretch_failed = true;
  return clip->stretch;
}

// Reads `frames` of clip audio, retimed if the clip asks for it.
//
// The stretcher decides how much source it wants and this feeds it until it
// has enough, so nothing here knows the ratio: at 10x that is ten reads for
// one chunk and at 0.1x it is one read for ten chunks, and both come out of
// the same loop. A short return means the source ended, which the caller
// leaves as silence.
//
// The fast path is chosen on the *speed*, not on whether there is a stretcher.
// Those are different questions, and answering the second would make a clip
// whose stretcher would not allocate play its sound at 1x under a picture
// running at 4x — silently, and further out of step every chunk.
static int32_t read_clip(VdAudioRenderer* r, VdAudioClip* clip,
                         VdAudioSource* source, float* out, int32_t frames) {
  if (clip->speed == 1.0) return vd_audio_source_read(source, out, frames);
  VdStretch* stretch = stretch_for(clip);
  if (!stretch) return 0;  // silent, rather than out of step

  int32_t done = 0;
  while (done < frames) {
    done += vd_stretch_read(stretch, out + (size_t)done * VD_AUDIO_CHANNELS,
                            frames - done);
    if (done >= frames) break;

    int32_t wanted = vd_stretch_wanted(stretch);
    if (wanted <= 0) break;  // full and still hungry: nothing more to try
    if (wanted > VD_AUDIO_CHUNK_FRAMES) wanted = VD_AUDIO_CHUNK_FRAMES;
    const int32_t got = vd_audio_source_read(source, r->scratch, wanted);
    if (got <= 0) break;  // the source ran out
    vd_stretch_write(stretch, r->scratch, got);
  }
  return done;
}

// --- decoding --------------------------------------------------------------

// Fills `out` with `frames` of mixed audio for timeline position `position`.
// Caller holds the lock.
static void mix_at(VdAudioRenderer* r, VdTick position, float* out,
                   int32_t frames) {
  memset(out, 0, (size_t)frames * VD_AUDIO_CHANNELS * sizeof(float));

  int32_t mixed = 0;
  for (int32_t i = 0; i < r->clip_count && mixed < VD_AUDIO_MAX_ACTIVE; i++) {
    VdAudioClip* clip = &r->clips[i];
    if (position < clip->start || position >= clip->start + clip->duration) {
      clip->positioned = false;  // it will need a seek when it comes round
      continue;
    }

    // A muted clip is not decoded at all. Reading it and multiplying by zero
    // would sound the same and cost a seek and a decode per chunk, and mute is
    // exactly the state a clip spends a long time in.
    if (clip->gain <= 0.0f) {
      clip->positioned = false;
      continue;
    }

    VdAudioSource* source = source_for(r, clip);
    if (!source) continue;

    const VdTick source_time = source_time_at(clip, position);
    if (!clip->positioned || clip->expected_position != position) {
      if (vd_audio_source_seek(source, source_time) != VD_OK) continue;
      // Whatever the stretcher had buffered belongs to a moment that is no
      // longer next: crossfading across a seek would smear the material
      // before it into the material after.
      if (clip->stretch) vd_stretch_reset(clip->stretch);
      clip->positioned = true;
    }

    const int32_t got = read_clip(r, clip, source, r->clip_out, frames);
    clip->expected_position =
        position + vd_scale(frames, VD_TICKS_PER_SECOND, VD_AUDIO_SAMPLE_RATE);

    const bool fading = clip->fade_in > 0 || clip->fade_out > 0;
    const bool automated = clip->points && clip->point_count > 0;
    const VdTick offset = position - clip->start;

    // A cursor rather than a search per frame: source time only goes forward
    // inside a chunk, so the segment is found once and then stepped past.
    int32_t segment = -1;
    if (automated) {
      while (segment + 1 < clip->point_count &&
             clip->points[segment + 1].source_time <= source_time) {
        segment++;
      }
    }

    // Sum. M1 only ever had one source here, but summing is the same loop that
    // ten of them need, and mixing is not where cleverness pays.
    for (int32_t frame = 0; frame < got; frame++) {
      float gain = clip->gain;
      if (fading || automated) {
        // Per frame, not per chunk. A chunk is 1024 frames — 21 ms — and an
        // envelope that stepped once a chunk would be a staircase of about
        // fifty steps, which is not a fade but a series of small clicks.
        const VdTick into = (VdTick)(((int64_t)frame * VD_TICKS_PER_SECOND) /
                                     VD_AUDIO_SAMPLE_RATE);
        if (fading) {
          gain *= vd_audio_fade_gain(offset + into, clip->duration,
                                     clip->fade_in, clip->fade_out);
        }
        if (automated) {
          // The fade is measured on the timeline and the volume line in the
          // source, so only one of the two moves when a clip is retimed: at 2x
          // a fade is still the length it was drawn, and the duck under it
          // arrives twice as soon because the word it was drawn on does.
          const VdTick at =
              source_time + (clip->speed == 1.0
                                 ? into
                                 : (VdTick)llround((double)into * clip->speed));
          while (segment + 1 < clip->point_count &&
                 clip->points[segment + 1].source_time <= at) {
            segment++;
          }
          gain *= automation_between(clip->points, clip->point_count, segment,
                                     at);
        }
      }
      for (int32_t ch = 0; ch < VD_AUDIO_CHANNELS; ch++) {
        const int32_t i = frame * VD_AUDIO_CHANNELS + ch;
        out[i] += r->clip_out[i] * gain;
      }
    }
    mixed++;
  }
}

static void* decode_thread(void* arg) {
  VdAudioRenderer* r = (VdAudioRenderer*)arg;
  pthread_mutex_lock(&r->lock);

  while (!r->quit) {
    if (!r->playing) {
      pthread_cond_wait(&r->wake, &r->lock);
      continue;
    }
    if (vd_audio_ring_space(r->ring) < VD_AUDIO_CHUNK_FRAMES) {
      // The ring is full: the device has all it needs for now. Wait rather
      // than spin, and wake early if anything changes.
      struct timespec deadline;
      clock_gettime(CLOCK_REALTIME, &deadline);
      deadline.tv_nsec += 5000000;  // 5 ms
      if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_nsec -= 1000000000L;
        deadline.tv_sec += 1;
      }
      pthread_cond_timedwait(&r->wake, &r->lock, &deadline);
      continue;
    }

    const VdTick position = r->decode_position;
    mix_at(r, position, r->mix, VD_AUDIO_CHUNK_FRAMES);
    vd_audio_ring_write(r->ring, r->mix, VD_AUDIO_CHUNK_FRAMES);
    r->decode_position +=
        vd_scale(VD_AUDIO_CHUNK_FRAMES, VD_TICKS_PER_SECOND,
                 VD_AUDIO_SAMPLE_RATE);
  }

  pthread_mutex_unlock(&r->lock);
  return NULL;
}

// Caller holds the lock.
static bool ensure_thread(VdAudioRenderer* r) {
  if (r->thread_running) return true;
  if (pthread_create(&r->thread, NULL, decode_thread, r) != 0) return false;
  r->thread_running = true;
  return true;
}

// --- lifecycle -------------------------------------------------------------

VdAudioRenderer* vd_audio_renderer_create(int32_t* out_result) {
  if (out_result) *out_result = VD_OK;
  VdAudioRenderer* r = calloc(1, sizeof(VdAudioRenderer));
  if (!r) {
    if (out_result) *out_result = VD_ERR_OPEN;
    return NULL;
  }
  pthread_mutex_init(&r->lock, NULL);
  pthread_cond_init(&r->wake, NULL);
  r->ring = vd_audio_ring_create(VD_AUDIO_RING_FRAMES);
  r->mix = calloc((size_t)VD_AUDIO_CHUNK_FRAMES * VD_AUDIO_CHANNELS,
                  sizeof(float));
  r->clip_out = calloc((size_t)VD_AUDIO_CHUNK_FRAMES * VD_AUDIO_CHANNELS,
                       sizeof(float));
  r->scratch = calloc((size_t)VD_AUDIO_CHUNK_FRAMES * VD_AUDIO_CHANNELS,
                      sizeof(float));
  if (!r->ring || !r->mix || !r->clip_out || !r->scratch) {
    vd_audio_renderer_destroy(r);
    if (out_result) *out_result = VD_ERR_OPEN;
    return NULL;
  }
  atomic_store(&r->frames_pulled, 0);
  atomic_store(&r->underruns, 0);
  return r;
}

void vd_audio_renderer_destroy(VdAudioRenderer* r) {
  if (!r) return;

  pthread_mutex_lock(&r->lock);
  r->quit = true;
  r->playing = false;
  pthread_cond_broadcast(&r->wake);
  const bool running = r->thread_running;
  pthread_mutex_unlock(&r->lock);

  // Join before freeing anything the thread touches. The device must already
  // be stopped by this point; that is the caller's contract, and it is the
  // order vd_engine_destroy uses.
  if (running) pthread_join(r->thread, NULL);

  free_clips(r);
  vd_audio_ring_destroy(r->ring);
  free(r->mix);
  free(r->clip_out);
  free(r->scratch);
  pthread_cond_destroy(&r->wake);
  pthread_mutex_destroy(&r->lock);
  free(r);
}

int32_t vd_audio_renderer_set_timeline(VdAudioRenderer* r,
                                       const VdTimelineClip* clips,
                                       int32_t clip_count) {
  if (!r) return VD_ERR_INVALID_ARG;
  if (clip_count < 0 || (clip_count > 0 && !clips)) return VD_ERR_INVALID_ARG;

  pthread_mutex_lock(&r->lock);

  VdAudioClip* previous = r->clips;
  const int32_t previous_count = r->clip_count;

  VdAudioClip* next =
      clip_count > 0 ? calloc((size_t)clip_count, sizeof(VdAudioClip)) : NULL;
  if (clip_count > 0 && !next) {
    pthread_mutex_unlock(&r->lock);
    return VD_ERR_OPEN;
  }

  bool any_audio = false;
  for (int32_t i = 0; i < clip_count; i++) {
    next[i].path = clips[i].path ? strdup(clips[i].path) : NULL;
    next[i].start = clips[i].start;
    next[i].duration = clips[i].duration;
    next[i].source_in = clips[i].source_in;
    next[i].speed = vd_speed_clamp(clips[i].speed);
    next[i].pitch_shift = clips[i].pitch_shift;
    next[i].gain = clips[i].gain;
    next[i].fade_in = clips[i].fade_in;
    next[i].fade_out = clips[i].fade_out;

    if (clips[i].volume_points && clips[i].volume_point_count > 0) {
      const size_t bytes =
          (size_t)clips[i].volume_point_count * sizeof(VdVolumePoint);
      next[i].points = malloc(bytes);
      if (next[i].points) {
        memcpy(next[i].points, clips[i].volume_points, bytes);
        next[i].point_count = clips[i].volume_point_count;
      }
      // A failed allocation loses the curve and keeps the sound. Refusing the
      // whole timeline because a duck would not fit in memory is the worse of
      // the two answers.
    }

    // Carry over an already-open source for the same file, so an edit does
    // not reopen and re-seek everything.
    for (int32_t j = 0; j < previous_count; j++) {
      VdAudioClip* old = &previous[j];
      if (old->source && old->path && next[i].path &&
          strcmp(old->path, next[i].path) == 0) {
        next[i].source = old->source;
        old->source = NULL;
        // And the stretcher with it, when the edit was not the speed itself.
        // Its buffers are a hundred kilobytes and its windows are the last
        // forty milliseconds of the clip; rebuilding both because somebody
        // nudged a fader would be work for nothing.
        if (old->stretch && vd_stretch_matches(old->stretch, next[i].speed,
                                               next[i].pitch_shift)) {
          next[i].stretch = old->stretch;
          old->stretch = NULL;
        }
        break;
      }
    }
    if (next[i].source) any_audio = true;
  }

  for (int32_t j = 0; j < previous_count; j++) {
    if (previous[j].source) vd_audio_source_close(previous[j].source);
    vd_stretch_destroy(previous[j].stretch);
    free(previous[j].path);
    free(previous[j].points);
  }
  free(previous);

  r->clips = next;
  r->clip_count = clip_count;

  // Probing every clip here would open every file on every edit. Ask only
  // about the ones not already known to have audio, and only once.
  if (!any_audio) {
    for (int32_t i = 0; i < clip_count; i++) {
      int32_t result = 0;
      VdAudioSource* probe = vd_audio_source_open(r->clips[i].path, &result);
      if (probe) {
        r->clips[i].source = probe;
        any_audio = true;
        break;
      }
      r->clips[i].open_failed = true;
    }
  }
  r->has_audio = any_audio;

  // The timeline moved under the buffered audio, so what is queued is stale.
  vd_audio_ring_clear(r->ring);
  for (int32_t i = 0; i < r->clip_count; i++) r->clips[i].positioned = false;

  pthread_cond_broadcast(&r->wake);
  pthread_mutex_unlock(&r->lock);
  return VD_OK;
}

bool vd_audio_renderer_has_audio(const VdAudioRenderer* r) {
  return r ? r->has_audio : false;
}

// --- transport -------------------------------------------------------------

// Caller holds the lock. Rebases the clock and throws away buffered audio.
static void rebase(VdAudioRenderer* r, VdTick position) {
  vd_audio_ring_clear(r->ring);
  r->decode_position = position;
  r->origin = position;
  r->origin_frames = atomic_load(&r->frames_pulled);
  for (int32_t i = 0; i < r->clip_count; i++) r->clips[i].positioned = false;
}

void vd_audio_renderer_start(VdAudioRenderer* r, VdTick position) {
  if (!r) return;
  pthread_mutex_lock(&r->lock);
  rebase(r, position);
  r->playing = true;
  ensure_thread(r);
  pthread_cond_broadcast(&r->wake);
  pthread_mutex_unlock(&r->lock);
}

void vd_audio_renderer_stop(VdAudioRenderer* r) {
  if (!r) return;
  pthread_mutex_lock(&r->lock);
  r->playing = false;
  // Whatever is buffered belongs to a moment that has passed.
  vd_audio_ring_clear(r->ring);
  pthread_cond_broadcast(&r->wake);
  pthread_mutex_unlock(&r->lock);
}

void vd_audio_renderer_seek(VdAudioRenderer* r, VdTick position) {
  if (!r) return;
  pthread_mutex_lock(&r->lock);
  rebase(r, position);
  pthread_cond_broadcast(&r->wake);
  pthread_mutex_unlock(&r->lock);
}

bool vd_audio_renderer_clock_valid(const VdAudioRenderer* r) {
  if (!r || !r->has_audio || !r->playing) return false;
  // Playing but not yet pulled: the device has not asked for anything, so no
  // time has passed as far as audio is concerned.
  return atomic_load(&r->frames_pulled) > r->origin_frames;
}

VdTick vd_audio_renderer_position(const VdAudioRenderer* r) {
  if (!r) return 0;
  // Read without the lock: this is called from the video render thread every
  // frame, and it must never wait on a decode.
  const int64_t pulled = atomic_load(&r->frames_pulled);
  return r->origin + vd_scale(pulled - r->origin_frames, VD_TICKS_PER_SECOND,
                              VD_AUDIO_SAMPLE_RATE);
}

// --- the device's side -----------------------------------------------------

int32_t vd_audio_renderer_pull(VdAudioRenderer* r, float* out, int32_t frames) {
  if (!r || !out || frames <= 0) return 0;

  // No lock, no allocation, no file access: this runs on the device's
  // real-time thread, and anything that can block here is a click.
  const int32_t got = vd_audio_ring_read(r->ring, out, frames);
  if (got < frames) {
    memset(out + (size_t)got * VD_AUDIO_CHANNELS, 0,
           (size_t)(frames - got) * VD_AUDIO_CHANNELS * sizeof(float));
    if (got < frames) atomic_fetch_add(&r->underruns, 1);
  }

  // Silence counts: the device really did play that much time.
  atomic_fetch_add(&r->frames_pulled, frames);
  return frames;
}

void vd_audio_renderer_stats(const VdAudioRenderer* r, VdAudioStats* out) {
  if (!r || !out) return;
  memset(out, 0, sizeof(*out));
  out->frames_rendered = atomic_load(&r->frames_pulled);
  out->underruns = atomic_load(&r->underruns);
  out->buffered_frames = vd_audio_ring_available(r->ring);
  int32_t open = 0;
  for (int32_t i = 0; i < r->clip_count; i++) {
    if (r->clips[i].source) open++;
  }
  out->open_sources = open;
}
