#include "vdodtor/vd_text.h"

#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include <vector>

#include "vdodtor/vd_probe.h"
#include "vdodtor/vd_raster.h"

// Everything below draws in Core Graphics' own coordinates, origin bottom
// left. A bitmap context stores its first row as the *top* of the image and
// maps user-space y=0 to the last one, so a CVPixelBuffer drawn into this way
// comes out the right way up with no flip anywhere — and Core Text, which
// wants an unflipped context, gets one. The single place the difference shows
// is the shadow offset, where the spec's downward +y has to be negated.
//
// Core Foundation rather than Foundation throughout: the engine is built
// without ARC, and CF's retain rules are the same whether it is on or off.

namespace {

// One registered face: what it calls itself, and the font it came from.
//
// The catalogue is the engine's own rather than the font manager's. Installing
// a face with CTFontManager registers it for the whole session or the whole
// machine — process scope is not offered for a font that came from memory —
// and a video editor has no business changing which fonts the computer it is
// running on has. Holding the CGFont and asking it for a sized CTFont at draw
// time is the same thing without the side effect.
//
// Names are strdup'd and never freed, which is what makes the pointers
// vd_text_font_name hands out safe to keep.
struct Face {
  char* family;
  CGFontRef font;
};

pthread_mutex_t g_font_lock = PTHREAD_MUTEX_INITIALIZER;

std::vector<Face>& faces() {
  static std::vector<Face>* registered = new std::vector<Face>();
  return *registered;
}

// The registered face for `family`, or NULL. Nothing is ever removed, so the
// CGFont outlives the lock.
CGFontRef find_face(const char* family) {
  if (!family || !*family) return nullptr;
  pthread_mutex_lock(&g_font_lock);
  CGFontRef font = nullptr;
  for (const Face& face : faces()) {
    if (strcmp(face.family, family) == 0) {
      font = face.font;
      break;
    }
  }
  pthread_mutex_unlock(&g_font_lock);
  return font;
}

// Under the names this file has always called them. They live in vd_raster.c
// now that a shape needs them too — see vd_raster.h.
CGColorRef make_color(uint32_t argb) { return vd_raster_color(argb); }
bool visible(uint32_t argb) { return vd_raster_visible(argb); }

// Text that touches the edge of the frame reads as a mistake, so a block that
// says nothing about its width gets a margin.
const float kDefaultMaxWidth = 0.9f;
const float kDefaultSize = 0.08f;

void set_number(CFMutableDictionaryRef dict, CFStringRef key, CGFloat value) {
  CFNumberRef number =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberCGFloatType, &value);
  if (number) {
    CFDictionarySetValue(dict, key, number);
    CFRelease(number);
  }
}

CTFontRef create_font(const char* name, CGFloat points) {
  if (CGFontRef registered = find_face(name)) {
    return CTFontCreateWithGraphicsFont(registered, points, nullptr, nullptr);
  }
  // Not one of ours: ask the machine, which is what a project made with a
  // pack installed should do on a machine without it. CTFontCreateWithName
  // never fails — an unknown name resolves to a default face, and showing the
  // words in the wrong typeface beats not showing them.
  if (name && *name) {
    CFStringRef requested = CFStringCreateWithCString(
        kCFAllocatorDefault, name, kCFStringEncodingUTF8);
    if (requested) {
      CTFontRef font = CTFontCreateWithName(requested, points, nullptr);
      CFRelease(requested);
      if (font) return font;
    }
  }
  return CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, points, nullptr);
}

