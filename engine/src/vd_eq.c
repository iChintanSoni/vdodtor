#include "vdodtor/vd_eq.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

// The most sections any preset below uses. Three is enough for the shape of a
// correction — take something away, put something back, and tilt the rest —
// and a fourth would be a parametric equaliser wearing a preset's name.
#define VD_EQ_MAX_SECTIONS 3

typedef enum {
  VD_SECTION_LOWPASS,
  VD_SECTION_HIGHPASS,
  VD_SECTION_PEAK,
  VD_SECTION_LOW_SHELF,
  VD_SECTION_HIGH_SHELF,
} VdSectionKind;

// One band of a preset, in the terms somebody would describe it in rather than
// in coefficients: what it does, where, how much and how wide.
typedef struct {
  VdSectionKind kind;
  double hz;
  double db;  // ignored by the two passes, which have nothing to gain
  double q;
} VdSectionSpec;

// A biquad, normalised so a0 is 1 and gone.
typedef struct {
  double b0, b1, b2, a1, a2;
} VdBiquad;

// Transposed direct form II keeps two numbers per channel and is the form that
// stays well behaved when the coefficients are extreme, which a 90 Hz
// high-pass at 48 kHz very nearly is.
typedef struct {
  double z1, z2;
} VdBiquadState;

struct VdEq {
  VdEqPreset preset;
  int32_t sample_rate;
  int32_t channels;
  int32_t section_count;
  VdBiquad sections[VD_EQ_MAX_SECTIONS];
  VdBiquadState state[VD_EQ_MAX_SECTIONS][VD_EQ_MAX_CHANNELS];
};

// --- the presets -----------------------------------------------------------

// Written out in Hz and decibels, because that is the only form in which
// anybody can argue with them. The coefficients below are derived; these are
// the decisions.
//
// `out` must hold VD_EQ_MAX_SECTIONS. Returns how many were written.
static int32_t sections_for(VdEqPreset preset, VdSectionSpec* out) {
  switch (preset) {
    case VD_EQ_VOICE:
      // The three things wrong with a voice recorded in a room. Rumble below
      // where speech starts, the boxiness a small room adds around 300 Hz, and
      // a consonant range that a soft microphone rolls off. Cutting first and
      // lifting second is the order a person would do it in — and it means the
      // presence lift is not amplifying the mud.
      out[0] = (VdSectionSpec){VD_SECTION_HIGHPASS, 90.0, 0.0, 0.707};
      out[1] = (VdSectionSpec){VD_SECTION_PEAK, 300.0, -3.0, 1.0};
      out[2] = (VdSectionSpec){VD_SECTION_PEAK, 3000.0, 4.0, 1.0};
      return 3;

    case VD_EQ_MUSIC:
      // The smile, gently. Three decibels at each end is the difference
      // between a bed that sits under a voice and one that sounds like a
      // recording of a bed; six would be the difference between that and a
      // car stereo.
      out[0] = (VdSectionSpec){VD_SECTION_LOW_SHELF, 100.0, 3.0, 0.707};
      out[1] = (VdSectionSpec){VD_SECTION_HIGH_SHELF, 8000.0, 3.0, 0.707};
      return 2;

    case VD_EQ_BASS:
      out[0] = (VdSectionSpec){VD_SECTION_LOW_SHELF, 120.0, 6.0, 0.707};
      return 1;

    case VD_EQ_BRIGHT:
      out[0] = (VdSectionSpec){VD_SECTION_HIGH_SHELF, 6000.0, 6.0, 0.707};
      return 1;

    case VD_EQ_TELEPHONE:
      // The band a phone line passes, and a lift in the middle of it. The
      // two filters alone give something thin; the honk is what makes it read
      // as a telephone rather than as a broken recording.
      out[0] = (VdSectionSpec){VD_SECTION_HIGHPASS, 400.0, 0.0, 0.707};
      out[1] = (VdSectionSpec){VD_SECTION_LOWPASS, 3000.0, 0.0, 0.707};
      out[2] = (VdSectionSpec){VD_SECTION_PEAK, 1500.0, 6.0, 1.0};
      return 3;

    case VD_EQ_NONE:
    default:
      return 0;
  }
}

