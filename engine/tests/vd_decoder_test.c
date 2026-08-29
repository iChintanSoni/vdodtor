// The decode session is addressed by time, so these tests are about time:
// does asking for tick T give back the frame that actually covers T, from any
// direction, without re-decoding what it already has.
#include "vd_check.h"
#include "vdodtor/vd_decoder.h"

#include <mach/mach.h>
#include <stdlib.h>

// Rotates through a few buffers, so building a timeline out of two fixture
// paths does not end up with both pointing at the same string.
static const char* fixture(const char* name) {
  static char paths[8][1024];
  static int next = 0;
  char* path = paths[next];
  next = (next + 1) % 8;
  snprintf(path, sizeof(paths[0]), "%s/%s", VD_TEST_MEDIA_DIR, name);
  return path;
}

// cfr_30fps_stereo.mp4 is 2 seconds of constant 30 fps.
#define TICKS_PER_FRAME 4000
#define FRAME_COUNT 60

static VdDecoder* open_fixture(const char* name, int hardware) {
  VdDecoderOptions options = vd_decoder_default_options();
  options.hardware = hardware;
  int32_t result = 999;
  VdDecoder* d = vd_decoder_open(fixture(name), options, &result);
  VD_CHECK_EQ(result, VD_OK);
  VD_CHECK(d != NULL);
  return d;
}

static void test_open_reports_what_probe_reports(void) {
  VdDecoder* d = open_fixture("cfr_30fps_stereo.mp4", 1);
  if (!d) return;

  VdProbeInfo info;
  VD_CHECK_EQ(vd_decoder_info(d, &info), VD_OK);
  VD_CHECK_EQ(info.width, 320);
  VD_CHECK_EQ(info.height, 240);
  VD_CHECK_EQ(info.duration, 2 * VD_TICKS_PER_SECOND);
  VD_CHECK(info.has_video);

  vd_decoder_close(d);
}

static void test_refuses_what_it_cannot_decode(void) {
  int32_t result = 999;
  VdDecoderOptions options = vd_decoder_default_options();

  VD_CHECK(vd_decoder_open(fixture("missing.mp4"), options, &result) == NULL);
  VD_CHECK_EQ(result, VD_ERR_OPEN);

  VD_CHECK(vd_decoder_open(fixture("not_media.txt"), options, &result) == NULL);
  VD_CHECK_EQ(result, VD_ERR_OPEN);

  // Audio-only has nothing for a video decoder to do, and saying so is better
  // than handing back a decoder that never produces a frame.
  VD_CHECK(vd_decoder_open(fixture("audio_only.m4a"), options, &result) == NULL);
  VD_CHECK_EQ(result, VD_ERR_UNSUPPORTED);

  VD_CHECK(vd_decoder_open(NULL, options, &result) == NULL);
  VD_CHECK_EQ(result, VD_ERR_INVALID_ARG);

  // A NULL out_result must not crash.
  VD_CHECK(vd_decoder_open(fixture("missing.mp4"), options, NULL) == NULL);
}

static void test_first_frame(void) {
  VdDecoder* d = open_fixture("cfr_30fps_stereo.mp4", 1);
  if (!d) return;

  VdFrame frame;
  VD_CHECK_EQ(vd_decoder_frame_at(d, 0, &frame), VD_OK);
  VD_CHECK_EQ(frame.pts, 0);
  VD_CHECK_EQ(frame.duration, TICKS_PER_FRAME);
  VD_CHECK_EQ(frame.width, 320);
  VD_CHECK_EQ(frame.height, 240);
  VD_CHECK(frame.pixel_buffer != NULL);
  VD_CHECK(frame.hardware);
  VD_CHECK_EQ(frame.format, VD_PIXEL_NV12);
  vd_frame_release(&frame);

  VD_CHECK(frame.pixel_buffer == NULL);
  vd_frame_release(&frame);  // releasing twice is harmless
  vd_frame_release(NULL);

  vd_decoder_close(d);
}

static void test_every_frame_in_order(void) {
  VdDecoder* d = open_fixture("cfr_30fps_stereo.mp4", 1);
  if (!d) return;

  for (int i = 0; i < FRAME_COUNT; i++) {
    VdFrame frame;
    VdTick want = (VdTick)i * TICKS_PER_FRAME;
    VD_CHECK_EQ(vd_decoder_frame_at(d, want, &frame), VD_OK);
    VD_CHECK_EQ(frame.pts, want);
    VD_CHECK(frame.pixel_buffer != NULL);
    vd_frame_release(&frame);
  }

  // Playing straight through must never seek: one seek to position at the
  // start is all this should have cost.
  VdDecoderStats stats;
  vd_decoder_stats(d, &stats);
  VD_CHECK(stats.seeks <= 1);
  VD_CHECK_EQ(stats.decode_errors, 0);

  vd_decoder_close(d);
}

