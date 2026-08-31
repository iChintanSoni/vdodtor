// Animated overlays, checked on which frame is on screen when.
//
// The fixtures are four solid colours, so "which frame" is a pixel and not a
// judgement: sticker_4up.gif holds them for a quarter of a second each, and
// sticker_uneven.gif holds the first one for twice as long as the second. That
// second file is the whole point of the sticker path — read at its nominal
// rate it would be showing green at 0.4 s, and read by *time*, which is what
// this does, it is still red.
#include "vd_check.h"
#include "vd_ink.h"
#include "vdodtor/vd_probe.h"
#include "vdodtor/vd_sticker.h"

#include <stdlib.h>
#include <string.h>

#include <CoreVideo/CoreVideo.h>

#define SECOND VD_TICKS_PER_SECOND

static const char* fixture(const char* name) {
  static char path[1024];
  snprintf(path, sizeof(path), "%s/%s", VD_TEST_MEDIA_DIR, name);
  return path;
}

static VdSticker* open_fixture(const char* name) {
  int32_t result = VD_OK;
  VdSticker* s =
      vd_sticker_open(fixture(name), vd_sticker_default_options(), &result);
  if (!s) fprintf(stderr, "  (%s: %s)\n", name, vd_result_string(result));
  VD_CHECK(s != NULL);
  return s;
}

// The colour in the middle of the frame at `t`, as R, G, B.
static void colour_at(VdSticker* s, VdTick t, uint8_t out[3]) {
  CVPixelBufferRef buffer = (CVPixelBufferRef)vd_sticker_frame_at(s, t, NULL);
  memset(out, 0, 3);
  if (!buffer) return;
  uint8_t bgra[4];
  pixel_at(buffer, vd_sticker_width(s) / 2, vd_sticker_height(s) / 2, bgra);
  out[0] = bgra[2];
  out[1] = bgra[1];
  out[2] = bgra[0];
}

// Loose enough to survive the trip through the palette a GIF has to take, and
// tight enough that red, green, blue and yellow cannot be confused.
static bool is_colour(const uint8_t got[3], uint8_t r, uint8_t g, uint8_t b) {
  return abs((int)got[0] - (int)r) < 60 && abs((int)got[1] - (int)g) < 60 &&
         abs((int)got[2] - (int)b) < 60;
}

static void check_colour(VdSticker* s, VdTick t, int r, int g, int b,
                         int line) {
  uint8_t got[3];
  colour_at(s, t, got);
  vd_checks++;
  if (!is_colour(got, (uint8_t)r, (uint8_t)g, (uint8_t)b)) {
    vd_failures++;
    fprintf(stderr, "FAIL %s:%d: at %lld expected %d,%d,%d got %d,%d,%d\n",
            __FILE__, line, (long long)t, r, g, b, got[0], got[1], got[2]);
  }
}

// A function behind a variadic macro rather than a macro doing the work: the
// colour names below expand to three arguments each, and the preprocessor
// counts a function-like macro's arguments before it expands them.
#define CHECK_COLOUR(s, t, ...) check_colour((s), (t), __VA_ARGS__, __LINE__)

// The four colours the fixtures cycle through, in order.
#define RED 192, 0, 0
#define GREEN 0, 192, 0
#define BLUE 0, 0, 192
#define YELLOW 192, 192, 0

// --- opening ---------------------------------------------------------------

static void test_a_gif_decodes_whole(void) {
  VdSticker* s = open_fixture("sticker_4up.gif");
  if (!s) return;

  VD_CHECK_EQ(vd_sticker_frame_count(s), 4);
  VD_CHECK_EQ(vd_sticker_width(s), 16);
  VD_CHECK_EQ(vd_sticker_height(s), 16);
  // Four quarter-second frames.
  VD_CHECK_EQ(vd_sticker_duration(s), SECOND);
  VD_CHECK_EQ(vd_sticker_bytes(s), 16 * 16 * 4 * 4);

  vd_sticker_close(s);
}

static void test_an_apng_decodes_too(void) {
  // A different container, a different decoder and a real alpha channel. The
  // point is that nothing above this line knows which of the three it opened.
  VdSticker* s = open_fixture("sticker_alpha.apng");
  if (!s) return;

  VD_CHECK_EQ(vd_sticker_frame_count(s), 2);
  VD_CHECK_EQ(vd_sticker_width(s), 16);
  VD_CHECK(vd_sticker_duration(s) > 0);

  vd_sticker_close(s);
}

