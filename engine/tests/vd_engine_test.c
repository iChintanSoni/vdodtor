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
#include "vdodtor/vd_lut.h"
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
// The two of them fully desaturated, by BT.709 luma. Used by the grading
// tests, where the assertion is that a clip's colour arrived rather than what
// the weights are — vd_color_test.c owns that.
static const int ORANGE_GREY[3] = {114, 114, 114};

// quadrants_cw90.mp4: four flat colours, one per quarter of the picture.
static const int QUAD_RED[3] = {192, 0, 0};
static const int QUAD_GREEN[3] = {0, 192, 0};
static const int QUAD_BLUE[3] = {0, 0, 192};
static const int QUAD_YELLOW[3] = {192, 192, 0};

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

// `fx` and `fy` are fractions of the output, so a caller says "the top left
// quarter" rather than doing arithmetic against a frame size it has to know.
static void check_frame_pixel_is(VdEngine* e, double fx, double fy,
                                 const int rgb[3], const char* what) {
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
  const size_t x = (size_t)(fx * (double)CVPixelBufferGetWidth(pixels));
  const size_t y = (size_t)(fy * (double)CVPixelBufferGetHeight(pixels));
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

static void check_frame_is(VdEngine* e, const int rgb[3], const char* what) {
  check_frame_pixel_is(e, 0.5, 0.5, rgb, what);
}

// The colour at a point, for the checks that are about a *blend* rather than
// about a colour anybody could name — halfway through a dissolve the frame is
// neither clip, and that is the assertion.
static bool frame_rgb(VdEngine* e, double fx, double fy, int out[3]) {
  void* buffer = vd_engine_copy_output(e);
  if (!buffer) return false;
  CVPixelBufferRef pixels = (CVPixelBufferRef)buffer;
  CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
  const uint8_t* base = (const uint8_t*)CVPixelBufferGetBaseAddress(pixels);
  const size_t stride = CVPixelBufferGetBytesPerRow(pixels);
  const size_t x = (size_t)(fx * (double)CVPixelBufferGetWidth(pixels));
  const size_t y = (size_t)(fy * (double)CVPixelBufferGetHeight(pixels));
  const uint8_t* px = base + y * stride + x * 4;  // BGRA
  out[0] = px[2];
  out[1] = px[1];
  out[2] = px[0];
  CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
  CVPixelBufferRelease(pixels);
  return true;
}

// Green for the first second, orange for the second. One track, no gaps.
// A cheap digest of the whole published frame.
//
// Used where the question is "is this the same picture as before?" rather than
// "what colour is it?" — which is what a speed test asks, because the claim is
// about *which source frame* reached the screen and no single pixel says that.
// Zero if there is nothing published, which no assertion below treats as a
// match.
static uint64_t frame_hash(VdEngine* e) {
  void* buffer = vd_engine_copy_output(e);
  if (!buffer) return 0;
  CVPixelBufferRef pixels = (CVPixelBufferRef)buffer;
  CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
  const uint8_t* base = (const uint8_t*)CVPixelBufferGetBaseAddress(pixels);
  const size_t stride = CVPixelBufferGetBytesPerRow(pixels);
  const size_t width = CVPixelBufferGetWidth(pixels);
  const size_t height = CVPixelBufferGetHeight(pixels);

  uint64_t hash = 1469598103934665603ULL;  // FNV-1a
  for (size_t y = 0; y < height; y++) {
    const uint8_t* row = base + y * stride;
    for (size_t x = 0; x < width * 4; x++) {
      hash ^= row[x];
      hash *= 1099511628211ULL;
    }
  }
  CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
  CVPixelBufferRelease(pixels);
  return hash;
}

// The hash of the frame at `position`, rendered synchronously.
static uint64_t hash_at(VdEngine* e, VdTick position) {
  vd_engine_seek(e, position);
  if (vd_engine_render_now(e) != VD_OK) return 0;
  return frame_hash(e);
}

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

// The whole of rotation, from the container to the screen.
//
// The compositor's own tests hand it a rotation; this one never mentions one.
// The engine has to read the display matrix off the file and pass it on, and
// the layer it builds is the one place that could quietly drop it — nothing
// else in the engine would notice, and a portrait clip playing on its side is
// not a subtle bug to ship.
static void test_a_turned_source_plays_upright(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clip = vd_timeline_clip_default();
  clip.path = fixture("quadrants_cw90.mp4");
  clip.start = 0;
  clip.duration = SECOND;
  // Stretched, so the four quarters of the source are the four quarters of
  // the output and reading which is where needs no arithmetic.
  clip.fit = VD_FIT_STRETCH;

  VdTimeline timeline;
  memset(&timeline, 0, sizeof(timeline));
  timeline.width = 320;
  timeline.height = 320;
  timeline.frame_rate = (VdRational){30, 1};
  timeline.clips = &clip;
  timeline.clip_count = 1;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  vd_engine_seek(e, 0);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  // A quarter turn clockwise brings the bottom left up to the top left.
  check_frame_pixel_is(e, 0.25, 0.25, QUAD_BLUE, "top left was bottom left");
  check_frame_pixel_is(e, 0.75, 0.25, QUAD_RED, "top right was top left");
  check_frame_pixel_is(e, 0.25, 0.75, QUAD_YELLOW,
                       "bottom left was bottom right");
  check_frame_pixel_is(e, 0.75, 0.75, QUAD_GREEN, "bottom right was top right");

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

// A caption is a clip with no file. It has to reach the screen through the
// same render list, the same z-order and the same transform as everything
// else — and it has to be laid out once rather than on every frame.
//
// The assertion is on the background box rather than on a glyph: a box is a
// filled rectangle of a colour nobody else in the frame is using, so "the
// caption is on screen" becomes a pixel and not an eyeball.
static const int CAPTION_RED[3] = {220, 40, 40};

static VdTextSpec boxed_caption(const char* text) {
  VdTextSpec spec = vd_text_spec_default();
  spec.text = text;
  spec.size = 0.2f;
  // Ink and box the same colour, so the middle of the frame is that colour
  // whether a glyph happens to fall on it or not — what is being asked here
  // is whether the caption reached the screen, not where its letters landed.
  spec.color = 0xFFDC2828u;      // CAPTION_RED, opaque
  spec.box_color = 0xFFDC2828u;
  spec.box_padding = 0.5f;
  spec.box_radius = 0.0f;
  return spec;
}

static void test_a_caption_composites_over_the_picture(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTextSpec spec = boxed_caption("Hi");
  VdTimelineClip clips[2];
  clips[0] = vd_timeline_clip_default();
  clips[0].path = fixture("solid_sd_601.mp4");
  clips[0].duration = SECOND;
  clips[1] = vd_timeline_clip_default();
  clips[1].text = &spec;   // and no path at all
  clips[1].duration = SECOND;
  clips[1].track = 1;
  clips[1].gain = 0.0f;

  VdTimeline timeline;
  memset(&timeline, 0, sizeof(timeline));
  timeline.width = 320;
  timeline.height = 240;
  timeline.frame_rate = (VdRational){30, 1};
  timeline.clips = clips;
  timeline.clip_count = 2;

  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  vd_engine_seek(e, SECOND / 2);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);

  check_frame_is(e, CAPTION_RED, "the caption is on top of the picture");
  // And only where it is: a caption is a few words on a transparent frame,
  // so the corners are still the clip underneath.
  check_frame_pixel_is(e, 0.02, 0.02, GREEN, "the picture around the caption");

  // It opens no decoder — there is no file to open, and a caption that costs
  // a file handle would be a caption that can fail.
  VdEngineStats stats;
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.open_decoders, 1);
  VD_CHECK_EQ(stats.active_layers, 2);
  VD_CHECK_EQ(stats.text_rasters, 1);

  // The transform reaches it like any other layer: pushed off the bottom, the
  // middle of the frame is the picture again.
  clips[1].transform = vd_transform_identity();
  clips[1].transform.offset_y = 0.9f;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, GREEN, "the caption moved out of the middle");

  vd_engine_destroy(e);
}