static void test_a_time_inside_a_frame_returns_that_frame(void) {
  VdDecoder* d = open_fixture("cfr_30fps_stereo.mp4", 1);
  if (!d) return;

  // Frame 10 covers [40000, 44000).
  const VdTick base = 10 * TICKS_PER_FRAME;
  const VdTick probes[] = {base, base + 1, base + TICKS_PER_FRAME / 2,
                           base + TICKS_PER_FRAME - 1};
  for (size_t i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
    VdFrame frame;
    VD_CHECK_EQ(vd_decoder_frame_at(d, probes[i], &frame), VD_OK);
    VD_CHECK_EQ(frame.pts, base);
    vd_frame_release(&frame);
  }

  // One tick later is the next frame, not this one.
  VdFrame next;
  VD_CHECK_EQ(vd_decoder_frame_at(d, base + TICKS_PER_FRAME, &next), VD_OK);
  VD_CHECK_EQ(next.pts, base + TICKS_PER_FRAME);
  vd_frame_release(&next);

  vd_decoder_close(d);
}

static void test_clamps_at_both_ends(void) {
  VdDecoder* d = open_fixture("cfr_30fps_stereo.mp4", 1);
  if (!d) return;

  VdFrame before;
  VD_CHECK_EQ(vd_decoder_frame_at(d, -50000, &before), VD_OK);
  VD_CHECK_EQ(before.pts, 0);
  vd_frame_release(&before);

  // A clip trimmed a hair past its source must show the last frame, not fail.
  VdFrame after;
  VD_CHECK_EQ(vd_decoder_frame_at(d, 10 * VD_TICKS_PER_SECOND, &after), VD_OK);
  VD_CHECK_EQ(after.pts, (VdTick)(FRAME_COUNT - 1) * TICKS_PER_FRAME);
  VD_CHECK(after.pixel_buffer != NULL);
  vd_frame_release(&after);

  vd_decoder_close(d);
}

static void test_seeking_backwards(void) {
  VdDecoder* d = open_fixture("cfr_30fps_stereo.mp4", 1);
  if (!d) return;

  const VdTick order[] = {
      50 * TICKS_PER_FRAME, 0, 59 * TICKS_PER_FRAME, 30 * TICKS_PER_FRAME,
      1 * TICKS_PER_FRAME,  45 * TICKS_PER_FRAME, 0,
  };
  for (size_t i = 0; i < sizeof(order) / sizeof(order[0]); i++) {
    VdFrame frame;
    VD_CHECK_EQ(vd_decoder_frame_at(d, order[i], &frame), VD_OK);
    VD_CHECK_EQ(frame.pts, order[i]);
    vd_frame_release(&frame);
  }

  VdDecoderStats stats;
  vd_decoder_stats(d, &stats);
  VD_CHECK_EQ(stats.decode_errors, 0);

  vd_decoder_close(d);
}

static void test_repeated_asks_come_from_the_cache(void) {
  VdDecoder* d = open_fixture("cfr_30fps_stereo.mp4", 1);
  if (!d) return;

  VdFrame frame;
  VD_CHECK_EQ(vd_decoder_frame_at(d, 20 * TICKS_PER_FRAME, &frame), VD_OK);
  vd_frame_release(&frame);

  vd_decoder_reset_stats(d);
  for (int i = 0; i < 20; i++) {
    VD_CHECK_EQ(vd_decoder_frame_at(d, 20 * TICKS_PER_FRAME, &frame), VD_OK);
    VD_CHECK_EQ(frame.pts, 20 * TICKS_PER_FRAME);
    vd_frame_release(&frame);
  }

  VdDecoderStats stats;
  vd_decoder_stats(d, &stats);
  VD_CHECK_EQ(stats.cache_hits, 20);
  VD_CHECK_EQ(stats.cache_misses, 0);
  VD_CHECK_EQ(stats.frames_decoded, 0);
  VD_CHECK_EQ(stats.seeks, 0);

  vd_decoder_close(d);
}

