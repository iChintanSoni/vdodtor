// An equaliser is checked on the signal, not on its coefficients. A cascade
// with a sign flipped still has a plausible-looking response on paper, and a
// state array indexed wrong still filters — just not the channel it thinks.
//
// So the shape of every test below is: push a steady tone through the real
// filter, measure how loud it comes out, and say in decibels what the preset
// claims to do at that frequency. `vd_eq_response_db` is used only to say
// *which* frequencies are worth asking about.
#include "vd_check.h"
#include "vdodtor/vd_eq.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define RATE 48000
#define CHANNELS 2

// A second of tone, filtered, with the first 100 ms thrown away: a biquad
// starting from silence takes a few dozen samples to settle, and measuring
// through that would report a level nothing sustains.
//
// Returns the change in level, in decibels.
static double gain_db_at(VdEqPreset preset, double hz) {
  VdEq* eq = vd_eq_create(preset, RATE, CHANNELS);
  if (!eq) return 0.0;

  const int32_t frames = RATE;
  float* buffer = calloc((size_t)frames * CHANNELS, sizeof(float));
  if (!buffer) {
    vd_eq_destroy(eq);
    return 0.0;
  }
  for (int32_t i = 0; i < frames; i++) {
    const float v = (float)(0.5 * sin(2.0 * M_PI * hz * i / RATE));
    for (int32_t c = 0; c < CHANNELS; c++) buffer[i * CHANNELS + c] = v;
  }

  vd_eq_process(eq, buffer, frames);

  const int32_t from = RATE / 10;
  double sum = 0.0;
  for (int32_t i = from * CHANNELS; i < frames * CHANNELS; i++) {
    sum += (double)buffer[i] * (double)buffer[i];
  }
  const double rms = sqrt(sum / ((frames - from) * CHANNELS));
  // The input was a 0.5 sine, whose RMS is 0.5/sqrt(2).
  const double reference = 0.5 / sqrt(2.0);

  free(buffer);
  vd_eq_destroy(eq);
  return 20.0 * log10(rms / reference);
}

// Says what happened when it did not match, which is the only time a test
// should say anything.
static void expect_db(VdEqPreset preset, const char* name, double hz,
                      double expected, double tolerance) {
  const double got = gain_db_at(preset, hz);
  vd_checks++;
  if (fabs(got - expected) > tolerance) {
    vd_failures++;
    fprintf(stderr,
            "FAIL %s at %.0f Hz\n  expected %+.1f dB (+/- %.1f)\n"
            "  actual   %+.1f dB\n",
            name, hz, expected, tolerance, got);
  }
}

// --- lifecycle -------------------------------------------------------------

static void test_guards(void) {
  // Not a failure, and the reason the mixer must branch on the preset rather
  // than on the pointer: a clip nobody equalised keeps no filter at all.
  VD_CHECK(vd_eq_create(VD_EQ_NONE, RATE, CHANNELS) == NULL);

  VD_CHECK(vd_eq_create(VD_EQ_VOICE, 0, CHANNELS) == NULL);
  VD_CHECK(vd_eq_create(VD_EQ_VOICE, RATE, 0) == NULL);
  VD_CHECK(vd_eq_create(VD_EQ_VOICE, RATE, VD_EQ_MAX_CHANNELS + 1) == NULL);
  // A preset from a newer version filters nothing rather than crashing — the
  // bargain a look nobody registered already takes.
  VD_CHECK(vd_eq_create((VdEqPreset)99, RATE, CHANNELS) == NULL);

  vd_eq_destroy(NULL);
  vd_eq_reset(NULL);
  vd_eq_process(NULL, NULL, 0);
  VD_CHECK(!vd_eq_matches(NULL, VD_EQ_VOICE));
  VD_CHECK_EQ((int)vd_eq_response_db(NULL, 1000.0), 0);

  VdEq* eq = vd_eq_create(VD_EQ_BASS, RATE, CHANNELS);
  VD_CHECK(eq != NULL);
  VD_CHECK(vd_eq_matches(eq, VD_EQ_BASS));
  VD_CHECK(!vd_eq_matches(eq, VD_EQ_BRIGHT));
  VD_CHECK(!vd_eq_matches(eq, VD_EQ_NONE));
  vd_eq_destroy(eq);
}

// --- what each preset does -------------------------------------------------

