#include "vdodtor/vd_engine.h"

#include <mach/mach_time.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <CoreVideo/CoreVideo.h>

#include "vdodtor/vd_decoder.h"

// How many decoders stay open at once. The M0 spike measured four concurrent
// 4K60 decoders at ~34% CPU, so this is comfortably inside what the machine
// can carry, and it means crossing a cut reuses a decoder rather than opening
// one — an open costs milliseconds, and a hitch at every cut is exactly what
// makes an editor feel cheap.
#define VD_MAX_OPEN_DECODERS 8

// Compositing is bounded by the product's track count: one main plus three
// overlays.
#define VD_MAX_LAYERS 4

typedef struct {
  char* path;
  VdTick start;
  VdTick duration;
  VdTick source_in;
  int32_t track;
  float opacity;
  VdFitMode fit;

  VdDecoder* decoder;  // opened lazily
  int64_t last_used;
  bool decoder_failed;  // do not retry every frame
} VdClipEntry;

struct VdEngine {
  // Two locks, always taken in this order when both are needed.
  //
  // `render_lock` serialises rendering and timeline mutation: a decoder is not
  // thread-safe, and two threads inside one only shows up as an assertion deep
  // in libavcodec. `lock` protects the small, fast state — position, playback
  // state, stats — so asking where the playhead is never waits on a decode.
  pthread_mutex_t render_lock;
  pthread_mutex_t lock;
  pthread_cond_t wake;
  pthread_t thread;
  bool thread_running;
  bool quit;

  VdCompositor* compositor;
  int32_t width;
  int32_t height;
  VdRational frame_rate;
  VdTick ticks_per_frame;

  VdClipEntry* clips;
  int32_t clip_count;
  VdTick duration;

  VdPlaybackState state;
  // Media position, and the host time it was anchored at. While playing,
  // position = anchor_position + elapsed since anchor_host.
  VdTick anchor_position;
  uint64_t anchor_host;
  bool render_requested;

  VdFrameCallback frame_callback;
  void* frame_callback_context;

  int64_t clock;  // LRU stamp for decoders
  VdEngineStats stats;
  uint64_t fps_window_start;
  int64_t fps_window_frames;
  double seek_started_host;
  bool seek_pending;
};

// --- host time -------------------------------------------------------------

static double g_ns_per_tick = 0.0;

static uint64_t host_now(void) { return mach_absolute_time(); }

static int64_t host_to_ns(uint64_t delta) {
  if (g_ns_per_tick == 0.0) {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    g_ns_per_tick = (double)info.numer / (double)info.denom;
  }
  return (int64_t)((double)delta * g_ns_per_tick);
}

// --- position --------------------------------------------------------------

// Caller holds the lock.
static VdTick current_position(const VdEngine* e) {
  if (e->state != VD_STATE_PLAYING) return e->anchor_position;
  int64_t elapsed_ns = host_to_ns(host_now() - e->anchor_host);
  VdTick position = e->anchor_position + vd_ticks_from_nanos(elapsed_ns);
  return position > e->duration ? e->duration : position;
}

// Caller holds the lock.
static void reanchor(VdEngine* e, VdTick position) {
  e->anchor_position = position < 0 ? 0 : position;
  e->anchor_host = host_now();
}

// --- decoders --------------------------------------------------------------

// Caller holds the lock.
static void close_least_recently_used(VdEngine* e) {
  VdClipEntry* victim = NULL;
  int32_t open = 0;
  for (int32_t i = 0; i < e->clip_count; i++) {
    if (!e->clips[i].decoder) continue;
    open++;
    if (!victim || e->clips[i].last_used < victim->last_used) {
      victim = &e->clips[i];
    }
  }
  if (open >= VD_MAX_OPEN_DECODERS && victim) {
    vd_decoder_close(victim->decoder);
    victim->decoder = NULL;
  }
}

