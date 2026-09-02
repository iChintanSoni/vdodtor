// Parity: the frame on screen and the frame in the file, held to one picture.
//
// The whole engine is shaped around one sentence — preview and export differ
// in the clock and in nothing else. Playback works out what time it is and
// renders that; an export counts frames and asks for those. Both arrive at
// `vd_engine_render_at`, and nothing below it can tell which called it.
//
// Every other test in this directory checks one side of that. vd_engine_test.c
// drives the preview clock and reads pixels; vd_export_test.c writes a file and
// asks whether it is the shape it was promised to be. Neither can catch the
// failure the sentence exists to prevent, which is the two of them quietly
// disagreeing: a transition resolved at a slightly different tick, a caption
// revealed one character further on, an animation evaluated off by a frame.
// Each of those looks perfectly correct on its own side and turns the preview
// into a liar.
//
// So this file renders the same timeline through both drivers and compares
// them to **one reference each** rather than to each other. Comparing the two
// directly would go green on the day they both broke the same way; a committed
// picture is a third party, and it is one a human approved by looking at it.
//
//   VD_UPDATE_GOLDENS=1 ctest --test-dir build/engine -R 'golden|parity'
//
// re-approves. Note what may approve a reference and what may not: the preview
// writes these goldens and the export is *measured* against them, because the
// preview is the thing the user was looking at when they decided the edit was
// finished. An export that disagrees is wrong even when it is prettier.
//
// **Nothing here draws a glyph or a curve**, and that is deliberate. Core
// Text's rasterisation of a sentence and Core Graphics' antialiasing of a
// circle are both tuned in macOS releases, so a reference PNG of either would
// go red on an upgrade while the renderer was still perfectly correct — the
// argument vd_text_test.c and vd_ink.h make at length. The scenes below are
// decoded video through the compositor, which is exact. The caption gets the
// parity check it can actually keep: the two drivers are compared to each
// other on *where the ink is*, which no rasteriser drift can move apart.
#include "vd_golden.h"

#include "vdodtor/vd_decoder.h"
#include "vdodtor/vd_engine.h"
#include "vdodtor/vd_export.h"
#include "vdodtor/vd_lut.h"
#include "vdodtor/vd_text.h"

#include <unistd.h>

#include <CoreVideo/CoreVideo.h>

#define SECOND VD_TICKS_PER_SECOND

// Every scene here is 30 fps, which is the only rate the arithmetic below
// names. The export renders frame k at exactly k * FRAME (see vd_export.mm),
// so a preview asked for the same tick is asking the same question.
#define FRAME (VD_TICKS_PER_SECOND / 30)

#define WIDTH 320
#define HEIGHT 240

// What an encode costs.
//
// The preview's frame goes to memory and the export's goes through H.264 and
// 4:2:0 chroma and back, so the two cannot be equal and the question is what
// the difference is allowed to look like. Flat regions come back within a
// couple of counts. Hard colour edges do not: chroma is stored at half
// resolution in both axes, so a boundary between two saturated colours is
// reconstructed over two pixels and lands tens of counts out along that seam.
//
// A bound on the worst pixel would therefore have to be enormous to be stable,
// and would assert nothing. Bounding the *proportion* of pixels past a
// sensible figure is what actually separates "the seams are soft" from "the
// picture is wrong": a frame drawn upside down, missing a layer, or through
// the wrong colour matrix fails this by orders of magnitude, and so does one
// that is a single frame early.
//
// The exports here are written at a deliberately extravagant bitrate — see
// parity_settings — so what is left is the chroma and the quantiser floor and
// almost nothing else. Measured: the scenes below come back with 1.0% to 2.0%
// of their pixels past twenty counts and a mean under 0.92, and every one of
// those pixels is on a seam. The same scenes rendered a single frame out of
// step come back at 2.7% to 12.0% with a mean of 2.9 to 6.6.
//
// Which is why both bounds are here and neither would do alone. A frame of
// drift across a *cut* moves almost every pixel a little, and the mean is what
// notices; a frame of drift in the middle of a dissolve barely moves the
// outlier count at all, because the two pictures either side of that frame are
// nearly the same blend. The gap between 0.92 and 2.9 is the one this file
// actually lives in.
#define VD_PARITY_THROUGH_AN_ENCODER \
  ((VdGoldenTolerance){.channel = 20, .outliers = 0.04, .mean = 2.0})