static void test_jogging_back_and_forth_does_not_re_decode(void) {
  VdDecoder* d = open_fixture("cfr_30fps_stereo.mp4", 1);
  if (!d) return;

  // Warm a run of frames, then jog over them the way a scrub does.
  for (int i = 20; i < 28; i++) {
    VdFrame frame;
    VD_CHECK_EQ(vd_decoder_frame_at(d, (VdTick)i * TICKS_PER_FRAME, &frame),
                VD_OK);
    vd_frame_release(&frame);
  }

  vd_decoder_reset_stats(d);
  for (int pass = 0; pass < 4; pass++) {
    for (int i = 27; i >= 20; i--) {
      VdFrame frame;
      VD_CHECK_EQ(vd_decoder_frame_at(d, (VdTick)i * TICKS_PER_FRAME, &frame),
                  VD_OK);
      VD_CHECK_EQ(frame.pts, (VdTick)i * TICKS_PER_FRAME);
      vd_frame_release(&frame);
    }
  }

  VdDecoderStats stats;
  vd_decoder_stats(d, &stats);
  VD_CHECK_EQ(stats.seeks, 0);
  VD_CHECK_EQ(stats.frames_decoded, 0);
  VD_CHECK_EQ(stats.cache_hits, 32);

  vd_decoder_close(d);
}

static void test_cache_is_bounded(void) {
  VdDecoderOptions options = vd_decoder_default_options();
  options.cache_capacity = 4;
  int32_t result = 0;
  VdDecoder* d =
      vd_decoder_open(fixture("cfr_30fps_stereo.mp4"), options, &result);
  VD_CHECK(d != NULL);
  if (!d) return;

  for (int i = 0; i < 40; i++) {
    VdFrame frame;
    VD_CHECK_EQ(vd_decoder_frame_at(d, (VdTick)i * TICKS_PER_FRAME, &frame),
                VD_OK);
    vd_frame_release(&frame);
  }

  // The oldest frames have been evicted, so going back to the start is a miss
  // again rather than a hit that a too-large cache would have faked.
  vd_decoder_reset_stats(d);
  VdFrame frame;
  VD_CHECK_EQ(vd_decoder_frame_at(d, 0, &frame), VD_OK);
  VD_CHECK_EQ(frame.pts, 0);
  vd_frame_release(&frame);

  VdDecoderStats stats;
  vd_decoder_stats(d, &stats);
  VD_CHECK_EQ(stats.cache_misses, 1);

  vd_decoder_close(d);
}

static void test_keyframe_index(void) {
  VdDecoder* d = open_fixture("cfr_30fps_stereo.mp4", 1);
  if (!d) return;

  int32_t count = vd_decoder_keyframe_count(d);
  VD_CHECK(count > 0);

  // The first keyframe is the start of the file, and the answer never runs
  // ahead of what was asked for.
  VD_CHECK_EQ(vd_decoder_keyframe_at_or_before(d, 0), 0);
  for (VdTick t = 0; t < 2 * VD_TICKS_PER_SECOND; t += TICKS_PER_FRAME) {
    VdTick kf = vd_decoder_keyframe_at_or_before(d, t);
    VD_CHECK(kf <= t);
  }
  // Monotone: a later time never gives an earlier keyframe.
  VdTick previous = -1;
  for (VdTick t = 0; t < 2 * VD_TICKS_PER_SECOND; t += TICKS_PER_FRAME) {
    VdTick kf = vd_decoder_keyframe_at_or_before(d, t);
    VD_CHECK(kf >= previous);
    previous = kf;
  }

  VD_CHECK_EQ(vd_decoder_keyframe_count(NULL), 0);
  VD_CHECK_EQ(vd_decoder_keyframe_at_or_before(NULL, 0), 0);

  vd_decoder_close(d);
}

static void test_software_path_agrees_with_hardware(void) {
  VdDecoder* hw = open_fixture("cfr_30fps_stereo.mp4", 1);
  VdDecoder* sw = open_fixture("cfr_30fps_stereo.mp4", 0);
  if (!hw || !sw) return;

  for (int i = 0; i < FRAME_COUNT; i += 7) {
    VdFrame a, b;
    VdTick want = (VdTick)i * TICKS_PER_FRAME;
    VD_CHECK_EQ(vd_decoder_frame_at(hw, want, &a), VD_OK);
    VD_CHECK_EQ(vd_decoder_frame_at(sw, want, &b), VD_OK);

    // Same timeline answer from both, whatever the pixels are wrapped in.
    VD_CHECK_EQ(a.pts, b.pts);
    VD_CHECK_EQ(a.duration, b.duration);
    VD_CHECK_EQ(a.width, b.width);
    VD_CHECK_EQ(a.height, b.height);

    VD_CHECK(b.pixel_buffer != NULL);
    VD_CHECK(!b.hardware);
    VD_CHECK_EQ(b.format, VD_PIXEL_YUV420P);

    vd_frame_release(&a);
    vd_frame_release(&b);
  }

  vd_decoder_close(hw);
  vd_decoder_close(sw);
}