CTParagraphStyleRef create_paragraph_style(VdTextAlign align,
                                           float line_spacing, CTFontRef font) {
  CTTextAlignment alignment;
  switch (align) {
    case VD_TEXT_ALIGN_LEFT: alignment = kCTTextAlignmentLeft; break;
    case VD_TEXT_ALIGN_RIGHT: alignment = kCTTextAlignmentRight; break;
    case VD_TEXT_ALIGN_CENTER:
    default: alignment = kCTTextAlignmentCenter; break;
  }

  // Spacing is asked for as a multiple of the line height and applied as an
  // adjustment *between* lines, which are not the same thing. A line height
  // multiple adds its extra space above every line, including the first, so a
  // block laid out with it sinks below the middle of the frame — and a
  // caption that moves when its leading changes is a caption nobody can place.
  // Between lines, the block grows about its own centre and stays put.
  CGFloat multiple = line_spacing > 0.0f ? (CGFloat)line_spacing : 1.0;
  if (multiple < 0.5) multiple = 0.5;
  if (multiple > 4.0) multiple = 4.0;
  const CGFloat line_height =
      CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font);
  const CGFloat adjustment = (multiple - 1.0) * line_height;

  const CTParagraphStyleSetting settings[] = {
      {kCTParagraphStyleSpecifierAlignment, sizeof(alignment), &alignment},
      {kCTParagraphStyleSpecifierLineSpacingAdjustment, sizeof(adjustment),
       &adjustment},
  };
  return CTParagraphStyleCreate(settings,
                                sizeof(settings) / sizeof(settings[0]));
}

// The spec's "0 means the default" fields, filled in once so the rest of this
// file never has to ask twice.
struct Resolved {
  CGFloat points;
  CGFloat wrap_width;
};

Resolved resolve(const VdTextSpec* spec, int32_t width, int32_t height) {
  const float size = spec->size > 0.0f ? spec->size : kDefaultSize;
  const float max_width =
      spec->max_width > 0.0f ? spec->max_width : kDefaultMaxWidth;
  Resolved r;
  r.points = (CGFloat)size * (CGFloat)height;
  r.wrap_width = (CGFloat)max_width * (CGFloat)width;
  return r;
}

// One laid-out block: the frame to draw and the rectangle its ink covers.
//
// The two are deliberately different. The block is laid out in a box as wide
// as wrapping allows, because that is what gives alignment somewhere to move
// a line to — with a box that hugged the words, "align left" would do nothing
// to a single line, which is the one case it is asked for most. The
// background box then has to hug the words instead, so it is measured from
// the lines that actually get drawn.
struct Block {
  CTFrameRef frame;
  CGRect ink;
  // Where the frame was laid out, which the line origins are relative to.
  CGRect path;
  bool valid;
};

CGRect measure_ink(CTFrameRef frame, CGRect path_rect) {
  CFArrayRef lines = CTFrameGetLines(frame);
  const CFIndex count = CFArrayGetCount(lines);
  if (count == 0) return CGRectNull;

  std::vector<CGPoint> origins((size_t)count);
  CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), origins.data());

  CGRect ink = CGRectNull;
  for (CFIndex i = 0; i < count; i++) {
    CTLineRef line = (CTLineRef)CFArrayGetValueAtIndex(lines, i);
    CGFloat ascent = 0, descent = 0, leading = 0;
    const double advance =
        CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
    // Trailing spaces are advance without ink, and a background box drawn
    // around them sits off-centre for a reason nobody can see.
    const CGFloat width =
        (CGFloat)(advance - CTLineGetTrailingWhitespaceWidth(line));
    if (width <= 0) continue;

    const CGPoint origin = origins[(size_t)i];
    const CGRect rect =
        CGRectMake(path_rect.origin.x + origin.x,
                   path_rect.origin.y + origin.y - descent, width,
                   ascent + descent);
    ink = CGRectIsNull(ink) ? rect : CGRectUnion(ink, rect);
  }
  return ink;
}