static const char* fixture(const char* name) {
  static char paths[8][1024];
  static int next = 0;
  char* path = paths[next];
  next = (next + 1) % 8;
  snprintf(path, sizeof(paths[0]), "%s/%s", VD_TEST_MEDIA_DIR, name);
  return path;
}

static const char* output(const char* name) {
  static char path[1024];
  snprintf(path, sizeof(path), "/tmp/vd_parity_test_%s.mp4", name);
  remove(path);
  return path;
}

// A real export, at a bitrate nobody would choose.
//
// The rate control is not what is on trial here. Every count H.264 spends is a
// count of tolerance this file has to give away, and a tolerance wide enough
// to absorb a 2 Mbps quantiser is one that would also absorb a genuinely wrong
// frame. Forty megabits at 320x240 is about a hundred times the default, which
// puts the encoder close enough to transparent that what remains is the chroma
// subsampling — a property of the *format*, which no bitrate can buy off and
// which the tolerance above is shaped around.
static VdExportSettings parity_settings(void) {
  VdExportSettings settings = vd_export_default_settings();
  settings.video_bitrate = 40000000;
  return settings;
}

// --- the two drivers -------------------------------------------------------

// No output device: ctest must not make a noise.
static VdEngine* make_engine(void) {
  VdEngineOptions options = vd_engine_default_options();
  options.audio_output = 0;
  return vd_engine_create_with_options(options, NULL);
}

// A CVPixelBuffer's BGRA, tightly packed. The GPU pads its rows to a stride of
// its own choosing and every comparison here wants them packed. Caller frees.
static uint8_t* packed_bgra(CVPixelBufferRef buffer, int32_t* out_w,
                            int32_t* out_h) {
  if (!buffer) return NULL;
  CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
  const uint8_t* base = (const uint8_t*)CVPixelBufferGetBaseAddress(buffer);
  const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
  const int32_t w = (int32_t)CVPixelBufferGetWidth(buffer);
  const int32_t h = (int32_t)CVPixelBufferGetHeight(buffer);
  uint8_t* packed = base ? malloc((size_t)w * (size_t)h * 4) : NULL;
  if (packed) {
    for (int32_t y = 0; y < h; y++) {
      memcpy(packed + (size_t)y * (size_t)w * 4, base + (size_t)y * stride,
             (size_t)w * 4);
    }
    *out_w = w;
    *out_h = h;
  }
  CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
  return packed;
}

// The preview driver: render exactly `t` and take what was published. Caller
// frees.
static uint8_t* preview_frame(VdEngine* e, VdTick t, int32_t* w, int32_t* h) {
  if (vd_engine_render_at(e, t) != VD_OK) {
    vd_checks++;
    vd_failures++;
    fprintf(stderr, "FAIL preview could not render tick %lld\n", (long long)t);
    return NULL;
  }
  CVPixelBufferRef buffer = (CVPixelBufferRef)vd_engine_copy_output(e);
  uint8_t* pixels = packed_bgra(buffer, w, h);
  if (buffer) CVPixelBufferRelease(buffer);
  return pixels;
}

// The export driver, read back: the written file, decoded, and put through the
// same compositor the preview used so that what is compared is RGB either
// side. Converting anywhere else would be a second YCbCr matrix to keep in
// step with the shader's, and a test with its own idea of what green is tests
// its own arithmetic.
typedef struct {
  VdDecoder* decoder;
  VdCompositor* compositor;
  int32_t width, height;
} Film;

static bool film_open(Film* film, const char* path, int32_t w, int32_t h) {
  memset(film, 0, sizeof(*film));
  film->decoder = vd_decoder_open(path, vd_decoder_default_options(), NULL);
  film->compositor = vd_compositor_create(w, h, NULL);
  film->width = w;
  film->height = h;
  const bool ok = film->decoder && film->compositor;
  VD_CHECK(ok);
  return ok;
}

static void film_close(Film* film) {
  if (film->decoder) vd_decoder_close(film->decoder);
  if (film->compositor) vd_compositor_destroy(film->compositor);
  memset(film, 0, sizeof(*film));
}

