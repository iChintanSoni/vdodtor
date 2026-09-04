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
  float hide[4];
  float grade[3][4];
  uint32_t graded;
  uint32_t lut_size;
  float lut_strength;
  // `keyed` sits before the pairs rather than after them because Metal gives a
  // float2 an 8-byte alignment: putting it last would leave a hole here and
  // not there, and the two layouts would part company silently.
  uint32_t keyed;
  float key_chromaticity[2];
  float key_axis[2];
  float key_inv_length;
  float key_tolerance;
  float key_softness;
  float key_spill;
  uint32_t matte;
  // Metal rounds a struct up to its own 16-byte alignment and this mirror
  // would stop at 196 bytes; setFragmentBytes copies exactly what it is told
  // to, so without this the GPU is handed a buffer shorter than the layout it
  // was compiled against.
  uint32_t padding_[3];
};
static_assert(sizeof(LayerUniforms) == 208,
              "VdLayerUniforms in vd_shaders.metal is 208 bytes; this mirror "
              "has drifted from it");

static float clamp01(float v) {
  if (!(v > 0.0f)) return 0.0f;  // NaN lands here too
  return v > 1.0f ? 1.0f : v;
}

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

// Folds a layer's five sliders into the rows the shader multiplies by, and
// says whether there is anything to multiply at all.
//
// Skipped entirely for a neutral grade rather than written out as the
// identity: an ungraded fragment then takes the arithmetic it took before the
// compositor learned about grading, which is what keeps the golden frames from
// moving for a feature nobody used.
void set_grade(LayerUniforms* u, const VdColorAdjust& adjust) {
  if (vd_color_is_neutral(&adjust)) {
    u->graded = 0;
    return;
  }
  const VdColorTransform t = vd_color_transform(&adjust);
  for (int row = 0; row < 3; row++) {
    u->grade[row][0] = t.m[row * 3 + 0];
    u->grade[row][1] = t.m[row * 3 + 1];
    u->grade[row][2] = t.m[row * 3 + 2];
    u->grade[row][3] = t.offset[row];
  }
  u->graded = 1;
}

// The key, resolved into what the shader needs once per layer rather than once
// per fragment — the division of labour `set_grade` makes, for the same reason.
// A layer nobody keyed takes the path it took before this existed.
void set_key(LayerUniforms* u, const VdChromaKey& key) {
  const VdKeyMatte matte = vd_key_matte(&key);
  if (vd_key_matte_is_off(&matte)) {
    u->keyed = 0;
    return;
  }
  u->key_chromaticity[0] = matte.chromaticity.cb;
  u->key_chromaticity[1] = matte.chromaticity.cr;
  u->key_axis[0] = matte.axis.cb;
  u->key_axis[1] = matte.axis.cr;
  u->key_inv_length = matte.inv_length;
  u->key_tolerance = matte.tolerance;
  u->key_softness = matte.softness;
  u->key_spill = matte.spill;
  u->keyed = 1;
}

// The other half, and the same bargain: a layer with no look on it takes the
// arithmetic it took before this compositor learned about looks, so the golden
// frames cannot move for a feature nobody used.
void set_look(LayerUniforms* u, const VdColorLook& look) {
  if (!look.lattice || look.size < 2 || look.id == 0 ||
      !(look.strength > 0.0f)) {
    u->lut_size = 0;
    return;
  }
  u->lut_size = (uint32_t)look.size;
  u->lut_strength = look.strength > 1.0f ? 1.0f : look.strength;
}

// How many distinct looks stay on the GPU at once.
//
// A cube is a few hundred kilobytes, and the number that can be on screen
// together is bounded by the lane count — but a timeline where every lane
// wears a different look is not the case worth sizing for, and an eviction
// only costs one upload. Eight is comfortably past what any real frame asks
// for and small enough to walk linearly.
const int32_t kLutSlots = 8;

struct LutSlot {
  // `key`, not `id`: a member called `id` shadows Objective-C's own `id` for
  // the rest of the struct, and the texture below stops being declarable.
  uint64_t key;
  id<MTLTexture> texture;
  int64_t last_used;
};

