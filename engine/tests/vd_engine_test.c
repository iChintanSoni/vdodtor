// Transport: the clock, the timeline, and the thread. What matters here is
// that a position maps to the right pixels, that play and pause and seek do
// what they say, and that tearing the engine down mid-playback is safe — the
// S1 spike's teardown bug presented as gradual decay rather than a crash,
// which is exactly the kind of thing that survives a casual test.
#include "vd_check.h"
#include "vdodtor/vd_engine.h"

#include <CoreVideo/CoreVideo.h>
#include <pthread.h>

#include "vdodtor/vd_audio.h"
#include <stdlib.h>
#include <unistd.h>

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

#define SECOND VD_TICKS_PER_SECOND
#define TOLERANCE 8

// The two flat-colour fixtures, as ffmpeg decodes them.
static const int GREEN[3] = {0, 200, 100};   // solid_sd_601.mp4
static const int ORANGE[3] = {200, 100, 0};  // solid_sd_orange.mp4
static const int BLACK[3] = {0, 0, 0};

static void sleep_ms(int ms) { usleep((useconds_t)ms * 1000); }

// No output device: ctest must not make a noise, and the audio path is
// exercised by pulling the renderer directly.
static VdEngine* make_engine(void) {
  VdEngineOptions options = vd_engine_default_options();
  options.audio_output = 0;
  return vd_engine_create_with_options(options, NULL);
}

static bool near_enough(int a, int b) {
  int d = a - b;
  return (d < 0 ? -d : d) <= TOLERANCE;
}

static void check_frame_is(VdEngine* e, const int rgb[3], const char* what) {
  void* buffer = vd_engine_copy_output(e);
  vd_checks++;
  if (!buffer) {
    vd_failures++;
    fprintf(stderr, "FAIL %s: no output frame\n", what);
    return;
  }
  CVPixelBufferRef pixels = (CVPixelBufferRef)buffer;
  CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
  const uint8_t* base = (const uint8_t*)CVPixelBufferGetBaseAddress(pixels);
  const size_t stride = CVPixelBufferGetBytesPerRow(pixels);
  const size_t x = CVPixelBufferGetWidth(pixels) / 2;
  const size_t y = CVPixelBufferGetHeight(pixels) / 2;
  const uint8_t* px = base + y * stride + x * 4;  // BGRA
  const int b = px[0], g = px[1], r = px[2];
  CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
  CVPixelBufferRelease(pixels);

  if (!near_enough(r, rgb[0]) || !near_enough(g, rgb[1]) ||
      !near_enough(b, rgb[2])) {
    vd_failures++;
    fprintf(stderr,
            "FAIL %s\n  expected RGB (%d, %d, %d)\n  actual   RGB (%d, %d, %d)\n",
            what, rgb[0], rgb[1], rgb[2], r, g, b);
  }
}

// Green for the first second, orange for the second. One track, no gaps.
static VdTimeline two_clip_timeline(VdTimelineClip* clips) {
  clips[0] = vd_timeline_clip_default();
  clips[0].path = fixture("solid_sd_601.mp4");
  clips[0].start = 0;
  clips[0].duration = SECOND;

  clips[1] = vd_timeline_clip_default();
  clips[1].path = fixture("solid_sd_orange.mp4");
  clips[1].start = SECOND;
  clips[1].duration = SECOND;

  VdTimeline timeline;
  memset(&timeline, 0, sizeof(timeline));
  timeline.width = 320;
  timeline.height = 240;
  timeline.frame_rate = (VdRational){30, 1};
  timeline.clips = clips;
  timeline.clip_count = 2;
  return timeline;
}

