// Peaks are checked on two things a waveform has to get right: the numbers in
// the finest level are the file's actual envelope, and every level above it
// says the same thing at a coarser grain. The second is the one worth testing
// hardest — a pyramid whose levels disagree draws a different waveform at
// every zoom, and there is no zoom at which that is visibly wrong.
#include "vd_check.h"
#include "vdodtor/vd_peaks.h"

#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "vdodtor/vd_audio.h"
#include "vdodtor/vd_probe.h"

static const char* fixture(const char* name) {
  static char paths[4][1024];
  static int next = 0;
  char* path = paths[next];
  next = (next + 1) % 4;
  snprintf(path, sizeof(paths[0]), "%s/%s", VD_TEST_MEDIA_DIR, name);
  return path;
}

static const int16_t* bucket_at(const VdPeaks* peaks, int32_t level,
                                int32_t index) {
  const int64_t offset = vd_peaks_level_offset(peaks, level);
  if (offset < 0 || index < 0 || index >= peaks->bucket_counts[level]) {
    return NULL;
  }
  return peaks->buckets + (offset + index) * 2;
}

// The bucket of `level` covering `seconds`.
static const int16_t* bucket_at_time(const VdPeaks* peaks, int32_t level,
                                     double seconds) {
  const int64_t frame = (int64_t)(seconds * peaks->sample_rate);
  const int64_t size = (int64_t)peaks->frames_per_bucket << level;
  return bucket_at(peaks, level, (int32_t)(frame / size));
}

static float to_float(int16_t v) { return (float)v / 32767.0f; }

static bool near(float actual, float expected, float tolerance) {
  return fabsf(actual - expected) <= tolerance;
}

// --- structure -------------------------------------------------------------

static void test_shape(void) {
  VdPeaks peaks;
  VD_CHECK_EQ(vd_peaks_analyze(fixture("audio_steps.m4a"), &peaks), VD_OK);

  VD_CHECK_EQ(peaks.frames_per_bucket, VD_PEAKS_FRAMES_PER_BUCKET);
  VD_CHECK_EQ(peaks.sample_rate, VD_AUDIO_SAMPLE_RATE);
  VD_CHECK_EQ(peaks.channels, VD_AUDIO_CHANNELS);

  // Three seconds at 48 kHz, give or take the codec's priming.
  VD_CHECK(peaks.frame_count > 140000 && peaks.frame_count < 148000);
  VD_CHECK(llabs(peaks.duration - 3 * VD_TICKS_PER_SECOND) <
           VD_TICKS_PER_SECOND / 10);

  // Level 0 covers every frame and no more: the partial bucket at the end is
  // kept, so the count rounds up rather than down.
  const int32_t expected0 =
      (int32_t)((peaks.frame_count + VD_PEAKS_FRAMES_PER_BUCKET - 1) /
                VD_PEAKS_FRAMES_PER_BUCKET);
  VD_CHECK_EQ(peaks.bucket_counts[0], expected0);

  // Each level halves, rounding up, and the pyramid stops at a single bucket.
  int64_t total = peaks.bucket_counts[0];
  for (int32_t level = 1; level < peaks.level_count; level++) {
    VD_CHECK_EQ(peaks.bucket_counts[level],
                (peaks.bucket_counts[level - 1] + 1) / 2);
    total += peaks.bucket_counts[level];
  }
  VD_CHECK_EQ(peaks.bucket_total, total);
  VD_CHECK(peaks.level_count > 1);
  VD_CHECK_EQ(peaks.bucket_counts[peaks.level_count - 1], 1);
  VD_CHECK(peaks.level_count <= VD_PEAKS_MAX_LEVELS);

  VD_CHECK_EQ(vd_peaks_level_offset(&peaks, 0), 0);
  VD_CHECK_EQ(vd_peaks_level_offset(&peaks, 1), peaks.bucket_counts[0]);
  VD_CHECK_EQ(vd_peaks_level_offset(&peaks, peaks.level_count), -1);
  VD_CHECK_EQ(vd_peaks_level_offset(&peaks, -1), -1);

  vd_peaks_free(&peaks);
  VD_CHECK(peaks.buckets == NULL);
  VD_CHECK_EQ(peaks.level_count, 0);
  vd_peaks_free(&peaks);  // safe twice
}

// --- the envelope ----------------------------------------------------------

