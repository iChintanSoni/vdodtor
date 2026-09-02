#include "vdodtor/vd_export.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include <atomic>
#include <libgen.h>
#include <limits.h>
#include <math.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <unistd.h>

#include "vdodtor/vd_audio.h"

// 192 kbps AAC-LC at 48 kHz stereo. See vd_export.h.
#define VD_EXPORT_DEFAULT_AUDIO_BITRATE 192000

// Audio is mixed and handed over in this many frames at a time — the same
// chunk the device asks for, which is what vd_audio_renderer_render_at is
// built around.
#define VD_EXPORT_AUDIO_CHUNK 1024

// A keyframe every two seconds. Short enough that scrubbing the exported file
// in someone else's player is not a slideshow, long enough that it costs a few
// per cent rather than a third of the bitrate.
#define VD_EXPORT_KEYFRAME_SECONDS 2.0

struct VdExport {
  // Its own engine, deliberately: an export renders at its own size and must
  // not move the playhead of whatever the user is looking at. Same code, two
  // instances — see the header.
  VdEngine* engine = nullptr;
  VdAudioRenderer* audio = nullptr;  // borrowed from `engine`

  AVAssetWriter* writer = nil;
  AVAssetWriterInput* video_input = nil;
  AVAssetWriterInputPixelBufferAdaptor* adaptor = nil;
  AVAssetWriterInput* audio_input = nil;  // nil when the timeline is silent
  CMFormatDescriptionRef pcm_format = nullptr;

  // One queue per medium, because the two really are independent: the picture
  // comes out of the compositor and the sound out of the mixer, and neither
  // waits for the other. The writer is what interleaves them.
  dispatch_queue_t video_queue = nil;
  dispatch_queue_t audio_queue = nil;
  dispatch_semaphore_t video_done = nil;
  dispatch_semaphore_t audio_done = nil;

  char* path = nullptr;
  int32_t width = 0;
  int32_t height = 0;
  VdRational frame_rate = {30, 1};
  VdTick ticks_per_frame = 0;
  VdTick duration = 0;
  int64_t frames_total = 0;
  int64_t audio_frames_total = 0;

  // Where each producer has got to. Touched only on that producer's own queue,
  // which AVFoundation guarantees is serial — so no lock, and no atomic.
  int64_t next_frame = 0;
  int64_t next_audio_frame = 0;
  bool video_finished = false;
  bool audio_finished = false;

  // One chunk of the mix as the mixer makes it, and the same chunk as the
  // encoder wants it.
  float* mix = nullptr;
  int16_t* pcm = nullptr;

  pthread_t thread;
  bool thread_running = false;

  // Everything that crosses between the producers and whoever is drawing a
  // progress bar.
  std::atomic<int32_t> state{VD_EXPORT_RUNNING};
  std::atomic<int64_t> frames_written{0};
  std::atomic<int32_t> error{VD_OK};
  std::atomic<bool> cancelled{false};
  std::atomic<bool> failed{false};
  std::atomic<int64_t> elapsed_ns{0};
  uint64_t started_host = 0;
};

// --- host time -------------------------------------------------------------

static double g_ns_per_tick = 0.0;

static int64_t host_to_ns(uint64_t delta) {
  if (g_ns_per_tick == 0.0) {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    g_ns_per_tick = (double)info.numer / (double)info.denom;
  }
  return (int64_t)((double)delta * g_ns_per_tick);
}

// --- the numbers a preset is made of ---------------------------------------

VdExportSettings vd_export_default_settings(void) {
  VdExportSettings settings;
  memset(&settings, 0, sizeof(settings));
  settings.codec = VD_CODEC_H264;
  settings.include_audio = true;
  return settings;
}