// The written frame that is on screen at `t`. Asked half a frame late on
// purpose: the export writes frame k at presentation time k * FRAME, and a
// decoder asked for exactly a boundary is being asked which of two intervals
// owns an instant. Asked from the middle of the interval there is no question,
// and the frame that comes back is the one the export rendered at `t`.
static uint8_t* film_frame(Film* film, VdTick t) {
  VdFrame frame;
  memset(&frame, 0, sizeof(frame));
  if (vd_decoder_frame_at(film->decoder, t + FRAME / 2, &frame) != VD_OK) {
    vd_checks++;
    vd_failures++;
    fprintf(stderr, "FAIL the file has no frame at tick %lld\n", (long long)t);
    return NULL;
  }

  VdLayer layer;
  memset(&layer, 0, sizeof(layer));
  layer.pixel_buffer = frame.pixel_buffer;
  layer.format = frame.format;
  layer.color_matrix = frame.color_matrix;
  layer.full_range = frame.full_range;
  // The file is the output's own size, so this fit is one to one and the
  // compositor is doing nothing here but the colour conversion.
  layer.fit = VD_FIT_CONTAIN;
  layer.opacity = 1.0f;
  const int32_t rendered = vd_compositor_render(film->compositor, &layer, 1);
  vd_frame_release(&frame);
  if (rendered != VD_OK) {
    vd_checks++;
    vd_failures++;
    fprintf(stderr, "FAIL could not composite the file's frame at %lld\n",
            (long long)t);
    return NULL;
  }

  const int32_t w = vd_compositor_width(film->compositor);
  const int32_t h = vd_compositor_height(film->compositor);
  const int64_t bytes = (int64_t)w * h * 4;
  uint8_t* pixels = malloc((size_t)bytes);
  if (pixels && vd_compositor_copy_pixels(film->compositor, pixels, bytes) !=
                    VD_OK) {
    free(pixels);
    pixels = NULL;
  }
  return pixels;
}

// Runs an export to completion, or gives up. Returns the final state.
static int32_t run_to_completion(VdExport* handle, int timeout_ms) {
  VdExportProgress progress;
  for (int waited = 0; waited < timeout_ms; waited += 10) {
    vd_export_progress(handle, &progress);
    if (progress.state != VD_EXPORT_RUNNING) return progress.state;
    usleep(10000);
  }
  vd_export_progress(handle, &progress);
  return progress.state;
}

// Exports `timeline` and leaves the file at `path`. False if it did not
// finish, in which case the caller has nothing to compare and should say so
// once rather than three times.
static bool export_to(const VdTimeline* timeline, const char* path) {
  int32_t result = VD_ERR_OPEN;
  VdExport* handle = vd_export_start(timeline, path, parity_settings(), &result);
  VD_CHECK_EQ(result, VD_OK);
  if (!handle) return false;
  const int32_t state = run_to_completion(handle, 120000);
  VD_CHECK_EQ(state, VD_EXPORT_DONE);
  vd_export_destroy(handle);
  return state == VD_EXPORT_DONE;
}

// One tick, through both drivers, against one reference.
static void check_both_drivers(VdEngine* preview, Film* film, VdTick t,
                               const char* name) {
  int32_t w = 0, h = 0;
  uint8_t* shown = preview_frame(preview, t, &w, &h);
  vd_golden_check(shown, w, h, name, NULL, VD_GOLDEN_SAME_RENDERER);
  free(shown);

  uint8_t* written = film_frame(film, t);
  vd_golden_check(written, film->width, film->height, name, "export",
                  VD_PARITY_THROUGH_AN_ENCODER);
  free(written);
}

// --- what the scenes are made of -------------------------------------------

static void register_teal_orange(void) {
  static bool done = false;
  if (done) return;
  done = true;
  char path[1024];
  snprintf(path, sizeof(path), "%s/teal_orange.cube", VD_LUT_DIR);
  FILE* f = fopen(path, "rb");
  VD_CHECK(f != NULL);
  if (!f) return;
  fseek(f, 0, SEEK_END);
  const long size = ftell(f);
  fseek(f, 0, SEEK_SET);
  void* data = size > 0 ? malloc((size_t)size) : NULL;
  const bool read = data && fread(data, 1, (size_t)size, f) == (size_t)size;
  fclose(f);
  // The name the app registers it under, so the clip below names a look the
  // way a document does.
  VD_CHECK(read && vd_lut_register("Teal & Orange", data, size) == VD_OK);
  free(data);
}

