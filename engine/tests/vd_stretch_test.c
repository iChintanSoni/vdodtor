// A time-stretch is checked on the signal, not on the frame count. A
// stretcher that returned exactly the right number of frames of mush would
// pass every arithmetic test there is, so most of what follows measures pitch
// — by counting zero crossings — and level, and only then the ratio.
//
// No file, no device and no clock: every input here is a sine in an array,
// which is the whole point of vd_stretch being plain C.
#include "vd_check.h"
#include "vdodtor/vd_stretch.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define RATE 48000
#define CHANNELS 2

// A tone, written into an interleaved stereo buffer. Both channels the same:
// the correlation search sums them, so an in-phase pair is the case that says
// the summing is not what is finding the alignment.
static void fill_tone(float* out, int32_t frames, double hz, double phase) {
  for (int32_t i = 0; i < frames; i++) {
    const float v =
        (float)sin(2.0 * M_PI * hz * ((double)i / RATE) + phase);
    for (int32_t c = 0; c < CHANNELS; c++) out[i * CHANNELS + c] = v;
  }
}

static int count_crossings(const float* frames, int32_t count) {
  int crossings = 0;
  for (int32_t i = 1; i < count; i++) {
    const float previous = frames[(i - 1) * CHANNELS];
    const float current = frames[i * CHANNELS];
    if ((previous < 0.0f && current >= 0.0f) ||
        (previous >= 0.0f && current < 0.0f)) {
      crossings++;
    }
  }
  return crossings;
}

static double rms(const float* frames, int32_t count) {
  double sum = 0.0;
  for (int32_t i = 0; i < count * CHANNELS; i++) {
    sum += (double)frames[i] * (double)frames[i];
  }
  return count > 0 ? sqrt(sum / (count * CHANNELS)) : 0.0;
}

// Runs `seconds` of a `hz` tone through a stretcher and returns what came out,
// stopping when the input runs dry. `*out_frames` is how much that was.
static float* run(double rate, bool pitch_shift, double hz, double seconds,
                  int32_t* out_frames) {
  VdStretch* s = vd_stretch_create(RATE, CHANNELS, rate, pitch_shift);
  if (!s) {
    *out_frames = 0;
    return NULL;
  }

  const int32_t in_total = (int32_t)(seconds * RATE);
  float* in = calloc((size_t)in_total * CHANNELS, sizeof(float));
  // Room for everything the input could possibly become, plus slack.
  const int32_t out_capacity = (int32_t)((double)in_total / rate) + RATE;
  float* out = calloc((size_t)out_capacity * CHANNELS, sizeof(float));
  fill_tone(in, in_total, hz, 0.0);

  int32_t written = 0;
  int32_t produced = 0;
  for (;;) {
    const int32_t got =
        vd_stretch_read(s, out + (size_t)produced * CHANNELS,
                        out_capacity - produced);
    produced += got;
    if (produced >= out_capacity) break;

    int32_t wanted = vd_stretch_wanted(s);
    if (wanted <= 0) break;
    if (wanted > in_total - written) wanted = in_total - written;
    if (wanted <= 0) break;  // the input ran out
    written += vd_stretch_write(s, in + (size_t)written * CHANNELS, wanted);
  }

  free(in);
  vd_stretch_destroy(s);
  *out_frames = produced;
  return out;
}

// --- lifecycle -------------------------------------------------------------

static void test_guards(void) {
  VD_CHECK(vd_stretch_create(0, CHANNELS, 2.0, false) == NULL);
  VD_CHECK(vd_stretch_create(RATE, 0, 2.0, false) == NULL);
  VD_CHECK(vd_stretch_create(RATE, CHANNELS + 1, 2.0, false) == NULL);
  VD_CHECK(vd_stretch_create(RATE, CHANNELS, 0.0, false) == NULL);
  VD_CHECK(vd_stretch_create(RATE, CHANNELS, -1.0, false) == NULL);

  vd_stretch_destroy(NULL);
  vd_stretch_reset(NULL);
  VD_CHECK_EQ(vd_stretch_wanted(NULL), 0);
  VD_CHECK_EQ(vd_stretch_write(NULL, NULL, 0), 0);
  VD_CHECK_EQ(vd_stretch_read(NULL, NULL, 0), 0);
  VD_CHECK_EQ(vd_stretch_priming_frames(NULL), 0);
  VD_CHECK(!vd_stretch_matches(NULL, 1.0, false));
}

