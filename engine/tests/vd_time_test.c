// The engine's tick arithmetic must agree with the Dart document model
// exactly. The table below is the same one app/test/model/time_test.dart
// checks; if the two ever diverge, preview and export land on different
// source timestamps.
#include "vd_check.h"
#include "vdodtor/vd_time.h"

static const VdRational FPS_24     = {24, 1};
static const VdRational FPS_25     = {25, 1};
static const VdRational FPS_30     = {30, 1};
static const VdRational FPS_60     = {60, 1};
static const VdRational FPS_23_976 = {24000, 1001};
static const VdRational FPS_29_97  = {30000, 1001};
static const VdRational FPS_59_94  = {60000, 1001};

static void test_ticks_per_frame(void) {
  VD_CHECK_EQ(vd_ticks_per_frame(FPS_24), 5000);
  VD_CHECK_EQ(vd_ticks_per_frame(FPS_25), 4800);
  VD_CHECK_EQ(vd_ticks_per_frame(FPS_30), 4000);
  VD_CHECK_EQ(vd_ticks_per_frame(FPS_60), 2000);
  VD_CHECK_EQ(vd_ticks_per_frame(FPS_23_976), 5005);
  VD_CHECK_EQ(vd_ticks_per_frame(FPS_29_97), 4004);
  VD_CHECK_EQ(vd_ticks_per_frame(FPS_59_94), 2002);
}

static void test_rejects_inexact_rates(void) {
  VdRational seven = {7, 1};
  VdRational zero = {0, 1};
  VdRational negative = {-30, 1};
  VD_CHECK(!vd_timebase_divides(seven));
  VD_CHECK_EQ(vd_ticks_per_frame(seven), 0);
  VD_CHECK(!vd_timebase_divides(zero));
  VD_CHECK(!vd_timebase_divides(negative));
  VD_CHECK(vd_timebase_divides(FPS_29_97));
}

static void test_no_drift_over_an_hour(void) {
  // One hour of 29.97: walking frame by frame must equal multiplying.
  const int64_t frames = 107892;
  VdTick multiplied = vd_tick_of_frame(frames, FPS_29_97);
  VD_CHECK_EQ(multiplied, frames * 4004);
  VD_CHECK_EQ(vd_frame_of_tick(multiplied, FPS_29_97), frames);

  VdTick walked = 0;
  for (int64_t i = 0; i < frames; i++) walked += vd_ticks_per_frame(FPS_29_97);
  VD_CHECK_EQ(walked, multiplied);
}

static void test_frame_of_tick_floors(void) {
  VD_CHECK_EQ(vd_frame_of_tick(0, FPS_30), 0);
  VD_CHECK_EQ(vd_frame_of_tick(3999, FPS_30), 0);
  VD_CHECK_EQ(vd_frame_of_tick(4000, FPS_30), 1);
  VD_CHECK_EQ(vd_frame_of_tick(-1, FPS_30), -1);
  VD_CHECK_EQ(vd_frame_of_tick(-4000, FPS_30), -1);
  VD_CHECK_EQ(vd_frame_of_tick(-4001, FPS_30), -2);
}

static void test_nanos(void) {
  VD_CHECK_EQ(vd_ticks_from_nanos(1000000000LL), 120000);
  VD_CHECK_EQ(vd_nanos_from_ticks(120000), 1000000000LL);
  VD_CHECK_EQ(vd_ticks_from_nanos(0), 0);
  VD_CHECK_EQ(vd_ticks_from_nanos(-1000000000LL), -120000);

  // Ten hours must not overflow, and must round-trip.
  const int64_t ten_hours_ns = 36000LL * 1000000000LL;
  VdTick t = vd_ticks_from_nanos(ten_hours_ns);
  VD_CHECK_EQ(t, 36000LL * 120000LL);
  VD_CHECK_EQ(vd_nanos_from_ticks(t), ten_hours_ns);
}

static void test_stream_time(void) {
  VdRational tb90k = {1, 90000};
  VD_CHECK_EQ(vd_ticks_from_stream_time(90000, tb90k), 120000);
  VD_CHECK_EQ(vd_ticks_from_stream_time(45000, tb90k), 60000);
  VD_CHECK_EQ(vd_ticks_from_stream_time(0, tb90k), 0);
  VD_CHECK_EQ(vd_stream_time_from_ticks(120000, tb90k), 90000);

  // A round trip on a coarse timebase loses nothing that matters: 1/15360 is
  // 7.8 ticks per unit, and both directions round the same way.
  VdRational tb15360 = {1, 15360};
  for (int64_t pts = 0; pts < 1000; pts += 137) {
    VdTick ticks = vd_ticks_from_stream_time(pts, tb15360);
    VD_CHECK_EQ(vd_stream_time_from_ticks(ticks, tb15360), pts);
  }
}

static void test_scale_rounds_half_away_from_zero(void) {
  VD_CHECK_EQ(vd_scale(1, 1, 2), 1);
  VD_CHECK_EQ(vd_scale(-1, 1, 2), -1);
  VD_CHECK_EQ(vd_scale(1, 1, 3), 0);
  VD_CHECK_EQ(vd_scale(2, 1, 3), 1);
  VD_CHECK_EQ(vd_scale(10, 3, 1), 30);
  VD_CHECK_EQ(vd_scale(123, 0, 1), 0);
  VD_CHECK_EQ(vd_scale(5, 1, 0), 0);  // division by zero is 0, not a crash
}

int main(void) {
  test_ticks_per_frame();
  test_rejects_inexact_rates();
  test_no_drift_over_an_hour();
  test_frame_of_tick_floors();
  test_nanos();
  test_stream_time();
  test_scale_rounds_half_away_from_zero();
  return VD_REPORT();
}
