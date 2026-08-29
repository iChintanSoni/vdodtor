// vd_time.h — the engine half of the tick model.
//
// The document model (app/lib/model/time.dart) defines time as integer ticks
// on a 120000/s timebase. The engine must agree with it exactly, or a frame
// rendered for preview and the same frame rendered for export land on
// different source timestamps. These conversions mirror the Dart ones
// one-for-one, and engine/tests/vd_time_test.c checks the same table the Dart
// tests check.

#ifndef VD_TIME_H
#define VD_TIME_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VD_EXPORT __attribute__((visibility("default")))

// Ticks per second of the project timebase. Divides exactly by 24, 25, 30, 60
// and the NTSC rates 24000/1001, 30000/1001, 60000/1001.
#define VD_TICKS_PER_SECOND 120000
#define VD_NANOS_PER_SECOND 1000000000LL

// An instant or a duration, in ticks. Signed: negative offsets are legal.
typedef int64_t VdTick;

// An exact rate, e.g. {30000, 1001}. den > 0.
typedef struct {
  int32_t num;
  int32_t den;
} VdRational;

// value * mul / div, rounded half away from zero, reduced before multiplying
// so a long timeline cannot overflow.
VD_EXPORT int64_t vd_scale(int64_t value, int64_t mul, int64_t div);

// Exact ticks per frame at `fps`, or 0 if the timebase cannot represent it.
// A 0 return is a programming error at the caller, not a rounding hint.
VD_EXPORT int64_t vd_ticks_per_frame(VdRational fps);

VD_EXPORT bool    vd_timebase_divides(VdRational fps);

VD_EXPORT VdTick  vd_ticks_from_nanos(int64_t nanos);
VD_EXPORT int64_t vd_nanos_from_ticks(VdTick ticks);

// Converts a timestamp on a stream's own timebase (as FFmpeg reports it,
// e.g. 1/90000) into project ticks.
VD_EXPORT VdTick  vd_ticks_from_stream_time(int64_t pts, VdRational timebase);
VD_EXPORT int64_t vd_stream_time_from_ticks(VdTick ticks, VdRational timebase);

// Frame index containing `t`, flooring so it is stable across the whole frame.
VD_EXPORT int64_t vd_frame_of_tick(VdTick t, VdRational fps);
VD_EXPORT VdTick  vd_tick_of_frame(int64_t frame, VdRational fps);

#ifdef __cplusplus
}
#endif
#endif  // VD_TIME_H