static void test_a_file_that_is_not_one_is_refused(void) {
  int32_t result = VD_OK;
  VD_CHECK(vd_sticker_open(fixture("not_media.txt"),
                           vd_sticker_default_options(), &result) == NULL);
  VD_CHECK(result < 0);

  VD_CHECK(vd_sticker_open(fixture("no_such_file.gif"),
                           vd_sticker_default_options(), &result) == NULL);
  VD_CHECK(result < 0);

  VD_CHECK(vd_sticker_open(NULL, vd_sticker_default_options(), &result) == NULL);
  VD_CHECK_EQ(result, VD_ERR_INVALID_ARG);

  // And closing nothing is not a crash, which is what every other close in
  // this engine promises.
  vd_sticker_close(NULL);
}

// --- which frame is on screen ----------------------------------------------

static void test_each_frame_is_on_screen_for_its_own_slice(void) {
  VdSticker* s = open_fixture("sticker_4up.gif");
  if (!s) return;

  CHECK_COLOUR(s, 0, RED);
  CHECK_COLOUR(s, SECOND / 8, RED);
  CHECK_COLOUR(s, SECOND / 4, GREEN);
  CHECK_COLOUR(s, SECOND / 2, BLUE);
  CHECK_COLOUR(s, 3 * SECOND / 4, YELLOW);
  // A tick before the loop ends is still the last frame.
  CHECK_COLOUR(s, SECOND - 1, YELLOW);

  vd_sticker_close(s);
}

// The one that matters. Read at the file's nominal rate — four frames over
// 1.04 s — 0.4 s would land in the second frame. Read by time it is still the
// first, because the first frame's delay is half a second.
static void test_uneven_delays_are_believed(void) {
  VdSticker* s = open_fixture("sticker_uneven.gif");
  if (!s) return;

  VD_CHECK_EQ(vd_sticker_frame_count(s), 4);

  CHECK_COLOUR(s, 0, RED);
  CHECK_COLOUR(s, 2 * SECOND / 5, RED);      // 0.4 s — still the first frame
  CHECK_COLOUR(s, 3 * SECOND / 5, GREEN);    // 0.6 s
  CHECK_COLOUR(s, 4 * SECOND / 5, BLUE);     // 0.8 s
  CHECK_COLOUR(s, SECOND + SECOND / 100, YELLOW);  // 1.01 s

  // The animation is longer than the frames-times-nominal-rate reading of it,
  // which is the arithmetic that would have gone wrong.
  VD_CHECK(vd_sticker_duration(s) > SECOND);

  vd_sticker_close(s);
}

static void test_a_sticker_loops(void) {
  VdSticker* s = open_fixture("sticker_4up.gif");
  if (!s) return;

  // Second time round, tenth time round: the same frames in the same order.
  // This is what lets a one-second GIF sit on a ten-second clip.
  CHECK_COLOUR(s, SECOND, RED);
  CHECK_COLOUR(s, SECOND + SECOND / 4, GREEN);
  CHECK_COLOUR(s, 10 * SECOND + SECOND / 2, BLUE);

  vd_sticker_close(s);
}

static void test_a_negative_offset_runs_backwards_into_the_loop(void) {
  // A clip dragged to start before its source should show the animation
  // running, not frozen on frame one — so the modulo comes back up into the
  // loop rather than clamping.
  VdSticker* s = open_fixture("sticker_4up.gif");
  if (!s) return;

  CHECK_COLOUR(s, -SECOND / 4, YELLOW);
  CHECK_COLOUR(s, -SECOND / 2, BLUE);
  CHECK_COLOUR(s, -SECOND, RED);

  vd_sticker_close(s);
}

// --- what a lookup costs ---------------------------------------------------