// --- coefficients ----------------------------------------------------------

// Robert Bristow-Johnson's cookbook, verbatim in shape. Written out rather
// than reached for from a library because five formulae with names on them are
// something a reader can check against the source they came from, and a
// dependency is not.
static VdBiquad design(const VdSectionSpec* spec, int32_t sample_rate) {
  // Above Nyquist a filter has no meaning; pinning it just below keeps the
  // arithmetic finite rather than producing a NaN that would silence the clip.
  double hz = spec->hz;
  const double limit = sample_rate * 0.49;
  if (hz > limit) hz = limit;
  if (hz < 1.0) hz = 1.0;

  const double w0 = 2.0 * M_PI * hz / (double)sample_rate;
  const double cos_w0 = cos(w0);
  const double sin_w0 = sin(w0);
  const double a_gain = pow(10.0, spec->db / 40.0);

  double b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0;

  switch (spec->kind) {
    case VD_SECTION_LOWPASS: {
      const double alpha = sin_w0 / (2.0 * spec->q);
      b0 = (1.0 - cos_w0) / 2.0;
      b1 = 1.0 - cos_w0;
      b2 = b0;
      a0 = 1.0 + alpha;
      a1 = -2.0 * cos_w0;
      a2 = 1.0 - alpha;
      break;
    }
    case VD_SECTION_HIGHPASS: {
      const double alpha = sin_w0 / (2.0 * spec->q);
      b0 = (1.0 + cos_w0) / 2.0;
      b1 = -(1.0 + cos_w0);
      b2 = b0;
      a0 = 1.0 + alpha;
      a1 = -2.0 * cos_w0;
      a2 = 1.0 - alpha;
      break;
    }
    case VD_SECTION_PEAK: {
      const double alpha = sin_w0 / (2.0 * spec->q);
      b0 = 1.0 + alpha * a_gain;
      b1 = -2.0 * cos_w0;
      b2 = 1.0 - alpha * a_gain;
      a0 = 1.0 + alpha / a_gain;
      a1 = -2.0 * cos_w0;
      a2 = 1.0 - alpha / a_gain;
      break;
    }
    case VD_SECTION_LOW_SHELF: {
      // Shelf slope 1, which is the gentlest the formula allows and the only
      // one a preset has any business using.
      const double alpha = sin_w0 / 2.0 * sqrt(2.0);
      const double sqrt_a = sqrt(a_gain);
      b0 = a_gain * ((a_gain + 1.0) - (a_gain - 1.0) * cos_w0 +
                     2.0 * sqrt_a * alpha);
      b1 = 2.0 * a_gain * ((a_gain - 1.0) - (a_gain + 1.0) * cos_w0);
      b2 = a_gain * ((a_gain + 1.0) - (a_gain - 1.0) * cos_w0 -
                     2.0 * sqrt_a * alpha);
      a0 = (a_gain + 1.0) + (a_gain - 1.0) * cos_w0 + 2.0 * sqrt_a * alpha;
      a1 = -2.0 * ((a_gain - 1.0) + (a_gain + 1.0) * cos_w0);
      a2 = (a_gain + 1.0) + (a_gain - 1.0) * cos_w0 - 2.0 * sqrt_a * alpha;
      break;
    }
    case VD_SECTION_HIGH_SHELF: {
      const double alpha = sin_w0 / 2.0 * sqrt(2.0);
      const double sqrt_a = sqrt(a_gain);
      b0 = a_gain * ((a_gain + 1.0) + (a_gain - 1.0) * cos_w0 +
                     2.0 * sqrt_a * alpha);
      b1 = -2.0 * a_gain * ((a_gain - 1.0) + (a_gain + 1.0) * cos_w0);
      b2 = a_gain * ((a_gain + 1.0) + (a_gain - 1.0) * cos_w0 -
                     2.0 * sqrt_a * alpha);
      a0 = (a_gain + 1.0) - (a_gain - 1.0) * cos_w0 + 2.0 * sqrt_a * alpha;
      a1 = 2.0 * ((a_gain - 1.0) - (a_gain + 1.0) * cos_w0);
      a2 = (a_gain + 1.0) - (a_gain - 1.0) * cos_w0 - 2.0 * sqrt_a * alpha;
      break;
    }
  }

  VdBiquad out;
  out.b0 = b0 / a0;
  out.b1 = b1 / a0;
  out.b2 = b2 / a0;
  out.a1 = a1 / a0;
  out.a2 = a2 / a0;
  return out;
}