static void test_a_caption_is_laid_out_once(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTextSpec spec = boxed_caption("Kept");
  VdTimelineClip clips[2];
  clips[0] = vd_timeline_clip_default();
  clips[0].path = fixture("solid_sd_601.mp4");
  clips[0].duration = 2 * SECOND;
  clips[1] = vd_timeline_clip_default();
  clips[1].text = &spec;
  clips[1].duration = 2 * SECOND;
  clips[1].track = 1;
  clips[1].gain = 0.0f;

  VdTimeline timeline;
  memset(&timeline, 0, sizeof(timeline));
  timeline.width = 320;
  timeline.height = 240;
  timeline.frame_rate = (VdRational){30, 1};
  timeline.clips = clips;
  timeline.clip_count = 2;

  vd_engine_set_timeline(e, &timeline);
  vd_engine_seek(e, 0);
  vd_engine_render_now(e);

  VdEngineStats stats;
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.text_rasters, 1);

  // Scrubbing renders frame after frame and lays nothing out again: a caption
  // does not change with time, which is the whole reason it is worth keeping.
  for (int i = 1; i <= 20; i++) {
    vd_engine_seek(e, (VdTick)i * SECOND / 20);
    vd_engine_render_now(e);
  }
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.text_rasters, 1);

  // Nor does an edit somewhere else on the timeline. This is the same bargain
  // a decoder gets from an unchanged path.
  clips[0].duration = SECOND;
  vd_engine_set_timeline(e, &timeline);
  vd_engine_render_now(e);
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.text_rasters, 1);

  // Changing the caption does lay it out again — that is what the cache is
  // keyed on, and a caption that did not redraw when retyped would be worse
  // than one that redrew constantly.
  spec.text = "Retyped";
  vd_engine_set_timeline(e, &timeline);
  vd_engine_render_now(e);
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.text_rasters, 2);

  // And so does a change of output size, because the raster is made at it.
  timeline.width = 640;
  timeline.height = 480;
  vd_engine_set_timeline(e, &timeline);
  vd_engine_render_now(e);
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.text_rasters, 3);

  vd_engine_destroy(e);
}

static void test_a_caption_alone_is_a_timeline(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  // No file anywhere on the timeline. Nothing may go looking for one: an
  // empty project with a title card has to play, and it has to be black
  // behind the words rather than nothing at all.
  VdTextSpec spec = boxed_caption("Title");
  VdTimelineClip clip = vd_timeline_clip_default();
  clip.text = &spec;
  clip.start = 0;
  clip.duration = SECOND;
  clip.gain = 0.0f;

  VdTimeline timeline;
  memset(&timeline, 0, sizeof(timeline));
  timeline.width = 320;
  timeline.height = 240;
  timeline.frame_rate = (VdRational){30, 1};
  timeline.clips = &clip;
  timeline.clip_count = 1;

  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  VD_CHECK_EQ(vd_engine_duration(e), SECOND);
  vd_engine_seek(e, SECOND / 2);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, CAPTION_RED, "a caption on its own");
  check_frame_pixel_is(e, 0.02, 0.02, BLACK, "and black behind it");

  VdEngineStats stats;
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.open_decoders, 0);

  vd_engine_destroy(e);
}

// A shape is the second thing the engine draws rather than decodes, and the
// point of these two is that it goes through the *same* path a caption does:
// the same render list, the same z-order, the same transform, and the same
// bargain about keeping its pixels across an edit that did not touch it.
//
// Blue rather than the caption's red, so a test that mixes the two can say
// which is on top.
static const int SHAPE_BLUE[3] = {40, 80, 220};

static VdShapeSpec blue_block(void) {
  VdShapeSpec spec = vd_shape_spec_default();
  spec.width = 0.6f;
  spec.height = 0.6f;
  spec.fill_color = 0xFF2850DCu;  // SHAPE_BLUE, opaque
  return spec;
}

static void test_a_shape_composites_over_the_picture(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdShapeSpec spec = blue_block();
  VdTimelineClip clips[2];
  clips[0] = vd_timeline_clip_default();
  clips[0].path = fixture("solid_sd_601.mp4");
  clips[0].duration = SECOND;
  clips[1] = vd_timeline_clip_default();
  clips[1].shape = &spec;  // and no path and no text
  clips[1].duration = SECOND;
  clips[1].track = 1;
  clips[1].gain = 0.0f;

  VdTimeline timeline;
  memset(&timeline, 0, sizeof(timeline));
  timeline.width = 320;
  timeline.height = 240;
  timeline.frame_rate = (VdRational){30, 1};
  timeline.clips = clips;
  timeline.clip_count = 2;

  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  vd_engine_seek(e, SECOND / 2);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);

  check_frame_is(e, SHAPE_BLUE, "the shape is on top of the picture");
  // The box is 0.6 of the frame's height, centred, so the corners are still
  // the clip underneath — a shape is not a colour wash.
  check_frame_pixel_is(e, 0.02, 0.02, GREEN, "the picture around the shape");

  VdEngineStats stats;
  vd_engine_stats(e, &stats);
  // No file to open, so no decoder and no way for a rectangle to fail.
  VD_CHECK_EQ(stats.open_decoders, 1);
  VD_CHECK_EQ(stats.active_layers, 2);
  VD_CHECK_EQ(stats.shape_rasters, 1);
  // A shape is not a caption, and the counter that measures Core Text has to
  // stay a measurement of Core Text.
  VD_CHECK_EQ(stats.text_rasters, 0);

  // The transform reaches it like any other layer.
  clips[1].transform = vd_transform_identity();
  clips[1].transform.offset_y = 0.9f;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, GREEN, "the shape moved out of the middle");

  vd_engine_destroy(e);
}