static void test_lifecycle(void) {
  int32_t result = 999;
  VdEngine* e = vd_engine_create(&result);
  VD_CHECK_EQ(result, VD_OK);
  VD_CHECK(e != NULL);
  if (!e) return;

  VD_CHECK_EQ(vd_engine_state(e), VD_STATE_IDLE);
  VD_CHECK_EQ(vd_engine_position(e), 0);
  VD_CHECK_EQ(vd_engine_duration(e), 0);
  VD_CHECK(vd_engine_copy_output(e) == NULL);
  // Nothing to render before a timeline exists, and saying so beats crashing.
  VD_CHECK_EQ(vd_engine_render_now(e), VD_ERR_UNSUPPORTED);

  vd_engine_destroy(e);
  vd_engine_destroy(NULL);

  VD_CHECK_EQ(vd_engine_state(NULL), VD_STATE_IDLE);
  VD_CHECK_EQ(vd_engine_position(NULL), 0);
  VD_CHECK(vd_engine_copy_output(NULL) == NULL);
}

static void test_rejects_a_bad_timeline(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clips[2];
  VdTimeline timeline = two_clip_timeline(clips);

  VD_CHECK_EQ(vd_engine_set_timeline(e, NULL), VD_ERR_INVALID_ARG);
  VD_CHECK_EQ(vd_engine_set_timeline(NULL, &timeline), VD_ERR_INVALID_ARG);

  VdTimeline bad = timeline;
  bad.width = 0;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &bad), VD_ERR_INVALID_ARG);
  bad = timeline;
  bad.clip_count = 3;
  bad.clips = NULL;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &bad), VD_ERR_INVALID_ARG);

  vd_engine_destroy(e);
}

static void test_position_selects_the_clip(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clips[2];
  VdTimeline timeline = two_clip_timeline(clips);
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  VD_CHECK_EQ(vd_engine_duration(e), 2 * SECOND);

  // Which clip is on screen is answered in pixels, not in indices.
  vd_engine_seek(e, 0);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, GREEN, "start of the first clip");

  vd_engine_seek(e, SECOND / 2);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, GREEN, "middle of the first clip");

  // The cut is exact: the last tick before it is still the first clip.
  vd_engine_seek(e, SECOND - 1);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, GREEN, "one tick before the cut");

  vd_engine_seek(e, SECOND);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, ORANGE, "the cut");

  vd_engine_seek(e, 2 * SECOND - 1);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, ORANGE, "end of the second clip");

  vd_engine_destroy(e);
}

static void test_a_gap_renders_black(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clips[2];
  VdTimeline timeline = two_clip_timeline(clips);
  // Push the second clip out, leaving a second of nothing between them.
  clips[1].start = 2 * SECOND;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  VD_CHECK_EQ(vd_engine_duration(e), 3 * SECOND);

  vd_engine_seek(e, SECOND + SECOND / 2);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, BLACK, "a gap in the timeline");

  vd_engine_destroy(e);
}

static void test_seek_clamps(void) {
  VdEngine* e = make_engine();
  if (!e) return;
  VdTimelineClip clips[2];
  VdTimeline timeline = two_clip_timeline(clips);
  vd_engine_set_timeline(e, &timeline);

  vd_engine_seek(e, -5 * SECOND);
  VD_CHECK_EQ(vd_engine_position(e), 0);

  vd_engine_seek(e, 99 * SECOND);
  VD_CHECK_EQ(vd_engine_position(e), 2 * SECOND);

  // Seeking out of idle leaves the engine paused, not playing.
  VD_CHECK_EQ(vd_engine_state(e), VD_STATE_PAUSED);
  vd_engine_seek(NULL, 0);

  vd_engine_destroy(e);
}

