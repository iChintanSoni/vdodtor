#include "vdodtor/vd_stretch.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

// --- the windows -----------------------------------------------------------
//
// Milliseconds rather than frames, because what they mean is a length of
// *sound*: the sequence has to be long enough to hold a pitch period of a low
// voice and short enough that a transient is not smeared across it, and that
// is true at 44.1 kHz and at 48.
//
// The search window is the one worth arguing about. 15 ms is six periods of a
// 400 Hz voice, so there is always an offset that lands in phase; halve it and
// a bass note has nowhere to align to and comes out warbling.
#define VD_STRETCH_SEQUENCE_MS 40
#define VD_STRETCH_OVERLAP_MS 10
#define VD_STRETCH_SEEK_MS 15

// Output frames the resampler builds in one go. Nothing depends on it beyond
// how often the buffer is compacted.
#define VD_STRETCH_RESAMPLE_BLOCK 1024

struct VdStretch {
  int32_t sample_rate;
  int32_t channels;
  double rate;
  bool pitch_shift;

  // Interleaved, `in_frames` valid from index 0. Compacted rather than
  // wrapped: the windows are tens of milliseconds and a memmove of a few
  // kilobytes thirty times a second is not worth a modular index.
  float* in;
  int32_t in_frames;
  int32_t in_capacity;

  float* out;
  int32_t out_frames;
  int32_t out_read;
  int32_t out_capacity;

  // WSOLA. `mid` is the tail of what was last emitted, kept as the reference
  // the next window is slid to match. `primed` is false until something has
  // been emitted, because the first window has nothing to continue.
  float* mid;
  int32_t sequence;
  int32_t overlap;
  int32_t seek;
  double nominal_skip;
  double skip_fraction;
  bool primed;

  // The resampler's read cursor, in input frames. Fractional, and the whole of
  // why the two paths cannot share one.
  double cursor;

  // Input frames it must hold before it can emit anything.
  int32_t required;
};

static int32_t ms_to_frames(int32_t sample_rate, int32_t ms) {
  return (int32_t)(((int64_t)sample_rate * ms) / 1000);
}

static int32_t max_i32(int32_t a, int32_t b) { return a > b ? a : b; }

double vd_speed_clamp(double speed) {
  // The NaN case falls through to 1 because every comparison against it is
  // false, which is the answer a clip with a corrupt speed wants: it plays.
  if (!(speed > 0.0)) return 1.0;
  if (speed < VD_SPEED_MIN) return VD_SPEED_MIN;
  if (speed > VD_SPEED_MAX) return VD_SPEED_MAX;
  return speed;
}

// --- lifecycle -------------------------------------------------------------

VdStretch* vd_stretch_create(int32_t sample_rate, int32_t channels,
                             double rate, bool pitch_shift) {
  if (sample_rate <= 0 || channels <= 0 ||
      channels > VD_STRETCH_MAX_CHANNELS) {
    return NULL;
  }
  if (!(rate > 0.0)) return NULL;  // also rejects NaN
  rate = vd_speed_clamp(rate);

  VdStretch* s = calloc(1, sizeof(VdStretch));
  if (!s) return NULL;
  s->sample_rate = sample_rate;
  s->channels = channels;
  s->rate = rate;
  s->pitch_shift = pitch_shift;

  s->sequence = ms_to_frames(sample_rate, VD_STRETCH_SEQUENCE_MS);
  s->overlap = ms_to_frames(sample_rate, VD_STRETCH_OVERLAP_MS);
  s->seek = ms_to_frames(sample_rate, VD_STRETCH_SEEK_MS);
  if (s->sequence < 4) s->sequence = 4;
  if (s->overlap < 1) s->overlap = 1;
  // A sequence is a crossfade plus a flat middle plus the tail kept for next
  // time, so it has to hold three overlaps. Nothing at any sample rate this
  // product supports comes near the clamp; it is here so the arithmetic below
  // cannot read past the buffer if one ever does.
  if (s->overlap * 3 > s->sequence) s->overlap = s->sequence / 3;

  s->nominal_skip = rate * (double)(s->sequence - s->overlap);

  if (pitch_shift) {
    s->out_capacity = VD_STRETCH_RESAMPLE_BLOCK;
    // A block of output needs `rate` times as much input, plus the two frames
    // an interpolation straddles.
    s->required = (int32_t)ceil(rate) + 2;
    s->in_capacity =
        (int32_t)((double)VD_STRETCH_RESAMPLE_BLOCK * rate) + s->required + 64;
  } else {
    s->out_capacity = s->sequence - s->overlap;
    // Enough to search the whole seek window from a full sequence, and enough
    // to throw away a whole skip afterwards — which above 1x is the larger of
    // the two by a long way.
    s->required = max_i32(s->seek + s->sequence,
                          (int32_t)ceil(s->nominal_skip) + s->overlap);
    s->in_capacity = s->required + 2048;
  }

  const size_t ch = (size_t)channels;
  s->in = calloc((size_t)s->in_capacity * ch, sizeof(float));
  s->out = calloc((size_t)s->out_capacity * ch, sizeof(float));
  s->mid = calloc((size_t)s->overlap * ch, sizeof(float));
  if (!s->in || !s->out || !s->mid) {
    vd_stretch_destroy(s);
    return NULL;
  }
  return s;
}