int64_t vd_export_default_bitrate(VdExportCodec codec, int32_t width,
                                  int32_t height, VdRational frame_rate) {
  if (width <= 0 || height <= 0) return 0;
  double fps = frame_rate.den > 0 ? (double)frame_rate.num / frame_rate.den : 0;
  if (fps <= 0) fps = 30.0;

  // Bits per pixel per frame. HEVC gets a lower figure because that is the
  // whole of what it is for; the two numbers are the difference between the
  // codecs expressed as the only thing anybody notices about them.
  const double per_pixel = codec == VD_CODEC_HEVC ? 0.06 : 0.10;
  double bits = (double)width * (double)height * fps * per_pixel;

  if (bits < 1000000.0) bits = 1000000.0;
  if (bits > 120000000.0) bits = 120000000.0;

  // To the nearest 100 kbps, so the number reads like a decision rather than
  // like the output of the line above it.
  return (int64_t)((bits + 50000.0) / 100000.0) * 100000;
}

int64_t vd_export_free_bytes(const char* path) {
  if (!path || !*path) return -1;
  // The file itself will not exist yet, so the question is about its folder.
  char copy[PATH_MAX];
  snprintf(copy, sizeof(copy), "%s", path);
  const char* dir = dirname(copy);
  if (!dir) return -1;
  struct statfs fs;
  if (statfs(dir, &fs) != 0) return -1;
  return (int64_t)fs.f_bavail * (int64_t)fs.f_bsize;
}

// --- writing ---------------------------------------------------------------

static void fail_with(VdExport* e, int32_t error) {
  int32_t none = VD_OK;
  e->error.compare_exchange_strong(none, error);  // the first reason wins
  e->failed.store(true);
}

// True once the producers should stop, whatever their own progress says.
static bool stopping(VdExport* e) {
  return e->cancelled.load() || e->failed.load();
}

// Copies the compositor's frame into one of the encoder's own buffers.
//
// The copy is not laziness. The compositor publishes into a single pixel
// buffer and draws the next frame straight over it, and an encoder holds what
// it is handed until it has finished with it — so appending the compositor's
// buffer would have VideoToolbox reading frame 41 out of memory that frame 42
// is already being written into. The symptom would be occasional tearing under
// load, which is the kind of bug that looks like a driver problem for a week.
static bool append_frame(VdExport* e, CVPixelBufferRef source, CMTime pts) {
  CVPixelBufferPoolRef pool = e->adaptor.pixelBufferPool;
  if (!pool) return false;

  CVPixelBufferRef destination = NULL;
  if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool,
                                         &destination) != kCVReturnSuccess ||
      !destination) {
    return false;
  }

  CVPixelBufferLockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
  CVPixelBufferLockBaseAddress(destination, 0);
  const uint8_t* src = (const uint8_t*)CVPixelBufferGetBaseAddress(source);
  uint8_t* dst = (uint8_t*)CVPixelBufferGetBaseAddress(destination);
  const size_t src_stride = CVPixelBufferGetBytesPerRow(source);
  const size_t dst_stride = CVPixelBufferGetBytesPerRow(destination);
  size_t rows = CVPixelBufferGetHeight(source);
  if (rows > CVPixelBufferGetHeight(destination)) {
    rows = CVPixelBufferGetHeight(destination);
  }
  const size_t row_bytes = src_stride < dst_stride ? src_stride : dst_stride;
  if (src && dst) {
    for (size_t y = 0; y < rows; y++) {
      memcpy(dst + y * dst_stride, src + y * src_stride, row_bytes);
    }
  }
  CVPixelBufferUnlockBaseAddress(destination, 0);
  CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);

  const bool ok = src && dst &&
                  [e->adaptor appendPixelBuffer:destination
                           withPresentationTime:pts];
  CVPixelBufferRelease(destination);
  return ok;
}