static void test_a_shape_is_drawn_once(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdShapeSpec spec = blue_block();
  VdTimelineClip clip = vd_timeline_clip_default();
  clip.shape = &spec;
  clip.duration = 2 * SECOND;
  clip.gain = 0.0f;
  // A slide, to make the point that moving a shape about the frame is the
  // compositor's work and not the rasteriser's: forty frames of travel cost
  // one drawing.
  clip.anim.in_preset = VD_ANIM_SLIDE_UP;
  clip.anim.in_duration = SECOND;

  VdTimeline timeline;
  memset(&timeline, 0, sizeof(timeline));
  timeline.width = 320;
  timeline.height = 240;
  timeline.frame_rate = (VdRational){30, 1};
  timeline.clips = &clip;
  timeline.clip_count = 1;

  vd_engine_set_timeline(e, &timeline);
  vd_engine_seek(e, 0);
  vd_engine_render_now(e);

  VdEngineStats stats;
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.shape_rasters, 1);

  for (int i = 1; i <= 40; i++) {
    vd_engine_seek(e, (VdTick)i * SECOND / 20);
    vd_engine_render_now(e);
  }
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.shape_rasters, 1);

  // An edit that leaves the shape alone leaves its pixels alone too.
  clip.duration = 3 * SECOND;
  vd_engine_set_timeline(e, &timeline);
  vd_engine_render_now(e);
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.shape_rasters, 1);

  // Changing it does redraw it — that is what the cache is keyed on.
  spec.corner = 1.0f;
  vd_engine_set_timeline(e, &timeline);
  vd_engine_render_now(e);
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.shape_rasters, 2);

  // And so does a change of output size, because the raster is made at it.
  timeline.width = 640;
  timeline.height = 480;
  vd_engine_set_timeline(e, &timeline);
  vd_engine_render_now(e);
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.shape_rasters, 3);

  // A typewriter has nothing to reveal on a shape. It must not blank it and
  // it must not redraw it once a frame looking for characters that are not
  // there — which is what "a preset that quietly does nothing" has to mean.
  clip.anim.in_preset = VD_ANIM_TYPEWRITER;
  vd_engine_set_timeline(e, &timeline);
  for (int i = 0; i <= 20; i++) {
    vd_engine_seek(e, (VdTick)i * SECOND / 20);
    vd_engine_render_now(e);
  }
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.shape_rasters, 3);
  check_frame_is(e, SHAPE_BLUE, "a shape a typewriter could not erase");

  vd_engine_destroy(e);
}

// An animated overlay is the third kind of layer: a file, like video, but
// decoded whole and composited as premultiplied BGRA, like a caption. These
// check the wiring — that it reaches the screen, that it keeps its alpha, that
// it is retimed rather than resampled, and that it survives an edit.
//
// sticker_4up.gif is four solid quarter-second frames: red, green, blue,
// yellow. Which frame is on screen is therefore a pixel.
static const int STICKER_RED[3] = {192, 0, 0};
static const int STICKER_BLUE[3] = {0, 0, 192};

static VdTimeline sticker_timeline(VdTimelineClip* clips, const char* file,
                                   VdTick duration) {
  clips[0] = vd_timeline_clip_default();
  clips[0].path = fixture("solid_sd_601.mp4");
  clips[0].duration = duration;
  clips[1] = vd_timeline_clip_default();
  clips[1].path = fixture(file);
  clips[1].sticker = true;
  clips[1].duration = duration;
  clips[1].track = 1;
  clips[1].gain = 0.0f;
  // Stretched, so the 16x16 fixture covers the frame and a middle pixel is
  // the sticker rather than the clip under it.
  clips[1].fit = VD_FIT_STRETCH;

  VdTimeline timeline;
  memset(&timeline, 0, sizeof(timeline));
  timeline.width = 320;
  timeline.height = 240;
  timeline.frame_rate = (VdRational){30, 1};
  timeline.clips = clips;
  timeline.clip_count = 2;
  return timeline;
}

static void test_a_sticker_composites_over_the_picture(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clips[2];
  VdTimeline timeline = sticker_timeline(clips, "sticker_4up.gif", 2 * SECOND);

  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  vd_engine_seek(e, 0);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, STICKER_RED, "the first frame of the sticker");

  // Half a second in is the third frame. Nothing seeked to get there — the
  // whole animation was decoded at open, and this is a lookup.
  vd_engine_seek(e, SECOND / 2);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, STICKER_BLUE, "the third frame of the sticker");

  VdEngineStats stats;
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.active_layers, 2);
  // One decoder for the video and none for the sticker: an animated overlay
  // is not opened as video, which matters because the video decoder cannot
  // export a BGRA frame at all and would render it as a gap.
  VD_CHECK_EQ(stats.open_decoders, 1);
  VD_CHECK_EQ(stats.sticker_opens, 1);
  VD_CHECK(stats.sticker_bytes > 0);
  // And it is not a caption or a shape, so neither of those counters moved.
  VD_CHECK_EQ(stats.text_rasters, 0);
  VD_CHECK_EQ(stats.shape_rasters, 0);

  vd_engine_destroy(e);
}

// The one that says a sticker is a sticker and not a still: past the end of
// the animation it starts again, which is what lets a one-second GIF sit on a
// clip of any length at all.
static void test_a_sticker_loops_under_the_playhead(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clips[2];
  VdTimeline timeline = sticker_timeline(clips, "sticker_4up.gif", 4 * SECOND);

  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  // The animation is one second long and the clip is four. Every second lands
  // on the same frame.
  for (int i = 0; i < 4; i++) {
    vd_engine_seek(e, (VdTick)i * SECOND);
    VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
    check_frame_is(e, STICKER_RED, "the start of a loop");

    vd_engine_seek(e, (VdTick)i * SECOND + SECOND / 2);
    VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
    check_frame_is(e, STICKER_BLUE, "the middle of a loop");
  }

  vd_engine_destroy(e);
}

// Retimed rather than resampled: the frame on screen is the one whose interval
// contains the instant, so a sticker that changes four times a second changes
// four times a second whatever the project's rate is.
//
// The counter is the assertion. Sixty renders across one second of a four
// frame animation have to put four frames on screen — sixty would mean every
// project frame was copying a picture that had not changed.
static void test_a_sticker_is_retimed_and_not_resampled(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clips[2];
  VdTimeline timeline = sticker_timeline(clips, "sticker_4up.gif", 2 * SECOND);
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  VdEngineStats before;
  vd_engine_stats(e, &before);
  for (int i = 0; i < 60; i++) {
    vd_engine_seek(e, (VdTick)i * SECOND / 60);
    vd_engine_render_now(e);
  }
  VdEngineStats after;
  vd_engine_stats(e, &after);
  VD_CHECK_EQ(after.sticker_frames - before.sticker_frames, 4);
  // And the file was opened once for all sixty.
  VD_CHECK_EQ(after.sticker_opens, 1);

  vd_engine_destroy(e);
}

// The same bargain a decoder gets from an unchanged path, and a better reason
// for it: reopening a decoder costs a seek, and reopening a sticker means
// decoding the whole animation again.
static void test_a_sticker_survives_an_edit(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clips[2];
  VdTimeline timeline = sticker_timeline(clips, "sticker_4up.gif", 2 * SECOND);
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  // Seeked inside the clip every time, and deliberately: an assertion that the
  // sticker was not reopened means nothing if the playhead is somewhere the
  // clip is not, because then nothing asked for it at all.
  vd_engine_seek(e, SECOND);
  vd_engine_render_now(e);

  VdEngineStats stats;
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.sticker_opens, 1);

  // Nudge it along its lane. The path did not change, so the pixels do not
  // have to be found again.
  clips[1].start = SECOND / 4;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  vd_engine_seek(e, SECOND);
  vd_engine_render_now(e);
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.sticker_opens, 1);
  VD_CHECK_EQ(stats.active_layers, 2);

  // Pointing it at a different file does reopen it — that is what the cache
  // is keyed on.
  clips[1].path = fixture("sticker_alpha.apng");
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  vd_engine_seek(e, SECOND);
  vd_engine_render_now(e);
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.sticker_opens, 2);

  vd_engine_destroy(e);
}