static void test_play_advances_and_ends(void) {
  VdEngine* e = make_engine();
  if (!e) return;
  VdTimelineClip clips[2];
  VdTimeline timeline = two_clip_timeline(clips);
  vd_engine_set_timeline(e, &timeline);

  vd_engine_seek(e, 0);
  vd_engine_play(e);
  VD_CHECK_EQ(vd_engine_state(e), VD_STATE_PLAYING);

  sleep_ms(300);
  const VdTick moved = vd_engine_position(e);
  VD_CHECK(moved > 0);
  // The clock is real time, so a third of a second of wall clock is a third of
  // a second of media, within scheduling slop.
  VD_CHECK(moved > SECOND / 5);
  VD_CHECK(moved < SECOND);

  // Playing across the cut shows the second clip without being told to.
  sleep_ms(900);
  check_frame_is(e, ORANGE, "playing past the cut");

  // And it stops at the end rather than running off it.
  sleep_ms(1000);
  VD_CHECK_EQ(vd_engine_state(e), VD_STATE_ENDED);
  VD_CHECK_EQ(vd_engine_position(e), 2 * SECOND);

  VdEngineStats stats;
  vd_engine_stats(e, &stats);
  VD_CHECK(stats.frames_presented > 30);
  VD_CHECK(stats.composite_ms_avg >= 0.0);
  VD_CHECK(stats.composite_ms_avg < 100.0);

  vd_engine_destroy(e);
}

static void test_pause_freezes_the_clock(void) {
  VdEngine* e = make_engine();
  if (!e) return;
  VdTimelineClip clips[2];
  VdTimeline timeline = two_clip_timeline(clips);
  vd_engine_set_timeline(e, &timeline);

  vd_engine_seek(e, 0);
  vd_engine_play(e);
  sleep_ms(200);
  vd_engine_pause(e);
  VD_CHECK_EQ(vd_engine_state(e), VD_STATE_PAUSED);

  const VdTick at_pause = vd_engine_position(e);
  sleep_ms(250);
  VD_CHECK_EQ(vd_engine_position(e), at_pause);

  // Resuming picks up where it stopped rather than restarting.
  vd_engine_play(e);
  sleep_ms(150);
  VD_CHECK(vd_engine_position(e) > at_pause);
  vd_engine_pause(e);
  vd_engine_pause(e);  // idempotent

  vd_engine_destroy(e);
}

static void test_play_from_the_end_restarts(void) {
  VdEngine* e = make_engine();
  if (!e) return;
  VdTimelineClip clips[2];
  VdTimeline timeline = two_clip_timeline(clips);
  vd_engine_set_timeline(e, &timeline);

  vd_engine_seek(e, 2 * SECOND);
  vd_engine_play(e);
  sleep_ms(120);
  // Pressing play on a finished clip plays it again from the top.
  VD_CHECK(vd_engine_position(e) < SECOND);
  vd_engine_pause(e);

  vd_engine_destroy(e);
}

static int g_callback_count = 0;
static void count_frames(void* context) {
  (void)context;
  g_callback_count++;
}

static void test_frame_callback(void) {
  VdEngine* e = make_engine();
  if (!e) return;
  VdTimelineClip clips[2];
  VdTimeline timeline = two_clip_timeline(clips);

  g_callback_count = 0;
  vd_engine_set_frame_callback(e, count_frames, NULL);
  vd_engine_set_timeline(e, &timeline);

  vd_engine_seek(e, 0);
  vd_engine_render_now(e);
  VD_CHECK(g_callback_count > 0);

  const int before = g_callback_count;
  vd_engine_play(e);
  sleep_ms(300);
  vd_engine_pause(e);
  // Playing publishes frames, and each one is announced.
  VD_CHECK(g_callback_count > before);

  vd_engine_set_frame_callback(e, NULL, NULL);
  vd_engine_set_frame_callback(NULL, count_frames, NULL);
  vd_engine_destroy(e);
}

static void test_editing_the_timeline_keeps_decoders(void) {
  VdEngine* e = make_engine();
  if (!e) return;
  VdTimelineClip clips[2];
  VdTimeline timeline = two_clip_timeline(clips);
  vd_engine_set_timeline(e, &timeline);

  vd_engine_seek(e, 0);
  vd_engine_render_now(e);
  vd_engine_seek(e, SECOND);
  vd_engine_render_now(e);

  VdEngineStats before;
  vd_engine_stats(e, &before);
  VD_CHECK_EQ(before.open_decoders, 2);

  // Nudging a clip is the commonest edit there is. It must not throw away the
  // decoders and stutter the preview.
  clips[1].start = SECOND + SECOND / 4;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  VdEngineStats after;
  vd_engine_stats(e, &after);
  VD_CHECK_EQ(after.open_decoders, 2);
  VD_CHECK_EQ(vd_engine_duration(e), 2 * SECOND + SECOND / 4);

  vd_engine_destroy(e);
}