// The scene both drivers are given.
//
// Everything on it is something the *engine* resolves per frame rather than
// something the compositor is handed: a transition window worked out from a
// cut, an animation evaluated from an offset into a clip's life, a look found
// by name in a catalogue. Those are exactly the places the two clocks could
// drift apart, and a static picture would not notice any of them.
//
// The pictures themselves are flat-coloured fixtures, because the encoder is
// the other half of this comparison and detail is what it spends its bits on.
// Four solid quadrants have hard edges to get wrong and nothing for H.264 to
// blur into a plausible smear.
static VdTimeline parity_scene(VdTimelineClip* clips) {
  const VdTick cut = SECOND / 2;

  // The outgoing shot: four flat quadrants, so a frame that arrived rotated,
  // mirrored or a layer short is obvious at a glance and enormous by the
  // numbers.
  clips[0] = vd_timeline_clip_default();
  clips[0].path = fixture("quadrants.mp4");
  clips[0].start = 0;
  clips[0].duration = cut;
  clips[0].fit = VD_FIT_COVER;
  clips[0].has_video = true;
  clips[0].gain = 0.0f;

  // The incoming shot, dissolving over the cut and wearing a grade and a look.
  // The transition window is 0.4s, which is [0.3s, 0.7s] — half either side —
  // so the middle sample below lands squarely inside it.
  clips[1] = vd_timeline_clip_default();
  clips[1].path = fixture("solid_sd_orange.mp4");
  clips[1].start = cut;
  clips[1].duration = SECOND - cut;
  clips[1].fit = VD_FIT_COVER;
  clips[1].has_video = true;
  clips[1].gain = 0.0f;
  clips[1].transition.preset = VD_TRANSITION_DISSOLVE;
  clips[1].transition.duration = (2 * SECOND) / 5;
  clips[1].color.contrast = 0.25f;
  clips[1].color.saturation = -0.3f;
  clips[1].color.temperature = 0.2f;
  clips[1].look = "Teal & Orange";
  clips[1].look_strength = 0.8f;

  // An overlay that arrives and leaves, on a lane of its own. Its position is
  // a function of how far into its own life it is, which is the second thing
  // only the engine knows and the clock decides.
  clips[2] = vd_timeline_clip_default();
  clips[2].path = fixture("solid_sd_601.mp4");
  clips[2].start = SECOND / 10;
  clips[2].duration = (4 * SECOND) / 5;
  clips[2].track = 1;
  clips[2].fit = VD_FIT_CONTAIN;
  clips[2].has_video = true;
  clips[2].gain = 0.0f;
  clips[2].opacity = 0.85f;
  clips[2].transform.scale = 0.4f;
  clips[2].transform.offset_x = 0.25f;
  clips[2].transform.offset_y = -0.2f;
  clips[2].anim.in_preset = VD_ANIM_SLIDE_UP;
  clips[2].anim.in_duration = (3 * SECOND) / 10;
  clips[2].anim.out_preset = VD_ANIM_ZOOM;
  clips[2].anim.out_duration = (3 * SECOND) / 10;

  // Sound, on a lane that contributes nothing to the picture.
  //
  // Not decoration: with no audio there is one input on the writer and the
  // interleaving never happens, so a video-only parity export would exercise
  // the easy half of the encoder. This makes the file the pictures come out of
  // an ordinary two-track export.
  clips[3] = vd_timeline_clip_default();
  clips[3].path = fixture("cfr_30fps_stereo.mp4");
  clips[3].start = 0;
  clips[3].duration = SECOND;
  clips[3].track = 2;
  clips[3].has_video = false;

  VdTimeline timeline;
  memset(&timeline, 0, sizeof(timeline));
  timeline.width = WIDTH;
  timeline.height = HEIGHT;
  timeline.frame_rate = (VdRational){30, 1};
  timeline.clips = clips;
  timeline.clip_count = 4;
  return timeline;
}