// The alpha is the point of a sticker. Without it an overlay is a rectangle
// with a picture painted on it, and the clip below never shows through.
static void test_a_sticker_keeps_its_alpha_over_the_picture(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  // The APNG fixture is an opaque square inside a transparent border, drawn
  // at its own size in the middle of the frame — so the corners of the output
  // are the video underneath it.
  VdTimelineClip clips[2];
  VdTimeline timeline =
      sticker_timeline(clips, "sticker_alpha.apng", 2 * SECOND);
  clips[1].fit = VD_FIT_CONTAIN;

  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  vd_engine_seek(e, 0);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);

  check_frame_is(e, STICKER_RED, "the sticker itself");
  check_frame_pixel_is(e, 0.02, 0.02, GREEN, "the picture around the sticker");

  vd_engine_destroy(e);
}

// A sticker is a clip like any other, so the transform and the in/out presets
// reach it — the same claim a caption and a shape each make, and the reason
// all three go through one VdLayer.
static void test_a_sticker_takes_a_transform_and_an_animation(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clips[2];
  VdTimeline timeline = sticker_timeline(clips, "sticker_4up.gif", 2 * SECOND);
  clips[1].transform = vd_transform_identity();
  clips[1].transform.offset_y = 0.9f;

  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  vd_engine_seek(e, 0);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, GREEN, "the sticker moved out of the middle");

  // And an entrance fades it, leaving the picture underneath.
  clips[1].transform = vd_transform_identity();
  clips[1].anim.in_preset = VD_ANIM_FADE;
  clips[1].anim.in_duration = SECOND;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  vd_engine_seek(e, 0);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, GREEN, "a sticker that has not arrived yet");

  vd_engine_destroy(e);
}

// A transition is arithmetic, and vd_transition_test.c checks the arithmetic.
// What is checked here is the wiring: that the two clips at a cut are on
// screen together at all, that the overlap comes out of nowhere but the
// engine, and that a cut with no handles either side still dissolves.
//
// Two solid-colour fixtures butt-joined, so "which clip is on screen" is a
// pixel: green then orange.
static VdTimeline cut_timeline(VdTimelineClip* clips, VdTick each,
                               VdTransitionPreset preset, VdTick length) {
  clips[0] = vd_timeline_clip_default();
  clips[0].path = fixture("solid_sd_601.mp4");
  clips[0].start = 0;
  clips[0].duration = each;
  clips[1] = vd_timeline_clip_default();
  clips[1].path = fixture("solid_sd_orange.mp4");
  clips[1].start = each;
  clips[1].duration = each;
  clips[1].transition.preset = preset;
  clips[1].transition.duration = length;

  VdTimeline timeline;
  memset(&timeline, 0, sizeof(timeline));
  timeline.width = 320;
  timeline.height = 240;
  timeline.frame_rate = (VdRational){30, 1};
  timeline.clips = clips;
  timeline.clip_count = 2;
  return timeline;
}

// The overlap is the whole mechanism, and nothing in the document has it: two
// clips that meet at a cut are both on screen through the transition because
// the engine widened their drawing windows, not because either moved.
static void test_a_transition_puts_both_clips_on_screen(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clips[2];
  VdTimeline timeline =
      cut_timeline(clips, SECOND, VD_TRANSITION_DISSOLVE, SECOND / 2);
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  // Well before the cut: one clip, and it is the first one.
  vd_engine_seek(e, SECOND / 4);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, GREEN, "before the transition");
  VdEngineStats stats;
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.active_layers, 1);

  // At the cut, halfway through the dissolve: both, blended.
  vd_engine_seek(e, SECOND);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.active_layers, 2);
  int middle[3];
  VD_CHECK(frame_rgb(e, 0.5, 0.5, middle));
  // Between the two colours and equal to neither, which is what a blend is:
  // less green than the clip leaving, more red than it had.
  VD_CHECK(middle[1] < GREEN[1] - 20);
  VD_CHECK(middle[0] > GREEN[0] + 20);

  // Well after: one clip again, and it is the second one.
  vd_engine_seek(e, 7 * SECOND / 4);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, ORANGE, "after the transition");
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.active_layers, 1);

  vd_engine_destroy(e);
}

// The window straddles the cut, so the first clip is still drawn after its own
// span has ended and the second before its own has begun. Both are asking
// their decoders for times outside their trims, and both get a frame — which
// is the whole of "never fails for lack of media".
static void test_the_overlap_reaches_past_both_clips_trims(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clips[2];
  VdTimeline timeline =
      cut_timeline(clips, SECOND, VD_TRANSITION_DISSOLVE, SECOND / 2);
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  // A quarter of a second before the cut, the *second* clip is already drawn
  // even though its own span has not started.
  vd_engine_seek(e, SECOND - SECOND / 8);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  VdEngineStats stats;
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.active_layers, 2);

  // And after the cut the first one is still there, past its end.
  vd_engine_seek(e, SECOND + SECOND / 8);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.active_layers, 2);

  // The project is no longer or shorter for any of it: a transition that
  // repacked the lane would move every clip after it.
  VD_CHECK_EQ(vd_engine_duration(e), 2 * SECOND);

  vd_engine_destroy(e);
}

// A dip goes all the way to the colour, and it is a layer of its own — so at
// the midpoint the frame is that colour and neither clip.
static void test_a_fade_dips_through_a_colour(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clips[2];
  VdTimeline timeline =
      cut_timeline(clips, SECOND, VD_TRANSITION_FADE_WHITE, SECOND / 2);
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  vd_engine_seek(e, SECOND);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  int px[3];
  VD_CHECK(frame_rgb(e, 0.5, 0.5, px));
  VD_CHECK(px[0] > 240 && px[1] > 240 && px[2] > 240);

  // Three layers, which is the number VD_LAYERS_PER_LANE was sized for: the
  // clip leaving (at zero opacity by now), the clip arriving, and the colour
  // over both of them.
  VdEngineStats stats;
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.active_layers, 3);

  // Black dips the other way, and to black rather than to whatever is behind.
  clips[1].transition.preset = VD_TRANSITION_FADE_BLACK;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  VD_CHECK(frame_rgb(e, 0.5, 0.5, px));
  VD_CHECK(px[0] < 12 && px[1] < 12 && px[2] < 12);

  vd_engine_destroy(e);
}

// The wipe, which is the one preset the transform cannot express. Halfway
// through, the left of the frame is the new clip and the right is the old one,
// with a hard edge between them.
static void test_a_wipe_splits_the_frame(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clips[2];
  VdTimeline timeline =
      cut_timeline(clips, SECOND, VD_TRANSITION_WIPE, SECOND / 2);
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  vd_engine_seek(e, SECOND);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_pixel_is(e, 0.1, 0.5, ORANGE, "the new clip has arrived here");
  check_frame_pixel_is(e, 0.9, 0.5, GREEN, "and not yet here");

  vd_engine_destroy(e);
}

