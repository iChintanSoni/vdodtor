#include "vdodtor/vd_lut.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "vdodtor/vd_probe.h"

// Side of the cube a one-dimensional file is baked into for the GPU.
//
// 33 because that is the size the looks people ship are written at, and
// because a cube is the only shape a 3D texture has: a curve reaching the
// compositor has to be sampled at *some* number of points, and a tone curve
// smooth enough to be a look is smooth enough for 33 of them. The curve itself
// is kept as it was read — vd_lut_sample walks all of it — so what is lost
// here is lost on the way to the GPU and nowhere else.
#define VD_LUT_1D_BAKE_SIZE 33

// How long a `.cube` may reasonably be before it is refusing to be a look.
// A 64-cube written to six decimal places is about six megabytes; anything
// past this is a file somebody handed us by mistake, and reading it into
// memory to find that out is the mistake being expensive.
#define VD_LUT_MAX_BYTES (64 * 1024 * 1024)

struct VdLut {
  char title[128];

  bool is_3d;
  int32_t size;

  // What the file said, `size` (1D) or `size`^3 (3D) straight RGB triples with
  // red varying fastest, clamped to 0..1.
  //
  // Clamped at the door rather than at every sample so that the arithmetic
  // here and the arithmetic the GPU does are the *same* arithmetic: a 3D
  // texture holds normalised integers and clamps on upload, and a CPU sampler
  // that interpolated unclamped values and clamped afterwards would answer a
  // slightly different colour from the one on screen. The `.cube` format
  // permits values outside 0..1 for log looks; this is a display-referred
  // pipeline and has nowhere to put them.
  float* data;
  int64_t entries;

  // The input range the lattice covers. Almost always 0..1, and a file that
  // says otherwise is rescaled on the way in rather than at every sample.
  float domain_min[3];
  float domain_max[3];

  // The cube the compositor samples: `bake_size`^3 triples in the same order.
  // Aliases `data` for the common case — a 3D file over the default domain is
  // already exactly this — and is a second allocation only for a 1D file or a
  // domain that is not 0..1.
  float* lattice;
  int32_t bake_size;
  bool owns_lattice;

  uint64_t id;
};

// --- reading numbers -------------------------------------------------------

// A decimal parser rather than strtof, because strtof reads the *locale's*
// decimal separator and a `.cube` always writes a full stop. Under a locale
// where that separator is a comma — which the app inherits from the machine,
// not from us — strtof stops at the point and reads every value in the file as
// its integer part, so a look loads without error and renders as garbage. That
// is a bug that only happens on other people's computers.
//
// Advances `*p` past what it read. Returns false when there was no number
// there at all.
static bool read_float(const char** p, const char* end, float* out) {
  const char* s = *p;
  while (s < end && (*s == ' ' || *s == '\t')) s++;

  const char* start = s;
  bool negative = false;
  if (s < end && (*s == '+' || *s == '-')) {
    negative = (*s == '-');
    s++;
  }

  double value = 0.0;
  bool any = false;
  while (s < end && *s >= '0' && *s <= '9') {
    value = value * 10.0 + (double)(*s - '0');
    s++;
    any = true;
  }
  if (s < end && *s == '.') {
    s++;
    double scale = 0.1;
    while (s < end && *s >= '0' && *s <= '9') {
      value += (double)(*s - '0') * scale;
      scale *= 0.1;
      s++;
      any = true;
    }
  }
  if (!any) {
    *p = start;
    return false;
  }

  if (s < end && (*s == 'e' || *s == 'E')) {
    const char* mark = s;
    s++;
    bool exp_negative = false;
    if (s < end && (*s == '+' || *s == '-')) {
      exp_negative = (*s == '-');
      s++;
    }
    int exponent = 0;
    bool exp_any = false;
    while (s < end && *s >= '0' && *s <= '9') {
      // Clamped as it is read: a file claiming 1e999999 must not spin here.
      if (exponent < 10000) exponent = exponent * 10 + (*s - '0');
      s++;
      exp_any = true;
    }
    if (!exp_any) {
      s = mark;  // an 'e' that led nowhere is not part of the number
    } else {
      double factor = 1.0;
      for (int i = 0; i < exponent && i < 400; i++) factor *= 10.0;
      value = exp_negative ? value / factor : value * factor;
    }
  }

  *out = (float)(negative ? -value : value);
  *p = s;
  return true;
}

