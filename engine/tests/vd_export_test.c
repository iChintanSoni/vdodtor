// Export: the timeline counted out one frame at a time, into a file the rest
// of the world can open.
//
// The assertions that matter here are not about speed. They are that the file
// exists and is the shape it was asked to be, that its index is at the front,
// that HEVC is tagged the way players expect, that the picture in it is the
// picture the compositor drew, that the sound in it is the sound the mixer
// made — and that a cancelled export leaves nothing behind, which is the one
// failure a user would otherwise discover a week later.
#include "vd_check.h"
#include "vdodtor/vd_export.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "vdodtor/vd_audio.h"
#include "vdodtor/vd_decoder.h"
#include "vdodtor/vd_probe.h"

#include <CoreVideo/CoreVideo.h>

#define SECOND VD_TICKS_PER_SECOND

static const char* fixture(const char* name) {
  static char path[1024];
  snprintf(path, sizeof(path), "%s/%s", VD_TEST_MEDIA_DIR, name);
  return path;
}

// One output path per test, so a run that leaves a file behind cannot make the
// next test pass for the wrong reason.
static const char* output(const char* name) {
  static char path[1024];
  snprintf(path, sizeof(path), "/tmp/vd_export_test_%s.mp4", name);
  remove(path);
  return path;
}

static VdTimeline one_clip_timeline(VdTimelineClip* clip, const char* file,
                                    VdTick duration) {
  *clip = vd_timeline_clip_default();
  clip->path = fixture(file);
  clip->start = 0;
  clip->duration = duration;
  clip->source_in = 0;
  clip->fit = VD_FIT_COVER;

  VdTimeline timeline;
  memset(&timeline, 0, sizeof(timeline));
  timeline.width = 320;
  timeline.height = 240;
  timeline.frame_rate = (VdRational){30, 1};
  timeline.clips = clip;
  timeline.clip_count = 1;
  return timeline;
}

// Runs an export to completion, or gives up after `timeout_ms`. Returns the
// final state so a caller can say what it expected rather than poll itself.
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

static long file_size(const char* path) {
  FILE* f = fopen(path, "rb");
  if (!f) return -1;
  fseek(f, 0, SEEK_END);
  const long size = ftell(f);
  fclose(f);
  return size;
}

// Where a four-character box name or codec tag first appears in the file, or
// -1. Crude on purpose: reading the box tree would be a second MP4 parser to
// keep correct, and the two questions asked of it here — is the index before
// the payload, and which of the two HEVC tags is in the sample description —
// are both answered by "where does this appear".
static long offset_of(const char* path, const char* needle) {
  FILE* f = fopen(path, "rb");
  if (!f) return -1;
  static char buffer[1 << 20];
  const size_t length = strlen(needle);
  long base = 0;
  long found = -1;
  size_t carry = 0;
  for (;;) {
    const size_t got = fread(buffer + carry, 1, sizeof(buffer) - carry, f);
    const size_t total = carry + got;
    if (total < length) break;
    for (size_t i = 0; i + length <= total; i++) {
      if (memcmp(buffer + i, needle, length) == 0) {
        found = base + (long)i;
        break;
      }
    }
    if (found >= 0 || got == 0) break;
    carry = length - 1;
    memmove(buffer, buffer + total - carry, carry);
    base += (long)(total - carry);
  }
  fclose(f);
  return found;
}

// --- the numbers under the preset picker -----------------------------------

