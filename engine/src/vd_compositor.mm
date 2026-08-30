#include "vdodtor/vd_compositor.h"

#include <algorithm>

#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <string.h>

#include <vector>

// Compiled from src/vd_shaders.metal and embedded by CMake.
extern "C" {
extern const unsigned char vd_shaders_metallib[];
extern const size_t vd_shaders_metallib_size;
}

namespace {

// Mirrors VdLayerUniforms in vd_shaders.metal. Field order and padding must
// match exactly.
struct LayerUniforms {
  float rect[4];
  float crop[4];
  float rotation[2];
  float aspect;
  float opacity;
  uint32_t quarter_turns;
  uint32_t full_range;
  uint32_t flip_h;
  uint32_t flip_v;
  float kr;
  float kb;
  float blur_step[2];
};

// A transform with its "unset means identity" fields filled in.
//
// Every field is defined so a zeroed struct is the identity, which means the
// zeros have to be turned back into ones exactly here and nowhere else.
VdTransform normalise(VdTransform t) {
  if (!(t.scale > 0.0f)) t.scale = 1.0f;
  if (!(t.crop_w > 0.0f)) { t.crop_x = 0.0f; t.crop_w = 1.0f; }
  if (!(t.crop_h > 0.0f)) { t.crop_y = 0.0f; t.crop_h = 1.0f; }
  // A crop that runs off the edge would sample clamped rows forever; pull it
  // back inside instead of letting it smear.
  if (t.crop_x < 0.0f) t.crop_x = 0.0f;
  if (t.crop_y < 0.0f) t.crop_y = 0.0f;
  if (t.crop_x + t.crop_w > 1.0f) t.crop_w = 1.0f - t.crop_x;
  if (t.crop_y + t.crop_h > 1.0f) t.crop_h = 1.0f - t.crop_y;
  return t;
}

// The only numbers that differ between the standard YCbCr matrices.
void luma_coefficients(VdColorMatrix matrix, float* kr, float* kb) {
  switch (matrix) {
    case VD_MATRIX_BT601:  *kr = 0.299f;  *kb = 0.114f;  break;
    case VD_MATRIX_BT2020: *kr = 0.2627f; *kb = 0.0593f; break;
    case VD_MATRIX_BT709:
    default:               *kr = 0.2126f; *kb = 0.0722f; break;
  }
}

struct FitRect {
  float x, y, w, h;
};

// Where a source of `src_w` x `src_h` lands in a `dst_w` x `dst_h` output,
// in normalised coordinates with the origin at the top left.
FitRect compute_fit(int32_t src_w, int32_t src_h, int32_t dst_w, int32_t dst_h,
                    VdFitMode mode) {
  if (src_w <= 0 || src_h <= 0 || dst_w <= 0 || dst_h <= 0) {
    return {0.0f, 0.0f, 1.0f, 1.0f};
  }
  if (mode == VD_FIT_STRETCH) return {0.0f, 0.0f, 1.0f, 1.0f};

  const double src_aspect = (double)src_w / (double)src_h;
  const double dst_aspect = (double)dst_w / (double)dst_h;

  // CONTAIN shrinks to the tighter axis, COVER grows to the looser one.
  const bool match_width =
      (mode == VD_FIT_CONTAIN) ? (src_aspect > dst_aspect)
                               : (src_aspect < dst_aspect);
  double w = 1.0;
  double h = 1.0;
  if (match_width) {
    h = (dst_aspect / src_aspect);
  } else {
    w = (src_aspect / dst_aspect);
  }
  return {(float)((1.0 - w) / 2.0), (float)((1.0 - h) / 2.0), (float)w,
          (float)h};
}

bool is_full_range(OSType pixel_format) {
  switch (pixel_format) {
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
    case kCVPixelFormatType_420YpCbCr8PlanarFullRange:
      return true;
    default:
      return false;
  }
}

}  // namespace

struct VdCompositor {
  int32_t width = 0;
  int32_t height = 0;

  id<MTLDevice> device = nil;
  id<MTLCommandQueue> queue = nil;
  id<MTLRenderPipelineState> pipeline_nv12 = nil;
  id<MTLRenderPipelineState> pipeline_yuv420p = nil;
  id<MTLRenderPipelineState> pipeline_blur = nil;
  id<MTLRenderPipelineState> pipeline_texture = nil;

  // Ping-pong pair for the blur-fill background, at a fraction of the output
  // size. Allocated on first use: most projects never letterbox anything.
  id<MTLTexture> blur_a = nil;
  id<MTLTexture> blur_b = nil;
  int32_t blur_width = 0;
  int32_t blur_height = 0;

