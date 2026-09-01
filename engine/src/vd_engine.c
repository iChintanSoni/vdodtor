#include "vdodtor/vd_engine.h"

#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <CoreVideo/CoreVideo.h>

#include "vdodtor/vd_audio.h"
#include "vdodtor/vd_decoder.h"
#include "vdodtor/vd_lut.h"
#include "vdodtor/vd_raster.h"
#include "vdodtor/vd_sticker.h"
#include "vdodtor/vd_transition.h"

// How many decoders stay open at once. The M0 spike measured four concurrent
// 4K60 decoders at ~34% CPU, so this is comfortably inside what the machine
// can carry, and it means crossing a cut reuses a decoder rather than opening
// one — an open costs milliseconds, and a hitch at every cut is exactly what
// makes an editor feel cheap.
#define VD_MAX_OPEN_DECODERS 8

// How much decoded sticker the engine holds at once. Bytes rather than a
// count, because a sticker's cost is memory and not a file handle: a dozen
// small GIFs are cheaper than one big one, and a cap on the number would let
// the big one through while turning the dozen away.
//
// Three times what one sticker may spend on itself, so the layers that can be
// on screen together mostly are — and an eviction only costs a re-decode,
// which for a file this size is milliseconds.
#define VD_MAX_STICKER_BYTES (192 * 1024 * 1024)

// Compositing is bounded by the product's track count: one main, three
// overlays and eight text lanes. It moves when Project.maxTracksOfKind in
// app/lib/model/project.dart moves, and the two have to agree — a lane the
// document allows and the compositor silently drops is a caption that is on
// the timeline and not on the screen.
#define VD_MAX_LANES 12

// A lane in the middle of a transition draws three layers where it normally
// draws one: the clip leaving, the clip arriving, and the colour dipped
// between them. Every lane could be at such a cut at once, so the ceiling is
// the product rather than the lane count — a layer dropped here is a frame
// with half a dissolve in it.
#define VD_LAYERS_PER_LANE 3
#define VD_MAX_LAYERS (VD_MAX_LANES * VD_LAYERS_PER_LANE)