// The number that says the retiming is happening. Sixty lookups across one
// second of a four-frame sticker have to put four frames on screen, not sixty
// — which is what "retimed to the project's rate" means when nothing resamples
// anything.
static void test_a_lookup_only_copies_when_the_frame_changes(void) {
  VdSticker* s = open_fixture("sticker_4up.gif");
  if (!s) return;

  int32_t changes = 0;
  for (int32_t i = 0; i < 60; i++) {
    bool changed = false;
    vd_sticker_frame_at(s, (VdTick)i * SECOND / 60, &changed);
    if (changed) changes++;
  }
  VD_CHECK_EQ(changes, 4);

  // And asking for the same instant twice costs nothing at all.
  bool changed = true;
  vd_sticker_frame_at(s, 0, &changed);
  VD_CHECK(changed);
  vd_sticker_frame_at(s, 0, &changed);
  VD_CHECK(!changed);

  vd_sticker_close(s);
}

// One buffer for the whole animation, not one per frame. A hundred-frame GIF
// that spent an IOSurface per frame would spend a hundred of them to show one.
static void test_every_frame_comes_back_in_the_same_buffer(void) {
  VdSticker* s = open_fixture("sticker_4up.gif");
  if (!s) return;

  void* first = vd_sticker_frame_at(s, 0, NULL);
  void* second = vd_sticker_frame_at(s, SECOND / 2, NULL);
  VD_CHECK(first != NULL);
  VD_CHECK(first == second);

  vd_sticker_close(s);
}

// --- what the compositor gets ----------------------------------------------

static void test_the_frames_keep_their_alpha(void) {
  VdSticker* s = open_fixture("sticker_alpha.apng");
  if (!s) return;

  CVPixelBufferRef buffer = (CVPixelBufferRef)vd_sticker_frame_at(s, 0, NULL);
  VD_CHECK(buffer != NULL);
  if (!buffer) {
    vd_sticker_close(s);
    return;
  }

  VD_CHECK_EQ(CVPixelBufferGetPixelFormatType(buffer),
              (long)kCVPixelFormatType_32BGRA);

  // The fixture is an opaque square inside a transparent border. Without the
  // alpha a sticker is a rectangle with a picture painted on it rather than
  // something composited over the clip below.
  uint8_t corner[4], centre[4];
  pixel_at(buffer, 0, 0, corner);
  pixel_at(buffer, 8, 8, centre);
  VD_CHECK_EQ(corner[3], 0);
  VD_CHECK_EQ(centre[3], 255);

  vd_sticker_close(s);
}