static void test_a_missing_source_is_a_gap_not_a_stall(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clips[2];
  VdTimeline timeline = two_clip_timeline(clips);
  clips[0].path = fixture("deleted_by_the_user.mp4");
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  vd_engine_seek(e, SECOND / 2);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, BLACK, "a source that is no longer there");

  // The rest of the timeline still plays.
  vd_engine_seek(e, SECOND + SECOND / 2);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, ORANGE, "the clip after a missing one");

  vd_engine_destroy(e);
}

static void test_an_empty_timeline_renders_black(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimeline timeline;
  memset(&timeline, 0, sizeof(timeline));
  timeline.width = 160;
  timeline.height = 120;
  timeline.frame_rate = (VdRational){30, 1};
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  VD_CHECK_EQ(vd_engine_duration(e), 0);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, BLACK, "an empty project");

  vd_engine_destroy(e);
}

static void test_scrubbing_stays_correct(void) {
  VdEngine* e = make_engine();
  if (!e) return;
  VdTimelineClip clips[2];
  VdTimeline timeline = two_clip_timeline(clips);
  vd_engine_set_timeline(e, &timeline);

  // Jump around the way a hand on a timeline does, and check every landing.
  unsigned seed = 99;
  for (int i = 0; i < 60; i++) {
    seed = seed * 1103515245u + 12345u;
    const VdTick t = (VdTick)((seed >> 16) % (2 * SECOND));
    vd_engine_seek(e, t);
    VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
    check_frame_is(e, t < SECOND ? GREEN : ORANGE, "scrub landing");
  }

  VdEngineStats stats;
  vd_engine_stats(e, &stats);
  VD_CHECK(stats.last_seek_ms >= 0.0);
  // The M0 spike measured 9-15 ms scrub latency; anything near a second means
  // something has gone badly wrong.
  VD_CHECK(stats.last_seek_ms < 500.0);

  vd_engine_destroy(e);
}

// The one the spike got wrong. Destroying mid-playback must join the render
// thread and drain the GPU before anything is freed.
static void test_destroy_while_playing(void) {
  for (int i = 0; i < 12; i++) {
    VdEngine* e = make_engine();
    if (!e) return;
    VdTimelineClip clips[2];
    VdTimeline timeline = two_clip_timeline(clips);
    vd_engine_set_timeline(e, &timeline);
    vd_engine_set_frame_callback(e, count_frames, NULL);

    vd_engine_seek(e, 0);
    vd_engine_play(e);
    sleep_ms(i * 7);  // tear down at a different point each time
    vd_engine_destroy(e);
  }
  VD_CHECK(true);  // reaching here without a crash or a hang is the assertion
}

static void test_seek_storm_while_playing(void) {
  VdEngine* e = make_engine();
  if (!e) return;
  VdTimelineClip clips[2];
  VdTimeline timeline = two_clip_timeline(clips);
  vd_engine_set_timeline(e, &timeline);

  vd_engine_play(e);
  for (int i = 0; i < 200; i++) {
    vd_engine_seek(e, (VdTick)((i * 9973) % (2 * SECOND)));
  }
  vd_engine_pause(e);

  VdEngineStats stats;
  vd_engine_stats(e, &stats);
  VD_CHECK(stats.position >= 0);
  VD_CHECK(stats.position <= 2 * SECOND);

  vd_engine_destroy(e);
}