// The table `defaultVideoBitrate` in app/lib/engine/export_plan.dart asserts
// too. One function in two languages, like vd_time.c and time.dart, and for
// the reason vd_export.h gives: the encoder writes at this rate and the app
// prints it under the picker.
static const struct {
  VdExportCodec codec;
  int32_t width;
  int32_t height;
  int32_t num;
  int32_t den;
  int64_t bits;
} kBitrates[] = {
    {VD_CODEC_H264, 1280, 720, 30, 1, 2800000},
    {VD_CODEC_H264, 1920, 1080, 30, 1, 6200000},
    // 23.976, which is 24000/1001 and not 24: the rate is exact everywhere
    // else in this engine and it is exact here.
    {VD_CODEC_H264, 1920, 1080, 24000, 1001, 5000000},
    // Vertical. The same pixels as 1920x1080 turned on their side, at twice
    // the rate, so twice the bits — and nothing about the shape matters.
    {VD_CODEC_H264, 1080, 1920, 60, 1, 12400000},
    {VD_CODEC_H264, 3840, 2160, 30, 1, 24900000},
    // The floor: a thumbnail-sized export at 200 kbps would look like a fax.
    {VD_CODEC_H264, 64, 64, 30, 1, 1000000},
    // The ceiling, which 8K60 walks straight into.
    {VD_CODEC_H264, 7680, 4320, 60, 1, 120000000},
    {VD_CODEC_HEVC, 1280, 720, 30, 1, 1700000},
    {VD_CODEC_HEVC, 1920, 1080, 30, 1, 3700000},
    {VD_CODEC_HEVC, 3840, 2160, 30, 1, 14900000},
    {VD_CODEC_HEVC, 3840, 2160, 60, 1, 29900000},
};

static void test_a_bitrate_is_bits_per_pixel_per_frame(void) {
  for (size_t i = 0; i < sizeof(kBitrates) / sizeof(kBitrates[0]); i++) {
    const VdRational rate = {kBitrates[i].num, kBitrates[i].den};
    const int64_t bits = vd_export_default_bitrate(
        kBitrates[i].codec, kBitrates[i].width, kBitrates[i].height, rate);
    vd_checks++;
    if (bits != kBitrates[i].bits) {
      vd_failures++;
      fprintf(stderr,
              "FAIL bitrate for %s %dx%d @ %d/%d\n  expected %lld\n"
              "  actual   %lld\n",
              kBitrates[i].codec == VD_CODEC_HEVC ? "HEVC" : "H.264",
              kBitrates[i].width, kBitrates[i].height, kBitrates[i].num,
              kBitrates[i].den, (long long)kBitrates[i].bits,
              (long long)bits);
    }
    // Every number reads like a decision rather than like arithmetic.
    VD_CHECK_EQ(bits % 100000, 0);
  }

  // A size with no pixels in it has no answer, rather than the floor.
  const VdRational thirty = {30, 1};
  VD_CHECK_EQ(vd_export_default_bitrate(VD_CODEC_H264, 0, 1080, thirty), 0);
  VD_CHECK_EQ(vd_export_default_bitrate(VD_CODEC_H264, 1920, -1, thirty), 0);
}

static void test_free_space_is_asked_of_the_folder(void) {
  // The file does not exist yet — that is the whole point of asking before
  // writing it — so the question has to be about where it is going.
  const int64_t free_bytes = vd_export_free_bytes("/tmp/vd_export_nothing.mp4");
  VD_CHECK(free_bytes > 0);
  VD_CHECK_EQ(vd_export_free_bytes(NULL), -1);
  VD_CHECK_EQ(vd_export_free_bytes(""), -1);
  VD_CHECK_EQ(vd_export_free_bytes("/no/such/volume/anywhere/file.mp4"), -1);
}

// --- writing a file --------------------------------------------------------