// Caller holds render_lock and not `lock`. Takes `lock` around the pointer
// mutations so vd_engine_stats never reads a decoder mid-swap.
static VdDecoder* decoder_for(VdEngine* e, VdClipEntry* clip) {
  pthread_mutex_lock(&e->lock);
  if (clip->decoder) {
    clip->last_used = ++e->clock;
    VdDecoder* existing = clip->decoder;
    pthread_mutex_unlock(&e->lock);
    return existing;
  }
  if (clip->decoder_failed || !clip->path) {
    pthread_mutex_unlock(&e->lock);
    return NULL;
  }

  close_least_recently_used(e);

  int32_t result = 0;
  VdDecoderOptions options = vd_decoder_default_options();
  clip->decoder = vd_decoder_open(clip->path, options, &result);
  if (!clip->decoder) {
    // A missing or unreadable source must not stall the render loop by being
    // retried sixty times a second. It renders as a gap until the timeline
    // changes.
    clip->decoder_failed = true;
    pthread_mutex_unlock(&e->lock);
    return NULL;
  }
  clip->last_used = ++e->clock;
  VdDecoder* opened = clip->decoder;
  pthread_mutex_unlock(&e->lock);
  return opened;
}

static void free_clips(VdEngine* e) {
  for (int32_t i = 0; i < e->clip_count; i++) {
    if (e->clips[i].decoder) vd_decoder_close(e->clips[i].decoder);
    free(e->clips[i].path);
  }
  free(e->clips);
  e->clips = NULL;
  e->clip_count = 0;
}

// --- rendering -------------------------------------------------------------

static int compare_track(const void* a, const void* b) {
  const VdClipEntry* const* x = (const VdClipEntry* const*)a;
  const VdClipEntry* const* y = (const VdClipEntry* const*)b;
  if ((*x)->track != (*y)->track) return (*x)->track - (*y)->track;
  return 0;
}

// Renders `position` into the compositor.
//
// Requires render_lock and *not* `lock`: decoding and compositing take
// milliseconds, and holding the state mutex across them would make every
// position query wait on a frame. render_lock is what keeps two threads out of
// one decoder.
static int32_t render_position(VdEngine* e, VdTick position) {
  VdClipEntry* active[VD_MAX_LAYERS];
  int32_t active_count = 0;

  // Safe without `lock`: the clip array only changes under render_lock.
  for (int32_t i = 0; i < e->clip_count && active_count < VD_MAX_LAYERS; i++) {
    VdClipEntry* clip = &e->clips[i];
    if (position < clip->start || position >= clip->start + clip->duration) {
      continue;
    }
    active[active_count++] = clip;
  }
  qsort(active, (size_t)active_count, sizeof(active[0]), compare_track);

  VdFrame frames[VD_MAX_LAYERS];
  VdLayer layers[VD_MAX_LAYERS];
  int32_t layer_count = 0;

  for (int32_t i = 0; i < active_count; i++) {
    VdClipEntry* clip = active[i];
    VdDecoder* decoder = decoder_for(e, clip);
    if (!decoder) continue;

    const VdTick source_time = clip->source_in + (position - clip->start);

    VdProbeInfo info;
    vd_decoder_info(decoder, &info);

    if (vd_decoder_frame_at(decoder, source_time, &frames[layer_count]) !=
        VD_OK) {
      continue;
    }

    VdLayer* layer = &layers[layer_count];
    memset(layer, 0, sizeof(*layer));
    layer->pixel_buffer = frames[layer_count].pixel_buffer;
    layer->format = frames[layer_count].format;
    layer->rotation_degrees = info.rotation_degrees;
    layer->color_matrix = frames[layer_count].color_matrix;
    layer->full_range = frames[layer_count].full_range;
    layer->fit = clip->fit;
    layer->opacity = clip->opacity;
    layer_count++;
  }

  const int32_t result = vd_compositor_render(e->compositor, layers, layer_count);
  const double gpu_ms = vd_compositor_last_gpu_ms(e->compositor);

  for (int32_t i = 0; i < layer_count; i++) vd_frame_release(&frames[i]);

  pthread_mutex_lock(&e->lock);
  e->stats.active_layers = layer_count;
  e->stats.position = position;
  // Rolling mean, weighted towards recent frames so a stall shows up promptly.
  e->stats.composite_ms_avg =
      e->stats.composite_ms_avg == 0.0
          ? gpu_ms
          : e->stats.composite_ms_avg * 0.9 + gpu_ms * 0.1;
  e->stats.frames_presented++;

  // Frames per second of wall time, measured over one-second windows.
  e->fps_window_frames++;
  const uint64_t now = host_now();
  if (e->fps_window_start == 0) e->fps_window_start = now;
  const int64_t window_ns = host_to_ns(now - e->fps_window_start);
  if (window_ns >= 1000000000LL) {
    e->stats.present_fps =
        (double)e->fps_window_frames * 1e9 / (double)window_ns;
    e->fps_window_frames = 0;
    e->fps_window_start = now;
  }

  if (e->seek_pending) {
    e->stats.last_seek_ms =
        (double)host_to_ns(now - (uint64_t)e->seek_started_host) / 1e6;
    e->seek_pending = false;
  }
  pthread_mutex_unlock(&e->lock);

  return result;
}