static float clamp01(float v) {
  if (!(v > 0.0f)) return 0.0f;  // NaN lands here too
  return v > 1.0f ? 1.0f : v;
}

// --- parsing ---------------------------------------------------------------

static bool starts_with(const char* line, const char* end, const char* word) {
  const size_t n = strlen(word);
  return (size_t)(end - line) >= n && strncmp(line, word, n) == 0;
}

static void skip_spaces(const char** p, const char* end) {
  while (*p < end && (**p == ' ' || **p == '\t')) (*p)++;
}

// TITLE "Warm Film" — the quotes are the format's, and a file that leaves them
// off is common enough to accept.
static void read_title(const char* p, const char* end, char* out,
                       size_t capacity) {
  skip_spaces(&p, end);
  if (p < end && *p == '"') {
    p++;
    const char* close = p;
    while (close < end && *close != '"') close++;
    end = close;
  } else {
    while (end > p && (end[-1] == ' ' || end[-1] == '\t')) end--;
  }
  size_t n = (size_t)(end - p);
  if (n >= capacity) n = capacity - 1;
  memcpy(out, p, n);
  out[n] = '\0';
}

static bool read_triple(const char* p, const char* end, float out[3]) {
  for (int i = 0; i < 3; i++) {
    if (!read_float(&p, end, &out[i])) return false;
  }
  return true;
}

static uint64_t next_id(void) {
  static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
  static uint64_t counter = 0;
  pthread_mutex_lock(&lock);
  const uint64_t id = ++counter;
  pthread_mutex_unlock(&lock);
  return id;
}

static void fail(VdLut* lut, int32_t* out_result, int32_t code) {
  if (out_result) *out_result = code;
  vd_lut_close(lut);
}

// Fills `lattice`/`bake_size` once the data is in.
//
// A 3D file over the default domain *is* the cube already — same order, same
// values, same size — so it is aliased rather than copied. Everything else is
// resampled through vd_lut_sample, which is one code path for "a curve" and
// "a cube on the wrong domain" and needs no second idea of what the file
// means.
static bool bake(VdLut* lut) {
  const bool unit_domain =
      lut->domain_min[0] == 0.0f && lut->domain_min[1] == 0.0f &&
      lut->domain_min[2] == 0.0f && lut->domain_max[0] == 1.0f &&
      lut->domain_max[1] == 1.0f && lut->domain_max[2] == 1.0f;

  if (lut->is_3d && unit_domain) {
    lut->lattice = lut->data;
    lut->bake_size = lut->size;
    lut->owns_lattice = false;
    return true;
  }

  const int32_t n = lut->is_3d ? lut->size : VD_LUT_1D_BAKE_SIZE;
  const int64_t count = (int64_t)n * n * n;
  float* out = (float*)malloc((size_t)count * 3 * sizeof(float));
  if (!out) return false;

  const float step = 1.0f / (float)(n - 1);
  int64_t at = 0;
  for (int32_t b = 0; b < n; b++) {
    for (int32_t g = 0; g < n; g++) {
      for (int32_t r = 0; r < n; r++) {
        float rgb[3] = {(float)r * step, (float)g * step, (float)b * step};
        vd_lut_sample(lut, rgb);
        out[at++] = rgb[0];
        out[at++] = rgb[1];
        out[at++] = rgb[2];
      }
    }
  }

  lut->lattice = out;
  lut->bake_size = n;
  lut->owns_lattice = true;
  return true;
}