// The range is the method's, not a product decision, so it is clamped rather
// than refused — a document that somehow claims 100x plays at ten.
static void test_the_range_is_clamped(void) {
  VD_CHECK(vd_speed_clamp(1.0) == 1.0);
  VD_CHECK(vd_speed_clamp(0.5) == 0.5);
  VD_CHECK(vd_speed_clamp(0.001) == VD_SPEED_MIN);
  VD_CHECK(vd_speed_clamp(100.0) == VD_SPEED_MAX);
  // Zero is a memset, not a request to stop time.
  VD_CHECK(vd_speed_clamp(0.0) == 1.0);
  VD_CHECK(vd_speed_clamp(-2.0) == 1.0);
  VD_CHECK(vd_speed_clamp(NAN) == 1.0);

  VdStretch* s = vd_stretch_create(RATE, CHANNELS, 1000.0, false);
  VD_CHECK(s != NULL);
  VD_CHECK(vd_stretch_matches(s, 1000.0, false));
  VD_CHECK(vd_stretch_matches(s, VD_SPEED_MAX, false));
  // The mode is part of the identity: the same rate through a resampler is a
  // different sound, so a stretcher may not be reused across the toggle.
  VD_CHECK(!vd_stretch_matches(s, VD_SPEED_MAX, true));
  VD_CHECK(!vd_stretch_matches(s, 2.0, false));
  vd_stretch_destroy(s);
}

// --- the ratio -------------------------------------------------------------

// The claim every speed rests on: N frames in become N/rate frames out,
// whichever method is running. Within one window, because both work a window
// at a time and a partial one at the end is not emitted.
static void test_the_length_is_the_rate(void) {
  const struct {
    double rate;
    bool pitch_shift;
  } cases[] = {
      {2.0, false},  {0.5, false}, {1.0, false}, {4.0, false}, {0.25, false},
      {2.0, true},   {0.5, true},  {1.0, true},  {VD_SPEED_MAX, false},
      {VD_SPEED_MIN, false},
  };

  for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
    const double rate = cases[i].rate;
    int32_t frames = 0;
    float* out = run(rate, cases[i].pitch_shift, 440.0, 2.0, &frames);
    if (!out) continue;

    const double expected = 2.0 * RATE / rate;
    // One analysis window of slack: what is left in the buffers when the input
    // runs out is not emitted, and at 0.1x that is 55 ms of source becoming
    // half a second of output.
    const double slack = 0.06 * RATE / rate + RATE / 20.0;
    vd_checks++;
    if (fabs((double)frames - expected) > slack) {
      vd_failures++;
      fprintf(stderr,
              "FAIL rate %.2f%s gave %d frames, expected ~%.0f (+/- %.0f)\n",
              rate, cases[i].pitch_shift ? " shifted" : "", frames, expected,
              slack);
    }
    free(out);
  }
}

// --- pitch preserved -------------------------------------------------------

// The whole feature in one assertion: a 440 Hz tone played at any speed is
// still a 440 Hz tone. Crossings are counted per second of *output*, so a
// stretcher that had quietly resampled would report the shifted frequency and
// nothing else in the file would notice.
static void test_the_pitch_survives_the_speed(void) {
  const double rates[] = {0.5, 0.75, 1.5, 2.0, 3.0};
  for (size_t i = 0; i < sizeof(rates) / sizeof(rates[0]); i++) {
    int32_t frames = 0;
    float* out = run(rates[i], false, 440.0, 3.0, &frames);
    if (!out || frames < RATE / 2) {
      free(out);
      continue;
    }

    // Away from both ends: the first window has nothing to continue and the
    // last is where the input ran out.
    const int32_t from = frames / 4;
    const int32_t count = frames / 2;
    const double hz = count_crossings(out + (size_t)from * CHANNELS, count) /
                      2.0 / ((double)count / RATE);

    vd_checks++;
    if (fabs(hz - 440.0) > 20.0) {
      vd_failures++;
      fprintf(stderr, "FAIL %.2fx preserved gave %.1f Hz, expected 440\n",
              rates[i], hz);
    }

    // And it is still a tone rather than a series of cancellations. A sine at
    // full scale is 0.707 RMS; the crossfades cost a little of it, and losing
    // more than a fifth would mean the overlap search was finding nothing.
    const double level = rms(out + (size_t)from * CHANNELS, count);
    vd_checks++;
    if (level < 0.55) {
      vd_failures++;
      fprintf(stderr, "FAIL %.2fx preserved came out at %.3f RMS\n", rates[i],
              level);
    }
    free(out);
  }
}

// --- pitch shifted ---------------------------------------------------------

// The other half of the toggle: played as a tape does it, the pitch goes with
// the speed. 440 Hz at 2x is 880 Hz, and at 0.5x it is 220.
static void test_the_pitch_goes_with_the_speed_when_asked(void) {
  const double rates[] = {0.5, 2.0, 4.0};
  for (size_t i = 0; i < sizeof(rates) / sizeof(rates[0]); i++) {
    int32_t frames = 0;
    float* out = run(rates[i], true, 440.0, 3.0, &frames);
    if (!out || frames < RATE / 2) {
      free(out);
      continue;
    }

    const int32_t from = frames / 8;
    const int32_t count = frames / 2;
    const double hz = count_crossings(out + (size_t)from * CHANNELS, count) /
                      2.0 / ((double)count / RATE);
    const double expected = 440.0 * rates[i];

    vd_checks++;
    if (fabs(hz - expected) > expected * 0.05) {
      vd_failures++;
      fprintf(stderr, "FAIL %.2fx shifted gave %.1f Hz, expected %.1f\n",
              rates[i], hz, expected);
    }
    free(out);
  }
}

