// Audio is checked on the signal, not on the frame count. A resampler that
// silently mangles a sine still returns the right number of frames, and a ring
// buffer with a subtle race still passes every single-threaded test.
#include "vd_check.h"
#include "vdodtor/vd_audio.h"

#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char* fixture(const char* name) {
  static char paths[8][1024];
  static int next = 0;
  char* path = paths[next];
  next = (next + 1) % 8;
  snprintf(path, sizeof(paths[0]), "%s/%s", VD_TEST_MEDIA_DIR, name);
  return path;
}

// Counts sign changes on the left channel. For a clean sine this is twice the
// frequency per second, which is enough to catch a resampler that shifted the
// pitch or a channel map that grabbed the wrong plane.
static int count_zero_crossings(const float* frames, int32_t count) {
  int crossings = 0;
  for (int32_t i = 1; i < count; i++) {
    const float previous = frames[(i - 1) * VD_AUDIO_CHANNELS];
    const float current = frames[i * VD_AUDIO_CHANNELS];
    if ((previous < 0.0f && current >= 0.0f) ||
        (previous >= 0.0f && current < 0.0f)) {
      crossings++;
    }
  }
  return crossings;
}

static double rms(const float* frames, int32_t count) {
  double sum = 0.0;
  for (int32_t i = 0; i < count * VD_AUDIO_CHANNELS; i++) {
    sum += (double)frames[i] * (double)frames[i];
  }
  return count > 0 ? sqrt(sum / (count * VD_AUDIO_CHANNELS)) : 0.0;
}

// --- source ----------------------------------------------------------------

static void test_source_lifecycle(void) {
  int32_t result = 999;
  VdAudioSource* s =
      vd_audio_source_open(fixture("cfr_30fps_stereo.mp4"), &result);
  VD_CHECK_EQ(result, VD_OK);
  VD_CHECK(s != NULL);
  if (s) {
    VD_CHECK_EQ(vd_audio_source_position(s), 0);
    VD_CHECK(vd_audio_source_duration(s) > 0);
    vd_audio_source_close(s);
  }

  // Silent video is ordinary, and saying "no audio" is not the same as
  // saying "broken file".
  VD_CHECK(vd_audio_source_open(fixture("rotated_cw90.mp4"), &result) == NULL);
  VD_CHECK_EQ(result, VD_ERR_NO_STREAMS);

  VD_CHECK(vd_audio_source_open(fixture("missing.mp4"), &result) == NULL);
  VD_CHECK_EQ(result, VD_ERR_OPEN);
  VD_CHECK(vd_audio_source_open(NULL, &result) == NULL);
  VD_CHECK_EQ(result, VD_ERR_INVALID_ARG);
  VD_CHECK(vd_audio_source_open(fixture("missing.mp4"), NULL) == NULL);

  vd_audio_source_close(NULL);
  VD_CHECK_EQ(vd_audio_source_position(NULL), 0);
  VD_CHECK_EQ(vd_audio_source_read(NULL, NULL, 0), 0);
}

// cfr_30fps_stereo.mp4 carries a 440 Hz sine at 48 kHz stereo — already the
// engine's format, so this is the no-resampling path.
static void test_reads_a_440hz_sine(void) {
  VdAudioSource* s = vd_audio_source_open(fixture("cfr_30fps_stereo.mp4"), NULL);
  if (!s) return;

  const int32_t want = VD_AUDIO_SAMPLE_RATE;  // one second
  float* buffer = calloc((size_t)want * VD_AUDIO_CHANNELS, sizeof(float));
  const int32_t got = vd_audio_source_read(s, buffer, want);

  VD_CHECK_EQ(got, want);
  // One second of media consumed means one second of position.
  VD_CHECK_EQ(vd_audio_source_position(s), VD_TICKS_PER_SECOND);

  const int crossings = count_zero_crossings(buffer, got);
  // 440 Hz is 880 crossings a second. Encoder ringing moves this a little,
  // but not by tens.
  VD_CHECK(crossings > 860);
  VD_CHECK(crossings < 900);
  if (crossings <= 860 || crossings >= 900) {
    fprintf(stderr, "  440 Hz sine gave %d zero crossings, expected ~880\n",
            crossings);
  }

  // A sine at full scale has an RMS near 0.707; ffmpeg's default is quieter,
  // so this only checks that it is neither silent nor clipping.
  const double level = rms(buffer, got);
  VD_CHECK(level > 0.05);
  VD_CHECK(level < 1.0);

  free(buffer);
  vd_audio_source_close(s);
}