// The bug that only a blur-filled clip could have.
//
// A blur-fill layer is drawn twice: the backdrop is rendered into an offscreen
// texture and then composited over the frame full-width. Cutting the *first*
// of those left the hidden part of the offscreen as opaque black — and that
// black was then painted across everything underneath, so a wipe erased the
// very clip it was wiping away from. The cut has to happen at the composite,
// where discarding leaves what is beneath showing.
//
// Worth its own test because blur fill is the document's default and every
// other check here uses contain or stretch, which have no second pass at all.
static void test_a_wipe_over_a_blur_filled_clip_keeps_it(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clips[2];
  VdTimeline timeline =
      cut_timeline(clips, SECOND, VD_TRANSITION_WIPE, SECOND / 2);
  // 4:3 sources in a 16:9 frame, so both clips have bars and both take the
  // blur path — which is exactly what the app does by default.
  clips[0].fit = VD_FIT_BLUR;
  clips[1].fit = VD_FIT_BLUR;
  timeline.width = 640;
  timeline.height = 360;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  vd_engine_seek(e, SECOND);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_pixel_is(e, 0.2, 0.5, ORANGE, "the new clip has arrived here");
  check_frame_pixel_is(e, 0.97, 0.5, GREEN,
                       "and the old one is still under the rest of the frame");

  // The start of the window: nothing of the new clip yet, and the old one
  // whole — including the blurred bars it fills the frame's edges with.
  vd_engine_seek(e, SECOND - SECOND / 4);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_pixel_is(e, 0.2, 0.5, GREEN, "the old clip at the start");
  check_frame_pixel_is(e, 0.97, 0.5, GREEN, "and its backdrop with it");

  vd_engine_destroy(e);
}

// A transition needs a cut. Two clips with a gap between them are not one, and
// a dissolve into nothing is a fade — which the user would have asked for if
// they wanted it.
static void test_a_transition_with_no_cut_does_nothing(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clips[2];
  VdTimeline timeline =
      cut_timeline(clips, SECOND, VD_TRANSITION_DISSOLVE, SECOND / 2);
  // Push the second clip away, leaving a gap where the cut was.
  clips[1].start = 2 * SECOND;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  vd_engine_seek(e, SECOND - SECOND / 8);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  VdEngineStats stats;
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.active_layers, 1);
  check_frame_is(e, GREEN, "no cut, no transition");

  vd_engine_destroy(e);
}

// Clips on different lanes that happen to meet in time are not a cut either:
// a transition joins two clips on one lane, and the clip above is an overlay.
static void test_a_transition_does_not_reach_across_lanes(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clips[2];
  VdTimeline timeline =
      cut_timeline(clips, SECOND, VD_TRANSITION_DISSOLVE, SECOND / 2);
  clips[1].track = 1;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  vd_engine_seek(e, SECOND - SECOND / 8);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  VdEngineStats stats;
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.active_layers, 1);

  vd_engine_destroy(e);
}

// Seeking into the middle of a transition shows exactly what playing into it
// would — the same claim an animation makes, and for the same reason: there is
// no state between frames to get out of step.
static void test_a_seek_into_a_transition_matches_playing_into_it(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clips[2];
  VdTimeline timeline =
      cut_timeline(clips, SECOND, VD_TRANSITION_DISSOLVE, SECOND / 2);
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  const VdTick at = SECOND + SECOND / 8;

  // Played into: every frame from before the transition up to it, and then
  // the instant itself — the stride does not divide the distance, and
  // comparing two different instants would prove nothing.
  for (VdTick t = SECOND / 2; t < at; t += SECOND / 30) {
    vd_engine_seek(e, t);
    vd_engine_render_now(e);
  }
  vd_engine_seek(e, at);
  vd_engine_render_now(e);
  int played[3];
  VD_CHECK(frame_rgb(e, 0.5, 0.5, played));

  // Jumped straight to, from the other end of the timeline.
  vd_engine_seek(e, 0);
  vd_engine_render_now(e);
  vd_engine_seek(e, at);
  vd_engine_render_now(e);
  int sought[3];
  VD_CHECK(frame_rgb(e, 0.5, 0.5, sought));

  for (int i = 0; i < 3; i++) {
    VD_CHECK(abs(played[i] - sought[i]) <= TOLERANCE);
  }

  vd_engine_destroy(e);
}


// --- animation -------------------------------------------------------------

// An animation is arithmetic, and vd_anim_test.c checks the arithmetic. What
// is checked here is the wiring: that the number reaches the compositor, that
// it composes with the transform the clip already had rather than replacing
// it, and that a typewriter — the one preset the transform cannot express —
// reaches the raster instead.

static VdTimeline one_clip_timeline(VdTimelineClip* clip, const char* file) {
  *clip = vd_timeline_clip_default();
  clip->path = fixture(file);
  clip->start = 0;
  clip->duration = 2 * SECOND;
  clip->fit = VD_FIT_STRETCH;

  VdTimeline timeline;
  memset(&timeline, 0, sizeof(timeline));
  timeline.width = 320;
  timeline.height = 240;
  timeline.frame_rate = (VdRational){30, 1};
  timeline.clips = clip;
  timeline.clip_count = 1;
  return timeline;
}

// --- colour grading ---------------------------------------------------------
// What a grade *means* is pinned in vd_color_test.c and that it reaches a
// fragment is pinned in vd_compositor_test.c. What is left for here is the
// engine's own half: that five numbers on a VdTimelineClip arrive on the
// layer, that they are the same five at every instant of the clip, and that
// dragging a slider does not cost a decoder.

// The grey the green fixture desaturates to, by BT.709 luma.
static const int GREEN_GREY[3] = {150, 150, 150};

static void test_a_grade_on_a_clip_reaches_the_frame(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clip;
  VdTimeline timeline = one_clip_timeline(&clip, "solid_sd_601.mp4");
  clip.color = vd_color_neutral();
  clip.color.saturation = -1.0f;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  vd_engine_seek(e, SECOND);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, GREEN_GREY, "a graded clip");

  // And back off again, so the grade is a property of the timeline rather
  // than something the engine keeps once it has seen it.
  clip.color = vd_color_neutral();
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, GREEN, "and ungraded again");

  vd_engine_destroy(e);
}

// The property that separates a grade from the animation and the transition
// beside it on the same struct: those are functions of time, and this is not.
// Every instant of the clip is graded identically, so there is no head, no
// tail and nothing to seek into the middle of.
static void test_a_grade_does_not_change_through_the_clip(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clip;
  VdTimeline timeline = one_clip_timeline(&clip, "solid_sd_601.mp4");
  clip.color = vd_color_neutral();
  clip.color.saturation = -1.0f;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  const VdTick at[] = {0, SECOND / 2, SECOND, 2 * SECOND - 1};
  for (size_t i = 0; i < sizeof(at) / sizeof(at[0]); i++) {
    vd_engine_seek(e, at[i]);
    VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
    check_frame_is(e, GREEN_GREY, "the same grade at every instant");
  }

  vd_engine_destroy(e);
}