  CVPixelBufferRef output = nullptr;
  id<MTLTexture> output_texture = nil;
  CVMetalTextureCacheRef texture_cache = nullptr;
  CVMetalTextureRef output_metal_texture = nullptr;

  double last_gpu_ms = 0.0;
};

// --- construction ----------------------------------------------------------

static id<MTLRenderPipelineState> make_pipeline(id<MTLDevice> device,
                                                id<MTLLibrary> library,
                                                NSString* fragment_name,
                                                bool blending = true) {
  MTLRenderPipelineDescriptor* desc = [[MTLRenderPipelineDescriptor alloc] init];
  desc.vertexFunction = [library newFunctionWithName:@"vd_vertex"];
  desc.fragmentFunction = [library newFunctionWithName:fragment_name];
  if (!desc.vertexFunction || !desc.fragmentFunction) return nil;

  MTLRenderPipelineColorAttachmentDescriptor* colour = desc.colorAttachments[0];
  colour.pixelFormat = MTLPixelFormatBGRA8Unorm;
  // Premultiplied source-over: the shaders already multiply by opacity.
  colour.blendingEnabled = blending;
  colour.rgbBlendOperation = MTLBlendOperationAdd;
  colour.alphaBlendOperation = MTLBlendOperationAdd;
  colour.sourceRGBBlendFactor = MTLBlendFactorOne;
  colour.sourceAlphaBlendFactor = MTLBlendFactorOne;
  colour.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  colour.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

  NSError* error = nil;
  return [device newRenderPipelineStateWithDescriptor:desc error:&error];
}

VdCompositor* vd_compositor_create(int32_t width, int32_t height,
                                   int32_t* out_result) {
  if (out_result) *out_result = VD_OK;
  if (width <= 0 || height <= 0) {
    if (out_result) *out_result = VD_ERR_INVALID_ARG;
    return nullptr;
  }

  VdCompositor* c = new VdCompositor();
  c->width = width;
  c->height = height;

  c->device = MTLCreateSystemDefaultDevice();
  if (!c->device) {
    if (out_result) *out_result = VD_ERR_UNSUPPORTED;
    vd_compositor_destroy(c);
    return nullptr;
  }
  c->queue = [c->device newCommandQueue];

  dispatch_data_t data = dispatch_data_create(
      vd_shaders_metallib, vd_shaders_metallib_size,
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
      DISPATCH_DATA_DESTRUCTOR_DEFAULT);
  NSError* error = nil;
  id<MTLLibrary> library = [c->device newLibraryWithData:data error:&error];
  if (!library) {
    if (out_result) *out_result = VD_ERR_UNSUPPORTED;
    vd_compositor_destroy(c);
    return nullptr;
  }

  c->pipeline_nv12 = make_pipeline(c->device, library, @"vd_fragment_nv12");
  c->pipeline_yuv420p =
      make_pipeline(c->device, library, @"vd_fragment_yuv420p");
  // The blur passes own their whole target, so they replace rather than blend.
  c->pipeline_blur =
      make_pipeline(c->device, library, @"vd_fragment_blur", false);
  c->pipeline_texture =
      make_pipeline(c->device, library, @"vd_fragment_texture");
  if (!c->pipeline_nv12 || !c->pipeline_yuv420p || !c->pipeline_blur ||
      !c->pipeline_texture) {
    if (out_result) *out_result = VD_ERR_UNSUPPORTED;
    vd_compositor_destroy(c);
    return nullptr;
  }

  if (CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, c->device,
                                nullptr, &c->texture_cache) != kCVReturnSuccess) {
    if (out_result) *out_result = VD_ERR_UNSUPPORTED;
    vd_compositor_destroy(c);
    return nullptr;
  }

  // IOSurface-backed so Flutter can adopt it as an external texture without a
  // copy, and so an encoder can take it directly in M4.
  CFDictionaryRef empty =
      CFDictionaryCreate(kCFAllocatorDefault, nullptr, nullptr, 0,
                         &kCFTypeDictionaryKeyCallBacks,
                         &kCFTypeDictionaryValueCallBacks);
  CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 2, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(attrs, kCVPixelBufferIOSurfacePropertiesKey, empty);
  CFDictionarySetValue(attrs, kCVPixelBufferMetalCompatibilityKey,
                       kCFBooleanTrue);

  CVReturn status =
      CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                          kCVPixelFormatType_32BGRA, attrs, &c->output);
  CFRelease(attrs);
  CFRelease(empty);
  if (status != kCVReturnSuccess || !c->output) {
    if (out_result) *out_result = VD_ERR_UNSUPPORTED;
    vd_compositor_destroy(c);
    return nullptr;
  }

  status = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, c->texture_cache, c->output, nullptr,
      MTLPixelFormatBGRA8Unorm, width, height, 0, &c->output_metal_texture);
  if (status != kCVReturnSuccess || !c->output_metal_texture) {
    if (out_result) *out_result = VD_ERR_UNSUPPORTED;
    vd_compositor_destroy(c);
    return nullptr;
  }
  c->output_texture = CVMetalTextureGetTexture(c->output_metal_texture);

  return c;
}