// audio_only.m4a is a 220 Hz sine, mono, at 44.1 kHz — so this exercises both
// resampling and the mono-to-stereo path.
static void test_resamples_and_upmixes(void) {
  VdAudioSource* s = vd_audio_source_open(fixture("audio_only.m4a"), NULL);
  if (!s) return;

  const int32_t want = VD_AUDIO_SAMPLE_RATE;
  float* buffer = calloc((size_t)want * VD_AUDIO_CHANNELS, sizeof(float));
  const int32_t got = vd_audio_source_read(s, buffer, want);
  VD_CHECK_EQ(got, want);

  // 220 Hz is 440 crossings a second, and it stays 220 Hz after resampling —
  // that is the whole point of checking the signal instead of the count.
  const int crossings = count_zero_crossings(buffer, got);
  VD_CHECK(crossings > 425);
  VD_CHECK(crossings < 460);
  if (crossings <= 425 || crossings >= 460) {
    fprintf(stderr, "  220 Hz sine gave %d zero crossings, expected ~440\n",
            crossings);
  }

  // Mono upmixed to stereo puts the same signal in both channels.
  int mismatched = 0;
  for (int32_t i = 0; i < got; i++) {
    const float left = buffer[i * 2];
    const float right = buffer[i * 2 + 1];
    if (fabsf(left - right) > 1e-6f) mismatched++;
  }
  VD_CHECK_EQ(mismatched, 0);

  free(buffer);
  vd_audio_source_close(s);
}

static void test_partial_reads_add_up(void) {
  VdAudioSource* s = vd_audio_source_open(fixture("cfr_30fps_stereo.mp4"), NULL);
  if (!s) return;

  // The device asks for awkward sizes; a decoded AAC packet is 1024 frames.
  // Neither divides the other, and the seam must not lose or duplicate a frame.
  float chunk[512 * VD_AUDIO_CHANNELS];
  int32_t total = 0;
  for (int i = 0; i < 40; i++) {
    total += vd_audio_source_read(s, chunk, 373);
  }
  VD_CHECK_EQ(total, 40 * 373);
  VD_CHECK_EQ(vd_audio_source_position(s),
              vd_scale(total, VD_TICKS_PER_SECOND, VD_AUDIO_SAMPLE_RATE));

  vd_audio_source_close(s);
}

static void test_seek(void) {
  VdAudioSource* s = vd_audio_source_open(fixture("cfr_30fps_stereo.mp4"), NULL);
  if (!s) return;

  const int32_t want = 4800;  // 100 ms
  float* a = calloc((size_t)want * VD_AUDIO_CHANNELS, sizeof(float));
  float* b = calloc((size_t)want * VD_AUDIO_CHANNELS, sizeof(float));

  VD_CHECK_EQ(vd_audio_source_seek(s, VD_TICKS_PER_SECOND), VD_OK);
  VD_CHECK_EQ(vd_audio_source_position(s), VD_TICKS_PER_SECOND);
  VD_CHECK_EQ(vd_audio_source_read(s, a, want), want);
  VD_CHECK(rms(a, want) > 0.05);

  // Seeking back to the same place gives the same audio: decoding is a pure
  // function of position, which is what lets a scrub be repeatable.
  VD_CHECK_EQ(vd_audio_source_seek(s, VD_TICKS_PER_SECOND), VD_OK);
  VD_CHECK_EQ(vd_audio_source_read(s, b, want), want);

  int different = 0;
  for (int32_t i = 0; i < want * VD_AUDIO_CHANNELS; i++) {
    if (fabsf(a[i] - b[i]) > 1e-4f) different++;
  }
  VD_CHECK_EQ(different, 0);

  VD_CHECK_EQ(vd_audio_source_seek(s, -1000), VD_OK);
  VD_CHECK_EQ(vd_audio_source_position(s), 0);
  VD_CHECK_EQ(vd_audio_source_seek(NULL, 0), VD_ERR_INVALID_ARG);

  free(a);
  free(b);
  vd_audio_source_close(s);
}

static void test_reading_past_the_end(void) {
  VdAudioSource* s = vd_audio_source_open(fixture("cfr_30fps_stereo.mp4"), NULL);
  if (!s) return;

  // The file is two seconds; ask for five.
  const int32_t want = VD_AUDIO_SAMPLE_RATE * 5;
  float* buffer = calloc((size_t)want * VD_AUDIO_CHANNELS, sizeof(float));
  const int32_t got = vd_audio_source_read(s, buffer, want);

  // Short read, not a lie about having produced silence.
  VD_CHECK(got > 0);
  VD_CHECK(got < want);
  VD_CHECK(got > VD_AUDIO_SAMPLE_RATE);       // at least a second
  VD_CHECK(got < VD_AUDIO_SAMPLE_RATE * 3);   // and not more than the file has

  VD_CHECK_EQ(vd_audio_source_read(s, buffer, want), 0);

  free(buffer);
  vd_audio_source_close(s);
}

// --- ring ------------------------------------------------------------------