// One clip's grade is its own. Two clips on one lane, one graded: the frame
// changes at the cut and nowhere else.
static void test_a_grade_belongs_to_the_clip_that_carries_it(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clips[2];
  VdTimeline timeline = two_clip_timeline(clips);
  clips[1].color = vd_color_neutral();
  clips[1].color.saturation = -1.0f;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  vd_engine_seek(e, SECOND / 2);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, GREEN, "the first clip, ungraded");

  vd_engine_seek(e, SECOND + SECOND / 2);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, ORANGE_GREY, "and the second, graded");

  vd_engine_destroy(e);
}

// A slider is dragged, so this is the commonest edit there is after nudging a
// clip: it arrives as a whole new timeline sixty times a second. Throwing the
// decoders away each time would make the preview stutter for the whole length
// of the drag — which is exactly when the user is trying to look at it.
static void test_dragging_a_grade_keeps_the_decoders(void) {
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

  for (int i = 1; i <= 10; i++) {
    clips[0].color = vd_color_neutral();
    clips[0].color.brightness = (float)i / 20.0f;
    VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  }

  VdEngineStats after;
  vd_engine_stats(e, &after);
  VD_CHECK_EQ(after.open_decoders, 2);

  vd_engine_destroy(e);
}

// --- looks ------------------------------------------------------------------
// What a look means is pinned in vd_lut_test.c and that a cube reaches a
// fragment is pinned in vd_compositor_test.c. What is left for here is the
// engine's own half: a clip names a look, the catalogue resolves it once per
// edit, a name nobody registered draws ungraded, and a drag on the strength
// slider costs neither a decoder nor an upload.

// Green with red and blue swapped, which is what a swap cube does to the
// fixture — 0 and 100 change places.
static const int GREEN_SWAPPED[3] = {100, 200, 0};

// Registers a swap cube under `name` and hands the name back, so a test can
// say what it wants without knowing the catalogue is a global. Registration is
// idempotent, which is exactly what makes calling this from several tests
// safe.
static const char* swap_look(void) {
  static const char* text =
      "TITLE \"Engine Swap\"\n"
      "LUT_3D_SIZE 2\n"
      "0 0 0\n0 0 1\n0 1 0\n0 1 1\n1 0 0\n1 0 1\n1 1 0\n1 1 1\n";
  vd_lut_register("Engine Swap", text, (int64_t)strlen(text));
  return "Engine Swap";
}

static void test_a_look_on_a_clip_reaches_the_frame(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clip;
  VdTimeline timeline = one_clip_timeline(&clip, "solid_sd_601.mp4");
  clip.look = swap_look();
  clip.look_strength = 1.0f;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  vd_engine_seek(e, SECOND);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, GREEN_SWAPPED, "a clip wearing a look");

  // And off again: a look is a property of the timeline, not something the
  // engine keeps once it has seen one.
  clip.look = NULL;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, GREEN, "and back to the shot as it was shot");

  vd_engine_destroy(e);
}

// A project made on a machine with a look pack opens on one without it. It
// draws ungraded rather than refusing, which is the bargain a caption in a
// missing face already takes — see VdTextSpec::font.
static void test_a_look_nobody_registered_draws_ungraded(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clip;
  VdTimeline timeline = one_clip_timeline(&clip, "solid_sd_601.mp4");
  clip.look = "A Look This Machine Has Never Heard Of";
  clip.look_strength = 1.0f;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  vd_engine_seek(e, SECOND);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, GREEN, "a missing look is no look");

  // Empty and NULL are the same thing all the way down from the document.
  clip.look = "";
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, GREEN, "an empty look name is no look");

  vd_engine_destroy(e);
}

// A look is the same cube at every instant of the clip, like the five sliders
// beside it and unlike the animation and the transition.
static void test_a_look_does_not_change_through_the_clip(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clip;
  VdTimeline timeline = one_clip_timeline(&clip, "solid_sd_601.mp4");
  clip.look = swap_look();
  clip.look_strength = 1.0f;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  const VdTick at[] = {0, SECOND / 2, SECOND, 2 * SECOND - 1};
  for (size_t i = 0; i < sizeof(at) / sizeof(at[0]); i++) {
    vd_engine_seek(e, at[i]);
    VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
    check_frame_is(e, GREEN_SWAPPED, "the same look at every instant");
  }

  vd_engine_destroy(e);
}

// The strength slider is dragged, so it arrives as a whole new timeline sixty
// times a second — and it must cost neither a reopened decoder nor a re-sent
// cube. A look that went up the bus on every value would stutter the preview
// for the whole length of the drag, which is exactly when the user is looking.
static void test_dragging_a_looks_strength_costs_nothing(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clip;
  VdTimeline timeline = one_clip_timeline(&clip, "solid_sd_601.mp4");
  clip.look = swap_look();
  clip.look_strength = 1.0f;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  vd_engine_seek(e, SECOND);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);

  VdEngineStats before;
  vd_engine_stats(e, &before);
  VD_CHECK_EQ(before.open_decoders, 1);
  VD_CHECK_EQ(before.lut_uploads, 1);

  for (int i = 1; i <= 20; i++) {
    clip.look_strength = (float)i / 20.0f;
    VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
    VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  }

  VdEngineStats after;
  vd_engine_stats(e, &after);
  VD_CHECK_EQ(after.open_decoders, 1);
  VD_CHECK_EQ(after.lut_uploads, 1);

  // At zero strength the look is gone from the frame without being gone from
  // the document, which is what makes the slider reversible.
  clip.look_strength = 0.0f;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, GREEN, "a look turned all the way down");

  vd_engine_destroy(e);
}

// --- speed -----------------------------------------------------------------

static const int STICKER_GREEN[3] = {0, 192, 0};

// One clip of moving footage, retimed. testsrc2 changes every frame, which is
// what makes a hash of the whole picture mean "which source frame is this".
static VdTimeline retimed_timeline(VdTimelineClip* clips, double speed,
                                   VdTick duration) {
  clips[0] = vd_timeline_clip_default();
  clips[0].path = fixture("cfr_30fps_stereo.mp4");
  clips[0].start = 0;
  clips[0].duration = duration;
  clips[0].speed = speed;
  clips[0].fit = VD_FIT_STRETCH;
  clips[0].gain = 0.0f;

  VdTimeline timeline;
  memset(&timeline, 0, sizeof(timeline));
  timeline.width = 320;
  timeline.height = 240;
  timeline.frame_rate = (VdRational){30, 1};
  timeline.clips = clips;
  timeline.clip_count = 1;
  return timeline;
}

