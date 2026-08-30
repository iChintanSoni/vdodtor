#include "vdodtor/vd_audio.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// Single producer, single consumer. The indices are the only shared state and
// each is written by exactly one side, which is what makes this safe without a
// lock: the producer owns `write`, the consumer owns `read`, and each reads the
// other's index with acquire ordering.
struct VdAudioRing {
  float* data;
  int32_t capacity;  // in frames
  _Atomic int32_t read;
  _Atomic int32_t write;
};

VdAudioRing* vd_audio_ring_create(int32_t capacity_frames) {
  if (capacity_frames <= 0) return NULL;
  VdAudioRing* r = calloc(1, sizeof(VdAudioRing));
  if (!r) return NULL;
  // One frame is left unused so a full ring is distinguishable from an empty
  // one without a separate count that both sides would have to write.
  r->capacity = capacity_frames + 1;
  r->data = calloc((size_t)r->capacity * VD_AUDIO_CHANNELS, sizeof(float));
  if (!r->data) {
    free(r);
    return NULL;
  }
  atomic_store(&r->read, 0);
  atomic_store(&r->write, 0);
  return r;
}

void vd_audio_ring_destroy(VdAudioRing* r) {
  if (!r) return;
  free(r->data);
  free(r);
}

int32_t vd_audio_ring_capacity(const VdAudioRing* r) {
  return r ? r->capacity - 1 : 0;
}

int32_t vd_audio_ring_available(const VdAudioRing* r) {
  if (!r) return 0;
  const int32_t w = atomic_load_explicit(&r->write, memory_order_acquire);
  const int32_t rd = atomic_load_explicit(&r->read, memory_order_acquire);
  return w >= rd ? w - rd : w - rd + r->capacity;
}

int32_t vd_audio_ring_space(const VdAudioRing* r) {
  if (!r) return 0;
  return vd_audio_ring_capacity(r) - vd_audio_ring_available(r);
}

int32_t vd_audio_ring_write(VdAudioRing* r, const float* frames, int32_t count) {
  if (!r || !frames || count <= 0) return 0;
  const int32_t space = vd_audio_ring_space(r);
  if (count > space) count = space;
  if (count == 0) return 0;

  int32_t w = atomic_load_explicit(&r->write, memory_order_relaxed);
  const int32_t first = r->capacity - w < count ? r->capacity - w : count;
  memcpy(r->data + (size_t)w * VD_AUDIO_CHANNELS, frames,
         (size_t)first * VD_AUDIO_CHANNELS * sizeof(float));
  if (first < count) {
    memcpy(r->data, frames + (size_t)first * VD_AUDIO_CHANNELS,
           (size_t)(count - first) * VD_AUDIO_CHANNELS * sizeof(float));
  }
  w += count;
  if (w >= r->capacity) w -= r->capacity;
  // Release: the samples above must be visible before the index that exposes
  // them.
  atomic_store_explicit(&r->write, w, memory_order_release);
  return count;
}

int32_t vd_audio_ring_read(VdAudioRing* r, float* out, int32_t count) {
  if (!r || !out || count <= 0) return 0;
  const int32_t available = vd_audio_ring_available(r);
  if (count > available) count = available;
  if (count == 0) return 0;

  int32_t rd = atomic_load_explicit(&r->read, memory_order_relaxed);
  const int32_t first = r->capacity - rd < count ? r->capacity - rd : count;
  memcpy(out, r->data + (size_t)rd * VD_AUDIO_CHANNELS,
         (size_t)first * VD_AUDIO_CHANNELS * sizeof(float));
  if (first < count) {
    memcpy(out + (size_t)first * VD_AUDIO_CHANNELS, r->data,
           (size_t)(count - first) * VD_AUDIO_CHANNELS * sizeof(float));
  }
  rd += count;
  if (rd >= r->capacity) rd -= r->capacity;
  atomic_store_explicit(&r->read, rd, memory_order_release);
  return count;
}

void vd_audio_ring_clear(VdAudioRing* r) {
  if (!r) return;
  // Producer side only: moving `write` back to wherever the consumer is means
  // the consumer sees an empty ring and returns silence until it refills.
  atomic_store_explicit(&r->write,
                        atomic_load_explicit(&r->read, memory_order_acquire),
                        memory_order_release);
}