static void test_ring_basics(void) {
  VD_CHECK(vd_audio_ring_create(0) == NULL);
  VD_CHECK(vd_audio_ring_create(-4) == NULL);
  vd_audio_ring_destroy(NULL);

  VdAudioRing* r = vd_audio_ring_create(100);
  VD_CHECK(r != NULL);
  if (!r) return;

  VD_CHECK_EQ(vd_audio_ring_capacity(r), 100);
  VD_CHECK_EQ(vd_audio_ring_available(r), 0);
  VD_CHECK_EQ(vd_audio_ring_space(r), 100);

  float in[10 * VD_AUDIO_CHANNELS];
  for (int i = 0; i < 10 * VD_AUDIO_CHANNELS; i++) in[i] = (float)i;

  VD_CHECK_EQ(vd_audio_ring_write(r, in, 10), 10);
  VD_CHECK_EQ(vd_audio_ring_available(r), 10);
  VD_CHECK_EQ(vd_audio_ring_space(r), 90);

  float out[10 * VD_AUDIO_CHANNELS];
  memset(out, 0, sizeof(out));
  VD_CHECK_EQ(vd_audio_ring_read(r, out, 10), 10);
  VD_CHECK_EQ(memcmp(in, out, sizeof(in)), 0);
  VD_CHECK_EQ(vd_audio_ring_available(r), 0);

  // Empty reads and full writes report what they did rather than blocking.
  VD_CHECK_EQ(vd_audio_ring_read(r, out, 10), 0);

  vd_audio_ring_destroy(r);
}

static void test_ring_fills_and_wraps(void) {
  VdAudioRing* r = vd_audio_ring_create(8);
  if (!r) return;

  float in[16 * VD_AUDIO_CHANNELS];
  for (int i = 0; i < 16 * VD_AUDIO_CHANNELS; i++) in[i] = (float)i;
  float out[16 * VD_AUDIO_CHANNELS];

  // Writing more than fits writes what fits.
  VD_CHECK_EQ(vd_audio_ring_write(r, in, 16), 8);
  VD_CHECK_EQ(vd_audio_ring_space(r), 0);
  VD_CHECK_EQ(vd_audio_ring_write(r, in, 1), 0);

  VD_CHECK_EQ(vd_audio_ring_read(r, out, 5), 5);
  VD_CHECK_EQ(vd_audio_ring_write(r, in, 5), 5);

  // Everything still comes out in order across the wrap point.
  VD_CHECK_EQ(vd_audio_ring_read(r, out, 8), 8);
  for (int frame = 0; frame < 3; frame++) {
    VD_CHECK_EQ((int)out[frame * VD_AUDIO_CHANNELS],
                (5 + frame) * VD_AUDIO_CHANNELS);
  }
  for (int frame = 0; frame < 5; frame++) {
    VD_CHECK_EQ((int)out[(3 + frame) * VD_AUDIO_CHANNELS],
                frame * VD_AUDIO_CHANNELS);
  }

  vd_audio_ring_clear(r);
  VD_CHECK_EQ(vd_audio_ring_available(r), 0);
  vd_audio_ring_clear(NULL);

  vd_audio_ring_destroy(r);
}

// A ring that is correct on one thread proves very little. This runs the two
// sides against each other and checks the stream arrives in order, which is
// the only failure a race here actually produces.
typedef struct {
  VdAudioRing* ring;
  int32_t total;
} RingStress;

static void* ring_producer(void* arg) {
  RingStress* s = (RingStress*)arg;
  float frame[VD_AUDIO_CHANNELS];
  int32_t written = 0;
  while (written < s->total) {
    frame[0] = (float)written;
    frame[1] = (float)-written;
    if (vd_audio_ring_write(s->ring, frame, 1) == 1) {
      written++;
    }
  }
  return NULL;
}

static void test_ring_across_threads(void) {
  VdAudioRing* r = vd_audio_ring_create(64);
  if (!r) return;

  RingStress stress = {.ring = r, .total = 200000};
  pthread_t producer;
  pthread_create(&producer, NULL, ring_producer, &stress);

  int32_t read = 0;
  int out_of_order = 0;
  float frame[VD_AUDIO_CHANNELS];
  while (read < stress.total) {
    if (vd_audio_ring_read(r, frame, 1) == 1) {
      if ((int32_t)frame[0] != read || (int32_t)frame[1] != -read) {
        out_of_order++;
      }
      read++;
    }
  }
  pthread_join(producer, NULL);

  VD_CHECK_EQ(out_of_order, 0);
  VD_CHECK_EQ(read, stress.total);

  vd_audio_ring_destroy(r);
}

// --- renderer --------------------------------------------------------------

static VdTimelineClip audio_clip(VdTick start, VdTick duration) {
  VdTimelineClip clip = vd_timeline_clip_default();
  clip.path = fixture("cfr_30fps_stereo.mp4");  // 440 Hz sine, 2 s
  clip.start = start;
  clip.duration = duration;
  return clip;
}