static void test_envelope_follows_the_file(void) {
  VdPeaks peaks;
  VD_CHECK_EQ(vd_peaks_analyze(fixture("audio_steps.m4a"), &peaks), VD_OK);

  // A second of silence, a second at 0.25, a second at 0.9 on one channel.
  // Sampled mid-second, away from the steps the codec smears across.
  const int16_t* quiet = bucket_at_time(&peaks, 0, 0.5);
  VD_CHECK(quiet != NULL);
  if (quiet) {
    VD_CHECK(near(to_float(quiet[0]), 0.0f, 0.02f));
    VD_CHECK(near(to_float(quiet[1]), 0.0f, 0.02f));
  }

  const int16_t* mid = bucket_at_time(&peaks, 0, 1.5);
  VD_CHECK(mid != NULL);
  if (mid) {
    VD_CHECK(near(to_float(mid[0]), -0.25f, 0.03f));
    VD_CHECK(near(to_float(mid[1]), 0.25f, 0.03f));
  }

  // The one that matters: the loud second is on the left channel alone, and
  // the envelope is its full height. Averaging the two channels — the obvious
  // way to get one waveform out of a stereo file — would draw this at 0.45.
  const int16_t* loud = bucket_at_time(&peaks, 0, 2.5);
  VD_CHECK(loud != NULL);
  if (loud) {
    VD_CHECK(near(to_float(loud[0]), -0.9f, 0.05f));
    VD_CHECK(near(to_float(loud[1]), 0.9f, 0.05f));
  }

  // Signed, not rectified: a waveform mirrored from absolute values is a
  // picture of a file nobody has.
  VD_CHECK(loud && loud[0] < 0 && loud[1] > 0);

  vd_peaks_free(&peaks);
}

// --- the pyramid -----------------------------------------------------------

// Every coarse bucket is exactly the extremes of the two under it. Checked on
// every bucket of every level rather than on a sample, because the whole claim
// of a mip pyramid is that it holds everywhere.
static void test_levels_agree(void) {
  VdPeaks peaks;
  VD_CHECK_EQ(vd_peaks_analyze(fixture("audio_steps.m4a"), &peaks), VD_OK);

  int mismatches = 0;
  for (int32_t level = 1; level < peaks.level_count; level++) {
    for (int32_t i = 0; i < peaks.bucket_counts[level]; i++) {
      const int16_t* coarse = bucket_at(&peaks, level, i);
      const int16_t* a = bucket_at(&peaks, level - 1, i * 2);
      const int16_t* b = bucket_at(&peaks, level - 1, i * 2 + 1);
      if (!coarse || !a) {
        mismatches++;
        continue;
      }
      int16_t lo = a[0];
      int16_t hi = a[1];
      if (b) {
        if (b[0] < lo) lo = b[0];
        if (b[1] > hi) hi = b[1];
      }
      if (coarse[0] != lo || coarse[1] != hi) mismatches++;
    }
  }
  VD_CHECK_EQ(mismatches, 0);

  // What that buys, stated as the property anyone actually cares about: the
  // loudest moment in the file is just as loud at the top of the pyramid as at
  // the bottom. An average-of-averages pyramid fails this by a mile — the
  // quiet and silent thirds drag the top bucket down towards a third of the
  // height — and it fails it silently, as a waveform that just looks calm.
  int16_t finest = 0;
  for (int32_t i = 0; i < peaks.bucket_counts[0]; i++) {
    const int16_t* b = bucket_at(&peaks, 0, i);
    if (b[1] > finest) finest = b[1];
  }
  const int16_t* top = bucket_at(&peaks, peaks.level_count - 1, 0);
  VD_CHECK(top != NULL);
  VD_CHECK_EQ(top ? top[1] : -1, finest);

  vd_peaks_free(&peaks);
}