// Mixes one chunk and hands it over as 16-bit PCM.
//
// Sixteen bits rather than the float the mixer works in, and the clamp is the
// reason rather than the size: summing lanes can leave a sample past ±1, and
// an encoder given one does something of its own choosing with it. Deciding
// here means the clipping is the same clipping every time, and it is the
// clipping a meter would have shown.
static bool append_audio(VdExport* e, int64_t frame_index, int32_t frames) {
  const VdTick position =
      vd_scale(frame_index, VD_TICKS_PER_SECOND, VD_AUDIO_SAMPLE_RATE);
  vd_audio_renderer_render_at(e->audio, position, e->mix, frames);

  const int32_t samples = frames * VD_AUDIO_CHANNELS;
  for (int32_t i = 0; i < samples; i++) {
    float value = e->mix[i];
    if (value > 1.0f) value = 1.0f;
    if (value < -1.0f) value = -1.0f;
    e->pcm[i] = (int16_t)lrintf(value * 32767.0f);
  }

  const size_t bytes = (size_t)samples * sizeof(int16_t);
  CMBlockBufferRef block = NULL;
  if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, bytes,
                                         kCFAllocatorDefault, NULL, 0, bytes,
                                         kCMBlockBufferAssureMemoryNowFlag,
                                         &block) != noErr) {
    return false;
  }
  if (CMBlockBufferReplaceDataBytes(e->pcm, block, 0, bytes) != noErr) {
    CFRelease(block);
    return false;
  }

  CMSampleBufferRef sample = NULL;
  const OSStatus status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      kCFAllocatorDefault, block, e->pcm_format, frames,
      CMTimeMake(frame_index, VD_AUDIO_SAMPLE_RATE), NULL, &sample);
  CFRelease(block);
  if (status != noErr || !sample) return false;

  const bool ok = [e->audio_input appendSampleBuffer:sample];
  CFRelease(sample);
  return ok;
}

// --- the two producers -----------------------------------------------------
//
// AVFoundation pulls; it is not pushed at, and the two are not
// interchangeable. An input that has had enough for the moment stops being
// ready, and what makes it ready again is the machinery behind the request
// block below. A loop of our own polling `isReadyForMoreMediaData` looks like
// it works — the picture alone will write to the end of a film that way — and
// then wedges permanently the first time a second input is added, because
// nothing is driving the queue that would have re-armed it.
//
// Each block is invoked serially on its own queue, so the cursor it advances
// needs no lock. It writes until the input has had enough, then returns and
// waits to be asked again; when there is nothing left it says so once, and the
// thread waiting on the semaphore closes the file.

static void finish_video(VdExport* e) {
  if (e->video_finished) return;
  e->video_finished = true;
  [e->video_input markAsFinished];
  dispatch_semaphore_signal(e->video_done);
}

static void finish_audio(VdExport* e) {
  if (e->audio_finished) return;
  e->audio_finished = true;
  [e->audio_input markAsFinished];
  dispatch_semaphore_signal(e->audio_done);
}

static void pull_video(VdExport* e) {
  while (e->video_input.isReadyForMoreMediaData) {
    if (stopping(e) || e->next_frame >= e->frames_total) break;
    @autoreleasepool {
      const VdTick position = e->next_frame * e->ticks_per_frame;

      // The line this whole file exists to reach: the renderer the preview
      // drives, asked for an instant a counter chose.
      if (vd_engine_render_at(e->engine, position) != VD_OK) {
        fail_with(e, VD_ERR_DECODE);
        break;
      }
      CVPixelBufferRef composited =
          (CVPixelBufferRef)vd_engine_copy_output(e->engine);
      if (!composited) {
        fail_with(e, VD_ERR_DECODE);
        break;
      }
      const bool ok = append_frame(
          e, composited,
          CMTimeMake(e->next_frame * e->frame_rate.den, e->frame_rate.num));
      CVPixelBufferRelease(composited);
      if (!ok) {
        fail_with(e, VD_ERR_OPEN);
        break;
      }
      e->next_frame++;
      e->frames_written.store(e->next_frame);
      e->elapsed_ns.store(host_to_ns(mach_absolute_time() - e->started_host));
    }
  }
  if (stopping(e) || e->next_frame >= e->frames_total) finish_video(e);
}