static void test_png_dump(void) {
  VdEngine* e = make_engine();
  if (!e) return;
  VdTimelineClip clips[2];
  VdTimeline timeline = two_clip_timeline(clips);
  vd_engine_set_timeline(e, &timeline);
  vd_engine_seek(e, 0);
  vd_engine_render_now(e);

  const char* path = "/tmp/vd_engine_test.png";
  VD_CHECK_EQ(vd_engine_dump_png(e, path), VD_OK);
  FILE* f = fopen(path, "rb");
  VD_CHECK(f != NULL);
  if (f) {
    fclose(f);
    remove(path);
  }
  VD_CHECK_EQ(vd_engine_dump_png(e, NULL), VD_ERR_INVALID_ARG);
  VD_CHECK_EQ(vd_engine_dump_png(NULL, path), VD_ERR_INVALID_ARG);

  vd_engine_destroy(e);
}

// --- A/V sync --------------------------------------------------------------

typedef struct {
  VdAudioRenderer* renderer;
  int32_t frames;
  volatile bool stop;
} PullJob;

// Drains the renderer as fast as it can. Deliberately *not* at real time:
// that is what separates "the engine follows audio" from "the engine follows
// the wall clock and audio happens to agree".
static void* pull_thread(void* arg) {
  PullJob* job = (PullJob*)arg;
  float buffer[512 * VD_AUDIO_CHANNELS];
  while (!job->stop && job->frames > 0) {
    const int32_t want = job->frames < 512 ? job->frames : 512;
    vd_audio_renderer_pull(job->renderer, buffer, want);
    job->frames -= want;
    usleep(200);
  }
  return NULL;
}

// A music bed: sound on the timeline that carries no picture at all.
//
// This is the shape the whole audio-lane feature rests on, and until the
// levels work nothing of the kind ever reached the engine — the render list
// was built from visual tracks only, so anything on an audio lane was silent
// no matter what was on it.
static void test_a_clip_with_no_picture_still_makes_a_sound(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clips[2];
  clips[0] = vd_timeline_clip_default();
  clips[0].path = fixture("solid_sd_601.mp4");  // silent, and all picture
  clips[0].start = 0;
  clips[0].duration = 2 * SECOND;

  clips[1] = vd_timeline_clip_default();
  clips[1].path = fixture("audio_only.m4a");  // 220 Hz, and all sound
  clips[1].start = 0;
  clips[1].duration = 2 * SECOND;
  clips[1].track = 1;
  clips[1].has_video = false;

  VdTimeline timeline;
  memset(&timeline, 0, sizeof(timeline));
  timeline.width = 320;
  timeline.height = 240;
  timeline.frame_rate = (VdRational){30, 1};
  timeline.clips = clips;
  timeline.clip_count = 2;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  VdEngineStats stats;
  vd_engine_stats(e, &stats);
  VD_CHECK(stats.audio_available);

  vd_engine_seek(e, 0);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  vd_engine_stats(e, &stats);
  // One layer, not two. The music has no picture and must not cost a decoder
  // or a layer slot to establish that.
  VD_CHECK_EQ(stats.active_layers, 1);

  vd_engine_play(e);
  PullJob job = {
      .renderer = vd_engine_audio_renderer(e),
      .frames = VD_AUDIO_SAMPLE_RATE / 2,
      .stop = false,
  };
  pthread_t thread;
  pthread_create(&thread, NULL, pull_thread, &job);
  pthread_join(thread, NULL);

  // And the sound came out: half a second of audio moved the playhead, which
  // only an audio clock that has something to count can do.
  VD_CHECK(vd_engine_position(e) > SECOND / 4);

  vd_engine_pause(e);
  vd_engine_destroy(e);
}

