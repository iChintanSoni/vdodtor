// vd_peaks.h — the shape of a file's sound, at every zoom a timeline has.
//
// A waveform is not one array. Drawn at 1200 px/s a pixel is under a
// millisecond of audio; drawn at 2 px/s it is half a second. Scanning the
// finest data at the widest zoom means reading five million values to paint
// seven thousand pixels, which is why the answer here is a pyramid: level 0
// holds a min and a max per VD_PEAKS_FRAMES_PER_BUCKET audio frames, and each
// level above folds pairs of the level below. Whatever the zoom, the caller
// picks the level whose bucket is closest to a pixel and reads two or three
// buckets per pixel.
//
// Folding by *min and max* rather than by an average is the whole reason this
// works. An average of averages smooths a transient away until a drum hit
// zoomed out is a flat line; a min of mins keeps it, because the coarse bucket
// still spans the sample that made it. So a peak visible at one zoom is
// visible at every zoom, which is what makes a waveform something you can cut
// against.
//
// This is analysis, not playback: it opens VdAudioSource and reads the file
// end to end, so it costs about what decoding the audio costs and belongs on
// a background thread. It decodes through the *same* source the mixer uses,
// so the waveform on screen is the sound that will come out of the speakers
// rather than a second opinion about the file.
//
// What comes back is in memory and says nothing about where it should be
// kept. Caching it is the app's business — the engine has no idea where this
// machine puts its caches, and should not learn.

#ifndef VD_PEAKS_H
#define VD_PEAKS_H

#include <stdint.h>

#include "vdodtor/vd_time.h"

#ifdef __cplusplus
extern "C" {
#endif

// Audio frames in one bucket of level 0. 128 frames is 2.67 ms at 48 kHz,
// finer than a pixel at the timeline's deepest zoom and far finer than a video
// frame — so level 0 is never the thing limiting what can be seen. It costs
// about 1.5 KB per second of audio before the pyramid, and about 3 KB with it.
#define VD_PEAKS_FRAMES_PER_BUCKET 128

// Ceiling on the pyramid's height. Levels stop when one bucket covers the
// whole file, or here, whichever comes first — a file long enough to hit this
// already has a coarsest bucket spanning over a minute, which is coarser than
// any zoom the timeline offers.
#define VD_PEAKS_MAX_LEVELS 16

// The pyramid. `buckets` holds every level concatenated finest-first, two
// int16 per bucket — the minimum then the maximum sample in it, scaled by
// 32767 and clamped to +/-32767.
//
// Signed, and both ends kept, because sound is not symmetrical: a rectified
// waveform drawn from absolute values looks tidier and hides which way a
// transient went, and mirroring one half is a picture of a file nobody has.
typedef struct {
  int32_t level_count;

  // Level 0's bucket size, in audio frames. Level n's is this << n.
  int32_t frames_per_bucket;

  int32_t sample_rate;

  // Channels the peaks were taken across. The minimum and maximum are over
  // every sample of every channel in the bucket, not over a mono downmix:
  // summing to mono lets two out-of-phase channels cancel into a flat line
  // for audio that is plainly audible.
  int32_t channels;

  // Audio frames scanned, and the same length in ticks.
  int64_t frame_count;
  VdTick duration;

  int32_t bucket_counts[VD_PEAKS_MAX_LEVELS];

  // Sum of bucket_counts; `buckets` holds twice this many int16.
  int64_t bucket_total;

  // Owned by the caller; release with vd_peaks_free.
  int16_t* buckets;
} VdPeaks;

// Reads the audio of `path` end to end and builds the pyramid.
//
// Returns VD_OK, or a negative VdResult: VD_ERR_INVALID_ARG for the
// arguments, VD_ERR_OPEN for a file that will not open, VD_ERR_NO_STREAMS for
// one with no audio — which is where silent video lands, and is a fact about
// the file rather than a failure — and VD_ERR_DECODE when there is an audio
// stream that yields no samples. `out` is zeroed on every failure.
VD_EXPORT int32_t vd_peaks_analyze(const char* path, VdPeaks* out);

// Where level `level` starts in `buckets`, counted in buckets. Negative for a
// level the pyramid does not have.
VD_EXPORT int64_t vd_peaks_level_offset(const VdPeaks* peaks, int32_t level);

// Frees the buckets and zeroes the struct. Safe on a zeroed value, and safe
// twice.
VD_EXPORT void vd_peaks_free(VdPeaks* peaks);

#ifdef __cplusplus
}
#endif
#endif  // VD_PEAKS_H