// Lays `string` out inside a box `wrap_width` wide, centred in the frame.
Block layout(CFAttributedStringRef string, CGFloat wrap_width, int32_t width,
             int32_t height) {
  Block block = {nullptr, CGRectNull, CGRectNull, false};
  CTFramesetterRef setter = CTFramesetterCreateWithAttributedString(string);
  if (!setter) return block;

  CFRange fitted = {0, 0};
  const CGSize suggested = CTFramesetterSuggestFrameSizeWithConstraints(
      setter, CFRangeMake(0, 0), nullptr, CGSizeMake(wrap_width, CGFLOAT_MAX),
      &fitted);

  // A path exactly as tall as the suggestion loses its last line to rounding
  // often enough that it is not worth finding out which time.
  const CGFloat box_height = ceil(suggested.height) + 2.0;
  const CGRect path_rect =
      CGRectMake(((CGFloat)width - wrap_width) * 0.5,
                 ((CGFloat)height - box_height) * 0.5, wrap_width, box_height);

  CGPathRef path = CGPathCreateWithRect(path_rect, nullptr);
  CTFrameRef frame =
      CTFramesetterCreateFrame(setter, CFRangeMake(0, 0), path, nullptr);
  CGPathRelease(path);
  CFRelease(setter);
  if (!frame) return block;

  block.frame = frame;
  block.path = path_rect;
  block.ink = measure_ink(frame, path_rect);
  block.valid = !CGRectIsNull(block.ink);
  return block;
}

// The UTF-16 index that `count` composed characters reach.
//
// Composed rather than code units, because that is how a person counts what
// they typed: an accented letter is one character and a flag emoji is one, and
// a typewriter that revealed half of either would draw something that is not a
// character at all.
CFIndex utf16_index_of_character(CFStringRef text, CFIndex count) {
  const CFIndex length = CFStringGetLength(text);
  CFIndex index = 0;
  CFIndex seen = 0;
  while (index < length && seen < count) {
    const CFRange composed =
        CFStringGetRangeOfComposedCharactersAtIndex(text, index);
    index = composed.location + composed.length;
    seen++;
  }
  return index;
}

CFIndex composed_length(CFStringRef text) {
  const CFIndex length = CFStringGetLength(text);
  CFIndex index = 0;
  CFIndex count = 0;
  while (index < length) {
    const CFRange composed =
        CFStringGetRangeOfComposedCharactersAtIndex(text, index);
    index = composed.location + composed.length;
    count++;
  }
  return count;
}

// Draws the block, but only the glyphs up to `limit` — a UTF-16 index into the
// string the frame was laid out from.
//
// The layout is the *whole* caption's, and only the drawing is cut short. That
// is what makes a typewriter reveal words where they will finally sit instead
// of sliding them along as the line grows: a centred line that re-centred on
// every character would be unreadable, and one that will wrap would reflow
// under its own animation.
//
// Glyphs are assumed to run in the same order as the characters they came
// from, which is true of every left-to-right script and not of Arabic or
// Hebrew. A right-to-left caption reveals in glyph order rather than reading
// order — visibly odd, but it draws the right glyphs in the right places,
// which is the failure worth having until somebody asks for the other one.
void draw_frame_prefix(CTFrameRef frame, CGRect path, CGContextRef ctx,
                       CFIndex limit) {
  CFArrayRef lines = CTFrameGetLines(frame);
  const CFIndex line_count = CFArrayGetCount(lines);
  if (line_count == 0) return;

  std::vector<CGPoint> origins((size_t)line_count);
  CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), origins.data());

  for (CFIndex i = 0; i < line_count; i++) {
    CTLineRef line = (CTLineRef)CFArrayGetValueAtIndex(lines, i);
    const CFRange range = CTLineGetStringRange(line);
    if (range.location >= limit) break;  // nothing on this line yet

    CGContextSetTextPosition(ctx, path.origin.x + origins[(size_t)i].x,
                             path.origin.y + origins[(size_t)i].y);
    if (range.location + range.length <= limit) {
      CTLineDraw(line, ctx);
      continue;
    }

    CFArrayRef runs = CTLineGetGlyphRuns(line);
    for (CFIndex r = 0; r < CFArrayGetCount(runs); r++) {
      CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, r);
      const CFIndex glyphs = CTRunGetGlyphCount(run);
      if (glyphs == 0) continue;

      std::vector<CFIndex> indices((size_t)glyphs);
      CTRunGetStringIndices(run, CFRangeMake(0, 0), indices.data());

      CFIndex visible = 0;
      while (visible < glyphs && indices[(size_t)visible] < limit) visible++;
      if (visible == 0) continue;
      CTRunDraw(run, ctx, CFRangeMake(0, visible));
      if (visible < glyphs) break;
    }
  }
}