static void test_audio_is_the_master_clock(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clip = vd_timeline_clip_default();
  clip.path = fixture("cfr_30fps_stereo.mp4");  // the fixture with sound
  clip.start = 0;
  clip.duration = 10 * SECOND;  // longer than the file, so it cannot end early

  VdTimeline timeline;
  memset(&timeline, 0, sizeof(timeline));
  timeline.width = 320;
  timeline.height = 240;
  timeline.frame_rate = (VdRational){30, 1};
  timeline.clips = &clip;
  timeline.clip_count = 1;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  VdEngineStats stats;
  vd_engine_stats(e, &stats);
  VD_CHECK(stats.audio_available);

  vd_engine_seek(e, 0);
  vd_engine_play(e);

  // Pull two seconds of audio in far less than two seconds of wall time.
  PullJob job = {
      .renderer = vd_engine_audio_renderer(e),
      .frames = VD_AUDIO_SAMPLE_RATE * 2,
      .stop = false,
  };
  pthread_t thread;
  pthread_create(&thread, NULL, pull_thread, &job);
  pthread_join(thread, NULL);

  const VdTick position = vd_engine_position(e);
  // Two seconds of audio consumed is two seconds of timeline, however long it
  // took in wall time. If the wall clock were still in charge this would read
  // a fraction of a second.
  VD_CHECK(position > SECOND + SECOND / 2);
  VD_CHECK(position < 3 * SECOND);
  if (position <= SECOND + SECOND / 2 || position >= 3 * SECOND) {
    fprintf(stderr,
            "  after 2 s of audio the playhead is at %lld ticks, expected ~%d\n",
            (long long)position, 2 * SECOND);
  }

  vd_engine_pause(e);
  vd_engine_destroy(e);
}

static void test_a_silent_timeline_uses_the_wall_clock(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  // solid_sd_601 and solid_sd_orange are both encoded -an.
  VdTimelineClip clips[2];
  VdTimeline timeline = two_clip_timeline(clips);
  vd_engine_set_timeline(e, &timeline);

  VdEngineStats stats;
  vd_engine_stats(e, &stats);
  VD_CHECK(!stats.audio_available);

  vd_engine_seek(e, 0);
  vd_engine_play(e);
  sleep_ms(300);
  const VdTick position = vd_engine_position(e);
  // Nothing is draining an audio clock, so the picture must still advance.
  VD_CHECK(position > SECOND / 5);
  VD_CHECK(position < SECOND);
  vd_engine_pause(e);

  vd_engine_destroy(e);
}

static void test_audio_follows_a_seek(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clip = vd_timeline_clip_default();
  clip.path = fixture("cfr_30fps_stereo.mp4");
  clip.start = 0;
  clip.duration = 10 * SECOND;

  VdTimeline timeline;
  memset(&timeline, 0, sizeof(timeline));
  timeline.width = 320;
  timeline.height = 240;
  timeline.frame_rate = (VdRational){30, 1};
  timeline.clips = &clip;
  timeline.clip_count = 1;
  vd_engine_set_timeline(e, &timeline);

  vd_engine_play(e);
  PullJob job = {
      .renderer = vd_engine_audio_renderer(e),
      .frames = VD_AUDIO_SAMPLE_RATE / 2,
      .stop = false,
  };
  pthread_t thread;
  pthread_create(&thread, NULL, pull_thread, &job);
  pthread_join(thread, NULL);

  // A seek rebases the audio clock; the playhead must land where it was told,
  // not where the accumulated frame count would have put it.
  vd_engine_seek(e, 4 * SECOND);
  const VdTick after = vd_engine_position(e);
  VD_CHECK(after >= 4 * SECOND);
  VD_CHECK(after < 4 * SECOND + SECOND / 4);

  vd_engine_pause(e);
  vd_engine_destroy(e);
}

int main(void) {
  test_lifecycle();
  test_rejects_a_bad_timeline();
  test_position_selects_the_clip();
  test_a_gap_renders_black();
  test_seek_clamps();
  test_play_advances_and_ends();
  test_pause_freezes_the_clock();
  test_play_from_the_end_restarts();
  test_frame_callback();
  test_editing_the_timeline_keeps_decoders();
  test_a_missing_source_is_a_gap_not_a_stall();
  test_an_empty_timeline_renders_black();
  test_scrubbing_stays_correct();
  test_destroy_while_playing();
  test_seek_storm_while_playing();
  test_png_dump();
  test_a_clip_with_no_picture_still_makes_a_sound();
  test_audio_is_the_master_clock();
  test_a_silent_timeline_uses_the_wall_clock();
  test_audio_follows_a_seek();
  return VD_REPORT();
}