void vd_stretch_destroy(VdStretch* s) {
  if (!s) return;
  free(s->in);
  free(s->out);
  free(s->mid);
  free(s);
}

bool vd_stretch_matches(const VdStretch* s, double rate, bool pitch_shift) {
  if (!s) return false;
  return s->pitch_shift == pitch_shift && s->rate == vd_speed_clamp(rate);
}

void vd_stretch_reset(VdStretch* s) {
  if (!s) return;
  s->in_frames = 0;
  s->out_frames = 0;
  s->out_read = 0;
  s->primed = false;
  s->skip_fraction = 0.0;
  s->cursor = 0.0;
  memset(s->mid, 0, (size_t)s->overlap * (size_t)s->channels * sizeof(float));
}

int32_t vd_stretch_priming_frames(const VdStretch* s) {
  return s ? s->required : 0;
}

// --- the input side --------------------------------------------------------

int32_t vd_stretch_wanted(const VdStretch* s) {
  if (!s) return 0;
  return s->in_capacity - s->in_frames;
}

int32_t vd_stretch_write(VdStretch* s, const float* in, int32_t frames) {
  if (!s || !in || frames <= 0) return 0;
  int32_t room = s->in_capacity - s->in_frames;
  if (room <= 0) return 0;
  if (frames > room) frames = room;
  memcpy(s->in + (size_t)s->in_frames * (size_t)s->channels, in,
         (size_t)frames * (size_t)s->channels * sizeof(float));
  s->in_frames += frames;
  return frames;
}

// Drops `frames` from the front of the input buffer.
static void consume(VdStretch* s, int32_t frames) {
  if (frames <= 0) return;
  if (frames > s->in_frames) frames = s->in_frames;
  const size_t ch = (size_t)s->channels;
  memmove(s->in, s->in + (size_t)frames * ch,
          (size_t)(s->in_frames - frames) * ch * sizeof(float));
  s->in_frames -= frames;
}

// --- pitch preserved: WSOLA ------------------------------------------------

// How well the `overlap` frames starting at `offset` continue what was last
// emitted, as a cross-correlation normalised by the candidate's own energy —
// so a loud window does not win merely by being loud.
//
// Measured on the channels summed rather than channel by channel. A stereo
// recording's two channels are the same event heard twice, so their sum is
// where the periodicity is; correlating them separately would cost twice as
// much to answer the same question, and this runs a few hundred thousand
// multiplies per emitted window as it is.
static double correlation(const VdStretch* s, const float* candidate) {
  const int32_t channels = s->channels;
  double cross = 0.0;
  double energy = 0.0;
  for (int32_t i = 0; i < s->overlap; i++) {
    double a = 0.0;
    double b = 0.0;
    for (int32_t c = 0; c < channels; c++) {
      a += (double)s->mid[(size_t)i * (size_t)channels + (size_t)c];
      b += (double)candidate[(size_t)i * (size_t)channels + (size_t)c];
    }
    cross += a * b;
    energy += b * b;
  }
  return cross / sqrt(energy + 1e-9);
}

// The offset in [0, seek] whose start best continues what was last emitted.
//
// This is the whole of WSOLA: the analysis position advances by a fixed
// `nominal_skip` whatever is chosen here, so the offset is a perturbation and
// never an accumulating drift — the output stays exactly `rate` times shorter
// than the input however hard the search argues with itself.
static int32_t best_offset(const VdStretch* s) {
  int32_t best = 0;
  double best_score = -1e30;
  for (int32_t offset = 0; offset <= s->seek; offset++) {
    const double score =
        correlation(s, s->in + (size_t)offset * (size_t)s->channels);
    if (score > best_score) {
      best_score = score;
      best = offset;
    }
  }
  return best;
}