// The attributes both passes share. The stroke pass adds two of its own and
// changes no metric, which is what lets one layout describe both.
CFMutableDictionaryRef base_attributes(const VdTextSpec* spec, CTFontRef font,
                                       CTParagraphStyleRef style,
                                       CGFloat points) {
  CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 4, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFDictionarySetValue(attrs, kCTFontAttributeName, font);
  CFDictionarySetValue(attrs, kCTParagraphStyleAttributeName, style);
  if (spec->letter_spacing != 0.0f) {
    set_number(attrs, kCTKernAttributeName,
               (CGFloat)spec->letter_spacing * points);
  }
  return attrs;
}

CFAttributedStringRef make_string(CFStringRef text, CFDictionaryRef base,
                                  CGColorRef foreground, CGColorRef stroke,
                                  float stroke_width) {
  CFMutableDictionaryRef attrs =
      CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, base);
  if (foreground) {
    CFDictionarySetValue(attrs, kCTForegroundColorAttributeName, foreground);
  }
  if (stroke) {
    CFDictionarySetValue(attrs, kCTStrokeColorAttributeName, stroke);
    // Core Text measures a stroke as a percentage of the font size, which is
    // also how the spec states it. A positive width strokes without filling,
    // which is what makes the outline a pass of its own.
    set_number(attrs, kCTStrokeWidthAttributeName,
               (CGFloat)stroke_width * 100.0);
  }
  CFAttributedStringRef string =
      CFAttributedStringCreate(kCFAllocatorDefault, text, attrs);
  CFRelease(attrs);
  return string;
}

bool same_string(const char* a, const char* b) {
  if (a == b) return true;
  if (!a || !b) return (!a || !*a) && (!b || !*b);
  return strcmp(a, b) == 0;
}

}  // namespace

VdTextSpec vd_text_spec_default(void) {
  VdTextSpec spec;
  memset(&spec, 0, sizeof(spec));
  spec.size = kDefaultSize;
  spec.color = 0xFFFFFFFFu;
  spec.stroke_color = 0xFF000000u;
  // Alpha 0 is how the two optional parts are switched off, so their shape is
  // still described — turning a shadow on should not also require guessing
  // what offset and blur someone wanted.
  spec.shadow_color = 0x00000000u;
  spec.shadow_dy = 0.04f;
  spec.shadow_blur = 0.06f;
  spec.box_color = 0x00000000u;
  spec.box_padding = 0.25f;
  spec.box_radius = 0.15f;
  spec.line_spacing = 1.0f;
  spec.max_width = kDefaultMaxWidth;
  spec.align = VD_TEXT_ALIGN_CENTER;
  return spec;
}

bool vd_text_spec_equal(const VdTextSpec* a, const VdTextSpec* b) {
  if (a == b) return true;
  if (!a || !b) return false;
  return same_string(a->text, b->text) && same_string(a->font, b->font) &&
         a->size == b->size && a->color == b->color &&
         a->stroke_color == b->stroke_color &&
         a->stroke_width == b->stroke_width &&
         a->shadow_color == b->shadow_color && a->shadow_dx == b->shadow_dx &&
         a->shadow_dy == b->shadow_dy && a->shadow_blur == b->shadow_blur &&
         a->box_color == b->box_color && a->box_padding == b->box_padding &&
         a->box_radius == b->box_radius &&
         a->letter_spacing == b->letter_spacing &&
         a->line_spacing == b->line_spacing && a->max_width == b->max_width &&
         a->align == b->align;
}

VdTextSpec* vd_text_spec_copy(const VdTextSpec* spec) {
  if (!spec) return nullptr;
  VdTextSpec* copy = (VdTextSpec*)calloc(1, sizeof(VdTextSpec));
  if (!copy) return nullptr;
  *copy = *spec;
  copy->text = spec->text ? strdup(spec->text) : nullptr;
  copy->font = spec->font ? strdup(spec->font) : nullptr;
  return copy;
}