// The one that earns the feature: a voice recorded in a room. Rumble goes,
// the boxiness under it comes down, and the consonants come forward.
static void test_voice_lifts_speech_out_of_a_room(void) {
  // Second order, so 12 dB per octave below the 90 Hz corner: 40 Hz is a bit
  // over an octave down and 25 Hz is nearly two. Handling noise and the hum a
  // room makes live down there and speech does not.
  expect_db(VD_EQ_VOICE, "voice", 25.0, -22.3, 1.5);
  expect_db(VD_EQ_VOICE, "voice", 40.0, -14.3, 1.5);
  expect_db(VD_EQ_VOICE, "voice", 300.0, -3.0, 1.0);
  // Where a voice actually lives, left roughly where it was: a preset that
  // moved the fundamental would change who is speaking.
  expect_db(VD_EQ_VOICE, "voice", 1000.0, 0.0, 1.5);
  expect_db(VD_EQ_VOICE, "voice", 3000.0, 4.0, 1.0);
}

static void test_music_smiles_at_both_ends(void) {
  expect_db(VD_EQ_MUSIC, "music", 50.0, 3.0, 1.0);
  expect_db(VD_EQ_MUSIC, "music", 1000.0, 0.0, 1.0);
  expect_db(VD_EQ_MUSIC, "music", 15000.0, 3.0, 1.0);
}

// The two tastes, and the assertion worth making about each is that it leaves
// the *other* end alone. A "bass" preset that also lifted the top would be a
// volume control with a misleading name.
static void test_bass_and_bright_move_one_end_each(void) {
  expect_db(VD_EQ_BASS, "bass", 50.0, 6.0, 1.0);
  expect_db(VD_EQ_BASS, "bass", 5000.0, 0.0, 0.5);

  expect_db(VD_EQ_BRIGHT, "bright", 12000.0, 6.0, 1.0);
  expect_db(VD_EQ_BRIGHT, "bright", 200.0, 0.0, 0.5);
}

// An effect rather than a correction, so what it must do is take things away.
static void test_telephone_passes_only_the_middle(void) {
  expect_db(VD_EQ_TELEPHONE, "telephone", 100.0, -24.1, 2.0);
  expect_db(VD_EQ_TELEPHONE, "telephone", 1500.0, 5.7, 1.0);
  expect_db(VD_EQ_TELEPHONE, "telephone", 12000.0, -28.0, 2.0);
}

// --- the implementation ----------------------------------------------------

// The coefficients and the filter have to agree. They are two ways of asking
// the same question and this is the only test that asks both — if the maths is
// right and the loop is wrong, every assertion above moves together and this
// one does not.
static void test_the_signal_matches_the_coefficients(void) {
  const struct {
    VdEqPreset preset;
    double hz;
  } probes[] = {
      {VD_EQ_VOICE, 3000.0},  {VD_EQ_VOICE, 300.0},
      {VD_EQ_MUSIC, 50.0},    {VD_EQ_BASS, 60.0},
      {VD_EQ_BRIGHT, 10000.0}, {VD_EQ_TELEPHONE, 1500.0},
  };

  for (size_t i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
    VdEq* eq = vd_eq_create(probes[i].preset, RATE, CHANNELS);
    if (!eq) continue;
    const double predicted = vd_eq_response_db(eq, probes[i].hz);
    vd_eq_destroy(eq);

    const double measured = gain_db_at(probes[i].preset, probes[i].hz);
    vd_checks++;
    if (fabs(predicted - measured) > 0.5) {
      vd_failures++;
      fprintf(stderr,
              "FAIL preset %d at %.0f Hz: coefficients say %+.2f dB, the "
              "filter did %+.2f dB\n",
              (int)probes[i].preset, probes[i].hz, predicted, measured);
    }
  }
}

// Two channels carrying different signals must come out still carrying them.
// A state array indexed by section only — the easy mistake — would run the
// left channel's history against the right channel's samples, and the symptom
// is a filter that works perfectly in mono.
static void test_the_channels_do_not_leak_into_each_other(void) {
  VdEq* eq = vd_eq_create(VD_EQ_TELEPHONE, RATE, CHANNELS);
  if (!eq) return;

  const int32_t frames = RATE / 2;
  float* buffer = calloc((size_t)frames * CHANNELS, sizeof(float));
  if (!buffer) {
    vd_eq_destroy(eq);
    return;
  }
  // A tone the telephone preset passes on the left, silence on the right.
  for (int32_t i = 0; i < frames; i++) {
    buffer[i * CHANNELS] =
        (float)(0.5 * sin(2.0 * M_PI * 1500.0 * i / RATE));
    buffer[i * CHANNELS + 1] = 0.0f;
  }
  vd_eq_process(eq, buffer, frames);

  double left = 0.0;
  double right = 0.0;
  for (int32_t i = frames / 4; i < frames; i++) {
    left += (double)buffer[i * CHANNELS] * buffer[i * CHANNELS];
    right += (double)buffer[i * CHANNELS + 1] * buffer[i * CHANNELS + 1];
  }
  VD_CHECK(left > 0.01);
  vd_checks++;
  if (right > 1e-12) {
    vd_failures++;
    fprintf(stderr, "FAIL silence on the right came out at %.9f\n", right);
  }

  free(buffer);
  vd_eq_destroy(eq);
}