static void pull_audio(VdExport* e) {
  while (e->audio_input.isReadyForMoreMediaData) {
    if (stopping(e) || e->next_audio_frame >= e->audio_frames_total) break;
    @autoreleasepool {
      int32_t chunk = VD_EXPORT_AUDIO_CHUNK;
      if (e->next_audio_frame + chunk > e->audio_frames_total) {
        // The tail, which is a few hundred samples whenever the length is not
        // a whole number of chunks. A file whose sound stops before its
        // picture does has a click at the end of it.
        chunk = (int32_t)(e->audio_frames_total - e->next_audio_frame);
      }
      if (!append_audio(e, e->next_audio_frame, chunk)) {
        fail_with(e, VD_ERR_OPEN);
        break;
      }
      e->next_audio_frame += chunk;
    }
  }
  if (stopping(e) || e->next_audio_frame >= e->audio_frames_total) {
    finish_audio(e);
  }
}

// --- closing the file ------------------------------------------------------

// Waits for one producer to say it is done.
//
// Woken every quarter second rather than waiting outright, because a writer
// that has failed may never ask for data again — and this thread is the one
// vd_export_destroy joins, which is called from the UI. A wait that could not
// end would be a beachball rather than an error message.
//
// The giving-up path finishes the input *on its own queue*, which both stops
// AVFoundation invoking the block again and fences out an invocation already in
// flight: the queue is serial, so once this returns nothing is still inside the
// engine that is about to be freed.
static void wait_for_producer(VdExport* e, dispatch_queue_t queue,
                              dispatch_semaphore_t done,
                              void (*finish)(VdExport*)) {
  for (;;) {
    if (dispatch_semaphore_wait(
            done, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC)) == 0) {
      // Even on the ordinary path, wait for the queue to drain: the block
      // signalled from inside itself and has not necessarily returned.
      dispatch_sync(queue, ^{
      });
      return;
    }
    if (e->writer.status == AVAssetWriterStatusWriting) continue;
    fail_with(e, VD_ERR_OPEN);
    dispatch_sync(queue, ^{
      finish(e);
    });
    return;
  }
}

static void* finish_thread(void* arg) {
  VdExport* e = (VdExport*)arg;

  wait_for_producer(e, e->video_queue, e->video_done, finish_video);
  if (e->audio_input) {
    wait_for_producer(e, e->audio_queue, e->audio_done, finish_audio);
  }

  const bool cancelled = e->cancelled.load();
  const bool complete = !cancelled && !e->failed.load() &&
                        e->frames_written.load() == e->frames_total;

  @autoreleasepool {
    NSString* file = [NSString stringWithUTF8String:e->path];
    if (complete) {
      dispatch_semaphore_t written = dispatch_semaphore_create(0);
      [e->writer finishWritingWithCompletionHandler:^{
        dispatch_semaphore_signal(written);
      }];
      dispatch_semaphore_wait(written, DISPATCH_TIME_FOREVER);
      dispatch_release(written);
      if (e->writer.status == AVAssetWriterStatusCompleted) {
        e->error.store(VD_OK);
        e->state.store(VD_EXPORT_DONE);
      } else {
        [[NSFileManager defaultManager] removeItemAtPath:file error:nil];
        fail_with(e, VD_ERR_OPEN);
        e->state.store(VD_EXPORT_FAILED);
      }
    } else {
      // cancelWriting removes the file itself; the remove after it is for the
      // case where it did not get that far. Either way the promise in the
      // header holds: no half a video is left behind.
      [e->writer cancelWriting];
      [[NSFileManager defaultManager] removeItemAtPath:file error:nil];
      if (cancelled) {
        // Cancelling is not failing, and an error code here would put a red
        // message on something the user asked for.
        e->error.store(VD_OK);
        e->state.store(VD_EXPORT_CANCELLED);
      } else {
        fail_with(e, VD_ERR_DECODE);
        e->state.store(VD_EXPORT_FAILED);
      }
    }
  }

  e->elapsed_ns.store(host_to_ns(mach_absolute_time() - e->started_host));
  return NULL;
}

// --- setting it up ---------------------------------------------------------