static void test_renderer_lifecycle(void) {
  int32_t result = 999;
  VdAudioRenderer* r = vd_audio_renderer_create(&result);
  VD_CHECK_EQ(result, VD_OK);
  VD_CHECK(r != NULL);
  if (!r) return;

  VD_CHECK(!vd_audio_renderer_has_audio(r));
  VD_CHECK(!vd_audio_renderer_clock_valid(r));
  VD_CHECK_EQ(vd_audio_renderer_position(r), 0);

  VD_CHECK_EQ(vd_audio_renderer_set_timeline(r, NULL, 3), VD_ERR_INVALID_ARG);
  VD_CHECK_EQ(vd_audio_renderer_set_timeline(NULL, NULL, 0),
              VD_ERR_INVALID_ARG);

  vd_audio_renderer_destroy(r);
  vd_audio_renderer_destroy(NULL);
  VD_CHECK(!vd_audio_renderer_has_audio(NULL));
  VD_CHECK(!vd_audio_renderer_clock_valid(NULL));
}

static void test_renderer_finds_the_audio(void) {
  VdAudioRenderer* r = vd_audio_renderer_create(NULL);
  if (!r) return;

  VdTimelineClip clip = audio_clip(0, 2 * VD_TICKS_PER_SECOND);
  VD_CHECK_EQ(vd_audio_renderer_set_timeline(r, &clip, 1), VD_OK);
  VD_CHECK(vd_audio_renderer_has_audio(r));

  // A timeline of silent video reports no audio, so the engine knows to keep
  // using its wall clock rather than waiting on a clock that will never move.
  VdTimelineClip silent = clip;
  silent.path = fixture("rotated_cw90.mp4");
  VD_CHECK_EQ(vd_audio_renderer_set_timeline(r, &silent, 1), VD_OK);
  VD_CHECK(!vd_audio_renderer_has_audio(r));

  // And an empty timeline.
  VD_CHECK_EQ(vd_audio_renderer_set_timeline(r, NULL, 0), VD_OK);
  VD_CHECK(!vd_audio_renderer_has_audio(r));

  vd_audio_renderer_destroy(r);
}

// Waits for the decode thread to get ahead, so a test is measuring the mix
// rather than measuring a cold start.
static void wait_for_buffer(VdAudioRenderer* r, int32_t frames) {
  for (int i = 0; i < 500; i++) {
    VdAudioStats stats;
    vd_audio_renderer_stats(r, &stats);
    if (stats.buffered_frames >= frames) return;
    usleep(2000);
  }
}

static void test_renderer_produces_the_signal(void) {
  VdAudioRenderer* r = vd_audio_renderer_create(NULL);
  if (!r) return;

  VdTimelineClip clip = audio_clip(0, 2 * VD_TICKS_PER_SECOND);
  vd_audio_renderer_set_timeline(r, &clip, 1);
  vd_audio_renderer_start(r, 0);
  wait_for_buffer(r, VD_AUDIO_SAMPLE_RATE / 4);

  const int32_t want = VD_AUDIO_SAMPLE_RATE / 4;  // 250 ms
  float* buffer = calloc((size_t)want * VD_AUDIO_CHANNELS, sizeof(float));
  VD_CHECK_EQ(vd_audio_renderer_pull(r, buffer, want), want);

  // The 440 Hz sine has to survive decode, resample, and the mixer.
  const int crossings = count_zero_crossings(buffer, want);
  VD_CHECK(crossings > 205);
  VD_CHECK(crossings < 235);
  if (crossings <= 205 || crossings >= 235) {
    fprintf(stderr, "  250 ms of 440 Hz gave %d crossings, expected ~220\n",
            crossings);
  }
  VD_CHECK(rms(buffer, want) > 0.05);

  free(buffer);
  vd_audio_renderer_destroy(r);
}

// --- levels ----------------------------------------------------------------

// The same table as `_fadeTable` in app/test/model/clip_audio_test.dart.
//
// A fade the timeline draws and a fade the speakers play have to be the same
// shape. Prose in two files saying so is not a mechanism; the same numbers
// asserted on in two files is.
static void test_the_fade_envelope_matches_the_document(void) {
  const VdTick duration = 1000;
  const VdTick fade_in = 200;
  const VdTick fade_out = 400;

  const struct {
    VdTick offset;
    float gain;
  } table[] = {
      {-1, 0.0f},       // before the clip
      {0, 0.0f},        // silent at the very start of a fade in
      {100, 0.5f},      // halfway up a 200-tick fade
      {200, 1.0f},      // fade in is over
      {500, 1.0f},      // the middle is untouched
      {600, 1.0f},      // exactly where the fade out begins
      {700, 0.75f},     // 300 of 400 remaining
      {900, 0.25f},
      {999, 0.0025f},   // one tick from the end, of a 400 fade
      {1000, 0.0f},     // past the end
  };

  for (size_t i = 0; i < sizeof(table) / sizeof(table[0]); i++) {
    const float got =
        vd_audio_fade_gain(table[i].offset, duration, fade_in, fade_out);
    vd_checks++;
    if (fabsf(got - table[i].gain) > 0.0005f) {
      vd_failures++;
      fprintf(stderr,
              "FAIL fade gain at offset %lld\n  expected %.4f\n  actual   %.4f\n",
              (long long)table[i].offset, table[i].gain, got);
    }
  }

  // No fades at all is a flat 1, not a ramp of length zero that divides by it.
  for (VdTick at = 0; at < duration; at += 250) {
    VD_CHECK(vd_audio_fade_gain(at, duration, 0, 0) == 1.0f);
  }
  VD_CHECK(vd_audio_fade_gain(0, 0, 0, 0) == 0.0f);
}