// --- the scenes ------------------------------------------------------------

// Three moments of one timeline, each rendered twice: once by the clock that
// draws the preview and once by the counter that writes the file.
//
// The ticks are chosen so that each says something a static frame could not.
// Frame 6 is before the transition opens, with the overlay a third of the way
// through arriving. Frame 15 is the cut itself, halfway through the dissolve,
// with the overlay at rest. Frame 24 is past the transition entirely — the
// incoming shot alone, graded and wearing its look — with the overlay two
// thirds of the way out. An export a single frame out of step fails all three.
static void scene_the_file_shows_what_the_preview_showed(void) {
  register_teal_orange();

  VdTimelineClip clips[4];
  VdTimeline timeline = parity_scene(clips);

  const char* path = output("scene");
  if (!export_to(&timeline, path)) return;

  VdEngine* preview = make_engine();
  VD_CHECK(preview != NULL);
  if (!preview) {
    remove(path);
    return;
  }
  VD_CHECK_EQ(vd_engine_set_timeline(preview, &timeline), VD_OK);

  Film film;
  if (film_open(&film, path, WIDTH, HEIGHT)) {
    check_both_drivers(preview, &film, 6 * FRAME, "parity_before_the_cut");
    check_both_drivers(preview, &film, 15 * FRAME, "parity_mid_dissolve");
    check_both_drivers(preview, &film, 24 * FRAME, "parity_after_the_cut");
    film_close(&film);
  }

  vd_engine_destroy(preview);
  remove(path);
}

// The same timeline at a size it was never cut at.
//
// Nothing in a render list is measured in pixels, which is what makes a 4K
// export of a 1080p edit one number changing — and this is the assertion that
// keeps it true. The preview engine is given the same timeline at the same
// size, so both drivers are being asked the same question; what would break it
// is anything that resolves against the output rather than against the
// document, and that would show up here as a layer in the wrong place rather
// than as a slightly softer picture.
//
// It gets no golden of its own. A reference at twice the size would pin the
// same three decisions a second time and cost a second encode to do it; what
// is worth asserting is that the two drivers still agree, and they are
// compared to each other for it.
static void scene_a_bigger_export_is_the_same_edit(void) {
  register_teal_orange();

  VdTimelineClip clips[4];
  VdTimeline timeline = parity_scene(clips);
  timeline.width = WIDTH * 2;
  timeline.height = HEIGHT * 2;

  const char* path = output("resized");
  if (!export_to(&timeline, path)) return;

  VdEngine* preview = make_engine();
  VD_CHECK(preview != NULL);
  if (!preview) {
    remove(path);
    return;
  }
  VD_CHECK_EQ(vd_engine_set_timeline(preview, &timeline), VD_OK);

  Film film;
  if (film_open(&film, path, WIDTH * 2, HEIGHT * 2)) {
    const VdTick t = 15 * FRAME;
    int32_t w = 0, h = 0;
    uint8_t* shown = preview_frame(preview, t, &w, &h);
    uint8_t* written = film_frame(&film, t);
    VD_CHECK_EQ(w, WIDTH * 2);
    VD_CHECK_EQ(h, HEIGHT * 2);

    vd_checks++;
    if (!shown || !written) {
      vd_failures++;
      fprintf(stderr, "FAIL no frame to compare at twice the size\n");
    } else {
      // Against each other rather than against a file, and with all three
      // bounds: the mean is what catches a frame of drift here, where the
      // outlier count on one sample of a dissolve could sit just inside.
      const VdGoldenTolerance tolerance = VD_PARITY_THROUGH_AN_ENCODER;
      const VdGoldenDelta delta =
          vd_golden_measure(written, shown, w, h, tolerance, NULL);
      if (!delta.ok) {
        vd_failures++;
        char what[128];
        snprintf(what, sizeof(what), "a %dx%d export is not the %dx%d edit", w,
                 h, WIDTH, HEIGHT);
        vd_golden_report(&delta, written, shown, w, tolerance, what);
      }
    }
    free(shown);
    free(written);
    film_close(&film);
  }

  vd_engine_destroy(preview);
  remove(path);
}

