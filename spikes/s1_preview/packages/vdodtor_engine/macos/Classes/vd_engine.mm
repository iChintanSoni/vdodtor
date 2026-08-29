// vd_engine.mm — S1 spike implementation.
//
// Threads:
//   decode  : demux + VideoToolbox decode -> bounded frame queue
//   present : pulls by media clock, runs the Metal composite, publishes output
// Flutter pulls the published buffer from copyPixelBuffer on the raster thread.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>
#import <simd/simd.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
#include <libavutil/opt.h>
}

#include "vd_engine.h"

#include <thread>
#include <mutex>
#include <condition_variable>
#include <deque>
#include <atomic>
#include <algorithm>

// ---------------------------------------------------------------- utilities

static uint64_t host_now_ns() {
  static mach_timebase_info_data_t tb;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ mach_timebase_info(&tb); });
  return mach_absolute_time() * tb.numer / tb.denom;
}

static double process_cpu_seconds() {
  task_thread_times_info_data_t t;
  mach_msg_type_number_t c = TASK_THREAD_TIMES_INFO_COUNT;
  double total = 0;
  if (task_info(mach_task_self(), TASK_THREAD_TIMES_INFO, (task_info_t)&t, &c) == KERN_SUCCESS) {
    total += t.user_time.seconds + t.user_time.microseconds / 1e6;
    total += t.system_time.seconds + t.system_time.microseconds / 1e6;
  }
  task_basic_info_64_data_t b;
  c = TASK_BASIC_INFO_64_COUNT;
  if (task_info(mach_task_self(), TASK_BASIC_INFO_64, (task_info_t)&b, &c) == KERN_SUCCESS) {
    total += b.user_time.seconds + b.user_time.microseconds / 1e6;
    total += b.system_time.seconds + b.system_time.microseconds / 1e6;
  }
  return total;
}

// Rolling mean that reacts quickly but stays readable.
static inline void roll(std::atomic<double>& slot, double sample) {
  slot.store(slot.load() * 0.9 + sample * 0.1);
}

static NSString* const kShaderSource = @R"METAL(
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float2 uv; };

// rect = (x, y, w, h) in normalized top-left-origin space.
vertex VOut vd_vertex(uint vid [[vertex_id]], constant float4& rect [[buffer(0)]]) {
  float2 quad[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
  float2 p = quad[vid];
  float2 n = rect.xy + p * rect.zw;
  VOut o;
  o.pos = float4(n.x * 2.0 - 1.0, 1.0 - n.y * 2.0, 0.0, 1.0);
  o.uv  = p;
  return o;
}

// params = (isVideoRange, alpha, unused, unused)
fragment float4 vd_fragment(VOut in [[stage_in]],
                            texture2d<float> yTex    [[texture(0)]],
                            texture2d<float> cbcrTex [[texture(1)]],
                            constant float4& params  [[buffer(0)]]) {
  constexpr sampler s(filter::linear, address::clamp_to_edge);
  float  y    = yTex.sample(s, in.uv).r;
  float2 cbcr = cbcrTex.sample(s, in.uv).rg;

  y = (y - params.x * (16.0/255.0)) * mix(1.0, 255.0/219.0, params.x);
  float2 c = (cbcr - 0.5) * mix(1.0, 255.0/224.0, params.x);

  // BT.709 limited/full -> linear-ish RGB (display-referred for the spike).
  float r = y + 1.5748 * c.y;
  float g = y - 0.1873 * c.x - 0.4681 * c.y;
  float b = y + 1.8556 * c.x;
  return float4(saturate(float3(r, g, b)), params.y);
}
)METAL";

// ---------------------------------------------------------------- engine

namespace {

struct Frame {
  CVPixelBufferRef pb = nullptr;
  int64_t pts_ns = 0;
};

constexpr size_t kMaxQueue = 6;

}  // namespace

struct VdEngine {
  // --- FFmpeg
  AVFormatContext* fmt = nullptr;
  AVCodecContext*  dec = nullptr;
  AVBufferRef*     hwctx = nullptr;
  int              vstream = -1;
  AVRational       tb{1, 1000};
  int64_t          duration_ns = 0;
  int64_t          frame_dur_ns = 16666666;