// Pulls 250 ms and reports how loud it was.
static double level_of(VdAudioRenderer* r) {
  const int32_t want = VD_AUDIO_SAMPLE_RATE / 4;
  float* buffer = calloc((size_t)want * VD_AUDIO_CHANNELS, sizeof(float));
  if (!buffer) return -1;
  vd_audio_renderer_pull(r, buffer, want);
  const double level = rms(buffer, want);
  free(buffer);
  return level;
}

static double level_at_gain(float gain) {
  VdAudioRenderer* r = vd_audio_renderer_create(NULL);
  if (!r) return -1;
  VdTimelineClip clip = audio_clip(0, 2 * VD_TICKS_PER_SECOND);
  clip.gain = gain;
  vd_audio_renderer_set_timeline(r, &clip, 1);
  vd_audio_renderer_start(r, 0);
  wait_for_buffer(r, VD_AUDIO_SAMPLE_RATE / 4);
  const double level = level_of(r);
  vd_audio_renderer_destroy(r);
  return level;
}

static void test_gain_scales_what_comes_out(void) {
  const double full = level_at_gain(1.0f);
  const double half = level_at_gain(0.5f);
  VD_CHECK(full > 0.05);

  // Linear gain: halving the number halves the amplitude, and RMS is linear
  // in amplitude, so the ratio comes straight through.
  vd_checks++;
  if (full <= 0 || fabs(half / full - 0.5) > 0.02) {
    vd_failures++;
    fprintf(stderr,
            "FAIL gain 0.5 gave %.4f against %.4f at unity (ratio %.3f)\n",
            half, full, full > 0 ? half / full : 0.0);
  }
}

static void test_a_muted_clip_is_silent_and_not_decoded(void) {
  // Silence is the whole assertion; the mixer skipping the decode is what
  // makes mute cost nothing, and a clip spends a long time muted.
  const double level = level_at_gain(0.0f);
  vd_checks++;
  if (level > 1e-6) {
    vd_failures++;
    fprintf(stderr, "FAIL a muted clip was audible at %.6f\n", level);
  }
}

static void test_a_fade_in_actually_ramps(void) {
  VdAudioRenderer* r = vd_audio_renderer_create(NULL);
  if (!r) return;

  // A one-second fade in over a two-second clip.
  VdTimelineClip clip = audio_clip(0, 2 * VD_TICKS_PER_SECOND);
  clip.fade_in = VD_TICKS_PER_SECOND;
  vd_audio_renderer_set_timeline(r, &clip, 1);
  vd_audio_renderer_start(r, 0);
  wait_for_buffer(r, VD_AUDIO_SAMPLE_RATE);

  // Four consecutive quarter-seconds. Each must be louder than the one before
  // it, which no constant gain can be — and the last is inside the fade's
  // final quarter, so it is still short of full.
  //
  // Waiting between pulls, not only before the first: draining the ring faster
  // than the decode thread fills it reads silence, and silence would look
  // exactly like a fade that went the wrong way.
  double level[4];
  for (int i = 0; i < 4; i++) {
    wait_for_buffer(r, VD_AUDIO_SAMPLE_RATE / 4);
    level[i] = level_of(r);
  }

  for (int i = 1; i < 4; i++) {
    vd_checks++;
    if (!(level[i] > level[i - 1])) {
      vd_failures++;
      fprintf(stderr,
              "FAIL a fade in did not rise: quarter %d was %.4f, "
              "quarter %d was %.4f\n",
              i - 1, level[i - 1], i, level[i]);
    }
  }

  // The first quarter of a one-second fade averages about an eighth of full
  // scale; a fade applied once per 1024-frame chunk instead of per frame would
  // still rise, so the shape is what is checked, not merely the direction.
  vd_checks++;
  if (!(level[0] < level[3] * 0.5)) {
    vd_failures++;
    fprintf(stderr, "FAIL the fade was too shallow: %.4f then %.4f\n",
            level[0], level[3]);
  }

  vd_audio_renderer_destroy(r);
}