static void test_an_export_is_a_file_the_world_can_open(void) {
  const char* path = output("h264");
  VdTimelineClip clip;
  VdTimeline timeline =
      one_clip_timeline(&clip, "cfr_30fps_stereo.mp4", 2 * SECOND);

  int32_t result = VD_ERR_OPEN;
  VdExport* handle =
      vd_export_start(&timeline, path, vd_export_default_settings(), &result);
  VD_CHECK_EQ(result, VD_OK);
  if (!handle) return;

  VD_CHECK_EQ(run_to_completion(handle, 60000), VD_EXPORT_DONE);

  VdExportProgress progress;
  vd_export_progress(handle, &progress);
  VD_CHECK_EQ(progress.error, VD_OK);
  // Two seconds at thirty is sixty frames, and every one of them was written.
  VD_CHECK_EQ(progress.frames_total, 60);
  VD_CHECK_EQ(progress.frames_written, 60);
  VD_CHECK_EQ(progress.position, 2 * SECOND);

  VdProbeInfo info;
  VD_CHECK_EQ(vd_probe_file(path, &info), VD_OK);
  VD_CHECK(info.has_video);
  VD_CHECK(info.has_audio);
  VD_CHECK_EQ(info.width, 320);
  VD_CHECK_EQ(info.height, 240);
  VD_CHECK_STR(info.video_codec, "h264");
  VD_CHECK_STR(info.audio_codec, "aac");
  VD_CHECK_EQ(info.audio_sample_rate, VD_AUDIO_SAMPLE_RATE);
  VD_CHECK_EQ(info.audio_channels, VD_AUDIO_CHANNELS);
  VD_CHECK_EQ(info.frame_rate.num, 30);
  VD_CHECK_EQ(info.frame_rate.den, 1);
  // Within a frame of the two seconds asked for.
  VD_CHECK(info.duration > 2 * SECOND - SECOND / 30);
  VD_CHECK(info.duration < 2 * SECOND + SECOND / 30);

  // The index before the payload, which is what faststart means and what makes
  // the file play in a browser before it has finished downloading.
  const long moov = offset_of(path, "moov");
  const long mdat = offset_of(path, "mdat");
  VD_CHECK(moov > 0);
  VD_CHECK(mdat > 0);
  VD_CHECK(moov < mdat);

  vd_export_destroy(handle);
  // Destroying a finished export does not take its file with it.
  VD_CHECK(file_size(path) > 0);
  remove(path);
}

static void test_hevc_is_tagged_the_way_players_expect(void) {
  const char* path = output("hevc");
  VdTimelineClip clip;
  VdTimeline timeline = one_clip_timeline(&clip, "solid_hd_709.mp4", SECOND);

  VdExportSettings settings = vd_export_default_settings();
  settings.codec = VD_CODEC_HEVC;

  int32_t result = VD_ERR_OPEN;
  VdExport* handle = vd_export_start(&timeline, path, settings, &result);
  if (result == VD_ERR_UNSUPPORTED) {
    // A machine with no HEVC encoder says so up front rather than failing a
    // second later, which is the whole reason that error exists.
    fprintf(stderr, "note: no HEVC encoder here; skipping\n");
    return;
  }
  VD_CHECK_EQ(result, VD_OK);
  if (!handle) return;

  VD_CHECK_EQ(run_to_completion(handle, 60000), VD_EXPORT_DONE);

  VdProbeInfo info;
  VD_CHECK_EQ(vd_probe_file(path, &info), VD_OK);
  VD_CHECK_STR(info.video_codec, "hevc");

  // `hvc1` and not `hev1`. The two are the same bitstream with the parameter
  // sets in different places, and QuickTime, Safari and most hardware players
  // will only open the first — so an export tagged `hev1` is one that works
  // everywhere the developer tested it and nowhere the user needs it.
  VD_CHECK(offset_of(path, "hvc1") > 0);
  VD_CHECK_EQ(offset_of(path, "hev1"), -1);

  vd_export_destroy(handle);
  remove(path);
}

// --- the same picture, the same sound --------------------------------------