// --- lifecycle -------------------------------------------------------------

VdEq* vd_eq_create(VdEqPreset preset, int32_t sample_rate, int32_t channels) {
  if (preset == VD_EQ_NONE) return NULL;
  if (sample_rate <= 0 || channels <= 0 || channels > VD_EQ_MAX_CHANNELS) {
    return NULL;
  }

  VdSectionSpec specs[VD_EQ_MAX_SECTIONS];
  const int32_t count = sections_for(preset, specs);
  // A preset this build has never heard of filters nothing, which is the same
  // bargain a look nobody registered takes: the clip still plays.
  if (count <= 0) return NULL;

  VdEq* eq = calloc(1, sizeof(VdEq));
  if (!eq) return NULL;
  eq->preset = preset;
  eq->sample_rate = sample_rate;
  eq->channels = channels;
  eq->section_count = count;
  for (int32_t i = 0; i < count; i++) {
    eq->sections[i] = design(&specs[i], sample_rate);
  }
  return eq;
}

void vd_eq_destroy(VdEq* eq) { free(eq); }

bool vd_eq_matches(const VdEq* eq, VdEqPreset preset) {
  return eq && eq->preset == preset;
}

void vd_eq_reset(VdEq* eq) {
  if (!eq) return;
  memset(eq->state, 0, sizeof(eq->state));
}

// --- the filter itself -----------------------------------------------------

void vd_eq_process(VdEq* eq, float* frames, int32_t frames_count) {
  if (!eq || !frames || frames_count <= 0) return;
  const int32_t channels = eq->channels;

  for (int32_t s = 0; s < eq->section_count; s++) {
    const VdBiquad* b = &eq->sections[s];
    for (int32_t c = 0; c < channels; c++) {
      VdBiquadState* z = &eq->state[s][c];
      double z1 = z->z1;
      double z2 = z->z2;
      for (int32_t i = 0; i < frames_count; i++) {
        const size_t at = (size_t)i * (size_t)channels + (size_t)c;
        const double x = (double)frames[at];
        const double y = b->b0 * x + z1;
        z1 = b->b1 * x - b->a1 * y + z2;
        z2 = b->b2 * x - b->a2 * y;
        frames[at] = (float)y;
      }
      z->z1 = z1;
      z->z2 = z2;
    }
  }
}

double vd_eq_response_db(const VdEq* eq, double hz) {
  if (!eq) return 0.0;
  const double w = 2.0 * M_PI * hz / (double)eq->sample_rate;
  double magnitude = 1.0;

  for (int32_t s = 0; s < eq->section_count; s++) {
    const VdBiquad* b = &eq->sections[s];
    // H(e^jw) evaluated the direct way: real and imaginary parts of the
    // numerator and the denominator, then the ratio of their magnitudes.
    const double cw = cos(w);
    const double c2w = cos(2.0 * w);
    const double sw = sin(w);
    const double s2w = sin(2.0 * w);

    const double num_re = b->b0 + b->b1 * cw + b->b2 * c2w;
    const double num_im = -(b->b1 * sw + b->b2 * s2w);
    const double den_re = 1.0 + b->a1 * cw + b->a2 * c2w;
    const double den_im = -(b->a1 * sw + b->a2 * s2w);

    const double num = sqrt(num_re * num_re + num_im * num_im);
    const double den = sqrt(den_re * den_re + den_im * den_im);
    magnitude *= den > 0.0 ? num / den : 0.0;
  }

  return 20.0 * log10(magnitude > 1e-12 ? magnitude : 1e-12);
}