  // --- Metal
  id<MTLDevice>               device = nil;
  id<MTLCommandQueue>         queue = nil;
  id<MTLRenderPipelineState>  pso = nil;
  CVMetalTextureCacheRef      texCache = nullptr;
  CVPixelBufferPoolRef        pool = nullptr;

  // --- published output
  std::mutex        outMx;
  CVPixelBufferRef  latest = nullptr;

  // --- frame queue
  std::mutex              qMx;
  std::condition_variable qCv;
  std::deque<Frame>       q;

  // --- threads
  std::thread       decodeThread, presentThread;
  std::atomic<bool> running{false};
  std::atomic<int>  state{0};
  std::atomic<int>  layers{1};

  // --- clock (media ns anchored to host ns)
  std::mutex clkMx;
  int64_t    clockBaseNs = 0;
  uint64_t   anchorHost = 0;
  std::atomic<bool> playing{false};

  // --- seek
  std::mutex           seekMx;
  std::atomic<bool>    seekReq{false};
  std::atomic<int64_t> seekTarget{0};
  std::atomic<uint64_t> seekStartHost{0};
  std::atomic<bool>    seekTiming{false};

  // --- stats
  std::atomic<int64_t> nDecoded{0}, nPresented{0}, nDropped{0};
  std::atomic<double>  decodeMs{0}, compMs{0}, presentFps{0}, lastSeekMs{0};
  std::atomic<int64_t> fpsWindowCount{0};
  std::atomic<uint64_t> fpsWindowStart{0};
  double lastCpuSeconds = 0;
  uint64_t lastCpuHost = 0;

  int srcW = 0, srcH = 0, outW = 0, outH = 0;

  VdFrameCallback cb = nullptr;
  void* cbCtx = nullptr;

  int64_t nowMediaNs() {
    std::lock_guard<std::mutex> lk(clkMx);
    if (!playing.load()) return clockBaseNs;
    return clockBaseNs + (int64_t)(host_now_ns() - anchorHost);
  }

  void setClock(int64_t mediaNs) {
    std::lock_guard<std::mutex> lk(clkMx);
    clockBaseNs = mediaNs;
    anchorHost = host_now_ns();
  }
};

// ---------------------------------------------------------------- decode side

static enum AVPixelFormat pick_hw_format(AVCodecContext*, const enum AVPixelFormat* fmts) {
  for (const enum AVPixelFormat* p = fmts; *p != AV_PIX_FMT_NONE; ++p) {
    if (*p == AV_PIX_FMT_VIDEOTOOLBOX) return *p;
  }
  NSLog(@"[vd] videotoolbox pixel format unavailable; hw decode not negotiated");
  return AV_PIX_FMT_NONE;
}

static void clear_queue(VdEngine* e) {
  std::lock_guard<std::mutex> lk(e->qMx);
  for (auto& f : e->q) if (f.pb) CFRelease(f.pb);
  e->q.clear();
}