// Premultiplied, like every other BGRA layer this engine composites. A channel
// brighter than its own alpha comes out as a bright fringe wherever the
// sticker is soft, which is every edge it has.
static void test_the_frames_are_premultiplied(void) {
  VdSticker* s = open_fixture("sticker_alpha.apng");
  if (!s) return;

  int violations = 0;
  for (int32_t f = 0; f < vd_sticker_frame_count(s); f++) {
    CVPixelBufferRef buffer = (CVPixelBufferRef)vd_sticker_frame_at(
        s, (VdTick)f * vd_sticker_duration(s) / vd_sticker_frame_count(s),
        NULL);
    if (!buffer) continue;
    const Ink ink = measure(buffer);
    (void)ink;
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    const uint8_t* base = (const uint8_t*)CVPixelBufferGetBaseAddress(buffer);
    const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    for (int32_t y = 0; y < vd_sticker_height(s); y++) {
      const uint8_t* row = base + (size_t)y * stride;
      for (int32_t x = 0; x < vd_sticker_width(s); x++) {
        const uint8_t* p = row + (size_t)x * 4;
        if (p[0] > p[3] || p[1] > p[3] || p[2] > p[3]) violations++;
      }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
  }
  VD_CHECK_EQ(violations, 0);

  vd_sticker_close(s);
}

// --- the budget ------------------------------------------------------------

// It scales rather than truncates. Losing resolution on an overlay is a
// compromise somebody might not notice; losing the second half of the
// animation is a bug they certainly would.
static void test_a_budget_shrinks_the_frames_and_keeps_them_all(void) {
  VdStickerOptions options = vd_sticker_default_options();
  options.max_bytes = 16 * 16 * 4 * 4 / 4;  // a quarter of what it wants

  int32_t result = VD_OK;
  VdSticker* s =
      vd_sticker_open(fixture("sticker_4up.gif"), options, &result);
  VD_CHECK(s != NULL);
  if (!s) return;

  VD_CHECK_EQ(vd_sticker_frame_count(s), 4);
  VD_CHECK_EQ(vd_sticker_duration(s), SECOND);
  VD_CHECK(vd_sticker_width(s) < 16);
  VD_CHECK(vd_sticker_width(s) >= 1);
  VD_CHECK(vd_sticker_bytes(s) <= options.max_bytes);
  // Still the right colours, just fewer pixels of them.
  CHECK_COLOUR(s, 0, RED);
  CHECK_COLOUR(s, SECOND / 2, BLUE);

  vd_sticker_close(s);
}

static void test_max_side_caps_a_sticker_at_the_output(void) {
  VdStickerOptions options = vd_sticker_default_options();
  options.max_side = 8;

  VdSticker* s = vd_sticker_open(fixture("sticker_4up.gif"), options, NULL);
  VD_CHECK(s != NULL);
  if (!s) return;

  VD_CHECK_EQ(vd_sticker_width(s), 8);
  VD_CHECK_EQ(vd_sticker_height(s), 8);
  VD_CHECK_EQ(vd_sticker_frame_count(s), 4);

  vd_sticker_close(s);
}

// A budget bigger than the file buys nothing: a sticker is never upscaled,
// because inventing pixels costs memory to look worse.
static void test_a_sticker_is_never_larger_than_its_file(void) {
  VdStickerOptions options = vd_sticker_default_options();
  options.max_side = 4096;

  VdSticker* s = vd_sticker_open(fixture("sticker_4up.gif"), options, NULL);
  VD_CHECK(s != NULL);
  if (!s) return;

  VD_CHECK_EQ(vd_sticker_width(s), 16);
  vd_sticker_close(s);
}

// --- telling one from a video ----------------------------------------------

static void test_the_codecs_that_are_stickers(void) {
  // The codec rather than the extension, because a .webp can be either and the
  // container is the thing that knows. The app asks this so the answer is
  // written down once instead of the engine probing a path it was handed.
  VD_CHECK(vd_sticker_is_sticker_codec("gif"));
  VD_CHECK(vd_sticker_is_sticker_codec("apng"));
  VD_CHECK(vd_sticker_is_sticker_codec("webp"));
  VD_CHECK(vd_sticker_is_sticker_codec("webp_anim"));

  VD_CHECK(!vd_sticker_is_sticker_codec("h264"));
  VD_CHECK(!vd_sticker_is_sticker_codec("hevc"));
  // A still PNG is not an APNG, and the codec name is where the two differ.
  VD_CHECK(!vd_sticker_is_sticker_codec("png"));
  VD_CHECK(!vd_sticker_is_sticker_codec("mjpeg"));
  VD_CHECK(!vd_sticker_is_sticker_codec(""));
  VD_CHECK(!vd_sticker_is_sticker_codec(NULL));
}

// What the app reads to make that decision. If the probe stopped reporting a
// codec name for these files, the classification above would quietly send
// every sticker down the video path.
static void test_the_probe_names_the_codec(void) {
  const struct {
    const char* file;
    const char* codec;
  } cases[] = {
      {"sticker_4up.gif", "gif"},
      {"sticker_uneven.gif", "gif"},
      {"sticker_alpha.apng", "apng"},
  };

  for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
    VdProbeInfo info;
    VD_CHECK_EQ(vd_probe_file(fixture(cases[i].file), &info), VD_OK);
    VD_CHECK_STR(info.video_codec, cases[i].codec);
    VD_CHECK(info.has_video);
    VD_CHECK(!info.has_audio);
    VD_CHECK(vd_sticker_is_sticker_codec(info.video_codec));
  }
}

int main(void) {
  test_a_gif_decodes_whole();
  test_an_apng_decodes_too();
  test_a_file_that_is_not_one_is_refused();

  test_each_frame_is_on_screen_for_its_own_slice();
  test_uneven_delays_are_believed();
  test_a_sticker_loops();
  test_a_negative_offset_runs_backwards_into_the_loop();

  test_a_lookup_only_copies_when_the_frame_changes();
  test_every_frame_comes_back_in_the_same_buffer();

  test_the_frames_keep_their_alpha();
  test_the_frames_are_premultiplied();

  test_a_budget_shrinks_the_frames_and_keeps_them_all();
  test_max_side_caps_a_sticker_at_the_output();
  test_a_sticker_is_never_larger_than_its_file();

  test_the_codecs_that_are_stickers();
  test_the_probe_names_the_codec();

  return VD_REPORT();
}
