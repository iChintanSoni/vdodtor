#include "vdodtor/vd_time.h"

static int64_t vd_gcd(int64_t a, int64_t b) {
  if (a < 0) a = -a;
  if (b < 0) b = -b;
  while (b != 0) {
    int64_t t = a % b;
    a = b;
    b = t;
  }
  return a == 0 ? 1 : a;
}

int64_t vd_scale(int64_t value, int64_t mul, int64_t div) {
  if (div == 0) return 0;
  int64_t g = vd_gcd(mul, div);
  int64_t m = mul / g;
  int64_t d = div / g;
  int64_t n = value * m;
  if (d == 1) return n;
  int64_t half = d / 2;
  return n >= 0 ? (n + half) / d : -((-n + half) / d);
}

bool vd_timebase_divides(VdRational fps) {
  if (fps.num <= 0 || fps.den <= 0) return false;
  return ((int64_t)VD_TICKS_PER_SECOND * fps.den) % fps.num == 0;
}

int64_t vd_ticks_per_frame(VdRational fps) {
  if (!vd_timebase_divides(fps)) return 0;
  return ((int64_t)VD_TICKS_PER_SECOND * fps.den) / fps.num;
}

VdTick vd_ticks_from_nanos(int64_t nanos) {
  return vd_scale(nanos, VD_TICKS_PER_SECOND, VD_NANOS_PER_SECOND);
}

int64_t vd_nanos_from_ticks(VdTick ticks) {
  return vd_scale(ticks, VD_NANOS_PER_SECOND, VD_TICKS_PER_SECOND);
}

VdTick vd_ticks_from_stream_time(int64_t pts, VdRational timebase) {
  if (timebase.den <= 0) return 0;
  return vd_scale(pts * timebase.num, VD_TICKS_PER_SECOND, timebase.den);
}

int64_t vd_stream_time_from_ticks(VdTick ticks, VdRational timebase) {
  if (timebase.num <= 0) return 0;
  return vd_scale(ticks, (int64_t)timebase.den,
                  (int64_t)VD_TICKS_PER_SECOND * timebase.num);
}

int64_t vd_frame_of_tick(VdTick t, VdRational fps) {
  int64_t per = vd_ticks_per_frame(fps);
  if (per <= 0) return 0;
  return t >= 0 ? t / per : -((-t + per - 1) / per);
}

VdTick vd_tick_of_frame(int64_t frame, VdRational fps) {
  return frame * vd_ticks_per_frame(fps);
}