void vd_compositor_destroy(VdCompositor* c) {
  if (!c) return;
  // Every render already waited for the GPU before returning, so there is
  // nothing in flight to drain here. That is the point of rendering
  // synchronously: the spike's teardown use-after-free is unreachable.
  if (c->output_metal_texture) CFRelease(c->output_metal_texture);
  if (c->texture_cache) {
    CVMetalTextureCacheFlush(c->texture_cache, 0);
    CFRelease(c->texture_cache);
  }
  if (c->output) CVPixelBufferRelease(c->output);
  c->output_texture = nil;
  c->blur_a = nil;
  c->blur_b = nil;
  c->pipeline_nv12 = nil;
  c->pipeline_yuv420p = nil;
  c->pipeline_blur = nil;
  c->pipeline_texture = nil;
  c->queue = nil;
  c->device = nil;
  delete c;
}

int32_t vd_compositor_width(const VdCompositor* c) { return c ? c->width : 0; }
int32_t vd_compositor_height(const VdCompositor* c) { return c ? c->height : 0; }
double vd_compositor_last_gpu_ms(const VdCompositor* c) {
  return c ? c->last_gpu_ms : 0.0;
}

// --- rendering -------------------------------------------------------------

// Wraps one plane of a CVPixelBuffer as a Metal texture. The returned
// CVMetalTextureRef must outlive the encoder, so callers keep it until the
// command buffer is committed.
static id<MTLTexture> plane_texture(VdCompositor* c, CVPixelBufferRef buffer,
                                    size_t plane, MTLPixelFormat format,
                                    CVMetalTextureRef* keep_alive) {
  const size_t w = CVPixelBufferGetWidthOfPlane(buffer, plane);
  const size_t h = CVPixelBufferGetHeightOfPlane(buffer, plane);
  CVMetalTextureRef ref = nullptr;
  if (CVMetalTextureCacheCreateTextureFromImage(
          kCFAllocatorDefault, c->texture_cache, buffer, nullptr, format, w, h,
          plane, &ref) != kCVReturnSuccess) {
    return nil;
  }
  *keep_alive = ref;
  return CVMetalTextureGetTexture(ref);
}

// The blur runs at a fraction of the output. A background that is about to be
// blurred into a wash does not need four million pixels to do it, and every
// one of them costs a tap in each of two passes.
static const int32_t kBlurDivisor = 8;
static const int32_t kBlurMinimum = 16;

static bool ensure_blur_textures(VdCompositor* c) {
  const int32_t w = std::max(c->width / kBlurDivisor, kBlurMinimum);
  const int32_t h = std::max(c->height / kBlurDivisor, kBlurMinimum);
  if (c->blur_a && c->blur_width == w && c->blur_height == h) return true;

  MTLTextureDescriptor* desc = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:(NSUInteger)w
                                  height:(NSUInteger)h
                               mipmapped:NO];
  desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  desc.storageMode = MTLStorageModePrivate;

  c->blur_a = [c->device newTextureWithDescriptor:desc];
  c->blur_b = [c->device newTextureWithDescriptor:desc];
  c->blur_width = w;
  c->blur_height = h;
  return c->blur_a != nil && c->blur_b != nil;
}

static id<MTLRenderCommandEncoder> begin_pass(id<MTLCommandBuffer> commands,
                                              id<MTLTexture> target,
                                              bool clear) {
  MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = target;
  pass.colorAttachments[0].loadAction =
      clear ? MTLLoadActionClear : MTLLoadActionLoad;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  // Opaque black: a timeline gap is black, not transparent.
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
  return [commands renderCommandEncoderWithDescriptor:pass];
}