// The same table as `_automationTable` in
// app/test/model/clip_audio_test.dart.
//
// The line the timeline draws and the line the speakers play have to be the
// same shape, for the same reason the fade envelope does — and by the same
// mechanism: the identical numbers asserted in both languages.
static void test_the_volume_line_matches_the_document(void) {
  // A duck: full level, down to a quarter across 200 ticks, held for 400,
  // and back up.
  const VdVolumePoint points[] = {
      {1000, 1.00f},
      {1200, 0.25f},
      {1600, 0.25f},
      {1800, 1.00f},
  };
  const int32_t count = (int32_t)(sizeof(points) / sizeof(points[0]));

  const struct {
    VdTick at;
    float gain;
  } table[] = {
      {0, 1.00f},      // before the first point, held flat at its value
      {1000, 1.00f},   // on it
      {1100, 0.625f},  // halfway down the ramp
      {1200, 0.25f},   // the bottom
      {1400, 0.25f},   // the floor of the duck
      {1600, 0.25f},   // the last tick of the floor
      {1700, 0.625f},  // halfway back up
      {1800, 1.00f},   // on the last point
      {9999, 1.00f},   // after them all, held flat — not ramped to unity
  };

  for (size_t i = 0; i < sizeof(table) / sizeof(table[0]); i++) {
    const float got = vd_audio_automation_gain(points, count, table[i].at);
    vd_checks++;
    if (fabsf(got - table[i].gain) > 0.0005f) {
      vd_failures++;
      fprintf(stderr,
              "FAIL volume line at %lld\n  expected %.4f\n  actual   %.4f\n",
              (long long)table[i].at, table[i].gain, got);
    }
  }

  // No line at all is a flat 1, and one point is a flat that one.
  VD_CHECK(vd_audio_automation_gain(NULL, 0, 500) == 1.0f);
  VD_CHECK(vd_audio_automation_gain(points, 0, 500) == 1.0f);
  const VdVolumePoint lone[] = {{500, 0.4f}};
  VD_CHECK(vd_audio_automation_gain(lone, 1, 0) == 0.4f);
  VD_CHECK(vd_audio_automation_gain(lone, 1, 5000) == 0.4f);

  // Two points at the same tick are a step, not a division by zero.
  const VdVolumePoint step[] = {{0, 1.0f}, {500, 1.0f}, {500, 0.0f}};
  VD_CHECK(vd_audio_automation_gain(step, 3, 499) > 0.99f);
  VD_CHECK(vd_audio_automation_gain(step, 3, 500) == 0.0f);
}

// The line is measured in the *source*, so a clip trimmed at the head plays
// the part of the curve its window lands on — not the head of the curve.
static void test_the_volume_line_is_measured_in_the_source(void) {
  // Silent for the first second of the file, full afterwards.
  const VdVolumePoint points[] = {
      {0, 0.0f},
      {VD_TICKS_PER_SECOND - 1, 0.0f},
      {VD_TICKS_PER_SECOND, 1.0f},
  };

  // A clip that starts one second into the file therefore starts loud, even
  // though it starts at zero on the timeline.
  VdAudioRenderer* r = vd_audio_renderer_create(NULL);
  if (!r) return;
  VdTimelineClip clip = audio_clip(0, VD_TICKS_PER_SECOND);
  clip.source_in = VD_TICKS_PER_SECOND;
  clip.volume_points = points;
  clip.volume_point_count = 3;
  vd_audio_renderer_set_timeline(r, &clip, 1);
  vd_audio_renderer_start(r, 0);
  wait_for_buffer(r, VD_AUDIO_SAMPLE_RATE / 4);
  const double level = level_of(r);
  vd_audio_renderer_destroy(r);

  vd_checks++;
  if (!(level > 0.05)) {
    vd_failures++;
    fprintf(stderr,
            "FAIL a clip trimmed past a silent stretch of its volume line "
            "came out at %.4f\n",
            level);
  }
}

static void test_the_volume_line_ducks_what_comes_out(void) {
  VdAudioRenderer* r = vd_audio_renderer_create(NULL);
  if (!r) return;

  // Full for the first quarter-second, a quarter of it for the second.
  const VdVolumePoint points[] = {
      {0, 1.0f},
      {VD_TICKS_PER_SECOND / 4, 1.0f},
      {VD_TICKS_PER_SECOND / 4 + 1, 0.25f},
  };
  VdTimelineClip clip = audio_clip(0, 2 * VD_TICKS_PER_SECOND);
  clip.volume_points = points;
  clip.volume_point_count = 3;
  vd_audio_renderer_set_timeline(r, &clip, 1);
  vd_audio_renderer_start(r, 0);

  double level[2];
  for (int i = 0; i < 2; i++) {
    wait_for_buffer(r, VD_AUDIO_SAMPLE_RATE / 4);
    level[i] = level_of(r);
  }
  vd_audio_renderer_destroy(r);

  // A quarter of the amplitude, and RMS is linear in amplitude. The tolerance
  // is wide because the step lands a frame or two either side of the boundary
  // between the two pulls; a curve applied once per chunk rather than per
  // frame would miss by far more than this.
  vd_checks++;
  if (level[0] <= 0 || fabs(level[1] / level[0] - 0.25) > 0.05) {
    vd_failures++;
    fprintf(stderr,
            "FAIL the volume line did not duck: %.4f then %.4f (ratio %.3f)\n",
            level[0], level[1], level[0] > 0 ? level[1] / level[0] : 0.0);
  }
}