static NSDictionary* video_settings(VdExport* e, VdExportSettings settings) {
  const int64_t bitrate =
      settings.video_bitrate > 0
          ? settings.video_bitrate
          : vd_export_default_bitrate(settings.codec, e->width, e->height,
                                      e->frame_rate);
  const double fps = (double)e->frame_rate.num / (double)e->frame_rate.den;

  NSMutableDictionary* compression = [NSMutableDictionary dictionary];
  compression[AVVideoAverageBitRateKey] = @(bitrate);
  compression[AVVideoExpectedSourceFrameRateKey] = @((int)(fps + 0.5));
  compression[AVVideoMaxKeyFrameIntervalDurationKey] =
      @(VD_EXPORT_KEYFRAME_SECONDS);
  compression[AVVideoAllowFrameReorderingKey] = @YES;
  if (settings.codec == VD_CODEC_H264) {
    compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel;
  }

  return @{
    AVVideoCodecKey : settings.codec == VD_CODEC_HEVC ? AVVideoCodecTypeHEVC
                                                      : AVVideoCodecTypeH264,
    AVVideoWidthKey : @(e->width),
    AVVideoHeightKey : @(e->height),
    AVVideoCompressionPropertiesKey : compression,
    // Said rather than left to the encoder to guess. The compositor works in
    // Rec.709 whatever the sources were coded in — that is what ycbcr_to_rgb
    // produces and where the grade is applied — so an untagged SD-sized export
    // would be read back as 601 by half the players in the world and come out
    // with its colours very slightly wrong.
    AVVideoColorPropertiesKey : @{
      AVVideoColorPrimariesKey : AVVideoColorPrimaries_ITU_R_709_2,
      AVVideoTransferFunctionKey : AVVideoTransferFunction_ITU_R_709_2,
      AVVideoYCbCrMatrixKey : AVVideoYCbCrMatrix_ITU_R_709_2,
    },
  };
}

static NSDictionary* audio_settings(int32_t bitrate) {
  AudioChannelLayout layout;
  memset(&layout, 0, sizeof(layout));
  layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
  return @{
    AVFormatIDKey : @(kAudioFormatMPEG4AAC),
    AVSampleRateKey : @(VD_AUDIO_SAMPLE_RATE),
    AVNumberOfChannelsKey : @(VD_AUDIO_CHANNELS),
    AVEncoderBitRateKey : @(bitrate > 0 ? bitrate
                                        : VD_EXPORT_DEFAULT_AUDIO_BITRATE),
    AVChannelLayoutKey : [NSData dataWithBytes:&layout length:sizeof(layout)],
  };
}

// What the mixer's chunks are handed over as: 16-bit interleaved stereo at the
// engine's own rate, which is what a WAV file is and what every AAC encoder in
// the world will take.
static bool make_pcm_format(VdExport* e) {
  AudioStreamBasicDescription asbd;
  memset(&asbd, 0, sizeof(asbd));
  asbd.mSampleRate = VD_AUDIO_SAMPLE_RATE;
  asbd.mFormatID = kAudioFormatLinearPCM;
  asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
  asbd.mChannelsPerFrame = VD_AUDIO_CHANNELS;
  asbd.mBitsPerChannel = 16;
  asbd.mFramesPerPacket = 1;
  asbd.mBytesPerFrame = VD_AUDIO_CHANNELS * 2;
  asbd.mBytesPerPacket = asbd.mBytesPerFrame;
  return CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0,
                                        NULL, NULL, &e->pcm_format) == noErr;
}