// Caller must not hold the lock.
static void notify_frame(VdEngine* e) {
  pthread_mutex_lock(&e->lock);
  VdFrameCallback callback = e->frame_callback;
  void* context = e->frame_callback_context;
  pthread_mutex_unlock(&e->lock);
  if (callback) callback(context);
}

static void* render_thread(void* arg) {
  VdEngine* e = (VdEngine*)arg;

  for (;;) {
    pthread_mutex_lock(&e->lock);
    while (!e->quit && e->state != VD_STATE_PLAYING && !e->render_requested) {
      pthread_cond_wait(&e->wake, &e->lock);
    }
    if (e->quit) {
      pthread_mutex_unlock(&e->lock);
      break;
    }
    e->render_requested = false;
    const VdTick position = current_position(e);
    const bool have_compositor = e->compositor != NULL;
    pthread_mutex_unlock(&e->lock);

    if (have_compositor) {
      // Taken *after* releasing `lock`, never while holding it, so the lock
      // order can never invert against set_timeline.
      pthread_mutex_lock(&e->render_lock);
      render_position(e, position);
      pthread_mutex_unlock(&e->render_lock);
      notify_frame(e);
    }

    pthread_mutex_lock(&e->lock);
    if (e->state == VD_STATE_PLAYING && position >= e->duration) {
      e->state = VD_STATE_ENDED;
      e->anchor_position = e->duration;
    }
    e->stats.state = e->state;

    if (e->state == VD_STATE_PLAYING && !e->quit) {
      // Wait until the next frame boundary. Waiting on the condition rather
      // than sleeping means pause and seek take effect immediately.
      const VdTick next =
          ((position / e->ticks_per_frame) + 1) * e->ticks_per_frame;
      int64_t wait_ns = vd_nanos_from_ticks(next - current_position(e));
      if (wait_ns > 0) {
        struct timespec deadline;
        clock_gettime(CLOCK_REALTIME, &deadline);
        deadline.tv_nsec += wait_ns % 1000000000LL;
        deadline.tv_sec += wait_ns / 1000000000LL;
        if (deadline.tv_nsec >= 1000000000LL) {
          deadline.tv_nsec -= 1000000000LL;
          deadline.tv_sec += 1;
        }
        pthread_cond_timedwait(&e->wake, &e->lock, &deadline);
      } else {
        e->stats.frames_late++;
      }
    }
    pthread_mutex_unlock(&e->lock);
  }

  return NULL;
}

// --- lifecycle -------------------------------------------------------------

VdEngine* vd_engine_create(int32_t* out_result) {
  if (out_result) *out_result = VD_OK;
  VdEngine* e = calloc(1, sizeof(VdEngine));
  if (!e) {
    if (out_result) *out_result = VD_ERR_OPEN;
    return NULL;
  }
  pthread_mutex_init(&e->render_lock, NULL);
  pthread_mutex_init(&e->lock, NULL);
  pthread_cond_init(&e->wake, NULL);
  e->state = VD_STATE_IDLE;
  e->frame_rate = (VdRational){30, 1};
  e->ticks_per_frame = vd_ticks_per_frame(e->frame_rate);
  return e;
}

void vd_engine_destroy(VdEngine* e) {
  if (!e) return;

  pthread_mutex_lock(&e->lock);
  e->quit = true;
  pthread_cond_broadcast(&e->wake);
  const bool running = e->thread_running;
  pthread_mutex_unlock(&e->lock);

  // Join before anything is freed. vd_compositor_render already waits on the
  // GPU, so once the thread is gone nothing else can be holding the engine.
  if (running) pthread_join(e->thread, NULL);

  // The thread is gone and every render already waited on the GPU, so nothing
  // can still be reading this. render_lock is taken anyway to make the
  // ordering explicit rather than merely true.
  pthread_mutex_lock(&e->render_lock);
  free_clips(e);
  if (e->compositor) vd_compositor_destroy(e->compositor);
  pthread_mutex_unlock(&e->render_lock);

  pthread_cond_destroy(&e->wake);
  pthread_mutex_destroy(&e->lock);
  pthread_mutex_destroy(&e->render_lock);
  free(e);
}