// A full-frame quad sampling `source`, at `opacity`. `step` is the blur offset
// per tap, or zero for a plain draw.
static void draw_full_frame(id<MTLRenderCommandEncoder> encoder,
                            id<MTLRenderPipelineState> pipeline,
                            id<MTLTexture> source, float opacity,
                            float step_x, float step_y) {
  LayerUniforms u = {};
  u.rect[0] = 0.0f;
  u.rect[1] = 0.0f;
  u.rect[2] = 1.0f;
  u.rect[3] = 1.0f;
  u.crop[2] = 1.0f;
  u.crop[3] = 1.0f;
  u.rotation[0] = 1.0f;  // no turn
  u.aspect = 1.0f;
  u.opacity = opacity;
  u.blur_step[0] = step_x;
  u.blur_step[1] = step_y;

  [encoder setRenderPipelineState:pipeline];
  [encoder setVertexBytes:&u length:sizeof(u) atIndex:0];
  [encoder setFragmentBytes:&u length:sizeof(u) atIndex:0];
  [encoder setFragmentTexture:source atIndex:0];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
              vertexStart:0
              vertexCount:4];
}

int32_t vd_compositor_render(VdCompositor* c, const VdLayer* layers,
                             int32_t layer_count) {
  if (!c) return VD_ERR_INVALID_ARG;
  if (layer_count < 0 || (layer_count > 0 && !layers)) {
    return VD_ERR_INVALID_ARG;
  }

  @autoreleasepool {
    id<MTLCommandBuffer> commands = [c->queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder =
        begin_pass(commands, c->output_texture, true);

    // Held until commit; releasing a CVMetalTextureRef before the GPU has read
    // it is exactly the kind of lifetime bug that shows up as corruption
    // rather than a crash.
    std::vector<CVMetalTextureRef> refs;

    for (int32_t i = 0; i < layer_count; i++) {
      const VdLayer& layer = layers[i];
      CVPixelBufferRef buffer = (CVPixelBufferRef)layer.pixel_buffer;
      if (!buffer) continue;

      const int32_t src_w = (int32_t)CVPixelBufferGetWidth(buffer);
      const int32_t src_h = (int32_t)CVPixelBufferGetHeight(buffer);
      const int32_t turns = ((layer.rotation_degrees % 360) + 360) % 360 / 90;
      // Rotation changes what the viewer sees, so the fit is computed against
      // the rotated dimensions.
      const int32_t disp_w = (turns % 2 == 0) ? src_w : src_h;
      const int32_t disp_h = (turns % 2 == 0) ? src_h : src_w;

      const VdTransform transform = normalise(layer.transform);

      // Cropping changes the aspect ratio, so it has to be known before the
      // fit is computed — fitting first would letterbox the part that was
      // about to be thrown away.
      const int32_t crop_w = (int32_t)((double)disp_w * transform.crop_w + 0.5);
      const int32_t crop_h = (int32_t)((double)disp_h * transform.crop_h + 0.5);

      // Blur fill shows the whole frame, like contain, and fills what is left
      // over with a blurred copy instead of black.
      const bool wants_blur = layer.fit == VD_FIT_BLUR;
      const VdFitMode foreground_fit =
          wants_blur ? VD_FIT_CONTAIN : layer.fit;

      FitRect fit =
          compute_fit(crop_w, crop_h, c->width, c->height, foreground_fit);

      // Nothing to fill when the picture already reaches every edge, and the
      // common case is exactly that — a 16:9 clip in a 16:9 project. Three
      // passes skipped for the price of one comparison.
      const bool has_bars = fit.w < 0.999f || fit.h < 0.999f;

      // Scale about the fitted centre, then move. Both are pure arithmetic on
      // the destination rectangle; only rotation needs the vertex shader.
      const float cx = fit.x + fit.w * 0.5f + transform.offset_x;
      const float cy = fit.y + fit.h * 0.5f + transform.offset_y;
      fit.w *= transform.scale;
      fit.h *= transform.scale;
      fit.x = cx - fit.w * 0.5f;
      fit.y = cy - fit.h * 0.5f;

      const double radians = (double)transform.rotation_degrees * M_PI / 180.0;
      const float opacity = layer.opacity < 0.0f
                                ? 0.0f
                                : (layer.opacity > 1.0f ? 1.0f : layer.opacity);

      LayerUniforms uniforms = {};
      uniforms.rect[0] = fit.x;
      uniforms.rect[1] = fit.y;
      uniforms.rect[2] = fit.w;
      uniforms.rect[3] = fit.h;
      uniforms.crop[0] = transform.crop_x;
      uniforms.crop[1] = transform.crop_y;
      uniforms.crop[2] = transform.crop_w;
      uniforms.crop[3] = transform.crop_h;
      uniforms.rotation[0] = (float)cos(radians);
      uniforms.rotation[1] = (float)sin(radians);
      uniforms.aspect = c->height > 0 ? (float)c->width / (float)c->height : 1.0f;
      uniforms.flip_h = transform.flip_h ? 1u : 0u;
      uniforms.flip_v = transform.flip_v ? 1u : 0u;
      uniforms.opacity = opacity;
      uniforms.quarter_turns = (uint32_t)turns;
      // The decoder read the range from the stream; the pixel buffer's own
      // format type is the fallback for buffers that did not come from it.
      uniforms.full_range =
          (layer.full_range ||
           is_full_range(CVPixelBufferGetPixelFormatType(buffer)))
              ? 1u
              : 0u;
      luma_coefficients(layer.color_matrix, &uniforms.kr, &uniforms.kb);

      id<MTLRenderPipelineState> pipeline = nil;
      id<MTLTexture> planes[3] = {nil, nil, nil};

      if (layer.format == VD_PIXEL_NV12) {
        CVMetalTextureRef a = nullptr, b = nullptr;
        planes[0] = plane_texture(c, buffer, 0, MTLPixelFormatR8Unorm, &a);
        planes[1] = plane_texture(c, buffer, 1, MTLPixelFormatRG8Unorm, &b);
        if (a) refs.push_back(a);
        if (b) refs.push_back(b);
        pipeline = c->pipeline_nv12;
      } else {
        CVMetalTextureRef a = nullptr, b = nullptr, d = nullptr;
        planes[0] = plane_texture(c, buffer, 0, MTLPixelFormatR8Unorm, &a);
        planes[1] = plane_texture(c, buffer, 1, MTLPixelFormatR8Unorm, &b);
        planes[2] = plane_texture(c, buffer, 2, MTLPixelFormatR8Unorm, &d);
        if (a) refs.push_back(a);
        if (b) refs.push_back(b);
        if (d) refs.push_back(d);
        pipeline = c->pipeline_yuv420p;
      }
      if (!planes[0] || !planes[1]) continue;

      if (wants_blur && has_bars && ensure_blur_textures(c)) {
        // The background is the same picture, cover-fitted so it reaches the
        // edges, and untouched by the layer's own scale or offset — moving a
        // clip should not drag its backdrop around with it.
        LayerUniforms background = uniforms;
        const FitRect cover =
            compute_fit(crop_w, crop_h, c->width, c->height, VD_FIT_COVER);
        background.rect[0] = cover.x;
        background.rect[1] = cover.y;
        background.rect[2] = cover.w;
        background.rect[3] = cover.h;
        background.rotation[0] = 1.0f;  // the extra turn belongs to the clip
        background.rotation[1] = 0.0f;
        background.opacity = 1.0f;      // applied once, at the final draw

        [encoder endEncoding];

        id<MTLRenderCommandEncoder> into =
            begin_pass(commands, c->blur_a, true);
        [into setRenderPipelineState:pipeline];
        [into setVertexBytes:&background length:sizeof(background) atIndex:0];
        [into setFragmentBytes:&background length:sizeof(background) atIndex:0];
        [into setFragmentTexture:planes[0] atIndex:0];
        [into setFragmentTexture:planes[1] atIndex:1];
        if (planes[2]) [into setFragmentTexture:planes[2] atIndex:2];
        [into drawPrimitives:MTLPrimitiveTypeTriangleStrip
                 vertexStart:0
                 vertexCount:4];
        [into endEncoding];

        // Separable: across, then down. Two cheap passes where a square kernel
        // would be one dear one.
        const float step_x = 1.0f / (float)c->blur_width;
        const float step_y = 1.0f / (float)c->blur_height;
        id<MTLRenderCommandEncoder> across =
            begin_pass(commands, c->blur_b, true);
        draw_full_frame(across, c->pipeline_blur, c->blur_a, 1.0f, step_x, 0.0f);
        [across endEncoding];

        id<MTLRenderCommandEncoder> down =
            begin_pass(commands, c->blur_a, true);
        draw_full_frame(down, c->pipeline_blur, c->blur_b, 1.0f, 0.0f, step_y);
        [down endEncoding];

        // Back to the output, keeping whatever earlier layers drew.
        encoder = begin_pass(commands, c->output_texture, false);
        draw_full_frame(encoder, c->pipeline_texture, c->blur_a, opacity, 0.0f,
                        0.0f);
      }

      [encoder setRenderPipelineState:pipeline];
      [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:0];
      [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
      [encoder setFragmentTexture:planes[0] atIndex:0];
      [encoder setFragmentTexture:planes[1] atIndex:1];
      if (planes[2]) [encoder setFragmentTexture:planes[2] atIndex:2];
      [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                  vertexStart:0
                  vertexCount:4];
    }

    [encoder endEncoding];

    const CFTimeInterval started = CACurrentMediaTime();
    [commands commit];
    // Synchronous by design. It costs about a millisecond of the frame budget
    // and removes every question about what the GPU still holds when the
    // engine is torn down.
    [commands waitUntilCompleted];
    c->last_gpu_ms = (CACurrentMediaTime() - started) * 1000.0;

    for (CVMetalTextureRef ref : refs) CFRelease(ref);
  }
  return VD_OK;
}

VdTransform vd_transform_identity(void) {
  VdTransform t = {};
  t.scale = 1.0f;
  t.crop_w = 1.0f;
  t.crop_h = 1.0f;
  return t;
}

void* vd_compositor_copy_output(VdCompositor* c) {
  if (!c || !c->output) return nullptr;
  return CVPixelBufferRetain(c->output);
}

bool vd_compositor_read_pixel(VdCompositor* c, int32_t x, int32_t y,
                              uint8_t* out_bgra) {
  if (!c || !c->output || !out_bgra) return false;
  if (x < 0 || y < 0 || x >= c->width || y >= c->height) return false;

  CVPixelBufferLockBaseAddress(c->output, kCVPixelBufferLock_ReadOnly);
  const uint8_t* base = (const uint8_t*)CVPixelBufferGetBaseAddress(c->output);
  const size_t stride = CVPixelBufferGetBytesPerRow(c->output);
  memcpy(out_bgra, base + (size_t)y * stride + (size_t)x * 4, 4);
  CVPixelBufferUnlockBaseAddress(c->output, kCVPixelBufferLock_ReadOnly);
  return true;
}

int32_t vd_compositor_copy_pixels(VdCompositor* c, uint8_t* out,
                                  int64_t capacity) {
  if (!c || !out || !c->output) return VD_ERR_INVALID_ARG;

  const int64_t row_bytes = (int64_t)c->width * 4;
  const int64_t needed = row_bytes * c->height;
  if (capacity < needed) return VD_ERR_INVALID_ARG;

  CVPixelBufferLockBaseAddress(c->output, kCVPixelBufferLock_ReadOnly);
  const uint8_t* base = (const uint8_t*)CVPixelBufferGetBaseAddress(c->output);
  const size_t stride = CVPixelBufferGetBytesPerRow(c->output);
  for (int32_t y = 0; y < c->height; ++y) {
    memcpy(out + (size_t)y * (size_t)row_bytes, base + (size_t)y * stride,
           (size_t)row_bytes);
  }
  CVPixelBufferUnlockBaseAddress(c->output, kCVPixelBufferLock_ReadOnly);
  return VD_OK;
}

int32_t vd_compositor_dump_png(VdCompositor* c, const char* path) {
  if (!c || !c->output || !path) return VD_ERR_INVALID_ARG;

  @autoreleasepool {
    CVPixelBufferLockBaseAddress(c->output, kCVPixelBufferLock_ReadOnly);
    void* base = CVPixelBufferGetBaseAddress(c->output);
    const size_t stride = CVPixelBufferGetBytesPerRow(c->output);

    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(
        base, c->width, c->height, 8, stride, space,
        kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef image = context ? CGBitmapContextCreateImage(context) : nullptr;

    int32_t result = VD_ERR_UNSUPPORTED;
    if (image) {
      NSURL* url = [NSURL fileURLWithPath:@(path)];
      CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
          (__bridge CFURLRef)url, CFSTR("public.png"), 1, nullptr);
      if (dest) {
        CGImageDestinationAddImage(dest, image, nullptr);
        result = CGImageDestinationFinalize(dest) ? VD_OK : VD_ERR_UNSUPPORTED;
        CFRelease(dest);
      }
      CGImageRelease(image);
    }
    if (context) CGContextRelease(context);
    CGColorSpaceRelease(space);
    CVPixelBufferUnlockBaseAddress(c->output, kCVPixelBufferLock_ReadOnly);
    return result;
  }
}