typedef struct {
  char* path;
  VdTick start;
  VdTick duration;
  VdTick source_in;
  int32_t track;
  float opacity;
  VdFitMode fit;
  VdTransform transform;
  VdColorAdjust color;

  // The look, resolved once per edit rather than looked up per frame: the
  // catalogue is a linear walk over strings, and doing that sixty times a
  // second for a cube that has not moved would be silly. NULL for a clip with
  // no look, and also for one naming a look this installation does not have —
  // which is the same thing as far as every frame is concerned.
  //
  // Borrowed. Nothing is ever unregistered, so this outlives the clip.
  const VdLut* lut;
  float look_strength;

  VdClipAnim anim;
  bool has_video;

  // Where this clip is drawn, which is its own span widened by whatever
  // transitions touch it: half a transition before its start if it is the
  // incoming side of one, and half a transition past its end if it is the
  // outgoing side. Resolved once per edit in set_timeline rather than searched
  // for per frame — pairing a cut is a walk over the clip list, and doing that
  // sixty times a second to draw the same two clips would be silly.
  VdTick render_from;
  VdTick render_to;

  // The transition at this clip's head, and the one at its tail — which is the
  // head transition of whichever clip follows it. Both are resolved windows
  // rather than durations, so the render loop divides rather than searches.
  VdTransitionPreset head_preset;
  VdTick head_from;
  VdTick head_to;
  VdTransitionPreset tail_preset;
  VdTick tail_from;
  VdTick tail_to;

  // What the document said about this clip's head, kept so the pairing above
  // can be redone whenever the timeline changes.
  VdClipTransition transition;

  VdDecoder* decoder;  // opened lazily
  int64_t last_used;
  bool decoder_failed;  // do not retry every frame

  // An animated overlay rather than video. `is_sticker` comes from the
  // timeline; `sticker` is opened lazily beside the decoder and never with it
  // — a clip is one or the other. See vd_sticker.h.
  bool is_sticker;
  VdSticker* sticker;

  // A generated clip instead of a decoded one. `text` and `shape` are owned
  // and at most one of them is set; `raster` is the CVPixelBufferRef whichever
  // it is last produced, kept until the spec or the output size changes.
  // Laying a caption out again on every frame would cost more than decoding
  // one, and a shape is cheap enough that the cache is really there so the
  // *layer* is stable — a new pixel buffer every frame would have the
  // compositor re-wrapping a texture sixty times a second for a rectangle
  // that never moved.
  VdTextSpec* text;
  VdShapeSpec* shape;
  void* raster;
  int32_t raster_width;
  int32_t raster_height;
  // How much of the caption the cached raster has typed out. -1 is all of it,
  // which is every caption without a typewriter on it — and the reason this is
  // part of the key rather than a reason to throw the cache away: a typewriter
  // redraws once per *character*, not once per frame.
  int32_t raster_reveal;
  // Characters in the caption, counted once when the spec arrives. A
  // typewriter divides its time by this, and counting composed characters is
  // not free enough to do sixty times a second.
  int32_t text_length;
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

  // The frame index last published. The render loop waits on a condition, and
  // a condition can wake early — so without this it would publish the same
  // frame twice and report a frame rate higher than the project's.
  int64_t last_frame;

  // A solid colour to lay over a cut, and which colour is in it. One small
  // buffer stretched over the frame rather than a shader of its own: the
  // compositor already draws premultiplied BGRA, and two by two is the
  // smallest thing that is unambiguously a picture.
  void* flash_buffer;
  uint32_t flash_color;

  VdAudioRenderer* audio;
  VdAudioDevice* audio_device;

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
//
// Audio is the master clock whenever there is audio to play. Video can be a
// millisecond late and nobody sees it; audio cannot be stretched or skipped
// without the listener hearing it immediately. So the picture follows the
// sound, and the wall clock is only the fallback for a silent timeline.
static VdTick current_position(const VdEngine* e) {
  if (e->state != VD_STATE_PLAYING) return e->anchor_position;

  VdTick position;
  if (e->audio && vd_audio_renderer_clock_valid(e->audio)) {
    position = vd_audio_renderer_position(e->audio);
  } else {
    const int64_t elapsed_ns = host_to_ns(host_now() - e->anchor_host);
    position = e->anchor_position + vd_ticks_from_nanos(elapsed_ns);
  }
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

// Caller holds the lock. Frees stickers, least recently drawn first, until
// what is left plus `wanted` is inside the budget.
//
// A loop rather than the decoders' one-victim rule because the sizes vary by
// two orders of magnitude: evicting one small GIF to make room for a big one
// would leave the budget just as blown as it started.
static void trim_stickers(VdEngine* e, int64_t wanted) {
  for (;;) {
    int64_t held = 0;
    VdClipEntry* victim = NULL;
    for (int32_t i = 0; i < e->clip_count; i++) {
      if (!e->clips[i].sticker) continue;
      held += vd_sticker_bytes(e->clips[i].sticker);
      if (!victim || e->clips[i].last_used < victim->last_used) {
        victim = &e->clips[i];
      }
    }
    if (held + wanted <= VD_MAX_STICKER_BYTES || !victim) return;
    vd_sticker_close(victim->sticker);
    victim->sticker = NULL;
  }
}

// Caller holds render_lock and not `lock`. The sticker equivalent of
// decoder_for, and deliberately its twin: opened lazily, kept on an LRU stamp,
// and never retried after a failure.
static VdSticker* sticker_for(VdEngine* e, VdClipEntry* clip) {
  pthread_mutex_lock(&e->lock);
  if (clip->sticker) {
    clip->last_used = ++e->clock;
    VdSticker* existing = clip->sticker;
    pthread_mutex_unlock(&e->lock);
    return existing;
  }
  if (clip->decoder_failed || !clip->path) {
    pthread_mutex_unlock(&e->lock);
    return NULL;
  }

  VdStickerOptions options = vd_sticker_default_options();
  // A sticker with more pixels than the frame it is drawn into is paying for
  // detail the compositor is about to throw away.
  options.max_side = e->width > e->height ? e->width : e->height;
  trim_stickers(e, options.max_bytes);

  clip->sticker = vd_sticker_open(clip->path, options, NULL);
  if (!clip->sticker) {
    // Same bargain a decoder gets: a file that will not open renders as a gap
    // rather than being retried sixty times a second.
    clip->decoder_failed = true;
    pthread_mutex_unlock(&e->lock);
    return NULL;
  }
  e->stats.sticker_opens++;
  clip->last_used = ++e->clock;
  VdSticker* opened = clip->sticker;
  pthread_mutex_unlock(&e->lock);
  return opened;
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

// The raster for `clip`, drawn if the one it has is missing or stale.
//
// Caller holds render_lock. Returns NULL for a clip the engine does not draw,
// which is how the caller tells the two kinds of layer apart.
static void* raster_for(VdEngine* e, VdClipEntry* clip, int32_t reveal) {
  if (!clip->text && !clip->shape) return NULL;
  if (clip->raster && clip->raster_width == e->width &&
      clip->raster_height == e->height && clip->raster_reveal == reveal) {
    return clip->raster;
  }
  // A raster is thrown away here for being the wrong size or for having typed
  // out a different number of characters; a change to the spec throws it away
  // in set_timeline, where the old spec is still around to be compared
  // against.
  if (clip->raster) {
    CVPixelBufferRelease((CVPixelBufferRef)clip->raster);
    clip->raster = NULL;
  }
  clip->raster =
      clip->text
          ? vd_text_render(clip->text, e->width, e->height, reveal, NULL)
          : vd_shape_render(clip->shape, e->width, e->height, NULL);
  clip->raster_width = e->width;
  clip->raster_height = e->height;
  clip->raster_reveal = reveal;

  pthread_mutex_lock(&e->lock);
  if (clip->text) {
    e->stats.text_rasters++;
  } else {
    e->stats.shape_rasters++;
  }
  pthread_mutex_unlock(&e->lock);
  return clip->raster;
}

static void free_clip_contents(VdClipEntry* clip) {
  if (clip->decoder) vd_decoder_close(clip->decoder);
  if (clip->sticker) vd_sticker_close(clip->sticker);
  if (clip->raster) CVPixelBufferRelease((CVPixelBufferRef)clip->raster);
  vd_text_spec_free(clip->text);
  vd_shape_spec_free(clip->shape);
  free(clip->path);
}

static void free_clips(VdEngine* e) {
  for (int32_t i = 0; i < e->clip_count; i++) {
    free_clip_contents(&e->clips[i]);
  }
  free(e->clips);
  e->clips = NULL;
  e->clip_count = 0;
}

// Pairs every transition with the clip it joins, and widens both clips'
// drawing windows to cover it.
//
// Done once per edit rather than once per frame: finding the outgoing clip is
// a walk over the list, and repeating that sixty times a second to draw the
// same two clips would be silly. It is also the only place that knows a
// transition involves two clips at all — everywhere downstream reads windows.
static void resolve_transitions(VdClipEntry* clips, int32_t count) {
  for (int32_t i = 0; i < count; i++) {
    clips[i].render_from = clips[i].start;
    clips[i].render_to = clips[i].start + clips[i].duration;
    clips[i].head_preset = VD_TRANSITION_NONE;
    clips[i].tail_preset = VD_TRANSITION_NONE;
  }

  for (int32_t i = 0; i < count; i++) {
    VdClipEntry* in = &clips[i];
    if (!vd_transition_active(&in->transition) || !in->has_video) continue;

    for (int32_t j = 0; j < count; j++) {
      if (j == i) continue;
      VdClipEntry* out = &clips[j];
      // The clip before it on its own lane, meeting it exactly. A transition
      // needs a cut, and a gap is not one: a dissolve into black over nothing
      // is a fade, and the user asked for a fade if they wanted one.
      if (out->track != in->track || !out->has_video) continue;
      if (out->start + out->duration != in->start) continue;

      VdTick from = 0;
      VdTick to = 0;
      if (!vd_transition_window(&in->transition, in->start, out->start,
                                in->start + in->duration, &from, &to)) {
        break;
      }

      in->head_preset = in->transition.preset;
      in->head_from = from;
      in->head_to = to;
      out->tail_preset = in->transition.preset;
      out->tail_from = from;
      out->tail_to = to;

      if (from < in->render_from) in->render_from = from;
      if (to > out->render_to) out->render_to = to;
      break;
    }
  }
}

// --- rendering -------------------------------------------------------------

static int compare_track(const void* a, const void* b) {
  const VdClipEntry* const* x = (const VdClipEntry* const*)a;
  const VdClipEntry* const* y = (const VdClipEntry* const*)b;
  if ((*x)->track != (*y)->track) return (*x)->track - (*y)->track;
  // Two clips on one lane only happens across a transition, and then the
  // order is the whole point: the clip leaving has to be underneath the clip
  // arriving, or a dissolve runs backwards.
  if ((*x)->start < (*y)->start) return -1;
  if ((*x)->start > (*y)->start) return 1;
  return 0;
}

// Folds an animation into a layer that has already been given the clip's own
// transform.
//
// Composed rather than assigned, in every field: offsets add, scale
// multiplies, rotation adds, opacity multiplies. A clip that was placed
// somewhere and then animated has to animate from where it was placed.
// The transition value at `position`, or NULL when this clip is not in one.
//
// `incoming` says which side of the cut this clip is on, which is what decides
// whether it reads the arriving half of the value or the leaving half. A clip
// can be both at once — the incoming side of one cut and the outgoing side of
// the next — when it is shorter than the two transitions touching it, so this
// answers one question at a time.
static bool transition_at(const VdClipEntry* clip, VdTick position,
                          bool incoming, VdTransitionValue* out) {
  const VdTransitionPreset preset =
      incoming ? clip->head_preset : clip->tail_preset;
  if (preset == VD_TRANSITION_NONE) return false;
  const VdTick from = incoming ? clip->head_from : clip->tail_from;
  const VdTick to = incoming ? clip->head_to : clip->tail_to;
  if (to <= from || position < from || position >= to) return false;
  *out = vd_transition_value(
      preset, (float)(position - from) / (float)(to - from));
  return true;
}

// Folds a transition into a layer that already carries the clip's own
// transform and animation.
//
// Composed, like an animation and for the same reason: a clip somebody pushed
// to one side has to push out from where they put it, not from the middle.
static void apply_transition(VdLayer* layer, const VdTransitionValue* v,
                             bool incoming) {
  if (incoming) {
    layer->transform.offset_x += v->in_offset_x;
    layer->transform.offset_y += v->in_offset_y;
    layer->opacity *= v->in_opacity;
    layer->reveal.left += v->in_hide_left;
    layer->reveal.top += v->in_hide_top;
    layer->reveal.right += v->in_hide_right;
    layer->reveal.bottom += v->in_hide_bottom;
  } else {
    layer->transform.offset_x += v->out_offset_x;
    layer->transform.offset_y += v->out_offset_y;
    layer->opacity *= v->out_opacity;
  }
}

// The 2x2 solid buffer a fade dips through, in `colour`.
//
// Rewritten rather than reallocated when the colour changes, and there is only
// ever one: two fades to different colours in one frame would fight over it,
// which is a frame nobody can construct — a clip has one transition at its
// head, and two lanes dipping to different colours at the same instant is not
// an edit anyone makes. If it ever is, this becomes a small cache.
static void* flash_buffer_for(VdEngine* e, uint32_t colour) {
  if (!e->flash_buffer) {
    e->flash_buffer = vd_raster_create(2, 2, NULL);
    e->flash_color = 0;
  }
  if (!e->flash_buffer) return NULL;
  if (e->flash_color == colour) return e->flash_buffer;

  CVPixelBufferRef buffer = (CVPixelBufferRef)e->flash_buffer;
  CVPixelBufferLockBaseAddress(buffer, 0);
  uint8_t* base = (uint8_t*)CVPixelBufferGetBaseAddress(buffer);
  const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
  const uint32_t a = (colour >> 24) & 0xFFu;
  // Premultiplied, like every other BGRA buffer this engine composites.
  const uint8_t bgra[4] = {
      (uint8_t)(((colour & 0xFFu) * a + 127) / 255),
      (uint8_t)((((colour >> 8) & 0xFFu) * a + 127) / 255),
      (uint8_t)((((colour >> 16) & 0xFFu) * a + 127) / 255),
      (uint8_t)a,
  };
  for (int y = 0; y < 2; y++) {
    for (int x = 0; x < 2; x++) {
      memcpy(base + (size_t)y * stride + (size_t)x * 4, bgra, 4);
    }
  }
  CVPixelBufferUnlockBaseAddress(buffer, 0);
  e->flash_color = colour;
  return e->flash_buffer;
}

// Adds the colour dipped over a cut: above the two clips it joins, and below
// anything on a higher lane — so a caption over a fade to black stays legible.
static void push_flash(VdEngine* e, VdLayer* layers, VdFrame* frames,
                       int32_t* layer_count, const VdTransitionValue* v) {
  if (v->flash <= 0.0f || *layer_count >= VD_MAX_LAYERS) return;
  void* buffer = flash_buffer_for(e, v->flash_color);
  if (!buffer) return;
  VdLayer* layer = &layers[*layer_count];
  memset(layer, 0, sizeof(*layer));
  layer->pixel_buffer = buffer;
  layer->format = VD_PIXEL_BGRA;
  layer->fit = VD_FIT_STRETCH;
  layer->opacity = v->flash;
  // The buffer belongs to the engine, not to this frame, so the release loop
  // has to find nothing here.
  memset(&frames[*layer_count], 0, sizeof(frames[0]));
  (*layer_count)++;
}

static void apply_anim(VdLayer* layer, const VdAnimValue* anim) {
  layer->transform.offset_x += anim->offset_x;
  layer->transform.offset_y += anim->offset_y;
  // A zeroed scale means "as fitted" everywhere else in this struct, so it has
  // to be resolved to 1 *before* being multiplied — multiplying the zero and
  // letting the compositor normalise it afterwards would silently throw the
  // animation away.
  const float base = layer->transform.scale > 0.0f ? layer->transform.scale
                                                   : 1.0f;
  layer->transform.scale = base * anim->scale;
  layer->transform.rotation_degrees += anim->rotation_degrees;
  layer->opacity *= anim->opacity;
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
  //
  // The window is `render_from`/`render_to` rather than the clip's own span,
  // and that is the whole of how a transition gets its overlap: the outgoing
  // clip stays on for half a transition past its end and the incoming one
  // starts half a transition early. Nothing in the document overlaps.
  for (int32_t i = 0; i < e->clip_count && active_count < VD_MAX_LAYERS; i++) {
    VdClipEntry* clip = &e->clips[i];
    if (!clip->has_video) continue;  // sound only; the mixer has it
    if (position < clip->render_from || position >= clip->render_to) continue;
    active[active_count++] = clip;
  }
  qsort(active, (size_t)active_count, sizeof(active[0]), compare_track);

  VdFrame frames[VD_MAX_LAYERS];
  VdLayer layers[VD_MAX_LAYERS];
  int32_t layer_count = 0;

  for (int32_t i = 0; i < active_count; i++) {
    VdClipEntry* clip = active[i];

    // Where the clip is in its own entrance or exit. Pure arithmetic on the
    // position — no state carried between frames — which is what keeps a seek
    // into the middle of an animation showing exactly the frame playback
    // would have.
    const VdAnimValue anim =
        vd_anim_at(&clip->anim, position - clip->start, clip->duration);

    // Which side of a cut this clip is on, if it is at one. Both are possible
    // at once for a clip shorter than the transitions touching either end.
    VdTransitionValue head;
    VdTransitionValue tail;
    const bool has_head = transition_at(clip, position, true, &head);
    const bool has_tail = transition_at(clip, position, false, &tail);

    // A generated clip draws itself. It goes through the same VdLayer as a
    // decoded one — same transform, same opacity, same z-order — because the
    // compositor is the one thing preview and export share and a second path
    // through it is a second thing to keep in step.
    if (clip->text || clip->shape) {
      // A typewriter is the one animation the transform cannot express, so it
      // reaches into the raster instead. Rounded up, so the first character
      // appears as soon as the animation starts rather than a frame later.
      //
      // A shape has nothing to reveal, so it asks for all of it and the
      // typewriter quietly does nothing — which is what vd_anim.h promises a
      // preset chosen for a clip that cannot use it will do.
      const int32_t reveal =
          (!clip->text || anim.reveal >= 1.0f)
              ? -1
              : (int32_t)ceilf(anim.reveal * (float)clip->text_length);
      void* raster = raster_for(e, clip, reveal);
      if (!raster) continue;
      VdLayer* layer = &layers[layer_count];
      memset(layer, 0, sizeof(*layer));
      layer->pixel_buffer = raster;
      layer->format = VD_PIXEL_BGRA;
      // The raster is exactly the size of the output, so there is nothing to
      // fit; saying so beats letting a rounding difference letterbox it.
      layer->fit = VD_FIT_STRETCH;
      layer->opacity = clip->opacity;
      layer->transform = clip->transform;
      layer->color = clip->color;
      layer->look = vd_lut_look(clip->lut, clip->look_strength);
      apply_anim(layer, &anim);
      if (has_head) apply_transition(layer, &head, true);
      if (has_tail) apply_transition(layer, &tail, false);
      // The raster belongs to the clip, not to this frame, so the release
      // loop below has to find nothing here.
      memset(&frames[layer_count], 0, sizeof(frames[0]));
      layer_count++;
      if (has_head) push_flash(e, layers, frames, &layer_count, &head);
      continue;
    }

    // An animated overlay is a file, so it has a path — but it is decoded
    // whole and looped rather than seeked in, and it arrives as premultiplied
    // BGRA like a caption rather than as YCbCr like video. It is fitted like a
    // decoded frame, though, because unlike a caption it has a size of its own
    // that is not the output's.
    if (clip->is_sticker) {
      VdSticker* sticker = sticker_for(e, clip);
      if (!sticker) continue;
      bool changed = false;
      void* buffer = vd_sticker_frame_at(
          sticker, clip->source_in + (position - clip->start), &changed);
      if (!buffer) continue;
      if (changed) {
        pthread_mutex_lock(&e->lock);
        e->stats.sticker_frames++;
        pthread_mutex_unlock(&e->lock);
      }
      VdLayer* layer = &layers[layer_count];
      memset(layer, 0, sizeof(*layer));
      layer->pixel_buffer = buffer;
      layer->format = VD_PIXEL_BGRA;
      layer->fit = clip->fit;
      layer->opacity = clip->opacity;
      layer->transform = clip->transform;
      layer->color = clip->color;
      layer->look = vd_lut_look(clip->lut, clip->look_strength);
      apply_anim(layer, &anim);
      if (has_head) apply_transition(layer, &head, true);
      if (has_tail) apply_transition(layer, &tail, false);
      // The buffer belongs to the sticker, not to this frame, so the release
      // loop below has to find nothing here.
      memset(&frames[layer_count], 0, sizeof(frames[0]));
      layer_count++;
      if (has_head) push_flash(e, layers, frames, &layer_count, &head);
      continue;
    }

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
    layer->pixel_aspect = info.pixel_aspect;
    layer->color_matrix = frames[layer_count].color_matrix;
    layer->full_range = frames[layer_count].full_range;
    layer->fit = clip->fit;
    layer->opacity = clip->opacity;
    layer->transform = clip->transform;
    // Straight across, not composed with anything: unlike the animation and
    // the transition below it, a grade does not change through the clip. The
    // look is the same story, and the lattice it points at is the catalogue's
    // — one cube however many clips are wearing it.
    layer->color = clip->color;
    layer->look = vd_lut_look(clip->lut, clip->look_strength);
    apply_anim(layer, &anim);
    if (has_head) apply_transition(layer, &head, true);
    if (has_tail) apply_transition(layer, &tail, false);
    layer_count++;
    if (has_head) push_flash(e, layers, frames, &layer_count, &head);
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

    const bool forced = e->render_requested;
    e->render_requested = false;
    const VdTick position = current_position(e);
    const int64_t frame = position / e->ticks_per_frame;

    if (e->state == VD_STATE_PLAYING && frame < e->last_frame) {
      e->stats.clock_regressions++;
    }

    // Not a new frame yet. This happens on every early wake, and it happens
    // often once audio is the clock: the wait is scheduled in wall time
    // against a deadline in audio time, and the two do not tick together.
    //
    // The comparison is `<=`, not `==`, on purpose. During playback the
    // playhead only ever moves forward as far as the viewer is concerned, so
    // a frame at or behind the one already on screen is never worth
    // publishing — and that holds however the position came to dip.
    if (e->state == VD_STATE_PLAYING && !forced && frame <= e->last_frame) {
      const VdTick next = (frame + 1) * e->ticks_per_frame;
      const int64_t wait_ns = vd_nanos_from_ticks(next - position);
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
      }
      pthread_mutex_unlock(&e->lock);
      continue;
    }

    // Skipped frames are the honest measure of not keeping up, and they are
    // only knowable here, by comparing frame indices rather than by noticing
    // that a deadline had passed.
    if (e->state == VD_STATE_PLAYING && e->last_frame >= 0 &&
        frame > e->last_frame + 1) {
      e->stats.frames_late += frame - e->last_frame - 1;
    }
    if (forced) e->stats.forced_renders++;
    e->last_frame = frame;
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
      if (e->audio_device) vd_audio_device_stop(e->audio_device);
      if (e->audio) vd_audio_renderer_stop(e->audio);
    }
    e->stats.state = e->state;
    pthread_mutex_unlock(&e->lock);
  }

  return NULL;
}

// --- lifecycle -------------------------------------------------------------

VdTimelineClip vd_timeline_clip_default(void) {
  VdTimelineClip clip;
  memset(&clip, 0, sizeof(clip));
  clip.opacity = 1.0f;
  clip.gain = 1.0f;
  clip.fit = VD_FIT_CONTAIN;
  clip.has_video = true;
  return clip;
}

VdEngineOptions vd_engine_default_options(void) {
  VdEngineOptions options = {.audio_output = 1};
  return options;
}

VdEngine* vd_engine_create(int32_t* out_result) {
  return vd_engine_create_with_options(vd_engine_default_options(), out_result);
}

struct VdAudioRenderer* vd_engine_audio_renderer(VdEngine* e) {
  return e ? (struct VdAudioRenderer*)e->audio : NULL;
}

VdEngine* vd_engine_create_with_options(VdEngineOptions options,
                                        int32_t* out_result) {
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
  e->last_frame = -1;
  e->frame_rate = (VdRational){30, 1};
  e->ticks_per_frame = vd_ticks_per_frame(e->frame_rate);

  // A machine with no output device is unusual but not a reason to refuse to
  // open a project: the picture still works, and the clock falls back to wall
  // time.
  e->audio = vd_audio_renderer_create(NULL);
  if (e->audio && options.audio_output) {
    e->audio_device = vd_audio_device_open(e->audio, NULL);
  }
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

  // Order matters here as much as it does on the video side. Closing the
  // device returns only once its real-time callback is guaranteed not to run
  // again, which is what makes it safe to free the renderer it was pulling
  // from.
  if (e->audio_device) vd_audio_device_close(e->audio_device);
  if (e->audio) vd_audio_renderer_destroy(e->audio);

  // The thread is gone and every render already waited on the GPU, so nothing
  // can still be reading this. render_lock is taken anyway to make the
  // ordering explicit rather than merely true.
  pthread_mutex_lock(&e->render_lock);
  free_clips(e);
  if (e->flash_buffer) CVPixelBufferRelease((CVPixelBufferRef)e->flash_buffer);
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
    dst->transform = src->transform;
    dst->color = src->color;
    dst->lut = vd_lut_find(src->look);
    dst->look_strength = src->look_strength;
    dst->has_video = src->has_video;
    dst->is_sticker = src->sticker;
    dst->anim = src->anim;
    dst->transition = src->transition;
    dst->text = vd_text_spec_copy(src->text);
    dst->shape = vd_shape_spec_copy(src->shape);
    // Counted once, here, rather than per frame: a typewriter divides its time
    // by this and composed characters are not free to count.
    dst->text_length = dst->text ? vd_text_length(dst->text) : 0;
    dst->raster_reveal = -1;

    for (int32_t j = 0; j < previous_count; j++) {
      VdClipEntry* old = &previous[j];
      if (old->decoder && old->path && dst->path &&
          strcmp(old->path, dst->path) == 0) {
        dst->decoder = old->decoder;
        dst->last_used = old->last_used;
        old->decoder = NULL;
        break;
      }
      // A sticker survives an edit on the same terms and for a stronger
      // reason: reopening one means decoding the whole animation again, where
      // reopening a decoder costs one seek.
      if (old->sticker && old->path && dst->path && dst->is_sticker &&
          strcmp(old->path, dst->path) == 0) {
        dst->sticker = old->sticker;
        dst->last_used = old->last_used;
        old->sticker = NULL;
        break;
      }
      // The same bargain for a drawn clip: a raster survives any edit that did
      // not change what the caption says or what the shape looks like, so
      // dragging one along its lane costs no drawing at all.
      const bool same_drawing =
          (old->text && dst->text &&
           vd_text_spec_equal(old->text, dst->text)) ||
          (old->shape && dst->shape &&
           vd_shape_spec_equal(old->shape, dst->shape));
      if (old->raster && same_drawing) {
        dst->raster = old->raster;
        dst->raster_width = old->raster_width;
        dst->raster_height = old->raster_height;
        // How much of it had been typed out comes across too. Without this a
        // half-typed raster would be taken for a finished one and the caption
        // would stay half-typed until something else invalidated it.
        dst->raster_reveal = old->raster_reveal;
        old->raster = NULL;
        break;
      }
    }

    if (src->start + src->duration > duration) {
      duration = src->start + src->duration;
    }
  }

  resolve_transitions(next, timeline->clip_count);

  for (int32_t j = 0; j < previous_count; j++) {
    free_clip_contents(&previous[j]);
  }
  free(previous);

  e->clips = next;
  e->clip_count = timeline->clip_count;
  e->duration = duration;
  e->stats.duration = duration;

  // The audio side gets the same render list and picks out what has sound.
  if (e->audio) {
    vd_audio_renderer_set_timeline(e->audio, timeline->clips,
                                   timeline->clip_count);
  }

  if (timeline->frame_rate.num > 0 && timeline->frame_rate.den > 0) {
    e->frame_rate = timeline->frame_rate;
    const int64_t per_frame = vd_ticks_per_frame(e->frame_rate);
    e->ticks_per_frame = per_frame > 0 ? per_frame : VD_TICKS_PER_SECOND / 30;
  }

  int32_t result = VD_OK;
  if (!e->compositor || e->width != timeline->width ||
      e->height != timeline->height) {
    if (e->flash_buffer) CVPixelBufferRelease((CVPixelBufferRef)e->flash_buffer);
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
    e->last_frame = -1;
    e->render_requested = true;
    if (e->audio) {
      vd_audio_renderer_start(e->audio, e->anchor_position);
      if (e->audio_device) vd_audio_device_start(e->audio_device);
    }
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
    if (e->audio_device) vd_audio_device_stop(e->audio_device);
    if (e->audio) vd_audio_renderer_stop(e->audio);
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
  if (e->audio) vd_audio_renderer_seek(e->audio, position);
  e->last_frame = -1;
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
  int64_t sticker_bytes = 0;
  for (int32_t i = 0; i < e->clip_count; i++) {
    if (e->clips[i].decoder) open++;
    sticker_bytes += vd_sticker_bytes(e->clips[i].sticker);
  }
  out->open_decoders = open;
  // Asked of the compositor rather than accumulated here: it is the one that
  // knows whether a cube went up the bus, and a second counter next to it
  // would be a second thing to keep in step.
  out->lut_uploads = vd_compositor_lut_uploads(e->compositor);
  // Counted here rather than accumulated, like open_decoders and for the same
  // reason: a clip leaving the timeline takes its sticker with it, and a
  // running total would have to be decremented on every path that frees one.
  out->sticker_bytes = sticker_bytes;

  if (e->audio) {
    VdAudioStats audio;
    vd_audio_renderer_stats(e->audio, &audio);
    out->audio_available = vd_audio_renderer_has_audio(e->audio);
    out->audio_underruns = audio.underruns;
    out->audio_buffered_frames = audio.buffered_frames;
  }
  pthread_mutex_unlock(&e->lock);
}