// --- the caption, which cannot be a golden ---------------------------------

// The typewriter is the one animation that is not a transform: it reaches into
// the caption's raster, so the engine caches on (spec, size, revealed
// characters) and re-lays the text out once per character. That makes it the
// single most parity-fragile thing in the engine — the preview reaches a tick
// by seeking to it and the export reaches the same tick by counting up to it,
// and a cache that answered from the wrong key would show a different number
// of letters in the file than on screen.
//
// It cannot have a golden, because a reference PNG of a sentence goes red the
// first time Apple retunes a rasteriser — the argument at the head of
// vd_text_test.c. What it can have is the two drivers measured against *each
// other* on where the ink is: both ran the same Core Text in the same process,
// so the two agree exactly or they disagree about characters, and no amount of
// hinting drift can move a caption's right edge by half a word.
#define CAPTION_TEXT "PARITY"
static const int CAPTION_BGR[3] = {40, 40, 220};  // opaque 0xFFDC2828, as BGR

// The bounding box of everything close to the caption's colour. -1 width when
// there is none, which is how "nothing was revealed yet" reads.
typedef struct {
  int32_t left, right, top, bottom;
  bool empty;
} Box;

static Box caption_box(const uint8_t* bgra, int32_t w, int32_t h) {
  Box box = {0, 0, 0, 0, true};
  for (int32_t y = 0; y < h; y++) {
    for (int32_t x = 0; x < w; x++) {
      const size_t i = ((size_t)y * w + x) * 4;
      bool near = true;
      for (int ch = 0; ch < 3; ch++) {
        int32_t d = (int32_t)bgra[i + ch] - CAPTION_BGR[ch];
        if (d < 0) d = -d;
        // Wide, because this pixel came off an encoder on one of the two
        // sides. The caption's colour shares no channel with the green under
        // it, so nothing else in the frame is within reach of this.
        if (d > 48) near = false;
      }
      if (!near) continue;
      if (box.empty) {
        box.left = box.right = x;
        box.top = box.bottom = y;
        box.empty = false;
        continue;
      }
      if (x < box.left) box.left = x;
      if (x > box.right) box.right = x;
      if (y < box.top) box.top = y;
      if (y > box.bottom) box.bottom = y;
    }
  }
  return box;
}

static int32_t box_width(const Box* box) {
  return box->empty ? -1 : box->right - box->left + 1;
}

static void register_inter(void) {
  static bool done = false;
  if (done) return;
  done = true;
  char path[1024];
  snprintf(path, sizeof(path), "%s/Inter.ttf", VD_FONT_DIR);
  FILE* f = fopen(path, "rb");
  VD_CHECK(f != NULL);
  if (!f) return;
  fseek(f, 0, SEEK_END);
  const long size = ftell(f);
  fseek(f, 0, SEEK_SET);
  void* data = size > 0 ? malloc((size_t)size) : NULL;
  const bool read = data && fread(data, 1, (size_t)size, f) == (size_t)size;
  fclose(f);
  VD_CHECK(read && vd_text_register_font(data, size) == VD_OK);
  free(data);
}

static void compare_boxes(const Box* shown, const Box* written, const char* at) {
  vd_checks++;
  if (shown->empty != written->empty) {
    vd_failures++;
    fprintf(stderr,
            "FAIL the caption is %s on screen and %s in the file, %s\n",
            shown->empty ? "absent" : "present",
            written->empty ? "absent" : "present", at);
    return;
  }
  if (shown->empty) return;

  // Two pixels either side. The two drivers laid the caption out with the same
  // Core Text on the same machine, so the type is in the same place to the
  // pixel; what this is absorbing is the encoder softening the edge of a box
  // by a column, not a difference of opinion about the words.
  const int32_t dl = shown->left - written->left;
  const int32_t dr = shown->right - written->right;
  const int32_t dt = shown->top - written->top;
  const int32_t db = shown->bottom - written->bottom;
  const int32_t worst =
      (dl < 0 ? -dl : dl) > (dr < 0 ? -dr : dr) ? (dl < 0 ? -dl : dl)
                                                : (dr < 0 ? -dr : dr);
  const int32_t worst_v =
      (dt < 0 ? -dt : dt) > (db < 0 ? -db : db) ? (dt < 0 ? -dt : dt)
                                                : (db < 0 ? -db : db);
  if (worst > 2 || worst_v > 2) {
    vd_failures++;
    fprintf(stderr,
            "FAIL the caption is not in the same place, %s\n"
            "  on screen  (%d,%d)-(%d,%d)\n"
            "  in the file (%d,%d)-(%d,%d)\n",
            at, shown->left, shown->top, shown->right, shown->bottom,
            written->left, written->top, written->right, written->bottom);
  }
}