VdExport* vd_export_start(const VdTimeline* timeline, const char* path,
                          VdExportSettings settings, int32_t* out_result) {
  if (out_result) *out_result = VD_OK;
  if (!timeline || !path || !*path || timeline->width <= 0 ||
      timeline->height <= 0) {
    if (out_result) *out_result = VD_ERR_INVALID_ARG;
    return NULL;
  }
  const VdTick ticks_per_frame = vd_ticks_per_frame(timeline->frame_rate);
  if (ticks_per_frame <= 0) {
    if (out_result) *out_result = VD_ERR_INVALID_ARG;
    return NULL;
  }

  VdExport* e = new VdExport();
  e->width = timeline->width;
  e->height = timeline->height;
  e->frame_rate = timeline->frame_rate;
  e->ticks_per_frame = ticks_per_frame;
  e->path = strdup(path);
  e->mix = (float*)calloc((size_t)VD_EXPORT_AUDIO_CHUNK * VD_AUDIO_CHANNELS,
                          sizeof(float));
  e->pcm = (int16_t*)calloc((size_t)VD_EXPORT_AUDIO_CHUNK * VD_AUDIO_CHANNELS,
                            sizeof(int16_t));
  if (!e->path || !e->mix || !e->pcm) {
    vd_export_destroy(e);
    if (out_result) *out_result = VD_ERR_OPEN;
    return NULL;
  }

  // No output device: an export must not make a noise, and there is nothing
  // for a sound card to keep up with.
  VdEngineOptions options = vd_engine_default_options();
  options.audio_output = 0;
  int32_t result = VD_OK;
  e->engine = vd_engine_create_with_options(options, &result);
  if (!e->engine) {
    vd_export_destroy(e);
    if (out_result) *out_result = result != VD_OK ? result : VD_ERR_OPEN;
    return NULL;
  }
  result = vd_engine_set_timeline(e->engine, timeline);
  if (result != VD_OK) {
    vd_export_destroy(e);
    if (out_result) *out_result = result;
    return NULL;
  }
  e->audio = vd_engine_audio_renderer(e->engine);

  e->duration = vd_engine_duration(e->engine);
  if (e->duration <= 0) {
    // Nothing to write. Refused here rather than left to produce a zero-length
    // file, which AVAssetWriter cannot finish anyway.
    vd_export_destroy(e);
    if (out_result) *out_result = VD_ERR_INVALID_ARG;
    return NULL;
  }
  // Rounded up: a timeline that ends part-way through a frame still gets that
  // frame, because an export shorter than the project is a missing ending.
  e->frames_total = (e->duration + ticks_per_frame - 1) / ticks_per_frame;

  const bool wants_audio = settings.include_audio && e->audio &&
                           vd_audio_renderer_has_audio(e->audio);
  e->audio_frames_total =
      wants_audio
          ? vd_scale(e->duration, VD_AUDIO_SAMPLE_RATE, VD_TICKS_PER_SECOND)
          : 0;

  @autoreleasepool {
    NSString* file = [NSString stringWithUTF8String:path];
    NSURL* url = [NSURL fileURLWithPath:file];
    // AVAssetWriter refuses a URL that already exists rather than overwriting,
    // and the user has already agreed to overwrite it in the save panel.
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];

    NSError* error = nil;
    e->writer = [[AVAssetWriter alloc] initWithURL:url
                                          fileType:AVFileTypeMPEG4
                                             error:&error];
    if (!e->writer) {
      vd_export_destroy(e);
      if (out_result) *out_result = VD_ERR_OPEN;
      return NULL;
    }
    // Faststart: the index goes at the front, so the file begins playing in a
    // browser before it has finished downloading. It costs a rewrite of the
    // whole file at the end, which is why it is a flag and not the default.
    e->writer.shouldOptimizeForNetworkUse = YES;

    NSDictionary* video = video_settings(e, settings);
    if (![e->writer canApplyOutputSettings:video forMediaType:AVMediaTypeVideo]) {
      // The machine cannot encode what was asked for — an old Intel Mac asked
      // for HEVC, in practice. Worth its own error: the fix is to pick the
      // other codec, and "the export failed" does not say that.
      vd_export_destroy(e);
      if (out_result) *out_result = VD_ERR_UNSUPPORTED;
      return NULL;
    }
    e->video_input =
        [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo
                                       outputSettings:video];
    e->video_input.expectsMediaDataInRealTime = NO;
    e->adaptor = [[AVAssetWriterInputPixelBufferAdaptor alloc]
           initWithAssetWriterInput:e->video_input
        sourcePixelBufferAttributes:@{
          (NSString*)kCVPixelBufferPixelFormatTypeKey :
              @(kCVPixelFormatType_32BGRA),
          (NSString*)kCVPixelBufferWidthKey : @(e->width),
          (NSString*)kCVPixelBufferHeightKey : @(e->height),
          (NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{},
        }];
    if (![e->writer canAddInput:e->video_input]) {
      vd_export_destroy(e);
      if (out_result) *out_result = VD_ERR_UNSUPPORTED;
      return NULL;
    }
    [e->writer addInput:e->video_input];

    if (wants_audio && make_pcm_format(e)) {
      e->audio_input = [[AVAssetWriterInput alloc]
          initWithMediaType:AVMediaTypeAudio
             outputSettings:audio_settings(settings.audio_bitrate)];
      e->audio_input.expectsMediaDataInRealTime = NO;
      if ([e->writer canAddInput:e->audio_input]) {
        [e->writer addInput:e->audio_input];
      } else {
        [e->audio_input release];
        e->audio_input = nil;
      }
    }

    if (![e->writer startWriting]) {
      vd_export_destroy(e);
      if (out_result) *out_result = VD_ERR_OPEN;
      return NULL;
    }
    [e->writer startSessionAtSourceTime:kCMTimeZero];
  }

  e->started_host = mach_absolute_time();
  e->video_done = dispatch_semaphore_create(0);
  e->audio_done = dispatch_semaphore_create(0);
  e->video_queue =
      dispatch_queue_create("vdodtor.export.video", DISPATCH_QUEUE_SERIAL);
  e->audio_queue =
      dispatch_queue_create("vdodtor.export.audio", DISPATCH_QUEUE_SERIAL);

  if (pthread_create(&e->thread, NULL, finish_thread, e) != 0) {
    vd_export_destroy(e);
    if (out_result) *out_result = VD_ERR_OPEN;
    return NULL;
  }
  e->thread_running = true;

  // Last, so nothing starts producing into a half-built export.
  [e->video_input requestMediaDataWhenReadyOnQueue:e->video_queue
                                        usingBlock:^{
                                          pull_video(e);
                                        }];
  if (e->audio_input) {
    [e->audio_input requestMediaDataWhenReadyOnQueue:e->audio_queue
                                          usingBlock:^{
                                            pull_audio(e);
                                          }];
  }
  return e;
}