// A biquad's state is the last two samples it saw. Across a seek those belong
// to a moment that is not next, and letting them ring into what follows is a
// click exactly where the listener is paying attention.
static void test_reset_forgets_what_it_was_carrying(void) {
  VdEq* eq = vd_eq_create(VD_EQ_BASS, RATE, CHANNELS);
  if (!eq) return;

  const int32_t frames = 2048;
  float* loud = calloc((size_t)frames * CHANNELS, sizeof(float));
  float* quiet = calloc((size_t)frames * CHANNELS, sizeof(float));
  if (!loud || !quiet) {
    free(loud);
    free(quiet);
    vd_eq_destroy(eq);
    return;
  }
  for (int32_t i = 0; i < frames * CHANNELS; i++) loud[i] = 0.9f;

  vd_eq_process(eq, loud, frames);
  vd_eq_reset(eq);
  vd_eq_process(eq, quiet, frames);

  double energy = 0.0;
  for (int32_t i = 0; i < frames * CHANNELS; i++) {
    energy += (double)quiet[i] * (double)quiet[i];
  }
  vd_checks++;
  if (energy > 1e-12) {
    vd_failures++;
    fprintf(stderr, "FAIL silence after a reset came out at %.9f\n", energy);
  }

  free(loud);
  free(quiet);
  vd_eq_destroy(eq);
}

// Filtering in blocks and filtering in one go have to give the same answer,
// because the mixer does the first and every test above does the second.
static void test_block_size_changes_nothing(void) {
  const int32_t frames = 4096;
  float* whole = calloc((size_t)frames * CHANNELS, sizeof(float));
  float* pieces = calloc((size_t)frames * CHANNELS, sizeof(float));
  if (!whole || !pieces) {
    free(whole);
    free(pieces);
    return;
  }
  for (int32_t i = 0; i < frames; i++) {
    const float v = (float)(0.4 * sin(2.0 * M_PI * 220.0 * i / RATE) +
                            0.2 * sin(2.0 * M_PI * 5000.0 * i / RATE));
    for (int32_t c = 0; c < CHANNELS; c++) {
      whole[i * CHANNELS + c] = v;
      pieces[i * CHANNELS + c] = v;
    }
  }

  VdEq* a = vd_eq_create(VD_EQ_VOICE, RATE, CHANNELS);
  VdEq* b = vd_eq_create(VD_EQ_VOICE, RATE, CHANNELS);
  if (a && b) {
    vd_eq_process(a, whole, frames);
    // Deliberately uneven, the way a device's callback is.
    int32_t at = 0;
    const int32_t sizes[] = {1, 7, 64, 1000, 333, 2691};
    for (size_t i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++) {
      const int32_t n = sizes[i] < frames - at ? sizes[i] : frames - at;
      if (n <= 0) break;
      vd_eq_process(b, pieces + (size_t)at * CHANNELS, n);
      at += n;
    }
    VD_CHECK_EQ(at, frames);

    double worst = 0.0;
    for (int32_t i = 0; i < frames * CHANNELS; i++) {
      const double d = fabs((double)whole[i] - (double)pieces[i]);
      if (d > worst) worst = d;
    }
    vd_checks++;
    if (worst > 1e-6) {
      vd_failures++;
      fprintf(stderr, "FAIL blocking changed the output by %.9f\n", worst);
    }
  }

  vd_eq_destroy(a);
  vd_eq_destroy(b);
  free(whole);
  free(pieces);
}

int main(void) {
  test_guards();
  test_voice_lifts_speech_out_of_a_room();
  test_music_smiles_at_both_ends();
  test_bass_and_bright_move_one_end_each();
  test_telephone_passes_only_the_middle();
  test_the_signal_matches_the_coefficients();
  test_the_channels_do_not_leak_into_each_other();
  test_reset_forgets_what_it_was_carrying();
  test_block_size_changes_nothing();
  return VD_REPORT();
}