static void decode_loop(VdEngine* e) {
  pthread_setname_np("vd.decode");
  AVPacket* pkt = av_packet_alloc();
  AVFrame*  frm = av_frame_alloc();
  bool eof = false;

  while (e->running.load()) {
    // ---- pending seek
    if (e->seekReq.exchange(false)) {
      int64_t target = e->seekTarget.load();
      int64_t ts = av_rescale_q(target, AVRational{1, 1000000000}, e->tb);
      av_seek_frame(e->fmt, e->vstream, ts, AVSEEK_FLAG_BACKWARD);
      avcodec_flush_buffers(e->dec);
      clear_queue(e);
      eof = false;
      e->state.store(e->playing.load() ? 1 : 2);
    }

    if (eof) {
      std::unique_lock<std::mutex> lk(e->qMx);
      e->qCv.wait_for(lk, std::chrono::milliseconds(20));
      continue;
    }

    // ---- backpressure
    {
      std::unique_lock<std::mutex> lk(e->qMx);
      e->qCv.wait_for(lk, std::chrono::milliseconds(5),
                      [&] { return e->q.size() < kMaxQueue || !e->running.load() || e->seekReq.load(); });
      if (e->q.size() >= kMaxQueue) continue;
    }
    if (e->seekReq.load()) continue;

    int r = av_read_frame(e->fmt, pkt);
    if (r < 0) {
      avcodec_send_packet(e->dec, nullptr);  // flush
      eof = true;
    } else if (pkt->stream_index != e->vstream) {
      av_packet_unref(pkt);
      continue;
    } else {
      uint64_t t0 = host_now_ns();
      int sr = avcodec_send_packet(e->dec, pkt);
      av_packet_unref(pkt);
      if (sr < 0 && sr != AVERROR(EAGAIN)) continue;
      (void)t0;
    }

    while (true) {
      uint64_t t0 = host_now_ns();
      int rr = avcodec_receive_frame(e->dec, frm);
      if (rr == AVERROR(EAGAIN)) break;
      if (rr == AVERROR_EOF) { e->state.store(3); break; }
      if (rr < 0) break;

      roll(e->decodeMs, (host_now_ns() - t0) / 1e6);

      if (frm->format != AV_PIX_FMT_VIDEOTOOLBOX || !frm->data[3]) {
        av_frame_unref(frm);
        continue;
      }
      CVPixelBufferRef pb = (CVPixelBufferRef)frm->data[3];
      CFRetain(pb);

      int64_t pts = frm->best_effort_timestamp;
      if (pts == AV_NOPTS_VALUE) pts = frm->pts;
      Frame f;
      f.pb = pb;
      f.pts_ns = (pts == AV_NOPTS_VALUE)
                     ? 0
                     : av_rescale_q(pts, e->tb, AVRational{1, 1000000000});
      av_frame_unref(frm);

      {
        std::lock_guard<std::mutex> lk(e->qMx);
        e->q.push_back(f);
      }
      e->nDecoded.fetch_add(1);
      e->qCv.notify_all();
    }
  }

  av_frame_free(&frm);
  av_packet_free(&pkt);
}

// ---------------------------------------------------------------- composite

static void publish(VdEngine* e, CVPixelBufferRef out) {
  {
    std::lock_guard<std::mutex> lk(e->outMx);
    if (e->latest) CFRelease(e->latest);
    e->latest = out;  // takes ownership
  }
  if (e->cb) e->cb(e->cbCtx);
}