// A tone that runs the length of the file is loud the length of the file —
// but only once a bucket is long enough to contain a whole cycle of it. Below
// that the envelope legitimately traces the wave itself, peak and
// zero-crossing alike, and a test demanding a flat reading at every level
// would be demanding the analyser lie about what is in the file.
//
// 220 Hz is a 4.5 ms cycle and level 0's bucket is 2.7 ms, so this checks both
// halves: level 0 varies by more than half, and every coarser level is loud
// everywhere with no dropouts. The bound is deliberately loose — a 32 kbit
// AAC of a sine is not a clean sine, and it rings by half as much again in
// places — because what this is here to catch is silence, a truncation or a
// rectified envelope, not the codec.
//
// The fixture is mono at 44.1 kHz, which is the only place anything exercises
// a source the analyser has to resample before it can measure it.
static void test_continuous_tone(void) {
  VdPeaks peaks;
  VD_CHECK_EQ(vd_peaks_analyze(fixture("audio_only.m4a"), &peaks), VD_OK);

  // Whatever the file is, the peaks are in the engine's format.
  VD_CHECK_EQ(peaks.sample_rate, VD_AUDIO_SAMPLE_RATE);
  VD_CHECK_EQ(peaks.channels, VD_AUDIO_CHANNELS);
  VD_CHECK(llabs(peaks.duration - 3 * VD_TICKS_PER_SECOND) <
           VD_TICKS_PER_SECOND / 10);
  VD_CHECK(peaks.level_count > 4);

  int16_t finest_low = INT16_MAX;
  int16_t finest_high = 0;
  for (int32_t i = 1; i < peaks.bucket_counts[0] - 1; i++) {
    const int16_t* b = bucket_at(&peaks, 0, i);
    if (b[1] < finest_low) finest_low = b[1];
    if (b[1] > finest_high) finest_high = b[1];
  }
  VD_CHECK(to_float(finest_low) < 0.5f * to_float(finest_high));

  int quiet = 0;
  int lopsided = 0;
  for (int32_t level = 3; level < peaks.level_count; level++) {
    for (int32_t i = 1; i < peaks.bucket_counts[level] - 1; i++) {
      const int16_t* b = bucket_at(&peaks, level, i);
      if (to_float(b[1]) < 0.05f) quiet++;
      // A sine is as loud below the line as above it. Rectifying the envelope,
      // or losing one channel of the resampler's output, shows up here.
      if (!near(-to_float(b[0]), to_float(b[1]), 0.3f * to_float(b[1]))) {
        lopsided++;
      }
    }
  }
  VD_CHECK_EQ(quiet, 0);
  VD_CHECK_EQ(lopsided, 0);

  vd_peaks_free(&peaks);
}

// --- failure ---------------------------------------------------------------

static void test_failures(void) {
  VdPeaks peaks;

  // Silent video is ordinary, not broken — the caller draws no waveform and
  // carries on.
  memset(&peaks, 0xAB, sizeof(peaks));
  VD_CHECK_EQ(vd_peaks_analyze(fixture("vfr.mp4"), &peaks), VD_ERR_NO_STREAMS);
  VD_CHECK(peaks.buckets == NULL);
  VD_CHECK_EQ(peaks.level_count, 0);

  memset(&peaks, 0xAB, sizeof(peaks));
  VD_CHECK_EQ(vd_peaks_analyze(fixture("not_media.txt"), &peaks),
              VD_ERR_OPEN);
  VD_CHECK(peaks.buckets == NULL);

  memset(&peaks, 0xAB, sizeof(peaks));
  VD_CHECK_EQ(vd_peaks_analyze(fixture("no_such_file.m4a"), &peaks),
              VD_ERR_OPEN);
  VD_CHECK(peaks.buckets == NULL);

  VD_CHECK_EQ(vd_peaks_analyze(NULL, &peaks), VD_ERR_INVALID_ARG);
  VD_CHECK_EQ(vd_peaks_analyze(fixture("audio_only.m4a"), NULL),
              VD_ERR_INVALID_ARG);
  vd_peaks_free(NULL);
}

// Analysing twice gives the same bytes. A waveform that changes between two
// runs of the same build would mean a cached one can never be trusted, which
// is the entire reason this is written to disk at all.
static void test_repeatable(void) {
  VdPeaks first;
  VdPeaks second;
  VD_CHECK_EQ(vd_peaks_analyze(fixture("cfr_30fps_stereo.mp4"), &first), VD_OK);
  VD_CHECK_EQ(vd_peaks_analyze(fixture("cfr_30fps_stereo.mp4"), &second),
              VD_OK);

  VD_CHECK_EQ(first.bucket_total, second.bucket_total);
  VD_CHECK_EQ(first.frame_count, second.frame_count);
  VD_CHECK(first.bucket_total > 0);
  VD_CHECK_EQ(memcmp(first.buckets, second.buckets,
                     (size_t)first.bucket_total * 2 * sizeof(int16_t)),
              0);

  vd_peaks_free(&first);
  vd_peaks_free(&second);
}

int main(void) {
  test_shape();
  test_envelope_follows_the_file();
  test_levels_agree();
  test_continuous_tone();
  test_failures();
  test_repeatable();
  return VD_REPORT();
}