static void scene_the_typewriter_types_at_the_same_speed(void) {
  register_inter();

  VdTextSpec spec = vd_text_spec_default();
  spec.text = CAPTION_TEXT;
  spec.font = "Inter";
  spec.size = 0.22f;
  spec.color = 0xFFDC2828u;
  // No background box, and that is the whole reason this works. The box is
  // laid out around the *finished* caption's ink and drawn from the first
  // character on — it exists to hold the caption's place so the line does not
  // re-centre on every keystroke — so its width says nothing about how far the
  // typewriter has got. The ink does.
  spec.box_color = 0x00000000u;

  VdTimelineClip clips[2];
  clips[0] = vd_timeline_clip_default();
  clips[0].path = fixture("solid_sd_601.mp4");
  clips[0].start = 0;
  clips[0].duration = SECOND;
  clips[0].fit = VD_FIT_COVER;
  clips[0].has_video = true;
  clips[0].gain = 0.0f;

  clips[1] = vd_timeline_clip_default();
  clips[1].text = &spec;
  clips[1].start = 0;
  clips[1].duration = SECOND;
  clips[1].track = 1;
  clips[1].gain = 0.0f;
  clips[1].anim.in_preset = VD_ANIM_TYPEWRITER;
  clips[1].anim.in_duration = (3 * SECOND) / 5;

  VdTimeline timeline;
  memset(&timeline, 0, sizeof(timeline));
  timeline.width = WIDTH;
  timeline.height = HEIGHT;
  timeline.frame_rate = (VdRational){30, 1};
  timeline.clips = clips;
  timeline.clip_count = 2;

  const char* path = output("caption");
  if (!export_to(&timeline, path)) return;

  VdEngine* preview = make_engine();
  VD_CHECK(preview != NULL);
  if (!preview) {
    remove(path);
    return;
  }
  VD_CHECK_EQ(vd_engine_set_timeline(preview, &timeline), VD_OK);

  Film film;
  if (film_open(&film, path, WIDTH, HEIGHT)) {
    // A third of the way through the reveal, two thirds through, and after it
    // has finished. Three points rather than one, because a single sample
    // could agree by luck on a caption that grows a character every four
    // frames.
    const VdTick ticks[3] = {6 * FRAME, 12 * FRAME, 24 * FRAME};
    const char* names[3] = {"a third in", "two thirds in", "fully typed"};
    int32_t widths[3] = {0, 0, 0};

    for (int i = 0; i < 3; i++) {
      int32_t w = 0, h = 0;
      uint8_t* shown = preview_frame(preview, ticks[i], &w, &h);
      uint8_t* written = film_frame(&film, ticks[i]);
      if (shown && written) {
        const Box a = caption_box(shown, w, h);
        const Box b = caption_box(written, film.width, film.height);
        compare_boxes(&a, &b, names[i]);
        widths[i] = box_width(&a);
      } else {
        vd_checks++;
        vd_failures++;
        fprintf(stderr, "FAIL no frame to compare, %s\n", names[i]);
      }
      free(shown);
      free(written);
    }

    // And the caption really was growing, so the agreement above could have
    // failed. Two drivers that both drew nothing would match perfectly.
    VD_CHECK(widths[0] > 0);
    VD_CHECK(widths[0] < widths[1]);
    VD_CHECK(widths[1] < widths[2]);
    film_close(&film);
  }

  vd_engine_destroy(preview);
  remove(path);
}

int main(void) {
  scene_the_file_shows_what_the_preview_showed();
  scene_a_bigger_export_is_the_same_edit();
  scene_the_typewriter_types_at_the_same_speed();
  vd_golden_epilogue();
  return VD_REPORT();
}