// A ramp inside one chunk. The fade test's argument applies here too: an
// envelope evaluated once per 1024-frame chunk would be a staircase of about
// fifty steps rather than a ramp, and the way to see that is to measure
// consecutive slices of one.
static void test_the_volume_line_ramps_within_a_chunk(void) {
  VdAudioRenderer* r = vd_audio_renderer_create(NULL);
  if (!r) return;

  const VdVolumePoint points[] = {{0, 0.0f}, {VD_TICKS_PER_SECOND, 1.0f}};
  VdTimelineClip clip = audio_clip(0, 2 * VD_TICKS_PER_SECOND);
  clip.volume_points = points;
  clip.volume_point_count = 2;
  vd_audio_renderer_set_timeline(r, &clip, 1);
  vd_audio_renderer_start(r, 0);

  double level[4];
  for (int i = 0; i < 4; i++) {
    wait_for_buffer(r, VD_AUDIO_SAMPLE_RATE / 4);
    level[i] = level_of(r);
  }
  vd_audio_renderer_destroy(r);

  for (int i = 1; i < 4; i++) {
    vd_checks++;
    if (!(level[i] > level[i - 1])) {
      vd_failures++;
      fprintf(stderr,
              "FAIL a volume ramp did not rise: quarter %d was %.4f, "
              "quarter %d was %.4f\n",
              i - 1, level[i - 1], i, level[i]);
    }
  }
  vd_checks++;
  if (!(level[0] < level[3] * 0.5)) {
    vd_failures++;
    fprintf(stderr, "FAIL the ramp was too shallow: %.4f then %.4f\n",
            level[0], level[3]);
  }
}

// The engine keeps its own copy: the caller's array is a stack local in the
// app's FFI arena and is gone the moment set_timeline returns.
static void test_the_volume_line_is_copied(void) {
  VdAudioRenderer* r = vd_audio_renderer_create(NULL);
  if (!r) return;

  VdVolumePoint* points = malloc(2 * sizeof(VdVolumePoint));
  points[0] = (VdVolumePoint){0, 0.0f};
  points[1] = (VdVolumePoint){10 * VD_TICKS_PER_SECOND, 0.0f};

  VdTimelineClip clip = audio_clip(0, 2 * VD_TICKS_PER_SECOND);
  clip.volume_points = points;
  clip.volume_point_count = 2;
  vd_audio_renderer_set_timeline(r, &clip, 1);
  // Freed before a single frame is decoded. Reading through the caller's
  // pointer would be a use-after-free, which is exactly the bug this is for.
  free(points);

  vd_audio_renderer_start(r, 0);
  wait_for_buffer(r, VD_AUDIO_SAMPLE_RATE / 4);
  const double level = level_of(r);
  vd_audio_renderer_destroy(r);

  vd_checks++;
  if (level > 1e-6) {
    vd_failures++;
    fprintf(stderr, "FAIL a line held at zero was audible at %.6f\n", level);
  }
}

static void test_renderer_clock(void) {
  VdAudioRenderer* r = vd_audio_renderer_create(NULL);
  if (!r) return;

  VdTimelineClip clip = audio_clip(0, 2 * VD_TICKS_PER_SECOND);
  vd_audio_renderer_set_timeline(r, &clip, 1);

  vd_audio_renderer_start(r, 0);
  VD_CHECK_EQ(vd_audio_renderer_position(r), 0);
  // Started but not pulled: no time has passed as far as audio is concerned.
  VD_CHECK(!vd_audio_renderer_clock_valid(r));

  wait_for_buffer(r, VD_AUDIO_SAMPLE_RATE / 4);

  float buffer[1024 * VD_AUDIO_CHANNELS];
  for (int i = 0; i < 48; i++) {  // 48 * 1024 frames = 1024 ms worth
    vd_audio_renderer_pull(r, buffer, 1024);
  }
  VD_CHECK(vd_audio_renderer_clock_valid(r));

  // The clock is the frame counter, exactly: 49152 frames at 48 kHz.
  const VdTick expected =
      vd_scale(48 * 1024, VD_TICKS_PER_SECOND, VD_AUDIO_SAMPLE_RATE);
  VD_CHECK_EQ(vd_audio_renderer_position(r), expected);

  // Seeking rebases it rather than accumulating from where it was.
  vd_audio_renderer_seek(r, 5 * VD_TICKS_PER_SECOND);
  VD_CHECK_EQ(vd_audio_renderer_position(r), 5 * VD_TICKS_PER_SECOND);
  vd_audio_renderer_pull(r, buffer, 1024);
  VD_CHECK_EQ(vd_audio_renderer_position(r),
              5 * VD_TICKS_PER_SECOND +
                  vd_scale(1024, VD_TICKS_PER_SECOND, VD_AUDIO_SAMPLE_RATE));

  vd_audio_renderer_destroy(r);
}