// Speeding up throws frames away, and picking the nearest one folds everything
// above the new Nyquist back down into the audible band as a whistle. 12 kHz
// decimated by four would come back as an audible tone; averaged over the span
// each output frame stands for, it comes back as nothing — which is what the
// box in resample_process is for.
static void test_speeding_up_does_not_alias(void) {
  int32_t frames = 0;
  float* out = run(4.0, true, 12000.0, 1.0, &frames);
  if (!out || frames < RATE / 8) {
    free(out);
    return;
  }
  const int32_t from = frames / 8;
  const int32_t count = frames / 2;
  const double level = rms(out + (size_t)from * CHANNELS, count);

  vd_checks++;
  if (level > 0.1) {
    vd_failures++;
    fprintf(stderr,
            "FAIL 12 kHz decimated by 4 came back at %.3f RMS — that is the "
            "alias, not the tone\n",
            level);
  }
  free(out);

  // And the band that survives really does survive: a 1 kHz tone at 4x is a
  // 4 kHz tone and still at full level, so the filter is a filter and not a
  // volume control.
  frames = 0;
  out = run(4.0, true, 1000.0, 1.0, &frames);
  if (!out || frames < RATE / 8) {
    free(out);
    return;
  }
  const double kept =
      rms(out + (size_t)(frames / 8) * CHANNELS, frames / 2);
  vd_checks++;
  if (kept < 0.45) {
    vd_failures++;
    fprintf(stderr, "FAIL 1 kHz at 4x came out at %.3f RMS\n", kept);
  }
  free(out);
}

// --- continuity ------------------------------------------------------------

// A reset is what a seek does to a stretcher, and the frame after it has to be
// the source's own — not a crossfade out of material from before the seek.
static void test_reset_forgets_what_came_before(void) {
  VdStretch* s = vd_stretch_create(RATE, CHANNELS, 2.0, false);
  if (!s) return;

  const int32_t total = RATE;
  float* loud = calloc((size_t)total * CHANNELS, sizeof(float));
  float* out = calloc((size_t)total * CHANNELS, sizeof(float));
  fill_tone(loud, total, 440.0, 0.0);

  // Prime it with a full-scale tone and take a window out.
  vd_stretch_write(s, loud, vd_stretch_wanted(s) < total
                                ? vd_stretch_wanted(s)
                                : total);
  VD_CHECK(vd_stretch_read(s, out, 1024) > 0);

  // Then reset and feed it silence. Nothing of the tone may come back.
  vd_stretch_reset(s);
  VD_CHECK_EQ(vd_stretch_read(s, out, 1024), 0);  // nothing buffered

  float* quiet = calloc((size_t)total * CHANNELS, sizeof(float));
  int32_t written = 0;
  while (written < total) {
    int32_t wanted = vd_stretch_wanted(s);
    if (wanted <= 0) break;
    if (wanted > total - written) wanted = total - written;
    written += vd_stretch_write(s, quiet, wanted);
    const int32_t got = vd_stretch_read(s, out, 1024);
    if (got > 0) {
      vd_checks++;
      if (rms(out, got) > 1e-6) {
        vd_failures++;
        fprintf(stderr, "FAIL silence after a reset came out at %.6f\n",
                rms(out, got));
      }
      break;
    }
  }

  free(loud);
  free(quiet);
  free(out);
  vd_stretch_destroy(s);
}

// It is a buffer as much as an algorithm, and a buffer that took more than it
// had room for would corrupt the heap rather than fail a test.
static void test_it_never_takes_more_than_it_asked_for(void) {
  VdStretch* s = vd_stretch_create(RATE, CHANNELS, 0.5, false);
  if (!s) return;

  const int32_t block = 4096;
  float* in = calloc((size_t)block * CHANNELS, sizeof(float));
  fill_tone(in, block, 440.0, 0.0);

  int32_t total = 0;
  for (int i = 0; i < 64; i++) {
    const int32_t wanted = vd_stretch_wanted(s);
    const int32_t taken = vd_stretch_write(s, in, block);
    VD_CHECK(taken <= wanted);
    VD_CHECK(taken <= block);
    total += taken;
    if (wanted == 0) VD_CHECK_EQ(taken, 0);
  }
  VD_CHECK(total > 0);

  free(in);
  vd_stretch_destroy(s);
}

int main(void) {
  test_guards();
  test_the_range_is_clamped();
  test_the_length_is_the_rate();
  test_the_pitch_survives_the_speed();
  test_the_pitch_goes_with_the_speed_when_asked();
  test_speeding_up_does_not_alias();
  test_reset_forgets_what_came_before();
  test_it_never_takes_more_than_it_asked_for();
  return VD_REPORT();
}
