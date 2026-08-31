#include "vdodtor/vd_peaks.h"

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "vdodtor/vd_audio.h"
#include "vdodtor/vd_probe.h"

// Frames pulled from the source per read. Big enough that the per-call cost
// disappears against the decode, small enough to stay off the stack.
#define VD_PEAKS_READ_FRAMES 8192

// A growable array of int16 pairs. Level 0's length is not known until the
// file has been read to the end — a container's declared duration is a claim,
// not a measurement, and building the pyramid around a wrong one would either
// truncate the tail or pad it with silence the file does not have.
typedef struct {
  int16_t* data;
  int64_t count;  // pairs
  int64_t cap;    // pairs
} VdBucketList;

static bool bucket_list_push(VdBucketList* list, int16_t lo, int16_t hi) {
  if (list->count == list->cap) {
    const int64_t next = list->cap < 4096 ? 4096 : list->cap * 2;
    int16_t* grown = (int16_t*)realloc(list->data, (size_t)next * 2 *
                                                       sizeof(int16_t));
    if (!grown) return false;
    list->data = grown;
    list->cap = next;
  }
  list->data[list->count * 2] = lo;
  list->data[list->count * 2 + 1] = hi;
  list->count++;
  return true;
}

static int16_t quantise(float value) {
  const float scaled = value * 32767.0f;
  if (scaled >= 32767.0f) return 32767;
  // Never -32768: the range is kept symmetrical so that negating a peak, which
  // is what mirroring a waveform about its centre line amounts to, cannot
  // overflow.
  if (scaled <= -32767.0f) return -32767;
  return (int16_t)(scaled >= 0 ? scaled + 0.5f : scaled - 0.5f);
}

int64_t vd_peaks_level_offset(const VdPeaks* peaks, int32_t level) {
  if (!peaks || level < 0 || level >= peaks->level_count) return -1;
  int64_t offset = 0;
  for (int32_t i = 0; i < level; i++) offset += peaks->bucket_counts[i];
  return offset;
}

// Reads `path` into level 0. Returns a VdResult; on VD_OK the caller owns
// `out_level0.data`.
static int32_t scan_level0(const char* path, VdBucketList* out_level0,
                           int64_t* out_frames) {
  int32_t result = VD_OK;
  VdAudioSource* source = vd_audio_source_open(path, &result);
  if (!source) return result == VD_OK ? VD_ERR_OPEN : result;

  float* buffer = (float*)malloc((size_t)VD_PEAKS_READ_FRAMES *
                                 VD_AUDIO_CHANNELS * sizeof(float));
  if (!buffer) {
    vd_audio_source_close(source);
    return VD_ERR_UNSUPPORTED;
  }

  int64_t frames = 0;
  int32_t in_bucket = 0;
  float lo = 0;
  float hi = 0;
  bool ok = true;

  for (;;) {
    const int32_t got =
        vd_audio_source_read(source, buffer, VD_PEAKS_READ_FRAMES);
    if (got <= 0) break;

    for (int32_t f = 0; f < got && ok; f++) {
      for (int32_t c = 0; c < VD_AUDIO_CHANNELS; c++) {
        const float sample = buffer[(int64_t)f * VD_AUDIO_CHANNELS + c];
        // Seeded from the first sample rather than from zero: a bucket whose
        // range was primed with 0 always claims to touch the centre line, and
        // a signal that never crosses it — anything with a DC offset, or a
        // tone slower than a bucket is long — would be drawn straddling a zero
        // it never reaches.
        if (in_bucket == 0 && c == 0) {
          lo = sample;
          hi = sample;
        } else if (sample < lo) {
          lo = sample;
        } else if (sample > hi) {
          hi = sample;
        }
      }
      frames++;
      if (++in_bucket == VD_PEAKS_FRAMES_PER_BUCKET) {
        ok = bucket_list_push(out_level0, quantise(lo), quantise(hi));
        in_bucket = 0;
      }
    }
    if (!ok) break;
  }

  // The tail. A short last bucket is kept rather than dropped: dropping it
  // loses up to 2.7 ms off the end of every clip, and the one place that is
  // always visible is the very edge a trim handle is sitting on.
  if (ok && in_bucket > 0) {
    ok = bucket_list_push(out_level0, quantise(lo), quantise(hi));
  }

  free(buffer);
  vd_audio_source_close(source);

  if (!ok) return VD_ERR_UNSUPPORTED;
  if (frames == 0) return VD_ERR_DECODE;
  *out_frames = frames;
  return VD_OK;
}

int32_t vd_peaks_analyze(const char* path, VdPeaks* out) {
  if (out) memset(out, 0, sizeof(*out));
  if (!path || !out) return VD_ERR_INVALID_ARG;

  VdBucketList level0 = {NULL, 0, 0};
  int64_t frames = 0;
  const int32_t result = scan_level0(path, &level0, &frames);
  if (result != VD_OK) {
    free(level0.data);
    return result;
  }

  int32_t counts[VD_PEAKS_MAX_LEVELS];
  int32_t level_count = 1;
  counts[0] = (int32_t)level0.count;
  int64_t total = counts[0];
  while (level_count < VD_PEAKS_MAX_LEVELS && counts[level_count - 1] > 1) {
    counts[level_count] = (counts[level_count - 1] + 1) / 2;
    total += counts[level_count];
    level_count++;
  }

  int16_t* buckets = (int16_t*)malloc((size_t)total * 2 * sizeof(int16_t));
  if (!buckets) {
    free(level0.data);
    return VD_ERR_UNSUPPORTED;
  }
  memcpy(buckets, level0.data, (size_t)counts[0] * 2 * sizeof(int16_t));
  free(level0.data);

  // Each level is the one below it, folded in pairs. Min of mins and max of
  // maxes — never an average — so a transient that survives into a bucket
  // survives all the way to the top of the pyramid.
  int64_t offset = 0;
  for (int32_t level = 1; level < level_count; level++) {
    const int16_t* src = buckets + offset * 2;
    const int32_t src_count = counts[level - 1];
    offset += src_count;
    int16_t* dst = buckets + offset * 2;

    for (int32_t i = 0; i < counts[level]; i++) {
      const int32_t a = i * 2;
      const int32_t b = a + 1;
      int16_t lo = src[a * 2];
      int16_t hi = src[a * 2 + 1];
      // The last bucket of an odd level has no sibling. It stands alone
      // rather than being folded with a zero, which would draw a phantom
      // return to silence at the very end of the file.
      if (b < src_count) {
        if (src[b * 2] < lo) lo = src[b * 2];
        if (src[b * 2 + 1] > hi) hi = src[b * 2 + 1];
      }
      dst[i * 2] = lo;
      dst[i * 2 + 1] = hi;
    }
  }

  out->level_count = level_count;
  out->frames_per_bucket = VD_PEAKS_FRAMES_PER_BUCKET;
  out->sample_rate = VD_AUDIO_SAMPLE_RATE;
  out->channels = VD_AUDIO_CHANNELS;
  out->frame_count = frames;
  out->duration = vd_scale(frames, VD_TICKS_PER_SECOND, VD_AUDIO_SAMPLE_RATE);
  memcpy(out->bucket_counts, counts, (size_t)level_count * sizeof(int32_t));
  out->bucket_total = total;
  out->buckets = buckets;
  return VD_OK;
}

void vd_peaks_free(VdPeaks* peaks) {
  if (!peaks) return;
  free(peaks->buckets);
  memset(peaks, 0, sizeof(*peaks));
}