VdLut* vd_lut_parse(const char* text, int64_t length, int32_t* out_result) {
  if (out_result) *out_result = VD_OK;
  if (!text || length <= 0) {
    if (out_result) *out_result = VD_ERR_INVALID_ARG;
    return NULL;
  }

  VdLut* lut = (VdLut*)calloc(1, sizeof(VdLut));
  if (!lut) {
    if (out_result) *out_result = VD_ERR_OPEN;
    return NULL;
  }
  for (int i = 0; i < 3; i++) {
    lut->domain_min[i] = 0.0f;
    lut->domain_max[i] = 1.0f;
  }

  const char* p = text;
  const char* file_end = text + length;
  int64_t written = 0;

  while (p < file_end) {
    const char* line = p;
    const char* end = line;
    while (end < file_end && *end != '\n') end++;
    p = (end < file_end) ? end + 1 : file_end;
    if (end > line && end[-1] == '\r') end--;

    skip_spaces(&line, end);
    if (line >= end || *line == '#') continue;

    if (starts_with(line, end, "TITLE")) {
      read_title(line + 5, end, lut->title, sizeof(lut->title));
      continue;
    }
    if (starts_with(line, end, "DOMAIN_MIN")) {
      read_triple(line + 10, end, lut->domain_min);
      continue;
    }
    if (starts_with(line, end, "DOMAIN_MAX")) {
      read_triple(line + 10, end, lut->domain_max);
      continue;
    }

    const bool is_3d = starts_with(line, end, "LUT_3D_SIZE");
    const bool is_1d = starts_with(line, end, "LUT_1D_SIZE");
    if (is_3d || is_1d) {
      // Two size lines, or a size after the data has started, is a file that
      // means two different things at once. Refusing beats picking one.
      if (lut->data) {
        fail(lut, out_result, VD_ERR_UNSUPPORTED);
        return NULL;
      }
      const char* at = line + 11;
      float declared = 0.0f;
      if (!read_float(&at, end, &declared)) {
        fail(lut, out_result, VD_ERR_UNSUPPORTED);
        return NULL;
      }
      const int32_t size = (int32_t)declared;
      const int32_t limit = is_3d ? VD_LUT_MAX_3D_SIZE : VD_LUT_MAX_1D_SIZE;
      // Two is the smallest lattice that can interpolate; one point is a
      // constant, which is not a look but a paint bucket.
      if (size < 2 || size > limit) {
        fail(lut, out_result, VD_ERR_UNSUPPORTED);
        return NULL;
      }
      lut->is_3d = is_3d;
      lut->size = size;
      lut->entries = is_3d ? (int64_t)size * size * size : (int64_t)size;
      lut->data = (float*)malloc((size_t)lut->entries * 3 * sizeof(float));
      if (!lut->data) {
        fail(lut, out_result, VD_ERR_OPEN);
        return NULL;
      }
      continue;
    }

    // Anything else is a row of the table — or a keyword from a later version
    // of the format, which reads as a row that is not three numbers and is
    // skipped. A file whose *data* is malformed runs out of rows instead, and
    // that is the error worth reporting.
    float rgb[3];
    if (!read_triple(line, end, rgb)) continue;
    if (!lut->data || written >= lut->entries) {
      // Rows before the size line, or more rows than the size promised. Either
      // way the file does not describe the table it declared.
      fail(lut, out_result, VD_ERR_UNSUPPORTED);
      return NULL;
    }
    lut->data[written * 3 + 0] = clamp01(rgb[0]);
    lut->data[written * 3 + 1] = clamp01(rgb[1]);
    lut->data[written * 3 + 2] = clamp01(rgb[2]);
    written++;
  }

  if (!lut->data || written != lut->entries) {
    fail(lut, out_result, VD_ERR_UNSUPPORTED);
    return NULL;
  }
  for (int i = 0; i < 3; i++) {
    if (!(lut->domain_max[i] > lut->domain_min[i])) {
      fail(lut, out_result, VD_ERR_UNSUPPORTED);
      return NULL;
    }
  }
  if (!bake(lut)) {
    fail(lut, out_result, VD_ERR_OPEN);
    return NULL;
  }
  lut->id = next_id();
  return lut;
}

VdLut* vd_lut_open(const char* path, int32_t* out_result) {
  if (out_result) *out_result = VD_OK;
  if (!path) {
    if (out_result) *out_result = VD_ERR_INVALID_ARG;
    return NULL;
  }
  FILE* file = fopen(path, "rb");
  if (!file) {
    if (out_result) *out_result = VD_ERR_OPEN;
    return NULL;
  }
  if (fseek(file, 0, SEEK_END) != 0) {
    fclose(file);
    if (out_result) *out_result = VD_ERR_OPEN;
    return NULL;
  }
  const long length = ftell(file);
  rewind(file);
  if (length <= 0 || length > VD_LUT_MAX_BYTES) {
    fclose(file);
    if (out_result) *out_result = VD_ERR_UNSUPPORTED;
    return NULL;
  }
  char* text = (char*)malloc((size_t)length);
  if (!text) {
    fclose(file);
    if (out_result) *out_result = VD_ERR_OPEN;
    return NULL;
  }
  const size_t read = fread(text, 1, (size_t)length, file);
  fclose(file);
  VdLut* lut = vd_lut_parse(text, (int64_t)read, out_result);
  free(text);
  return lut;
}