static bool wsola_process(VdStretch* s) {
  if (s->in_frames < s->required) return false;

  const int32_t channels = s->channels;
  const size_t ch = (size_t)channels;
  const int32_t emit = s->sequence - s->overlap;
  const int32_t offset = s->primed ? best_offset(s) : 0;
  const float* in = s->in + (size_t)offset * ch;

  if (s->primed) {
    // Linear crossfade out of what was emitted last and into what was chosen
    // now. The search above is what makes this a join rather than a smear:
    // the two are already in phase, so a linear ramp keeps the level.
    for (int32_t i = 0; i < s->overlap; i++) {
      const float w = (float)(i + 1) / (float)(s->overlap + 1);
      for (int32_t c = 0; c < channels; c++) {
        const size_t k = (size_t)i * ch + (size_t)c;
        s->out[k] = s->mid[k] * (1.0f - w) + in[k] * w;
      }
    }
    memcpy(s->out + (size_t)s->overlap * ch, in + (size_t)s->overlap * ch,
           (size_t)(emit - s->overlap) * ch * sizeof(float));
  } else {
    // Nothing to continue yet, so the first window goes out as it stands.
    // That is also what makes the first output frame land exactly on the
    // source time the caller seeked to, rather than half a window past it.
    memcpy(s->out, in, (size_t)emit * ch * sizeof(float));
    s->primed = true;
  }

  // The frames immediately after what was emitted, kept as next window's
  // reference. Taken from the input rather than from the output, so a chain of
  // crossfades cannot compound.
  memcpy(s->mid, in + (size_t)emit * ch,
         (size_t)s->overlap * ch * sizeof(float));

  s->out_frames = emit;
  s->out_read = 0;

  s->skip_fraction += s->nominal_skip;
  const int32_t skip = (int32_t)s->skip_fraction;
  s->skip_fraction -= (double)skip;
  consume(s, skip);
  return true;
}

// --- pitch shifted: resampling ---------------------------------------------

// Input frames the resampler needs in hand to produce one output frame from
// `cursor`.
static int32_t resample_need(const VdStretch* s) {
  if (s->rate <= 1.0) return (int32_t)s->cursor + 2;
  return (int32_t)(s->cursor + s->rate) + 2;
}

static bool resample_process(VdStretch* s) {
  const int32_t channels = s->channels;
  const size_t ch = (size_t)channels;
  int32_t produced = 0;

  while (produced < s->out_capacity && s->in_frames >= resample_need(s)) {
    float* out = s->out + (size_t)produced * ch;
    if (s->rate <= 1.0) {
      // Slower than it was recorded, so this is an interpolation between two
      // neighbouring frames and there is nothing to lose by not filtering.
      const int32_t i = (int32_t)s->cursor;
      const float f = (float)(s->cursor - (double)i);
      const float* a = s->in + (size_t)i * ch;
      const float* b = a + ch;
      for (int32_t c = 0; c < channels; c++) {
        out[c] = a[c] * (1.0f - f) + b[c] * f;
      }
    } else {
      // Faster, which means throwing frames away — and picking the nearest one
      // is how a resampler folds everything above the new Nyquist back down
      // into the audible band as a whistle. Averaging over the whole span each
      // output frame stands for is the cheapest thing that does not: a box of
      // `rate` frames has its first null exactly at the rate it is decimating
      // by, which is where the aliasing would have come from.
      const double from = s->cursor;
      const double to = s->cursor + s->rate;
      const int32_t first = (int32_t)from;
      const int32_t last = (int32_t)to;
      double acc[VD_STRETCH_MAX_CHANNELS] = {0.0};
      if (first == last) {
        for (int32_t c = 0; c < channels; c++) {
          acc[c] = (double)s->in[(size_t)first * ch + (size_t)c] * (to - from);
        }
      } else {
        const double head = (double)(first + 1) - from;
        for (int32_t c = 0; c < channels; c++) {
          acc[c] += (double)s->in[(size_t)first * ch + (size_t)c] * head;
        }
        for (int32_t i = first + 1; i < last; i++) {
          for (int32_t c = 0; c < channels; c++) {
            acc[c] += (double)s->in[(size_t)i * ch + (size_t)c];
          }
        }
        const double tail = to - (double)last;
        if (tail > 0.0) {
          for (int32_t c = 0; c < channels; c++) {
            acc[c] += (double)s->in[(size_t)last * ch + (size_t)c] * tail;
          }
        }
      }
      for (int32_t c = 0; c < channels; c++) {
        out[c] = (float)(acc[c] / (to - from));
      }
    }
    s->cursor += s->rate;
    produced++;
  }

  if (produced == 0) return false;

  const int32_t consumed = (int32_t)s->cursor;
  consume(s, consumed);
  s->cursor -= (double)consumed;
  s->out_frames = produced;
  s->out_read = 0;
  return true;
}

// --- the output side -------------------------------------------------------

int32_t vd_stretch_read(VdStretch* s, float* out, int32_t frames) {
  if (!s || !out || frames <= 0) return 0;
  const size_t ch = (size_t)s->channels;
  int32_t done = 0;

  while (done < frames) {
    const int32_t available = s->out_frames - s->out_read;
    if (available <= 0) {
      const bool produced =
          s->pitch_shift ? resample_process(s) : wsola_process(s);
      if (!produced) break;
      continue;
    }
    int32_t take = frames - done;
    if (take > available) take = available;
    memcpy(out + (size_t)done * ch,
           s->out + (size_t)s->out_read * ch,
           (size_t)take * ch * sizeof(float));
    s->out_read += take;
    done += take;
    if (s->out_read >= s->out_frames) {
      s->out_read = 0;
      s->out_frames = 0;
    }
  }
  return done;
}