void vd_text_spec_free(VdTextSpec* spec) {
  if (!spec) return;
  free((void*)spec->text);
  free((void*)spec->font);
  free(spec);
}

int32_t vd_text_register_font(const void* data, int64_t size) {
  if (!data || size <= 0) return VD_ERR_INVALID_ARG;

  @autoreleasepool {
    CFDataRef bytes =
        CFDataCreate(kCFAllocatorDefault, (const UInt8*)data, (CFIndex)size);
    if (!bytes) return VD_ERR_OPEN;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(bytes);
    CGFontRef font = provider ? CGFontCreateWithDataProvider(provider) : nullptr;
    if (provider) CGDataProviderRelease(provider);
    CFRelease(bytes);
    if (!font) return VD_ERR_UNSUPPORTED;

    // The catalogue is keyed on what the file calls itself, because that is
    // the name a spec has to ask for later — and the only name that survives
    // the file being renamed. A variable font resolves to its default
    // instance here, which is the face the family name means.
    CTFontRef probe = CTFontCreateWithGraphicsFont(font, 12.0, nullptr, nullptr);
    CFStringRef family = probe ? CTFontCopyFamilyName(probe) : nullptr;
    char name[256] = {0};
    const bool named =
        family && CFStringGetCString(family, name, sizeof(name),
                                     kCFStringEncodingUTF8);
    if (family) CFRelease(family);
    if (probe) CFRelease(probe);
    if (!named) {
      CGFontRelease(font);
      return VD_ERR_UNSUPPORTED;
    }

    pthread_mutex_lock(&g_font_lock);
    bool seen = false;
    for (const Face& face : faces()) {
      if (strcmp(face.family, name) == 0) { seen = true; break; }
    }
    // Registering the same family twice is what happens when the app restarts
    // an engine. The first one stays and the second is dropped, so the
    // catalogue's order is stable across a restart.
    if (!seen) faces().push_back({strdup(name), font});
    pthread_mutex_unlock(&g_font_lock);
    if (seen) CGFontRelease(font);
  }
  return VD_OK;
}

int32_t vd_text_font_count(void) {
  pthread_mutex_lock(&g_font_lock);
  const int32_t count = (int32_t)faces().size();
  pthread_mutex_unlock(&g_font_lock);
  return count;
}

const char* vd_text_font_name(int32_t index) {
  pthread_mutex_lock(&g_font_lock);
  const char* name = nullptr;
  if (index >= 0 && (size_t)index < faces().size()) {
    name = faces()[(size_t)index].family;
  }
  pthread_mutex_unlock(&g_font_lock);
  return name;
}

int32_t vd_text_length(const VdTextSpec* spec) {
  if (!spec || !spec->text || !*spec->text) return 0;
  @autoreleasepool {
    CFStringRef text = CFStringCreateWithCString(
        kCFAllocatorDefault, spec->text, kCFStringEncodingUTF8);
    if (!text) return 0;
    const CFIndex count = composed_length(text);
    CFRelease(text);
    return (int32_t)count;
  }
}

