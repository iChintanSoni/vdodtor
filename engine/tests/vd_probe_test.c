// Probe fixtures live in engine/tests/media and are committed; regenerate them
// with media/generate.sh if the expectations here ever need to change.
#include "vd_check.h"
#include "vdodtor/vd_probe.h"

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

static void test_constant_rate_video_with_audio(void) {
  VdProbeInfo info;
  VD_CHECK_EQ(vd_probe_file(fixture("cfr_30fps_stereo.mp4"), &info), VD_OK);

  VD_CHECK(info.has_video);
  VD_CHECK(info.has_audio);
  VD_CHECK_EQ(info.width, 320);
  VD_CHECK_EQ(info.height, 240);
  VD_CHECK_EQ(info.frame_rate.num, 30);
  VD_CHECK_EQ(info.frame_rate.den, 1);
  VD_CHECK(!info.variable_frame_rate);
  VD_CHECK_EQ(info.rotation_degrees, 0);
  VD_CHECK_EQ(info.audio_channels, 2);
  VD_CHECK_EQ(info.audio_sample_rate, 48000);
  VD_CHECK_STR(info.video_codec, "h264");
  VD_CHECK_STR(info.audio_codec, "aac");
  VD_CHECK_EQ(info.pixel_aspect.num, 1);
  VD_CHECK_EQ(info.pixel_aspect.den, 1);

  // Two seconds, on the project timebase, exactly.
  VD_CHECK_EQ(info.duration, 2 * VD_TICKS_PER_SECOND);
}

static void test_rotation_is_clockwise_for_display(void) {
  VdProbeInfo info;
  VD_CHECK_EQ(vd_probe_file(fixture("rotated_cw90.mp4"), &info), VD_OK);
  VD_CHECK_EQ(info.rotation_degrees, 90);
  // Coded dimensions stay as coded; rotation is applied at display time.
  VD_CHECK_EQ(info.width, 320);
  VD_CHECK_EQ(info.height, 240);
}

static void test_audio_only(void) {
  VdProbeInfo info;
  VD_CHECK_EQ(vd_probe_file(fixture("audio_only.m4a"), &info), VD_OK);
  VD_CHECK(!info.has_video);
  VD_CHECK(info.has_audio);
  VD_CHECK_EQ(info.audio_channels, 1);
  VD_CHECK_EQ(info.audio_sample_rate, 44100);
  VD_CHECK_EQ(info.width, 0);
  VD_CHECK_EQ(info.height, 0);
  VD_CHECK_STR(info.video_codec, "");
  VD_CHECK_EQ(info.duration, 3 * VD_TICKS_PER_SECOND);
}

static void test_variable_frame_rate_is_detected(void) {
  VdProbeInfo info;
  VD_CHECK_EQ(vd_probe_file(fixture("vfr.mp4"), &info), VD_OK);
  VD_CHECK(info.has_video);
  VD_CHECK(info.variable_frame_rate);
}

static void test_failures_are_reported_not_guessed(void) {
  VdProbeInfo info;

  VD_CHECK_EQ(vd_probe_file(fixture("does_not_exist.mp4"), &info),
              VD_ERR_OPEN);
  VD_CHECK_EQ(vd_probe_file(fixture("not_media.txt"), &info), VD_ERR_OPEN);

  VD_CHECK_EQ(vd_probe_file(NULL, &info), VD_ERR_INVALID_ARG);
  VD_CHECK_EQ(vd_probe_file(fixture("cfr_30fps_stereo.mp4"), NULL),
              VD_ERR_INVALID_ARG);

  VD_CHECK_STR(vd_result_string(VD_OK), "ok");
  VD_CHECK(vd_result_string(VD_ERR_OPEN)[0] != '\0');
  VD_CHECK_STR(vd_result_string(12345), "unknown error");
}

static void test_output_is_zeroed_on_failure(void) {
  VdProbeInfo info;
  VD_CHECK_EQ(vd_probe_file(fixture("cfr_30fps_stereo.mp4"), &info), VD_OK);
  VD_CHECK(info.has_video);

  // Reusing the struct must not leave stale fields behind.
  VD_CHECK_EQ(vd_probe_file(fixture("does_not_exist.mp4"), &info),
              VD_ERR_OPEN);
  VD_CHECK(!info.has_video);
  VD_CHECK(!info.has_audio);
  VD_CHECK_EQ(info.width, 0);
  VD_CHECK_EQ(info.duration, 0);
}

static void test_probing_is_repeatable(void) {
  // Probing runs on every import; it must not leak or drift across calls.
  VdProbeInfo first, again;
  VD_CHECK_EQ(vd_probe_file(fixture("cfr_30fps_stereo.mp4"), &first), VD_OK);
  for (int i = 0; i < 50; i++) {
    VD_CHECK_EQ(vd_probe_file(fixture("cfr_30fps_stereo.mp4"), &again), VD_OK);
  }
  VD_CHECK_EQ(again.duration, first.duration);
  VD_CHECK_EQ(again.width, first.width);
  VD_CHECK_EQ(again.frame_rate.num, first.frame_rate.num);
}

int main(void) {
  test_constant_rate_video_with_audio();
  test_rotation_is_clockwise_for_display();
  test_audio_only();
  test_variable_frame_rate_is_detected();
  test_failures_are_reported_not_guessed();
  test_output_is_zeroed_on_failure();
  test_probing_is_repeatable();
  return VD_REPORT();
}