// Composites `src` (NV12 from VideoToolbox) into a pooled BGRA buffer.
static void composite(VdEngine* e, CVPixelBufferRef src) {
  CVPixelBufferRef out = nullptr;
  if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, e->pool, &out) != kCVReturnSuccess) {
    return;  // pool exhausted: Flutter still holds buffers; skip this frame
  }

  OSType pf = CVPixelBufferGetPixelFormatType(src);
  float isVideoRange = (pf == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) ? 1.0f : 0.0f;

  size_t w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src);
  CVMetalTextureRef yRef = nullptr, cRef = nullptr, oRef = nullptr;

  CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, e->texCache, src, nullptr,
                                            MTLPixelFormatR8Unorm, w, h, 0, &yRef);
  CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, e->texCache, src, nullptr,
                                            MTLPixelFormatRG8Unorm, w / 2, h / 2, 1, &cRef);
  CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, e->texCache, out, nullptr,
                                            MTLPixelFormatBGRA8Unorm, e->outW, e->outH, 0, &oRef);
  if (!yRef || !cRef || !oRef) {
    if (yRef) CFRelease(yRef);
    if (cRef) CFRelease(cRef);
    if (oRef) CFRelease(oRef);
    CFRelease(out);
    return;
  }

  MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture = CVMetalTextureGetTexture(oRef);
  rp.colorAttachments[0].loadAction = MTLLoadActionClear;
  rp.colorAttachments[0].storeAction = MTLStoreActionStore;
  rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);

  id<MTLCommandBuffer> cmd = [e->queue commandBuffer];
  id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rp];
  [enc setRenderPipelineState:e->pso];
  [enc setFragmentTexture:CVMetalTextureGetTexture(yRef) atIndex:0];
  [enc setFragmentTexture:CVMetalTextureGetTexture(cRef) atIndex:1];

  int n = std::max(1, std::min(8, e->layers.load()));
  for (int i = 0; i < n; ++i) {
    simd_float4 rect, params;
    if (i == 0) {
      rect = simd_make_float4(0, 0, 1, 1);
      params = simd_make_float4(isVideoRange, 1.0f, 0, 0);
    } else {
      // Stacked picture-in-picture layers: the real compositor's overlay path.
      float s = 0.34f - i * 0.02f;
      rect = simd_make_float4(0.62f - i * 0.06f, 0.60f - i * 0.06f, s, s);
      params = simd_make_float4(isVideoRange, 0.85f, 0, 0);
    }
    [enc setVertexBytes:&rect length:sizeof(rect) atIndex:0];
    [enc setFragmentBytes:&params length:sizeof(params) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  }
  [enc endEncoding];

  __block CVMetalTextureRef byRef = yRef, bcRef = cRef, boRef = oRef;
  [cmd addCompletedHandler:^(id<MTLCommandBuffer> done) {
    roll(e->compMs, ([done GPUEndTime] - [done GPUStartTime]) * 1000.0);
    CFRelease(byRef);
    CFRelease(bcRef);
    CFRelease(boRef);
    publish(e, out);  // ownership transfers to the published slot

    e->nPresented.fetch_add(1);
    int64_t c = e->fpsWindowCount.fetch_add(1) + 1;
    uint64_t start = e->fpsWindowStart.load();
    uint64_t now = host_now_ns();
    if (now - start >= 1000000000ull) {
      e->presentFps.store(c * 1e9 / (double)(now - start));
      e->fpsWindowCount.store(0);
      e->fpsWindowStart.store(now);
    }
    if (e->seekTiming.exchange(false)) {
      e->lastSeekMs.store((now - e->seekStartHost.load()) / 1e6);
    }
  }];
  [cmd commit];
}

// ---------------------------------------------------------------- present side

static void present_loop(VdEngine* e) {
  pthread_setname_np("vd.present");
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

  while (e->running.load()) {
    Frame chosen;
    bool have = false;
    int64_t now = e->nowMediaNs();
    // Half a frame of slack: show a frame once its deadline is within reach.
    int64_t slack = e->frame_dur_ns / 2;

    {
      std::lock_guard<std::mutex> lk(e->qMx);
      while (!e->q.empty() && e->q.front().pts_ns <= now + slack) {
        if (have) {                 // a newer frame is also due: the older one is late
          CFRelease(chosen.pb);
          e->nDropped.fetch_add(1);
        }
        chosen = e->q.front();
        e->q.pop_front();
        have = true;
        if (!e->playing.load()) break;   // paused/scrub: exactly one frame
      }
    }
    e->qCv.notify_all();

    if (have) {
      composite(e, chosen.pb);
      CFRelease(chosen.pb);
      if (!e->playing.load()) e->setClock(chosen.pts_ns);
    } else {
      std::this_thread::sleep_for(std::chrono::microseconds(1000));
    }
  }
}

// ---------------------------------------------------------------- public API

VdEngine* vd_engine_create(void) {
  VdEngine* e = new VdEngine();
  e->device = MTLCreateSystemDefaultDevice();
  if (!e->device) {
    NSLog(@"[vd] no Metal device");
    delete e;
    return nullptr;
  }
  e->queue = [e->device newCommandQueue];

  NSError* err = nil;
  id<MTLLibrary> lib = [e->device newLibraryWithSource:kShaderSource options:nil error:&err];
  if (!lib) {
    NSLog(@"[vd] shader compile failed: %@", err);
    delete e;
    return nullptr;
  }
  MTLRenderPipelineDescriptor* d = [[MTLRenderPipelineDescriptor alloc] init];
  d.vertexFunction = [lib newFunctionWithName:@"vd_vertex"];
  d.fragmentFunction = [lib newFunctionWithName:@"vd_fragment"];
  d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  d.colorAttachments[0].blendingEnabled = YES;
  d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
  d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  e->pso = [e->device newRenderPipelineStateWithDescriptor:d error:&err];
  if (!e->pso) {
    NSLog(@"[vd] pipeline failed: %@", err);
    delete e;
    return nullptr;
  }
  CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, e->device, nullptr, &e->texCache);
  e->lastCpuSeconds = process_cpu_seconds();
  e->lastCpuHost = host_now_ns();
  return e;
}