// A retimed clip is a window that travels over its source at a different rate,
// and that is the whole of it: where the clip sits and how long it lasts are
// unchanged, because the document decided both.
//
// Read off a sticker rather than off footage, because a sticker's frames are
// four flat colours a quarter of a second apart — so "which frame is on
// screen" is a question one pixel answers.
static void test_speed_moves_the_window_over_the_source(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clips[2];
  VdTimeline timeline = sticker_timeline(clips, "sticker_4up.gif", 4 * SECOND);

  clips[1].speed = 2.0;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  vd_engine_seek(e, 0);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, STICKER_RED, "2x at the head is still the first frame");
  vd_engine_seek(e, SECOND / 8);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, STICKER_GREEN, "2x an eighth in is a quarter in");
  vd_engine_seek(e, SECOND / 4);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, STICKER_BLUE, "2x a quarter in is half way");

  clips[1].speed = 0.5;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  vd_engine_seek(e, SECOND / 2);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, STICKER_GREEN, "half speed half a second in");
  vd_engine_seek(e, SECOND);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, STICKER_BLUE, "half speed a second in");

  vd_engine_destroy(e);
}

// Slow motion, which turns out not to be a feature at all.
//
// There is no duplication step in the engine because there is nothing to
// duplicate: a frame is on screen until the next frame starts, and asking for
// a source time that has not left the current frame's interval hands back the
// frame that is already there. Four project frames at a quarter speed are one
// source frame, and the fifth is the next one.
static void test_slow_motion_holds_each_source_frame(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  const VdTick frame = SECOND / 30;
  VdTimelineClip clips[1];
  VdTimeline timeline = retimed_timeline(clips, 1.0, 2 * SECOND);
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  // At its own speed, every project frame is a different source frame. This is
  // the control: without it the assertion below would also pass on a fixture
  // that never changed.
  uint64_t own[5];
  for (int i = 0; i < 5; i++) own[i] = hash_at(e, (VdTick)i * frame);
  for (int i = 1; i < 5; i++) {
    vd_checks++;
    if (own[i] == own[i - 1] || own[i] == 0) {
      vd_failures++;
      fprintf(stderr, "FAIL frames %d and %d of the source are the same\n",
              i - 1, i);
    }
  }

  clips[0].speed = 0.25;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  for (int i = 0; i < 4; i++) {
    vd_checks++;
    const uint64_t held = hash_at(e, (VdTick)i * frame);
    if (held != own[0]) {
      vd_failures++;
      fprintf(stderr,
              "FAIL at a quarter speed project frame %d was not the source's "
              "first frame\n",
              i);
    }
  }
  // And the fifth is the source's second, which is what makes it slow motion
  // rather than a freeze.
  vd_checks++;
  if (hash_at(e, 4 * frame) != own[1]) {
    vd_failures++;
    fprintf(stderr, "FAIL a quarter speed never reached the second frame\n");
  }

  vd_engine_destroy(e);
}

// The other direction: at 2x every other source frame is skipped, and the one
// that arrives is exactly the one the same source time would have given at 1x.
static void test_speeding_up_skips_source_frames(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  const VdTick frame = SECOND / 30;
  VdTimelineClip clips[1];
  VdTimeline timeline = retimed_timeline(clips, 1.0, 2 * SECOND);
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  uint64_t own[8];
  for (int i = 0; i < 8; i++) own[i] = hash_at(e, (VdTick)i * frame);

  clips[0].speed = 2.0;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  for (int i = 0; i < 4; i++) {
    vd_checks++;
    if (hash_at(e, (VdTick)i * frame) != own[2 * i]) {
      vd_failures++;
      fprintf(stderr, "FAIL at 2x project frame %d was not source frame %d\n",
              i, 2 * i);
    }
  }

  // A zeroed speed is what a caller that memset the struct leaves behind, and
  // it has to mean "as it was shot" rather than "stop time" — the one field on
  // VdTimelineClip that a memset gets right by not being set.
  clips[0].speed = 0.0;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);
  for (int i = 0; i < 4; i++) {
    vd_checks++;
    if (hash_at(e, (VdTick)i * frame) != own[i]) {
      vd_failures++;
      fprintf(stderr, "FAIL a zeroed speed did not play at its own speed\n");
    }
  }

  vd_engine_destroy(e);
}

static void test_an_entrance_fades_the_picture_up_from_black(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clip;
  VdTimeline timeline = one_clip_timeline(&clip, "solid_sd_601.mp4");
  clip.anim = vd_clip_anim_none();
  clip.anim.in_preset = VD_ANIM_FADE;
  clip.anim.in_duration = SECOND;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  // The first frame is the clip at zero opacity, which over the compositor's
  // black is black. Nothing else in the engine could produce that.
  vd_engine_seek(e, 0);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, BLACK, "the first frame of a fade in");

  // Past the entrance it is the clip, exactly.
  vd_engine_seek(e, SECOND);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, GREEN, "after the fade has finished");

  vd_engine_seek(e, 2 * SECOND - 1);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, GREEN, "the last frame, with no exit set");

  vd_engine_destroy(e);
}

static void test_an_exit_is_measured_from_the_end(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTimelineClip clip;
  VdTimeline timeline = one_clip_timeline(&clip, "solid_sd_601.mp4");
  clip.anim = vd_clip_anim_none();
  clip.anim.out_preset = VD_ANIM_FADE;
  clip.anim.out_duration = SECOND;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  vd_engine_seek(e, 0);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, GREEN, "the head, with no entrance set");

  // Deep into the exit the picture is nearly gone.
  vd_engine_seek(e, 2 * SECOND - SECOND / 20);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  uint8_t nearly[4];
  void* buffer = vd_engine_copy_output(e);
  VD_CHECK(buffer != NULL);
  if (buffer) {
    CVPixelBufferRef pixels = (CVPixelBufferRef)buffer;
    CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
    const uint8_t* base = (const uint8_t*)CVPixelBufferGetBaseAddress(pixels);
    memcpy(nearly, base + 120 * CVPixelBufferGetBytesPerRow(pixels) + 160 * 4,
           4);
    CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferRelease(pixels);
    // Well under the clip's own green, and not yet black.
    VD_CHECK(nearly[1] < 100);
  }

  vd_engine_destroy(e);
}

static void test_an_animation_composes_with_the_transform(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  // A clip pushed to the right half of the frame, then faded in. The fade
  // must not move it back to the middle, and the offset must not stop it
  // fading — replacing the transform instead of composing with it would do
  // one or the other.
  VdTimelineClip clip;
  VdTimeline timeline = one_clip_timeline(&clip, "solid_sd_601.mp4");
  clip.transform = vd_transform_identity();
  clip.transform.scale = 0.4f;
  clip.transform.offset_x = 0.25f;
  clip.anim = vd_clip_anim_none();
  clip.anim.in_preset = VD_ANIM_FADE;
  clip.anim.in_duration = SECOND;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  vd_engine_seek(e, SECOND);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  // At rest: where the transform put it, and nowhere near the middle.
  check_frame_pixel_is(e, 0.75, 0.5, GREEN, "the placed clip, animation over");
  check_frame_pixel_is(e, 0.25, 0.5, BLACK, "and nothing on the other side");

  vd_engine_seek(e, 0);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_pixel_is(e, 0.75, 0.5, BLACK, "faded out at the start");

  vd_engine_destroy(e);
}