// The claim the whole module exists to make: what came out is what the
// compositor drew. A flat green fixture through a lossy encoder is still flat
// green, so the tolerance can be tight enough to catch a wrong colour matrix
// or an upside-down frame while staying loose enough not to argue with H.264.
static void test_the_picture_is_the_one_the_preview_showed(void) {
  const char* path = output("picture");
  VdTimelineClip clip;
  VdTimeline timeline = one_clip_timeline(&clip, "solid_sd_601.mp4", SECOND);

  int32_t result = VD_ERR_OPEN;
  VdExport* handle =
      vd_export_start(&timeline, path, vd_export_default_settings(), &result);
  VD_CHECK_EQ(result, VD_OK);
  if (!handle) return;
  VD_CHECK_EQ(run_to_completion(handle, 60000), VD_EXPORT_DONE);
  vd_export_destroy(handle);

  VdDecoder* decoder = vd_decoder_open(path, vd_decoder_default_options(), NULL);
  VD_CHECK(decoder != NULL);
  if (!decoder) {
    remove(path);
    return;
  }
  VdFrame frame;
  memset(&frame, 0, sizeof(frame));
  VD_CHECK_EQ(vd_decoder_frame_at(decoder, SECOND / 2, &frame), VD_OK);

  if (frame.pixel_buffer) {
    // The fixture is BT.601 green; the export is tagged BT.709, and the point
    // of the tag is that a decoder reading it back arrives at the same RGB.
    // Comparing in YCbCr would test nothing, so this reads the luma plane and
    // asks only that it is the *level* the green has — which is what a swapped
    // matrix or a black frame would get wrong.
    CVPixelBufferRef pixels = (CVPixelBufferRef)frame.pixel_buffer;
    CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
    const uint8_t* luma =
        (const uint8_t*)(CVPixelBufferIsPlanar(pixels)
                             ? CVPixelBufferGetBaseAddressOfPlane(pixels, 0)
                             : CVPixelBufferGetBaseAddress(pixels));
    const size_t stride =
        CVPixelBufferIsPlanar(pixels)
            ? CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
            : CVPixelBufferGetBytesPerRow(pixels);
    const int centre = luma ? luma[(240 / 2) * stride + (320 / 2)] : 0;
    CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);

    // RGB (0, 200, 100) is about 150 of BT.709 luma, video range. A frame that
    // came out black, white, or through the wrong matrix misses this by far
    // more than the twelve levels allowed for the encoder.
    VD_CHECK(centre > 138 && centre < 162);
  }
  vd_frame_release(&frame);
  vd_decoder_close(decoder);
  remove(path);
}

static void test_the_sound_is_the_one_the_mixer_made(void) {
  const char* path = output("sound");
  VdTimelineClip clip;
  VdTimeline timeline =
      one_clip_timeline(&clip, "cfr_30fps_stereo.mp4", SECOND);

  int32_t result = VD_ERR_OPEN;
  VdExport* handle =
      vd_export_start(&timeline, path, vd_export_default_settings(), &result);
  VD_CHECK_EQ(result, VD_OK);
  if (!handle) return;
  VD_CHECK_EQ(run_to_completion(handle, 60000), VD_EXPORT_DONE);
  vd_export_destroy(handle);

  VdAudioSource* source = vd_audio_source_open(path, NULL);
  VD_CHECK(source != NULL);
  if (source) {
    static float samples[4096 * VD_AUDIO_CHANNELS];
    const int32_t got = vd_audio_source_read(source, samples, 4096);
    VD_CHECK(got > 0);
    float peak = 0;
    for (int32_t i = 0; i < got * VD_AUDIO_CHANNELS; i++) {
      const float value = samples[i] < 0 ? -samples[i] : samples[i];
      if (value > peak) peak = value;
    }
    // Something rather than nothing: an export that wrote a silent track would
    // pass every structural check above it and be useless.
    VD_CHECK(peak > 0.01f);
    vd_audio_source_close(source);
  }
  remove(path);
}