// Caller holds the lock.
static bool ensure_thread(VdEngine* e) {
  if (e->thread_running) return true;
  if (pthread_create(&e->thread, NULL, render_thread, e) != 0) return false;
  e->thread_running = true;
  return true;
}

int32_t vd_engine_set_timeline(VdEngine* e, const VdTimeline* timeline) {
  if (!e || !timeline) return VD_ERR_INVALID_ARG;
  if (timeline->width <= 0 || timeline->height <= 0) return VD_ERR_INVALID_ARG;
  if (timeline->clip_count < 0 ||
      (timeline->clip_count > 0 && !timeline->clips)) {
    return VD_ERR_INVALID_ARG;
  }

  // Held for the whole swap: the render loop walks this array without the
  // state lock, so it must not be freed underneath it.
  pthread_mutex_lock(&e->render_lock);
  pthread_mutex_lock(&e->lock);

  // Hold on to the decoders already open for sources that are still in the
  // timeline. Reopening every decoder on every edit would make the preview
  // stutter each time the user nudges a clip.
  VdClipEntry* previous = e->clips;
  const int32_t previous_count = e->clip_count;

  VdClipEntry* next = timeline->clip_count > 0
                          ? calloc((size_t)timeline->clip_count,
                                   sizeof(VdClipEntry))
                          : NULL;
  if (timeline->clip_count > 0 && !next) {
    pthread_mutex_unlock(&e->lock);
    pthread_mutex_unlock(&e->render_lock);
    return VD_ERR_OPEN;
  }

  VdTick duration = 0;
  for (int32_t i = 0; i < timeline->clip_count; i++) {
    const VdTimelineClip* src = &timeline->clips[i];
    VdClipEntry* dst = &next[i];
    dst->path = src->path ? strdup(src->path) : NULL;
    dst->start = src->start;
    dst->duration = src->duration;
    dst->source_in = src->source_in;
    dst->track = src->track;
    dst->opacity = src->opacity;
    dst->fit = src->fit;

    for (int32_t j = 0; j < previous_count; j++) {
      VdClipEntry* old = &previous[j];
      if (old->decoder && old->path && dst->path &&
          strcmp(old->path, dst->path) == 0) {
        dst->decoder = old->decoder;
        dst->last_used = old->last_used;
        old->decoder = NULL;
        break;
      }
    }

    if (src->start + src->duration > duration) {
      duration = src->start + src->duration;
    }
  }

  for (int32_t j = 0; j < previous_count; j++) {
    if (previous[j].decoder) vd_decoder_close(previous[j].decoder);
    free(previous[j].path);
  }
  free(previous);

  e->clips = next;
  e->clip_count = timeline->clip_count;
  e->duration = duration;
  e->stats.duration = duration;

  if (timeline->frame_rate.num > 0 && timeline->frame_rate.den > 0) {
    e->frame_rate = timeline->frame_rate;
    const int64_t per_frame = vd_ticks_per_frame(e->frame_rate);
    e->ticks_per_frame = per_frame > 0 ? per_frame : VD_TICKS_PER_SECOND / 30;
  }

  int32_t result = VD_OK;
  if (!e->compositor || e->width != timeline->width ||
      e->height != timeline->height) {
    if (e->compositor) vd_compositor_destroy(e->compositor);
    e->compositor =
        vd_compositor_create(timeline->width, timeline->height, &result);
    e->width = timeline->width;
    e->height = timeline->height;
  }
  if (!e->compositor) {
    pthread_mutex_unlock(&e->lock);
    pthread_mutex_unlock(&e->render_lock);
    return result == VD_OK ? VD_ERR_UNSUPPORTED : result;
  }

  if (e->anchor_position > duration) reanchor(e, duration);
  if (e->state == VD_STATE_ENDED && e->anchor_position < duration) {
    e->state = VD_STATE_PAUSED;
  }

  e->render_requested = true;
  ensure_thread(e);
  pthread_cond_broadcast(&e->wake);
  pthread_mutex_unlock(&e->lock);
  pthread_mutex_unlock(&e->render_lock);
  return VD_OK;
}

// --- transport -------------------------------------------------------------