int32_t vd_engine_open(VdEngine* e, const char* path, int32_t out_w, int32_t out_h) {
  if (!e) return -1;

  if (avformat_open_input(&e->fmt, path, nullptr, nullptr) < 0) {
    NSLog(@"[vd] cannot open %s", path);
    e->state.store(-1);
    return -2;
  }
  if (avformat_find_stream_info(e->fmt, nullptr) < 0) { e->state.store(-1); return -3; }

  const AVCodec* codec = nullptr;
  e->vstream = av_find_best_stream(e->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
  if (e->vstream < 0) { e->state.store(-1); return -4; }

  AVStream* st = e->fmt->streams[e->vstream];
  e->tb = st->time_base;
  e->srcW = st->codecpar->width;
  e->srcH = st->codecpar->height;
  e->outW = out_w > 0 ? out_w : e->srcW;
  e->outH = out_h > 0 ? out_h : e->srcH;
  e->duration_ns = e->fmt->duration > 0 ? e->fmt->duration * 1000 : 0;

  AVRational fr = av_guess_frame_rate(e->fmt, st, nullptr);
  if (fr.num > 0 && fr.den > 0) e->frame_dur_ns = (int64_t)(1e9 * fr.den / fr.num);

  e->dec = avcodec_alloc_context3(codec);
  avcodec_parameters_to_context(e->dec, st->codecpar);
  e->dec->get_format = pick_hw_format;
  e->dec->pkt_timebase = st->time_base;

  if (av_hwdevice_ctx_create(&e->hwctx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nullptr, nullptr, 0) < 0) {
    NSLog(@"[vd] videotoolbox hwdevice create failed");
    e->state.store(-1);
    return -5;
  }
  e->dec->hw_device_ctx = av_buffer_ref(e->hwctx);
  if (avcodec_open2(e->dec, codec, nullptr) < 0) { e->state.store(-1); return -6; }

  NSDictionary* attrs = @{
    (NSString*)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (NSString*)kCVPixelBufferWidthKey : @(e->outW),
    (NSString*)kCVPixelBufferHeightKey : @(e->outH),
    (NSString*)kCVPixelBufferMetalCompatibilityKey : @YES,
    (NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };
  if (CVPixelBufferPoolCreate(kCFAllocatorDefault, nullptr,
                              (__bridge CFDictionaryRef)attrs, &e->pool) != kCVReturnSuccess) {
    e->state.store(-1);
    return -7;
  }

  NSLog(@"[vd] open ok: %dx%d -> %dx%d, %.3f fps, codec=%s",
        e->srcW, e->srcH, e->outW, e->outH,
        fr.den ? (double)fr.num / fr.den : 0.0, codec->name);

  e->running.store(true);
  e->state.store(2);
  e->fpsWindowStart.store(host_now_ns());
  e->decodeThread = std::thread(decode_loop, e);
  e->presentThread = std::thread(present_loop, e);
  return 0;
}

void vd_engine_play(VdEngine* e) {
  if (!e) return;
  e->setClock(e->nowMediaNs());
  e->playing.store(true);
  e->setClock(e->nowMediaNs());  // re-anchor now that playing is true
  e->state.store(1);
  e->qCv.notify_all();
}

void vd_engine_pause(VdEngine* e) {
  if (!e) return;
  int64_t at = e->nowMediaNs();
  e->playing.store(false);
  e->setClock(at);
  e->state.store(2);
}

void vd_engine_seek_ns(VdEngine* e, int64_t position_ns) {
  if (!e) return;
  e->seekStartHost.store(host_now_ns());
  e->seekTiming.store(true);
  e->seekTarget.store(position_ns);
  e->setClock(position_ns);
  e->seekReq.store(true);
  e->qCv.notify_all();
}

void vd_engine_set_layers(VdEngine* e, int32_t layers) {
  if (e) e->layers.store(layers);
}

void vd_engine_set_frame_callback(VdEngine* e, VdFrameCallback cb, void* ctx) {
  if (!e) return;
  e->cb = cb;
  e->cbCtx = ctx;
}

void* vd_engine_copy_output(VdEngine* e) {
  if (!e) return nullptr;
  std::lock_guard<std::mutex> lk(e->outMx);
  if (!e->latest) return nullptr;
  return (void*)CFRetain(e->latest);
}

int32_t vd_engine_dump_png(VdEngine* e, const char* path) {
  CVPixelBufferRef pb = (CVPixelBufferRef)vd_engine_copy_output(e);
  if (!pb) return -1;

  CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
  void* base = CVPixelBufferGetBaseAddress(pb);
  size_t bpr = CVPixelBufferGetBytesPerRow(pb);

  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(
      base, w, h, 8, bpr, cs,
      kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
  CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : nullptr;

  int32_t rc = -2;
  if (img) {
    NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    CGImageDestinationRef dst =
        CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (CFStringRef)@"public.png", 1, nullptr);
    if (dst) {
      CGImageDestinationAddImage(dst, img, nullptr);
      rc = CGImageDestinationFinalize(dst) ? 0 : -3;
      CFRelease(dst);
    }
    CGImageRelease(img);
  }
  if (ctx) CGContextRelease(ctx);
  CGColorSpaceRelease(cs);
  CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  CFRelease(pb);
  return rc;
}

void vd_engine_stats(VdEngine* e, VdStats* out) {
  if (!e || !out) return;
  out->frames_decoded = e->nDecoded.load();
  out->frames_presented = e->nPresented.load();
  out->frames_dropped = e->nDropped.load();
  out->decode_ms_avg = e->decodeMs.load();
  out->composite_ms_avg = e->compMs.load();
  out->present_fps = e->presentFps.load();
  out->position_ns = e->nowMediaNs();
  out->duration_ns = e->duration_ns;
  out->width = e->srcW;
  out->height = e->srcH;
  out->out_width = e->outW;
  out->out_height = e->outH;
  out->state = e->state.load();
  out->layers = e->layers.load();
  out->last_seek_ms = e->lastSeekMs.load();

  double cpu = process_cpu_seconds();
  uint64_t now = host_now_ns();
  double dt = (now - e->lastCpuHost) / 1e9;
  out->cpu_percent = dt > 0.01 ? (cpu - e->lastCpuSeconds) / dt * 100.0 : 0.0;
  if (dt > 0.01) {
    e->lastCpuSeconds = cpu;
    e->lastCpuHost = now;
  }
}

void vd_engine_destroy(VdEngine* e) {
  if (!e) return;
  e->running.store(false);
  e->qCv.notify_all();
  if (e->decodeThread.joinable()) e->decodeThread.join();
  if (e->presentThread.joinable()) e->presentThread.join();

  // Completion handlers capture `e`, so every in-flight command buffer must
  // retire before it is freed. Command buffers on one queue complete in
  // submission order, so waiting on a fresh one drains all prior work.
  e->cb = nullptr;
  if (e->queue) {
    id<MTLCommandBuffer> fence = [e->queue commandBuffer];
    [fence commit];
    [fence waitUntilCompleted];
  }

  clear_queue(e);
  {
    std::lock_guard<std::mutex> lk(e->outMx);
    if (e->latest) { CFRelease(e->latest); e->latest = nullptr; }
  }
  if (e->pool) CVPixelBufferPoolRelease(e->pool);
  if (e->texCache) CFRelease(e->texCache);
  if (e->dec) avcodec_free_context(&e->dec);
  if (e->hwctx) av_buffer_unref(&e->hwctx);
  if (e->fmt) avformat_close_input(&e->fmt);
  delete e;
}