// A clip with its gain at zero is the case a "did any sound arrive" test would
// happily pass on: the track is there, the samples are not. This is the one
// that says the mixer, and not a bypass around it, is what filled the file.
static void test_a_silenced_clip_exports_silence(void) {
  const char* path = output("silence");
  VdTimelineClip clip;
  VdTimeline timeline =
      one_clip_timeline(&clip, "cfr_30fps_stereo.mp4", SECOND);
  clip.gain = 0.0f;

  int32_t result = VD_ERR_OPEN;
  VdExport* handle =
      vd_export_start(&timeline, path, vd_export_default_settings(), &result);
  VD_CHECK_EQ(result, VD_OK);
  if (!handle) return;
  VD_CHECK_EQ(run_to_completion(handle, 60000), VD_EXPORT_DONE);
  vd_export_destroy(handle);

  VdAudioSource* source = vd_audio_source_open(path, NULL);
  VD_CHECK(source != NULL);
  if (source) {
    static float samples[4096 * VD_AUDIO_CHANNELS];
    const int32_t got = vd_audio_source_read(source, samples, 4096);
    float peak = 0;
    for (int32_t i = 0; i < got * VD_AUDIO_CHANNELS; i++) {
      const float value = samples[i] < 0 ? -samples[i] : samples[i];
      if (value > peak) peak = value;
    }
    VD_CHECK(peak < 0.01f);
    vd_audio_source_close(source);
  }
  remove(path);
}

static void test_a_timeline_with_no_sound_gets_no_audio_track(void) {
  const char* path = output("mute");
  VdTimelineClip clip;
  VdTimeline timeline = one_clip_timeline(&clip, "solid_sd_601.mp4", SECOND);

  int32_t result = VD_ERR_OPEN;
  VdExport* handle =
      vd_export_start(&timeline, path, vd_export_default_settings(), &result);
  VD_CHECK_EQ(result, VD_OK);
  if (!handle) return;
  VD_CHECK_EQ(run_to_completion(handle, 60000), VD_EXPORT_DONE);
  vd_export_destroy(handle);

  VdProbeInfo info;
  VD_CHECK_EQ(vd_probe_file(path, &info), VD_OK);
  VD_CHECK(info.has_video);
  // A silent AAC stream is not a courtesy: it is a track every downstream tool
  // now has to have an opinion about.
  VD_CHECK(!info.has_audio);
  remove(path);
}

// --- the size the timeline asks for ----------------------------------------

// Nothing in the render list is measured in pixels, so exporting at a size the
// project was never cut at is one number changing. This is the mechanism the
// 4K-from-a-1080p-edit path rests on, tested at a size a unit test can afford.
static void test_the_timeline_decides_the_size(void) {
  const char* path = output("resized");
  VdTimelineClip clip;
  VdTimeline timeline = one_clip_timeline(&clip, "solid_sd_601.mp4", SECOND);
  timeline.width = 640;
  timeline.height = 480;

  int32_t result = VD_ERR_OPEN;
  VdExport* handle =
      vd_export_start(&timeline, path, vd_export_default_settings(), &result);
  VD_CHECK_EQ(result, VD_OK);
  if (!handle) return;
  VD_CHECK_EQ(run_to_completion(handle, 60000), VD_EXPORT_DONE);
  vd_export_destroy(handle);

  VdProbeInfo info;
  VD_CHECK_EQ(vd_probe_file(path, &info), VD_OK);
  VD_CHECK_EQ(info.width, 640);
  VD_CHECK_EQ(info.height, 480);
  remove(path);
}

// --- stopping --------------------------------------------------------------

static void test_cancelling_leaves_no_file(void) {
  const char* path = output("cancelled");
  VdTimelineClip clip;
  VdTimeline timeline =
      one_clip_timeline(&clip, "cfr_30fps_stereo.mp4", 60 * SECOND);

  int32_t result = VD_ERR_OPEN;
  VdExport* handle =
      vd_export_start(&timeline, path, vd_export_default_settings(), &result);
  VD_CHECK_EQ(result, VD_OK);
  if (!handle) return;

  // Let it get properly under way, so this is a cancel of something running
  // rather than a race with the thread starting.
  usleep(200000);
  vd_export_cancel(handle);
  VD_CHECK_EQ(run_to_completion(handle, 10000), VD_EXPORT_CANCELLED);

  VdExportProgress progress;
  vd_export_progress(handle, &progress);
  // Cancelling is not failing.
  VD_CHECK_EQ(progress.error, VD_OK);
  VD_CHECK(progress.frames_written < progress.frames_total);

  vd_export_destroy(handle);
  // Half a video is worse than none: it plays, it looks finished, and the part
  // that is missing is the ending.
  VD_CHECK_EQ(file_size(path), -1);
}