void vd_lut_close(VdLut* lut) {
  if (!lut) return;
  if (lut->owns_lattice) free(lut->lattice);
  free(lut->data);
  free(lut);
}

const char* vd_lut_title(const VdLut* lut) { return lut ? lut->title : ""; }
int32_t vd_lut_size(const VdLut* lut) { return lut ? lut->size : 0; }
bool vd_lut_is_3d(const VdLut* lut) { return lut ? lut->is_3d : false; }

int32_t vd_lut_bake_size(const VdLut* lut) { return lut ? lut->bake_size : 0; }

// --- sampling --------------------------------------------------------------

// Where `v` falls on an axis of `n` lattice points: the lower point in `*index`
// and how far past it in `*fraction`.
static void locate(float v, float lo, float hi, int32_t n, int32_t* index,
                   float* fraction) {
  const float normalised = clamp01((v - lo) / (hi - lo));
  const float scaled = normalised * (float)(n - 1);
  int32_t i = (int32_t)scaled;
  // The top of the range lands exactly on the last point, where there is no
  // pair to interpolate between; step back one and let the fraction be 1.
  if (i > n - 2) i = n - 2;
  if (i < 0) i = 0;
  *index = i;
  *fraction = scaled - (float)i;
}

void vd_lut_sample(const VdLut* lut, float rgb[3]) {
  if (!lut || !rgb) return;

  if (!lut->is_3d) {
    // Three independent curves: each channel is looked up in its own column,
    // and nothing a channel does can affect another. That is the whole
    // difference between a 1D file and a cube, and the reason a split-tone
    // cannot be written as one.
    for (int ch = 0; ch < 3; ch++) {
      int32_t i;
      float f;
      locate(rgb[ch], lut->domain_min[ch], lut->domain_max[ch], lut->size, &i,
             &f);
      const float a = lut->data[(int64_t)i * 3 + ch];
      const float b = lut->data[((int64_t)i + 1) * 3 + ch];
      rgb[ch] = clamp01(a + (b - a) * f);
    }
    return;
  }

  int32_t i0[3];
  float f[3];
  for (int ch = 0; ch < 3; ch++) {
    locate(rgb[ch], lut->domain_min[ch], lut->domain_max[ch], lut->size, &i0[ch],
           &f[ch]);
  }

  // Trilinear over the eight lattice points around the colour — the same eight
  // taps, in the same proportions, that a 3D texture with linear filtering
  // does in one instruction. Red varies fastest, which is the order a `.cube`
  // writes its rows in.
  const int32_t n = lut->size;
  float out[3] = {0.0f, 0.0f, 0.0f};
  for (int corner = 0; corner < 8; corner++) {
    const int32_t dr = corner & 1;
    const int32_t dg = (corner >> 1) & 1;
    const int32_t db = (corner >> 2) & 1;
    const float weight = (dr ? f[0] : 1.0f - f[0]) *
                         (dg ? f[1] : 1.0f - f[1]) *
                         (db ? f[2] : 1.0f - f[2]);
    if (weight == 0.0f) continue;
    const int64_t index =
        ((int64_t)(i0[2] + db) * n + (i0[1] + dg)) * n + (i0[0] + dr);
    out[0] += lut->data[index * 3 + 0] * weight;
    out[1] += lut->data[index * 3 + 1] * weight;
    out[2] += lut->data[index * 3 + 2] * weight;
  }
  rgb[0] = clamp01(out[0]);
  rgb[1] = clamp01(out[1]);
  rgb[2] = clamp01(out[2]);
}

void vd_lut_apply(const VdLut* lut, float strength, float rgb[3]) {
  if (!lut || !rgb) return;
  const float mix = clamp01(strength);
  if (mix == 0.0f) return;
  float looked[3] = {rgb[0], rgb[1], rgb[2]};
  vd_lut_sample(lut, looked);
  for (int ch = 0; ch < 3; ch++) {
    rgb[ch] = rgb[ch] + (looked[ch] - rgb[ch]) * mix;
  }
}