void vd_engine_play(VdEngine* e) {
  if (!e) return;
  pthread_mutex_lock(&e->lock);
  if (e->compositor) {
    // Playing from the end starts over, which is what pressing play on a
    // finished clip should do.
    if (e->state == VD_STATE_ENDED || e->anchor_position >= e->duration) {
      reanchor(e, 0);
    } else {
      reanchor(e, e->anchor_position);
    }
    e->state = VD_STATE_PLAYING;
    e->stats.state = e->state;
    ensure_thread(e);
    pthread_cond_broadcast(&e->wake);
  }
  pthread_mutex_unlock(&e->lock);
}

void vd_engine_pause(VdEngine* e) {
  if (!e) return;
  pthread_mutex_lock(&e->lock);
  if (e->state == VD_STATE_PLAYING) {
    reanchor(e, current_position(e));
    e->state = VD_STATE_PAUSED;
    e->stats.state = e->state;
    pthread_cond_broadcast(&e->wake);
  }
  pthread_mutex_unlock(&e->lock);
}

void vd_engine_seek(VdEngine* e, VdTick position) {
  if (!e) return;
  pthread_mutex_lock(&e->lock);
  if (position < 0) position = 0;
  if (position > e->duration) position = e->duration;
  reanchor(e, position);
  if (e->state == VD_STATE_IDLE || e->state == VD_STATE_ENDED) {
    e->state = VD_STATE_PAUSED;
  }
  e->stats.state = e->state;
  e->seek_started_host = (double)host_now();
  e->seek_pending = true;
  // Render even while paused: a scrub that shows nothing is not a scrub.
  e->render_requested = true;
  ensure_thread(e);
  pthread_cond_broadcast(&e->wake);
  pthread_mutex_unlock(&e->lock);
}

int32_t vd_engine_render_now(VdEngine* e) {
  if (!e) return VD_ERR_INVALID_ARG;
  pthread_mutex_lock(&e->lock);
  const bool ready = e->compositor != NULL;
  const VdTick position = current_position(e);
  pthread_mutex_unlock(&e->lock);
  if (!ready) return VD_ERR_UNSUPPORTED;

  pthread_mutex_lock(&e->render_lock);
  const int32_t result = render_position(e, position);
  pthread_mutex_unlock(&e->render_lock);

  notify_frame(e);
  return result;
}

VdTick vd_engine_position(VdEngine* e) {
  if (!e) return 0;
  pthread_mutex_lock(&e->lock);
  const VdTick position = current_position(e);
  pthread_mutex_unlock(&e->lock);
  return position;
}

VdTick vd_engine_duration(VdEngine* e) {
  if (!e) return 0;
  pthread_mutex_lock(&e->lock);
  const VdTick duration = e->duration;
  pthread_mutex_unlock(&e->lock);
  return duration;
}

int32_t vd_engine_state(VdEngine* e) {
  if (!e) return VD_STATE_IDLE;
  pthread_mutex_lock(&e->lock);
  const int32_t state = (int32_t)e->state;
  pthread_mutex_unlock(&e->lock);
  return state;
}

void vd_engine_set_frame_callback(VdEngine* e, VdFrameCallback callback,
                                  void* context) {
  if (!e) return;
  pthread_mutex_lock(&e->lock);
  e->frame_callback = callback;
  e->frame_callback_context = context;
  pthread_mutex_unlock(&e->lock);
}

void* vd_engine_copy_output(VdEngine* e) {
  if (!e) return NULL;
  pthread_mutex_lock(&e->lock);
  void* output = e->compositor ? vd_compositor_copy_output(e->compositor)
                               : NULL;
  pthread_mutex_unlock(&e->lock);
  return output;
}

int32_t vd_engine_dump_png(VdEngine* e, const char* path) {
  if (!e || !path) return VD_ERR_INVALID_ARG;
  pthread_mutex_lock(&e->lock);
  const int32_t result = e->compositor
                             ? vd_compositor_dump_png(e->compositor, path)
                             : VD_ERR_UNSUPPORTED;
  pthread_mutex_unlock(&e->lock);
  return result;
}

void vd_engine_stats(VdEngine* e, VdEngineStats* out) {
  if (!e || !out) return;
  pthread_mutex_lock(&e->lock);
  *out = e->stats;
  out->position = current_position(e);
  out->duration = e->duration;
  out->state = (int32_t)e->state;
  int32_t open = 0;
  for (int32_t i = 0; i < e->clip_count; i++) {
    if (e->clips[i].decoder) open++;
  }
  out->open_decoders = open;
  pthread_mutex_unlock(&e->lock);
}