// A lattice as the GPU holds it: 16-bit normalised, which is the widest format
// that filters on every Metal family.
//
// Not 32-bit float — on Apple GPUs RGBA32Float is not filterable, so the
// hardware trilinear the whole design rests on would silently stop happening
// and every look would show its lattice as banding. 16 bits is 65536 levels
// across a range this pipeline has already clamped to 0..1, which is far more
// than an 8-bit output can show.
void pack_lattice(const float* lattice, int32_t size, uint16_t* out) {
  const int64_t texels = (int64_t)size * size * size;
  for (int64_t i = 0; i < texels; i++) {
    for (int c = 0; c < 3; c++) {
      float v = lattice[i * 3 + c];
      if (!(v > 0.0f)) v = 0.0f;  // NaN lands here too
      if (v > 1.0f) v = 1.0f;
      out[i * 4 + c] = (uint16_t)(v * 65535.0f + 0.5f);
    }
    out[i * 4 + 3] = 65535;
  }
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

  // The cubes uploaded so far, keyed on the id the engine gave each look, and
  // a 2x2x2 identity for every draw that has no look on it — a fragment
  // function declares its texture arguments whether or not it reads them, and
  // an unbound one is not a thing Metal will validate.
  LutSlot luts[kLutSlots];
  id<MTLTexture> lut_identity = nil;
  int64_t lut_clock = 0;
  int64_t lut_uploads = 0;

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

// An empty 3D texture of `size` per axis, ready for a lattice.
static id<MTLTexture> make_lut_texture(id<MTLDevice> device, int32_t size) {
  MTLTextureDescriptor* desc = [[MTLTextureDescriptor alloc] init];
  desc.textureType = MTLTextureType3D;
  desc.pixelFormat = MTLPixelFormatRGBA16Unorm;
  desc.width = (NSUInteger)size;
  desc.height = (NSUInteger)size;
  desc.depth = (NSUInteger)size;
  desc.usage = MTLTextureUsageShaderRead;
  return [device newTextureWithDescriptor:desc];
}

// The look that changes nothing: a 2-cube whose corners are the corners of the
// colour space, so trilinear between them is the colour you started with.
static id<MTLTexture> make_identity_lut(id<MTLDevice> device) {
  id<MTLTexture> texture = make_lut_texture(device, 2);
  if (!texture) return nil;
  float lattice[2 * 2 * 2 * 3];
  int32_t at = 0;
  for (int32_t b = 0; b < 2; b++) {
    for (int32_t g = 0; g < 2; g++) {
      for (int32_t r = 0; r < 2; r++) {
        lattice[at++] = (float)r;
        lattice[at++] = (float)g;
        lattice[at++] = (float)b;
      }
    }
  }
  uint16_t packed[2 * 2 * 2 * 4];
  pack_lattice(lattice, 2, packed);
  [texture replaceRegion:MTLRegionMake3D(0, 0, 0, 2, 2, 2)
             mipmapLevel:0
                   slice:0
               withBytes:packed
             bytesPerRow:2 * 4 * sizeof(uint16_t)
           bytesPerImage:2 * 2 * 4 * sizeof(uint16_t)];
  return texture;
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

  // The cube a draw with no look on it binds. It is never sampled — the shader
  // returns before the fetch when lut_size is 0 — but it has to exist, and
  // making it the *identity* rather than an empty texture means a binding that
  // did get sampled by mistake would show the picture rather than a colour
  // nobody can explain.
  c->lut_identity = make_identity_lut(c->device);
  if (!c->lut_identity) {
    if (out_result) *out_result = VD_ERR_UNSUPPORTED;
    vd_compositor_destroy(c);
    return nullptr;
  }

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
  for (int32_t i = 0; i < kLutSlots; i++) c->luts[i].texture = nil;
  c->lut_identity = nil;
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
int64_t vd_compositor_lut_uploads(const VdCompositor* c) {
  return c ? c->lut_uploads : 0;
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

// The same, for a buffer that has no planes to ask about. A generated layer
// arrives as interleaved BGRA, and CVPixelBufferGetWidthOfPlane answers 0 for
// one of those — the plane accessors are for planar buffers only.
static id<MTLTexture> whole_texture(VdCompositor* c, CVPixelBufferRef buffer,
                                    MTLPixelFormat format,
                                    CVMetalTextureRef* keep_alive) {
  const size_t w = CVPixelBufferGetWidth(buffer);
  const size_t h = CVPixelBufferGetHeight(buffer);
  CVMetalTextureRef ref = nullptr;
  if (CVMetalTextureCacheCreateTextureFromImage(
          kCFAllocatorDefault, c->texture_cache, buffer, nullptr, format, w, h,
          0, &ref) != kCVReturnSuccess) {
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

// The GPU's copy of `look`, uploaded if this is the first time it has been
// seen and reused every time after.
//
// Keyed on the id the look was given when it was parsed, never on the lattice
// pointer: a cube freed and another allocated at the same address would be a
// cache hit on the wrong picture, and a look that is wrong only sometimes is
// the worst kind of wrong. Returns the identity for a layer with no look,
// which is what the shader's own short-circuit already assumes.
static id<MTLTexture> lut_texture_for(VdCompositor* c,
                                      const VdColorLook& look) {
  if (!look.lattice || look.size < 2 || look.id == 0) return c->lut_identity;

  int32_t victim = 0;
  for (int32_t i = 0; i < kLutSlots; i++) {
    if (c->luts[i].key == look.id && c->luts[i].texture) {
      c->luts[i].last_used = ++c->lut_clock;
      return c->luts[i].texture;
    }
    // An empty slot first, then the one drawn longest ago.
    if (!c->luts[i].texture) {
      victim = i;
      break;
    }
    if (c->luts[i].last_used < c->luts[victim].last_used) victim = i;
  }

  id<MTLTexture> texture = make_lut_texture(c->device, look.size);
  if (!texture) return c->lut_identity;

  const int64_t texels = (int64_t)look.size * look.size * look.size;
  uint16_t* packed = (uint16_t*)malloc((size_t)texels * 4 * sizeof(uint16_t));
  if (!packed) return c->lut_identity;
  pack_lattice(look.lattice, look.size, packed);
  [texture replaceRegion:MTLRegionMake3D(0, 0, 0, (NSUInteger)look.size,
                                         (NSUInteger)look.size,
                                         (NSUInteger)look.size)
             mipmapLevel:0
                   slice:0
               withBytes:packed
             bytesPerRow:(NSUInteger)look.size * 4 * sizeof(uint16_t)
           bytesPerImage:(NSUInteger)look.size * look.size * 4 *
                         sizeof(uint16_t)];
  free(packed);

  c->luts[victim].key = look.id;
  c->luts[victim].texture = texture;
  c->luts[victim].last_used = ++c->lut_clock;
  c->lut_uploads++;
  return texture;
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
                            id<MTLTexture> source, id<MTLTexture> lut,
                            float opacity, float step_x, float step_y,
                            const float hide[4], bool matte) {
  LayerUniforms u = {};
  if (hide) memcpy(u.hide, hide, sizeof(u.hide));
  // Zeroed uniforms mean no key here — the backdrop was keyed, or rather was
  // not, in the pass that produced the texture. The matte flag does carry,
  // because it is about how the whole frame is being looked at.
  u.matte = matte ? 1u : 0u;
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
  // Zeroed uniforms mean no look here, so this is only ever the identity —
  // bound because the fragment function declares the argument, not because
  // anything reads it. The blur-fill backdrop carried its look into the
  // offscreen already, exactly as it carried its grade.
  [encoder setFragmentTexture:lut atIndex:3];
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

      // The size the source asks to be shown at: coded pixels widened by the
      // sample aspect, and then turned, because a quarter turn puts the
      // stretch on the other axis. Rotation changes what the viewer sees, so
      // the fit is computed against this rather than against the coded size.
      double wide = (double)src_w;
      if (layer.pixel_aspect.num > 0 && layer.pixel_aspect.den > 0) {
        wide *= (double)layer.pixel_aspect.num / (double)layer.pixel_aspect.den;
      }
      const double disp_w = (turns % 2 == 0) ? wide : (double)src_h;
      const double disp_h = (turns % 2 == 0) ? (double)src_h : wide;

      const VdTransform transform = normalise(layer.transform);

      // Cropping changes the aspect ratio, so it has to be known before the
      // fit is computed — fitting first would letterbox the part that was
      // about to be thrown away.
      const int32_t crop_w = (int32_t)(disp_w * transform.crop_w + 0.5);
      const int32_t crop_h = (int32_t)(disp_h * transform.crop_h + 0.5);

      // **A keyed layer contains, whatever its fit says.** Filling a bar with
      // a blurred copy of a background the user has just declared is not there
      // floods the frame with the very colour being removed — and the backdrop
      // goes into an offscreen cleared to opaque black and is then drawn
      // full-frame, so the holes a key put in it would paint black over every
      // layer underneath. The substitution happens here, once, rather than at
      // the `wants_blur` test alone: VD_FIT_BLUR is not VD_FIT_CONTAIN to
      // compute_fit, so a keyed layer that skipped only the blur passes would
      // still be laid out as cover. See VdLayer::key.
      const VdFitMode fit_mode =
          (layer.fit == VD_FIT_BLUR && !vd_key_is_off(&layer.key))
              ? VD_FIT_CONTAIN
              : layer.fit;

      // Blur fill shows the whole frame, like contain, and fills what is left
      // over with a blurred copy instead of black.
      const bool wants_blur = fit_mode == VD_FIT_BLUR;
      const VdFitMode foreground_fit = wants_blur ? VD_FIT_CONTAIN : fit_mode;

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
      // Clamped rather than trusted: a pair of margins that overlap would
      // discard every fragment, and a clip that vanished mid-wipe is a harder
      // bug to see than one that stops wiping.
      uniforms.hide[0] = clamp01(layer.reveal.left);
      uniforms.hide[1] = clamp01(layer.reveal.top);
      uniforms.hide[2] = clamp01(layer.reveal.right);
      uniforms.hide[3] = clamp01(layer.reveal.bottom);
      uniforms.opacity = opacity;
      set_grade(&uniforms, layer.color);
      set_look(&uniforms, layer.look);
      set_key(&uniforms, layer.key);
      uniforms.matte = layer.matte_view ? 1u : 0u;
      id<MTLTexture> lut = lut_texture_for(c, layer.look);
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

      if (layer.format == VD_PIXEL_BGRA) {
        // Already the colour the output is in and already premultiplied, so
        // there is nothing to convert: the same pass that draws the blur-fill
        // background draws this, and for the same reason.
        CVMetalTextureRef a = nullptr;
        planes[0] = whole_texture(c, buffer, MTLPixelFormatBGRA8Unorm, &a);
        if (a) refs.push_back(a);
        pipeline = c->pipeline_texture;
      } else if (layer.format == VD_PIXEL_NV12) {
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
      // A YCbCr layer is missing half its picture without its chroma plane; a
      // BGRA one has everything in the first texture.
      if (!planes[0]) continue;
      if (layer.format != VD_PIXEL_BGRA && !planes[1]) continue;

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
        // The offscreen is a colour source for the blur, so it is drawn as a
        // picture even when the frame is being looked at as a matte; the flag
        // is put back on the draw that composites it.
        background.matte = 0;
        // The backdrop is rendered *whole* and cut at the final composite
        // below, not here. Cutting it here would leave the hidden part of the
        // offscreen texture as opaque black, and that black is then drawn
        // full-frame over everything underneath — so a wipe on a blur-filled
        // clip would erase the clip it is wiping away from.
        memset(background.hide, 0, sizeof(background.hide));

        [encoder endEncoding];

        id<MTLRenderCommandEncoder> into =
            begin_pass(commands, c->blur_a, true);
        [into setRenderPipelineState:pipeline];
        [into setVertexBytes:&background length:sizeof(background) atIndex:0];
        [into setFragmentBytes:&background length:sizeof(background) atIndex:0];
        [into setFragmentTexture:planes[0] atIndex:0];
        [into setFragmentTexture:planes[1] atIndex:1];
        if (planes[2]) [into setFragmentTexture:planes[2] atIndex:2];
        [into setFragmentTexture:lut atIndex:3];
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
        draw_full_frame(across, c->pipeline_blur, c->blur_a, c->lut_identity,
                        1.0f, step_x, 0.0f, nullptr, false);
        [across endEncoding];

        id<MTLRenderCommandEncoder> down =
            begin_pass(commands, c->blur_a, true);
        draw_full_frame(down, c->pipeline_blur, c->blur_b, c->lut_identity,
                        1.0f, 0.0f, step_y, nullptr, false);
        [down endEncoding];

        // Back to the output, keeping whatever earlier layers drew.
        encoder = begin_pass(commands, c->output_texture, false);
        // Cut here, where discarding leaves what is underneath showing. The
        // grade is *not* passed on, and neither is the look: `background`
        // carried both into the offscreen above, so these pixels are already
        // graded and doing it again would leave the bars twice as far from
        // neutral as the picture in front of them.
        draw_full_frame(encoder, c->pipeline_texture, c->blur_a,
                        c->lut_identity, opacity, 0.0f, 0.0f, uniforms.hide,
                        layer.matte_view);
      }

      [encoder setRenderPipelineState:pipeline];
      [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:0];
      [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
      [encoder setFragmentTexture:planes[0] atIndex:0];
      [encoder setFragmentTexture:planes[1] atIndex:1];
      if (planes[2]) [encoder setFragmentTexture:planes[2] atIndex:2];
      [encoder setFragmentTexture:lut atIndex:3];
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