static void test_variable_frame_rate_source(void) {
  VdDecoder* d = open_fixture("vfr.mp4", 1);
  if (!d) return;

  // Frames do not land on a fixed cadence, but every time still resolves to
  // exactly one frame, and asking in order never goes backwards.
  VdTick previous = -1;
  for (VdTick t = 0; t < VD_TICKS_PER_SECOND; t += VD_TICKS_PER_SECOND / 60) {
    VdFrame frame;
    VD_CHECK_EQ(vd_decoder_frame_at(d, t, &frame), VD_OK);
    VD_CHECK(frame.pts <= t);
    VD_CHECK(frame.pts + frame.duration > t);
    VD_CHECK(frame.pts >= previous);
    previous = frame.pts;
    vd_frame_release(&frame);
  }

  vd_decoder_close(d);
}

static void test_rotated_source_reports_coded_size(void) {
  VdDecoder* d = open_fixture("rotated_cw90.mp4", 1);
  if (!d) return;

  VdProbeInfo info;
  vd_decoder_info(d, &info);
  VD_CHECK_EQ(info.rotation_degrees, 90);

  // Rotation is a display transform; the decoder hands back coded pixels and
  // lets the compositor turn them.
  VdFrame frame;
  VD_CHECK_EQ(vd_decoder_frame_at(d, 0, &frame), VD_OK);
  VD_CHECK_EQ(frame.width, 320);
  VD_CHECK_EQ(frame.height, 240);
  vd_frame_release(&frame);

  vd_decoder_close(d);
}

static size_t resident_bytes(void) {
  mach_task_basic_info_data_t info;
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info,
                &count) != KERN_SUCCESS) {
    return 0;
  }
  return (size_t)info.resident_size;
}

// The S1 spike's use-after-free showed up as gradual decay rather than a
// crash, so a long scrub with a fixed-size cache is worth watching directly.
static void test_a_long_scrub_does_not_grow(void) {
  VdDecoder* d = open_fixture("cfr_30fps_stereo.mp4", 1);
  if (!d) return;

  unsigned seed = 12345;
  for (int i = 0; i < 200; i++) {  // settle the allocator first
    VdFrame frame;
    seed = seed * 1103515245u + 12345u;
    VdTick t = (VdTick)((seed >> 16) % (2 * VD_TICKS_PER_SECOND));
    VD_CHECK_EQ(vd_decoder_frame_at(d, t, &frame), VD_OK);
    vd_frame_release(&frame);
  }

  size_t before = resident_bytes();
  for (int i = 0; i < 2000; i++) {
    VdFrame frame;
    seed = seed * 1103515245u + 12345u;
    VdTick t = (VdTick)((seed >> 16) % (2 * VD_TICKS_PER_SECOND));
    if (vd_decoder_frame_at(d, t, &frame) == VD_OK) vd_frame_release(&frame);
  }
  size_t after = resident_bytes();

  VdDecoderStats stats;
  vd_decoder_stats(d, &stats);
  VD_CHECK_EQ(stats.decode_errors, 0);

  // Leaking one 320x240 frame per call would be ~230 MB over 2000 calls. The
  // cache itself is 32 frames, so anything past 64 MB of growth is a leak.
  if (before > 0 && after > before) {
    size_t growth = after - before;
    VD_CHECK(growth < 64u * 1024u * 1024u);
    if (growth >= 64u * 1024u * 1024u) {
      fprintf(stderr, "  resident grew by %zu bytes over 2000 scrubs\n", growth);
    }
  }

  vd_decoder_close(d);
}

static void test_many_open_close_cycles(void) {
  // Opening a decoder per clip is the expected pattern, so the lifecycle has
  // to survive being exercised hard.
  for (int i = 0; i < 50; i++) {
    VdDecoder* d = open_fixture("cfr_30fps_stereo.mp4", 1);
    if (!d) return;
    VdFrame frame;
    VD_CHECK_EQ(vd_decoder_frame_at(d, 15 * TICKS_PER_FRAME, &frame), VD_OK);
    vd_frame_release(&frame);
    vd_decoder_close(d);
  }
  vd_decoder_close(NULL);  // harmless
}

int main(void) {
  test_open_reports_what_probe_reports();
  test_refuses_what_it_cannot_decode();
  test_first_frame();
  test_every_frame_in_order();
  test_a_time_inside_a_frame_returns_that_frame();
  test_clamps_at_both_ends();
  test_seeking_backwards();
  test_repeated_asks_come_from_the_cache();
  test_jogging_back_and_forth_does_not_re_decode();
  test_cache_is_bounded();
  test_keyframe_index();
  test_software_path_agrees_with_hardware();
  test_variable_frame_rate_source();
  test_rotated_source_reports_coded_size();
  test_a_long_scrub_does_not_grow();
  test_many_open_close_cycles();
  return VD_REPORT();
}