static void test_a_zoom_keeps_the_clips_own_scale(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  // The scale multiplies rather than replaces. A clip at 40% that zooms in
  // has to end at 40%, not at 100% — and the check is a pixel just outside
  // where 40% reaches.
  VdTimelineClip clip;
  VdTimeline timeline = one_clip_timeline(&clip, "solid_sd_601.mp4");
  clip.transform = vd_transform_identity();
  clip.transform.scale = 0.4f;
  clip.anim = vd_clip_anim_none();
  clip.anim.in_preset = VD_ANIM_ZOOM;
  clip.anim.in_duration = SECOND;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  vd_engine_seek(e, SECOND);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, GREEN, "the middle, at the clip's own scale");
  check_frame_pixel_is(e, 0.05, 0.5, BLACK, "and no wider than 40%");

  // Early in the zoom it is smaller still, so a point that the resting size
  // covers is not covered yet.
  vd_engine_seek(e, SECOND / 20);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_pixel_is(e, 0.5 + 0.4 * 0.45, 0.5, BLACK,
                       "the edge has not reached its resting size");

  vd_engine_destroy(e);
}

static void test_a_typewriter_types_and_stops(void) {
  VdEngine* e = make_engine();
  if (!e) return;

  VdTextSpec spec = boxed_caption("Typing");
  // No box: what is being counted here is how often the caption is laid out,
  // and a box would make every frame look the same to the eye anyway.
  spec.box_color = 0x00000000u;
  spec.size = 0.3f;

  VdTimelineClip clip = vd_timeline_clip_default();
  clip.text = &spec;
  clip.duration = 2 * SECOND;
  clip.gain = 0.0f;
  clip.anim = vd_clip_anim_none();
  clip.anim.in_preset = VD_ANIM_TYPEWRITER;
  clip.anim.in_duration = SECOND;

  VdTimeline timeline;
  memset(&timeline, 0, sizeof(timeline));
  timeline.width = 320;
  timeline.height = 240;
  timeline.frame_rate = (VdRational){30, 1};
  timeline.clips = &clip;
  timeline.clip_count = 1;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  // Nothing at the very start: no characters have been typed.
  vd_engine_seek(e, 0);
  VD_CHECK_EQ(vd_engine_render_now(e), VD_OK);
  check_frame_is(e, BLACK, "before the first character");

  // A caption is re-drawn once per *character*, not once per frame. Thirty
  // frames across a one-second typewriter over six characters is at most six
  // more layouts, and the frames between them cost nothing.
  VdEngineStats before;
  vd_engine_stats(e, &before);
  for (int i = 1; i <= 30; i++) {
    vd_engine_seek(e, (VdTick)i * SECOND / 30);
    vd_engine_render_now(e);
  }
  VdEngineStats after;
  vd_engine_stats(e, &after);
  const int64_t layouts = after.text_rasters - before.text_rasters;
  vd_checks++;
  if (layouts > 7) {
    vd_failures++;
    fprintf(stderr,
            "FAIL a typewriter laid out %lld times over 30 frames of 6 "
            "characters\n",
            (long long)layouts);
  }
  VD_CHECK(layouts >= 2);  // it did type

  // And once it is finished it stops entirely: the rest of the clip is one
  // raster, however much of it gets scrubbed.
  vd_engine_stats(e, &before);
  for (int i = 0; i < 10; i++) {
    vd_engine_seek(e, SECOND + (VdTick)i * SECOND / 10);
    vd_engine_render_now(e);
  }
  vd_engine_stats(e, &after);
  VD_CHECK(after.text_rasters - before.text_rasters <= 1);

  vd_engine_destroy(e);
}

static void test_an_animated_caption_that_is_not_a_typewriter_never_redraws(
    void) {
  VdEngine* e = make_engine();
  if (!e) return;

  // The point of doing animation as a transform: a caption that slides,
  // scales, turns and fades is the *same pixels* moved about, so it is laid
  // out once for its whole life however much it moves.
  VdTextSpec spec = boxed_caption("Moving");
  VdTimelineClip clip = vd_timeline_clip_default();
  clip.text = &spec;
  clip.duration = 2 * SECOND;
  clip.gain = 0.0f;
  clip.anim = vd_clip_anim_none();
  clip.anim.in_preset = VD_ANIM_SPIN;
  clip.anim.in_duration = SECOND;
  clip.anim.out_preset = VD_ANIM_SLIDE_UP;
  clip.anim.out_duration = SECOND;

  VdTimeline timeline;
  memset(&timeline, 0, sizeof(timeline));
  timeline.width = 320;
  timeline.height = 240;
  timeline.frame_rate = (VdRational){30, 1};
  timeline.clips = &clip;
  timeline.clip_count = 1;
  VD_CHECK_EQ(vd_engine_set_timeline(e, &timeline), VD_OK);

  for (int i = 0; i <= 40; i++) {
    vd_engine_seek(e, (VdTick)i * 2 * SECOND / 40);
    vd_engine_render_now(e);
  }
  VdEngineStats stats;
  vd_engine_stats(e, &stats);
  VD_CHECK_EQ(stats.text_rasters, 1);

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
  test_a_turned_source_plays_upright();
  test_a_gap_renders_black();
  test_seek_clamps();
  test_play_advances_and_ends();
  test_pause_freezes_the_clock();
  test_play_from_the_end_restarts();
  test_frame_callback();
  test_editing_the_timeline_keeps_decoders();
  test_a_caption_composites_over_the_picture();
  test_a_caption_is_laid_out_once();
  test_a_caption_alone_is_a_timeline();
  test_a_shape_composites_over_the_picture();
  test_a_shape_is_drawn_once();
  test_a_sticker_composites_over_the_picture();
  test_a_sticker_loops_under_the_playhead();
  test_a_sticker_is_retimed_and_not_resampled();
  test_a_sticker_survives_an_edit();
  test_a_sticker_keeps_its_alpha_over_the_picture();
  test_a_sticker_takes_a_transform_and_an_animation();
  test_a_transition_puts_both_clips_on_screen();
  test_the_overlap_reaches_past_both_clips_trims();
  test_a_fade_dips_through_a_colour();
  test_a_wipe_splits_the_frame();
  test_a_wipe_over_a_blur_filled_clip_keeps_it();
  test_a_transition_with_no_cut_does_nothing();
  test_a_transition_does_not_reach_across_lanes();
  test_a_seek_into_a_transition_matches_playing_into_it();
  test_a_grade_on_a_clip_reaches_the_frame();
  test_a_grade_does_not_change_through_the_clip();
  test_a_grade_belongs_to_the_clip_that_carries_it();
  test_dragging_a_grade_keeps_the_decoders();
  test_a_look_on_a_clip_reaches_the_frame();
  test_a_look_nobody_registered_draws_ungraded();
  test_a_look_does_not_change_through_the_clip();
  test_dragging_a_looks_strength_costs_nothing();
  test_speed_moves_the_window_over_the_source();
  test_slow_motion_holds_each_source_frame();
  test_speeding_up_skips_source_frames();
  test_an_entrance_fades_the_picture_up_from_black();
  test_an_exit_is_measured_from_the_end();
  test_an_animation_composes_with_the_transform();
  test_a_zoom_keeps_the_clips_own_scale();
  test_a_typewriter_types_and_stops();
  test_an_animated_caption_that_is_not_a_typewriter_never_redraws();
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
