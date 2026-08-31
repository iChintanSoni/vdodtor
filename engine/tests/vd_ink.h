// Reading a raster back: where the ink is, and what colour a pixel came out.
//
// Both of the engine's drawn sources are checked this way rather than against
// a golden frame. For text that is a deliberate exemption — see the head of
// vd_text_test.c — and for shapes it is the same argument one step weaker:
// Core Graphics' antialiasing of a curve is not promised to be identical
// across OS releases either, and a reference PNG of a circle would go red on
// an upgrade while the renderer was still perfectly correct.
//
// So the assertions in both files are about *where* the marks are, not which
// pixels they cover: a size widens the ink, a corner rounds it, a shadow falls
// below and to the right of it. Every one of those survives any amount of
// rasteriser drift and breaks the moment the geometry is wrong.
#ifndef VD_INK_H
#define VD_INK_H

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include <CoreVideo/CoreVideo.h>

// Where the ink is, in pixels, origin top left. Empty when nothing was drawn.
typedef struct {
  int32_t left, top, right, bottom;
  int64_t coverage;  // sum of alpha over the frame
  bool empty;
} Ink;

static inline int32_t ink_width(const Ink* ink) {
  return ink->empty ? 0 : ink->right - ink->left + 1;
}
static inline int32_t ink_height(const Ink* ink) {
  return ink->empty ? 0 : ink->bottom - ink->top + 1;
}
static inline int32_t ink_centre_x(const Ink* ink) {
  return ink->empty ? 0 : (ink->left + ink->right) / 2;
}
static inline int32_t ink_centre_y(const Ink* ink) {
  return ink->empty ? 0 : (ink->top + ink->bottom) / 2;
}

// Anything faint enough to be antialiasing rather than a mark someone would
// see. Measuring the bounds against a threshold rather than against zero is
// what makes the numbers in both test files stable across rasterisers.
#define INK_THRESHOLD 40

static inline Ink measure(CVPixelBufferRef buffer) {
  Ink ink = {0, 0, 0, 0, 0, true};
  if (!buffer) return ink;

  CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
  const uint8_t* base = (const uint8_t*)CVPixelBufferGetBaseAddress(buffer);
  const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
  const int32_t w = (int32_t)CVPixelBufferGetWidth(buffer);
  const int32_t h = (int32_t)CVPixelBufferGetHeight(buffer);

  for (int32_t y = 0; y < h; y++) {
    const uint8_t* row = base + (size_t)y * stride;
    for (int32_t x = 0; x < w; x++) {
      const uint8_t alpha = row[(size_t)x * 4 + 3];
      ink.coverage += alpha;
      if (alpha < INK_THRESHOLD) continue;
      if (ink.empty) {
        ink.left = ink.right = x;
        ink.top = ink.bottom = y;
        ink.empty = false;
        continue;
      }
      if (x < ink.left) ink.left = x;
      if (x > ink.right) ink.right = x;
      if (y < ink.top) ink.top = y;
      if (y > ink.bottom) ink.bottom = y;
    }
  }
  CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
  return ink;
}

// BGRA, straight out of the buffer.
static inline void pixel_at(CVPixelBufferRef buffer, int32_t x, int32_t y,
                            uint8_t out[4]) {
  CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
  const uint8_t* base = (const uint8_t*)CVPixelBufferGetBaseAddress(buffer);
  const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
  memcpy(out, base + (size_t)y * stride + (size_t)x * 4, 4);
  CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
}

#endif  // VD_INK_H