VdColorLook vd_lut_look(const VdLut* lut, float strength) {
  VdColorLook look;
  memset(&look, 0, sizeof(look));
  if (!lut) return look;
  const float mix = clamp01(strength);
  // A look at no strength is no look, and saying so here means the compositor
  // never uploads a cube for a slider somebody dragged to zero.
  if (mix == 0.0f) return look;
  look.lattice = lut->lattice;
  look.size = lut->bake_size;
  look.id = lut->id;
  look.strength = mix;
  return look;
}

// --- the catalogue ---------------------------------------------------------

typedef struct {
  char name[128];
  VdLut* lut;
} VdLutEntry;

static pthread_mutex_t g_lut_lock = PTHREAD_MUTEX_INITIALIZER;
static VdLutEntry* g_luts = NULL;
static int32_t g_lut_count = 0;
static int32_t g_lut_capacity = 0;

int32_t vd_lut_register(const char* name, const void* data, int64_t size) {
  if (!name || !*name || !data || size <= 0) return VD_ERR_INVALID_ARG;
  if (strlen(name) >= sizeof(((VdLutEntry*)0)->name)) {
    return VD_ERR_INVALID_ARG;
  }

  pthread_mutex_lock(&g_lut_lock);
  for (int32_t i = 0; i < g_lut_count; i++) {
    if (strcmp(g_luts[i].name, name) == 0) {
      // Already there. Quietly ignored rather than replaced: every clip on the
      // timeline is holding the first one, and swapping it underneath them
      // would change what is on screen for a call whose whole job is to be
      // idempotent across a hot restart.
      pthread_mutex_unlock(&g_lut_lock);
      return VD_OK;
    }
  }
  pthread_mutex_unlock(&g_lut_lock);

  int32_t result = VD_OK;
  VdLut* lut = vd_lut_parse((const char*)data, size, &result);
  if (!lut) return result;

  pthread_mutex_lock(&g_lut_lock);
  // Checked again with the lock held: two threads registering the same name
  // would otherwise both parse and both append.
  for (int32_t i = 0; i < g_lut_count; i++) {
    if (strcmp(g_luts[i].name, name) == 0) {
      pthread_mutex_unlock(&g_lut_lock);
      vd_lut_close(lut);
      return VD_OK;
    }
  }
  if (g_lut_count == g_lut_capacity) {
    const int32_t capacity = g_lut_capacity ? g_lut_capacity * 2 : 8;
    VdLutEntry* grown =
        (VdLutEntry*)realloc(g_luts, (size_t)capacity * sizeof(VdLutEntry));
    if (!grown) {
      pthread_mutex_unlock(&g_lut_lock);
      vd_lut_close(lut);
      return VD_ERR_OPEN;
    }
    g_luts = grown;
    g_lut_capacity = capacity;
  }
  snprintf(g_luts[g_lut_count].name, sizeof(g_luts[g_lut_count].name), "%s",
           name);
  g_luts[g_lut_count].lut = lut;
  g_lut_count++;
  pthread_mutex_unlock(&g_lut_lock);
  return VD_OK;
}

int32_t vd_lut_count(void) {
  pthread_mutex_lock(&g_lut_lock);
  const int32_t count = g_lut_count;
  pthread_mutex_unlock(&g_lut_lock);
  return count;
}

const char* vd_lut_name(int32_t index) {
  pthread_mutex_lock(&g_lut_lock);
  const char* name =
      (index >= 0 && index < g_lut_count) ? g_luts[index].name : "";
  pthread_mutex_unlock(&g_lut_lock);
  return name;
}

const VdLut* vd_lut_find(const char* name) {
  if (!name || !*name) return NULL;
  pthread_mutex_lock(&g_lut_lock);
  const VdLut* found = NULL;
  for (int32_t i = 0; i < g_lut_count; i++) {
    if (strcmp(g_luts[i].name, name) == 0) {
      found = g_luts[i].lut;
      break;
    }
  }
  pthread_mutex_unlock(&g_lut_lock);
  // Safe to hand out with the lock dropped: nothing is ever unregistered, so
  // what this points at outlives every caller. That is the whole reason there
  // is no vd_lut_unregister.
  return found;
}