static void test_renderer_silence_where_there_is_none(void) {
  VdAudioRenderer* r = vd_audio_renderer_create(NULL);
  if (!r) return;

  // Audio from 1s to 2s, nothing before it.
  VdTimelineClip clip =
      audio_clip(VD_TICKS_PER_SECOND, VD_TICKS_PER_SECOND);
  vd_audio_renderer_set_timeline(r, &clip, 1);
  vd_audio_renderer_start(r, 0);
  wait_for_buffer(r, VD_AUDIO_SAMPLE_RATE / 4);

  const int32_t want = VD_AUDIO_SAMPLE_RATE / 8;
  float* buffer = calloc((size_t)want * VD_AUDIO_CHANNELS, sizeof(float));
  vd_audio_renderer_pull(r, buffer, want);
  // A gap is silence, not the previous clip left ringing.
  VD_CHECK(rms(buffer, want) < 1e-6);

  free(buffer);
  vd_audio_renderer_destroy(r);
}

static void test_renderer_underruns_are_counted(void) {
  VdAudioRenderer* r = vd_audio_renderer_create(NULL);
  if (!r) return;

  VdTimelineClip clip = audio_clip(0, 2 * VD_TICKS_PER_SECOND);
  vd_audio_renderer_set_timeline(r, &clip, 1);
  vd_audio_renderer_start(r, 0);

  // Pull far faster than any decoder could keep up with. The ring empties,
  // and every empty pull is a click the user would hear — so it is counted
  // rather than hidden.
  float buffer[4096 * VD_AUDIO_CHANNELS];
  for (int i = 0; i < 200; i++) {
    vd_audio_renderer_pull(r, buffer, 4096);
  }

  VdAudioStats stats;
  vd_audio_renderer_stats(r, &stats);
  VD_CHECK(stats.underruns > 0);
  VD_CHECK_EQ(stats.frames_rendered, 200 * 4096);

  vd_audio_renderer_destroy(r);
}

static void test_renderer_destroy_while_playing(void) {
  // The decode thread must be joined before anything it touches is freed.
  for (int i = 0; i < 10; i++) {
    VdAudioRenderer* r = vd_audio_renderer_create(NULL);
    if (!r) return;
    VdTimelineClip clip = audio_clip(0, 2 * VD_TICKS_PER_SECOND);
    vd_audio_renderer_set_timeline(r, &clip, 1);
    vd_audio_renderer_start(r, 0);
    usleep((useconds_t)i * 3000);
    vd_audio_renderer_destroy(r);
  }
  VD_CHECK(true);
}

static void test_renderer_pull_guards(void) {
  VdAudioRenderer* r = vd_audio_renderer_create(NULL);
  if (!r) return;
  float buffer[64 * VD_AUDIO_CHANNELS];
  VD_CHECK_EQ(vd_audio_renderer_pull(NULL, buffer, 8), 0);
  VD_CHECK_EQ(vd_audio_renderer_pull(r, NULL, 8), 0);
  VD_CHECK_EQ(vd_audio_renderer_pull(r, buffer, 0), 0);
  // Nothing playing: silence, not stale memory.
  memset(buffer, 0x7f, sizeof(buffer));
  VD_CHECK_EQ(vd_audio_renderer_pull(r, buffer, 64), 64);
  VD_CHECK_EQ(rms(buffer, 64), 0.0);
  vd_audio_renderer_stats(NULL, NULL);
  vd_audio_renderer_stop(NULL);
  vd_audio_renderer_start(NULL, 0);
  vd_audio_renderer_seek(NULL, 0);
  vd_audio_renderer_destroy(r);
}

int main(void) {
  test_source_lifecycle();
  test_reads_a_440hz_sine();
  test_resamples_and_upmixes();
  test_partial_reads_add_up();
  test_seek();
  test_reading_past_the_end();
  test_ring_basics();
  test_ring_fills_and_wraps();
  test_ring_across_threads();
  test_renderer_lifecycle();
  test_renderer_finds_the_audio();
  test_renderer_produces_the_signal();
  test_the_fade_envelope_matches_the_document();
  test_gain_scales_what_comes_out();
  test_a_muted_clip_is_silent_and_not_decoded();
  test_a_fade_in_actually_ramps();
  test_the_volume_line_matches_the_document();
  test_the_volume_line_is_measured_in_the_source();
  test_the_volume_line_ducks_what_comes_out();
  test_the_volume_line_ramps_within_a_chunk();
  test_the_volume_line_is_copied();
  test_renderer_clock();
  test_renderer_silence_where_there_is_none();
  test_renderer_underruns_are_counted();
  test_renderer_destroy_while_playing();
  test_renderer_pull_guards();
  return VD_REPORT();
}