void* vd_text_render(const VdTextSpec* spec, int32_t width, int32_t height,
                     int32_t reveal, int32_t* out_result) {
  if (out_result) *out_result = VD_OK;
  if (!spec || width <= 0 || height <= 0) {
    if (out_result) *out_result = VD_ERR_INVALID_ARG;
    return nullptr;
  }

  @autoreleasepool {
    CVPixelBufferRef buffer =
        (CVPixelBufferRef)vd_raster_create(width, height, out_result);
    if (!buffer) return nullptr;

    CGContextRef ctx = vd_raster_begin(buffer);
    if (!ctx) {
      CVPixelBufferRelease(buffer);
      if (out_result) *out_result = VD_ERR_UNSUPPORTED;
      return nullptr;
    }

    CFStringRef text =
        spec->text && *spec->text
            ? CFStringCreateWithCString(kCFAllocatorDefault, spec->text,
                                        kCFStringEncodingUTF8)
            : nullptr;

    // Nothing revealed yet: a transparent frame, and not even the box. The
    // box holds the caption's place once there is a caption to hold it for,
    // and a rectangle that appears a beat before the first letter reads as a
    // flash rather than as a backdrop.
    if (text && reveal == 0) {
      CFRelease(text);
      text = nullptr;
    }

    if (text) {
      const Resolved resolved = resolve(spec, width, height);
      CTFontRef font = create_font(spec->font, resolved.points);
      CTParagraphStyleRef style =
          create_paragraph_style(spec->align, spec->line_spacing, font);
      CFMutableDictionaryRef base =
          base_attributes(spec, font, style, resolved.points);

      CGColorRef fill = make_color(spec->color);
      CFAttributedStringRef fill_string =
          make_string(text, base, fill, nullptr, 0.0f);
      const Block block = layout(fill_string, resolved.wrap_width, width, height);

      // Everything below draws at most this far into the string. The layout
      // above used all of it, which is the point: the words that are already
      // on screen do not move as the rest arrives.
      const CFIndex limit = reveal < 0
                                ? CFStringGetLength(text)
                                : utf16_index_of_character(text, reveal);

      if (block.valid) {
        // The box first, so the ink's shadow falls across it rather than
        // underneath it.
        if (visible(spec->box_color)) {
          const CGFloat pad = (CGFloat)spec->box_padding * resolved.points;
          const CGRect box = CGRectInset(block.ink, -pad, -pad);
          CGFloat radius = (CGFloat)spec->box_radius * resolved.points;
          const CGFloat limit =
              MIN(CGRectGetWidth(box), CGRectGetHeight(box)) * 0.5;
          if (radius > limit) radius = limit;
          if (radius < 0) radius = 0;
          CGPathRef path =
              CGPathCreateWithRoundedRect(box, radius, radius, nullptr);
          CGColorRef colour = make_color(spec->box_color);
          CGContextSetFillColorWithColor(ctx, colour);
          CGContextAddPath(ctx, path);
          CGContextFillPath(ctx);
          CGColorRelease(colour);
          CGPathRelease(path);
        }

        if (visible(spec->shadow_color)) {
          CGColorRef colour = make_color(spec->shadow_color);
          // The spec's +y is down, the way a light above the frame throws it;
          // Core Graphics' is up.
          CGContextSetShadowWithColor(
              ctx,
              CGSizeMake((CGFloat)spec->shadow_dx * resolved.points,
                         -(CGFloat)spec->shadow_dy * resolved.points),
              (CGFloat)spec->shadow_blur * resolved.points, colour);
          CGColorRelease(colour);
        }

        // Outline under fill: a stroke is centred on the glyph's outline, so
        // drawing the fill over it leaves the outer half showing and the
        // letterform keeps its own shape instead of a thinned version of it.
        if (spec->stroke_width > 0.0f && visible(spec->stroke_color)) {
          CGColorRef stroke_colour = make_color(spec->stroke_color);
          CFAttributedStringRef stroke_string =
              make_string(text, base, nullptr, stroke_colour,
                          spec->stroke_width);
          const Block outline =
              layout(stroke_string, resolved.wrap_width, width, height);
          if (outline.frame) {
            draw_frame_prefix(outline.frame, outline.path, ctx, limit);
            CFRelease(outline.frame);
          }
          CFRelease(stroke_string);
          CGColorRelease(stroke_colour);
          // One shadow, cast by the outermost ink. Left on, it would give the
          // fill a second one, visible wherever the fill is not opaque.
          CGContextSetShadowWithColor(ctx, CGSizeZero, 0, nullptr);
        }

        draw_frame_prefix(block.frame, block.path, ctx, limit);
        CGContextSetShadowWithColor(ctx, CGSizeZero, 0, nullptr);
      }

      if (block.frame) CFRelease(block.frame);
      CFRelease(fill_string);
      CGColorRelease(fill);
      CFRelease(base);
      CFRelease(style);
      CFRelease(font);
      CFRelease(text);
    }

    vd_raster_finish(buffer, ctx);
    return buffer;
  }
}