void vd_export_progress(VdExport* e, VdExportProgress* out) {
  if (!e || !out) return;
  memset(out, 0, sizeof(*out));
  out->state = e->state.load();
  out->frames_written = e->frames_written.load();
  out->frames_total = e->frames_total;
  out->position = out->frames_written * e->ticks_per_frame;
  out->error = e->error.load();
  out->elapsed_ms = (double)e->elapsed_ns.load() / 1e6;
}

void vd_export_cancel(VdExport* e) {
  if (!e) return;
  e->cancelled.store(true);
}

void vd_export_destroy(VdExport* e) {
  if (!e) return;

  if (e->thread_running) {
    e->cancelled.store(true);
    // The producers notice the next time they are asked for data, which is
    // within a frame, and the thread closes the file once both have stopped.
    // Joining is what makes freeing the engine below safe: a request block
    // that outlived it would be rendering into memory that is gone.
    pthread_join(e->thread, NULL);
    e->thread_running = false;
  }

  // One rule for the file, and it is the promise the header makes: it survives
  // only a finished export. A run that was cancelled or failed has already
  // removed it on the thread, and removing it again costs nothing; a setup
  // that failed part-way never had a thread to do it, and AVAssetWriter has
  // already created the file by the time most of those failures happen.
  if (e->state.load() != VD_EXPORT_DONE && e->path) unlink(e->path);

  if (e->pcm_format) CFRelease(e->pcm_format);
  [e->adaptor release];
  [e->video_input release];
  [e->audio_input release];
  [e->writer release];
  if (e->video_queue) dispatch_release(e->video_queue);
  if (e->audio_queue) dispatch_release(e->audio_queue);
  if (e->video_done) dispatch_release(e->video_done);
  if (e->audio_done) dispatch_release(e->audio_done);

  // The audio renderer is the engine's, not ours.
  if (e->engine) vd_engine_destroy(e->engine);

  free(e->mix);
  free(e->pcm);
  free(e->path);
  delete e;
}