// Destroying a running export is a cancel, because the alternative is a thread
// still writing into memory that has been freed.
static void test_destroying_a_running_export_stops_it(void) {
  const char* path = output("destroyed");
  VdTimelineClip clip;
  VdTimeline timeline =
      one_clip_timeline(&clip, "cfr_30fps_stereo.mp4", 60 * SECOND);

  VdExport* handle =
      vd_export_start(&timeline, path, vd_export_default_settings(), NULL);
  VD_CHECK(handle != NULL);
  if (!handle) return;
  usleep(100000);
  vd_export_destroy(handle);
  VD_CHECK_EQ(file_size(path), -1);
}

// --- what it refuses -------------------------------------------------------

static void test_what_cannot_be_exported_is_refused_up_front(void) {
  VdTimelineClip clip;
  VdTimeline timeline = one_clip_timeline(&clip, "solid_sd_601.mp4", SECOND);
  VdExportSettings settings = vd_export_default_settings();

  int32_t result = VD_OK;
  VD_CHECK(vd_export_start(NULL, "/tmp/x.mp4", settings, &result) == NULL);
  VD_CHECK_EQ(result, VD_ERR_INVALID_ARG);

  VD_CHECK(vd_export_start(&timeline, NULL, settings, &result) == NULL);
  VD_CHECK_EQ(result, VD_ERR_INVALID_ARG);

  // A frame rate the tick model cannot express exactly. Refused here rather
  // than rounded, because a rounded rate is a file that drifts out of sync
  // with itself and nobody would know why.
  VdTimeline odd = timeline;
  odd.frame_rate = (VdRational){7, 1};
  VD_CHECK(vd_export_start(&odd, "/tmp/x.mp4", settings, &result) == NULL);
  VD_CHECK_EQ(result, VD_ERR_INVALID_ARG);

  // Nothing on the timeline is nothing to write, and AVAssetWriter cannot
  // finish a file with no samples in it anyway.
  VdTimeline empty = timeline;
  empty.clips = NULL;
  empty.clip_count = 0;
  VD_CHECK(vd_export_start(&empty, "/tmp/x.mp4", settings, &result) == NULL);
  VD_CHECK_EQ(result, VD_ERR_INVALID_ARG);

  // Somewhere that cannot be written to.
  const char* nowhere = "/no/such/folder/anywhere/out.mp4";
  VD_CHECK(vd_export_start(&timeline, nowhere, settings, &result) == NULL);
  VD_CHECK(result != VD_OK);

  // And the calls that take a handle survive not having one.
  vd_export_cancel(NULL);
  vd_export_destroy(NULL);
  VdExportProgress progress;
  vd_export_progress(NULL, &progress);
}

int main(void) {
  test_a_bitrate_is_bits_per_pixel_per_frame();
  test_free_space_is_asked_of_the_folder();
  test_an_export_is_a_file_the_world_can_open();
  test_hevc_is_tagged_the_way_players_expect();
  test_the_picture_is_the_one_the_preview_showed();
  test_the_sound_is_the_one_the_mixer_made();
  test_a_silenced_clip_exports_silence();
  test_a_timeline_with_no_sound_gets_no_audio_track();
  test_the_timeline_decides_the_size();
  test_cancelling_leaves_no_file();
  test_destroying_a_running_export_stops_it();
  test_what_cannot_be_exported_is_refused_up_front();
  return VD_REPORT();
}
