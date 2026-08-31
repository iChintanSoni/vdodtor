#include "vdodtor/vd_raster.h"

#include <CoreVideo/CoreVideo.h>

#include "vdodtor/vd_probe.h"

void* vd_raster_create(int32_t width, int32_t height, int32_t* out_result) {
  if (out_result) *out_result = VD_OK;
  if (width <= 0 || height <= 0) {
    if (out_result) *out_result = VD_ERR_INVALID_ARG;
    return NULL;
  }

  // IOSurface-backed and Metal-compatible on the same terms as the
  // compositor's own output: the whole point of rasterising here rather than
  // in the app is that the compositor can wrap the result without a copy.
  CFDictionaryRef empty =
      CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0,
                         &kCFTypeDictionaryKeyCallBacks,
                         &kCFTypeDictionaryValueCallBacks);
  CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 2, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(attrs, kCVPixelBufferIOSurfacePropertiesKey, empty);
  CFDictionarySetValue(attrs, kCVPixelBufferMetalCompatibilityKey,
                       kCFBooleanTrue);

  CVPixelBufferRef buffer = NULL;
  const CVReturn status =
      CVPixelBufferCreate(kCFAllocatorDefault, (size_t)width, (size_t)height,
                          kCVPixelFormatType_32BGRA, attrs, &buffer);
  CFRelease(attrs);
  CFRelease(empty);
  if (status != kCVReturnSuccess || !buffer) {
    if (out_result) *out_result = VD_ERR_OPEN;
    return NULL;
  }
  return buffer;
}

CGContextRef vd_raster_begin(void* pixel_buffer) {
  if (!pixel_buffer) return NULL;
  CVPixelBufferRef buffer = (CVPixelBufferRef)pixel_buffer;

  CVPixelBufferLockBaseAddress(buffer, 0);
  CGContextRef ctx = CGBitmapContextCreate(
      CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetWidth(buffer),
      CVPixelBufferGetHeight(buffer), 8, CVPixelBufferGetBytesPerRow(buffer),
      vd_raster_srgb(),
      kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
  if (!ctx) {
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return NULL;
  }

  // A fresh pixel buffer is not promised to be zeroed, and every pixel a drawn
  // source does not draw has to be transparent rather than whatever was there.
  CGContextClearRect(ctx, CGRectMake(0, 0, (CGFloat)CVPixelBufferGetWidth(buffer),
                                     (CGFloat)CVPixelBufferGetHeight(buffer)));
  // Subpixel smoothing puts colour fringes on the edges of glyphs, which is a
  // trick for ink on a known background and a defect on ink with an alpha
  // channel that will be composited over something else.
  CGContextSetShouldSmoothFonts(ctx, false);
  CGContextSetShouldAntialias(ctx, true);
  return ctx;
}

void vd_raster_finish(void* pixel_buffer, CGContextRef ctx) {
  if (ctx) {
    CGContextFlush(ctx);
    CGContextRelease(ctx);
  }
  if (pixel_buffer) {
    CVPixelBufferUnlockBaseAddress((CVPixelBufferRef)pixel_buffer, 0);
  }
}

CGColorSpaceRef vd_raster_srgb(void) {
  static CGColorSpaceRef space;
  if (!space) space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  return space;
}

CGColorRef vd_raster_color(uint32_t argb) {
  const CGFloat components[4] = {
      (CGFloat)((argb >> 16) & 0xFFu) / 255.0,
      (CGFloat)((argb >> 8) & 0xFFu) / 255.0,
      (CGFloat)(argb & 0xFFu) / 255.0,
      (CGFloat)((argb >> 24) & 0xFFu) / 255.0,
  };
  return CGColorCreate(vd_raster_srgb(), components);
}

bool vd_raster_visible(uint32_t argb) { return ((argb >> 24) & 0xFFu) != 0u; }
