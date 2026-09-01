// Composite shaders: YUV planes in, premultiplied BGRA out.
//
// Precompiled to a .metallib by CMake and embedded in the binary, so there is
// no runtime shader compilation and no resource to find in a bundle.

#include <metal_stdlib>
using namespace metal;

struct VdLayerUniforms {
  // Destination rectangle in normalised output space, origin top-left. The
  // fit, the scale and the offset are all folded into this on the CPU; only
  // the rotation has to happen per-vertex.
  float4 rect;
  // The part of the source to sample, normalised, in display orientation.
  float4 crop;
  // cos and sin of the layer's rotation.
  float2 rotation;
  // Output width divided by height. Rotation happens in a square space and
  // comes back out again, or a turned square would leave as a rhombus.
  float aspect;
  float opacity;
  // Clockwise quarter turns to apply when sampling: 0..3.
  uint quarter_turns;
  // 1 when the source is full-range (0-255), 0 for video range (16-235).
  uint full_range;
  uint flip_h;
  uint flip_v;
  // Luma coefficients for red and blue. BT.601, BT.709 and BT.2020 differ
  // only in these two numbers, so the matrix is derived rather than branched.
  float kr;
  float kb;
  // Distance between blur taps, in texture coordinates. One axis at a time:
  // a separable blur is two cheap passes where a square kernel is one dear
  // one, and at these radii the difference is the whole cost.
  float2 blur_step;
  // How much of the layer's own quad to cut away, per side: left, top, right,
  // bottom. Zeroed cuts nothing, so a layer that says nothing about it draws
  // whole — which is every layer but the incoming half of a wipe.
  float4 hide;
  // The colour grade: one row of a 3x3 matrix per float4, with that row's
  // offset in w. Five sliders composed on the CPU into `rgb' = m*rgb + b` —
  // see vd_color.h, where the arithmetic that decides what a grade *means*
  // lives and can be tested without a GPU.
  float4 grade[3];
  // 0 for a layer nobody graded, and then the multiply-add is skipped
  // entirely. Not an optimisation — nine multiplies is nothing here — but a
  // guarantee: an ungraded fragment takes the path it took before this shader
  // learned about grading, bit for bit, so the golden frames cannot move for
  // a feature nobody used.
  uint graded;
  // Entries per axis of the look's cube, or 0 for a layer wearing no look —
  // which short-circuits the fetch on the same terms and for the same reason
  // `graded` does. The size is needed rather than merely the flag because a
  // lattice point sits at a texel *centre*, so where 0 and 1 land in the
  // texture depends on how many texels there are.
  uint lut_size;
  // How far towards the look to go: 0 is the shot as it was graded, 1 is the
  // look at full strength.
  float lut_strength;
};

struct VertexOut {
  float4 position [[position]];
  float2 uv;
  // Where this fragment falls inside the layer's own rectangle, 0..1. The uv
  // above has been cropped, flipped and turned by the time it arrives, so it
  // cannot answer "how far across the clip is this" — which is the only
  // question a wipe asks.
  float2 quad;
};

vertex VertexOut vd_vertex(uint vid [[vertex_id]],
                           constant VdLayerUniforms& u [[buffer(0)]]) {
  // Triangle strip over a unit quad: (0,0) (1,0) (0,1) (1,1).
  float2 corner = float2(float(vid & 1u), float((vid >> 1) & 1u));

  // Rotate the quad about its own centre. In normalised output space x and y
  // do not measure the same distance, so the offset goes into a square space
  // to be turned and comes back out again; skipping that turns a square clip
  // into a rhombus on any output that is not itself square.
  const float2 centre = u.rect.xy + u.rect.zw * 0.5;
  float2 local = (corner - 0.5) * u.rect.zw;
  local.x *= u.aspect;
  local = float2(local.x * u.rotation.x - local.y * u.rotation.y,
                 local.x * u.rotation.y + local.y * u.rotation.x);
  local.x /= u.aspect;

  const float2 unit = centre + local;
  VertexOut out;
  out.position = float4(unit.x * 2.0 - 1.0, 1.0 - unit.y * 2.0, 0.0, 1.0);

  // Sampling runs the other way, from what the viewer sees back to what the
  // decoder produced: flip and crop in display orientation, then undo the
  // source's own quarter turns to land in the frame's own coordinates.
  float2 uv = corner;
  if (u.flip_h != 0u) uv.x = 1.0 - uv.x;
  if (u.flip_v != 0u) uv.y = 1.0 - uv.y;
  uv = u.crop.xy + uv * u.crop.zw;
  switch (u.quarter_turns) {
    case 1: uv = float2(uv.y, 1.0 - uv.x); break;
    case 2: uv = float2(1.0 - uv.x, 1.0 - uv.y); break;
    case 3: uv = float2(1.0 - uv.y, uv.x); break;
    default: break;
  }
  out.uv = uv;
  out.quad = corner;
  return out;
}

// Cuts the fragment away if it falls outside what the layer reveals. A hard
// edge on purpose: a wipe that faded at its boundary is a dissolve in a
// costume.
static inline bool vd_hidden(float2 quad, float4 hide) {
  return quad.x < hide.x || quad.y < hide.y || quad.x > 1.0 - hide.z ||
         quad.y > 1.0 - hide.w;
}

// YCbCr to RGB for any of the standard matrices, built from kr and kb.
static inline float3 ycbcr_to_rgb(float y, float cb, float cr, float kr,
                                  float kb, bool full_range) {
  if (!full_range) {
    y = (y - 16.0 / 255.0) * (255.0 / 219.0);
    cb = (cb - 128.0 / 255.0) * (255.0 / 224.0);
    cr = (cr - 128.0 / 255.0) * (255.0 / 224.0);
  } else {
    cb -= 0.5;
    cr -= 0.5;
  }
  const float kg = 1.0 - kr - kb;
  float3 rgb;
  rgb.r = y + 2.0 * (1.0 - kr) * cr;
  rgb.b = y + 2.0 * (1.0 - kb) * cb;
  rgb.g = y - (2.0 * kr * (1.0 - kr) / kg) * cr
            - (2.0 * kb * (1.0 - kb) / kg) * cb;
  return clamp(rgb, 0.0, 1.0);
}

constexpr sampler vd_lut_sampler(filter::linear, address::clamp_to_edge);

// The look: an arbitrary map from colour to colour, which is the half of a
// grade that cannot be a matrix. See vd_lut.h, where what a look *means* lives
// and can be asserted on numbers.
//
// A lattice point sits at the centre of a texel, so the ends of the ramp are
// half a texel in from the ends of the texture — sampling at rgb directly
// would read the first and last lattice points a texel early and flatten both
// ends of every look.
static inline float3 vd_look(float3 rgb, constant VdLayerUniforms& u,
                             texture3d<float> lut) {
  if (u.lut_size == 0u) return rgb;
  const float n = float(u.lut_size);
  const float3 coord = (clamp(rgb, 0.0, 1.0) * (n - 1.0) + 0.5) / n;
  return mix(rgb, lut.sample(vd_lut_sampler, coord).rgb, u.lut_strength);
}

// The grade, on a straight — not premultiplied — RGB triple.
//
// Five sliders and then the look, which is the order a colourist works in:
// correct the shot, then style it. It is also the order the look was authored
// expecting — a film emulation built against a neutral, properly exposed frame
// should be handed one — and it is why the inspector puts the look under the
// sliders rather than over them.
static inline float3 vd_grade(float3 rgb, constant VdLayerUniforms& u,
                              texture3d<float> lut) {
  if (u.graded != 0u) {
    const float3 graded = float3(dot(u.grade[0].xyz, rgb) + u.grade[0].w,
                                 dot(u.grade[1].xyz, rgb) + u.grade[1].w,
                                 dot(u.grade[2].xyz, rgb) + u.grade[2].w);
    rgb = clamp(graded, 0.0, 1.0);
  }
  return vd_look(rgb, u, lut);
}

// The same, for a texel that arrives premultiplied — a caption, a shape, a
// sticker, a blur-fill backdrop.
//
// Undone and redone around the grade rather than applied through it: the
// matrix is affine, so multiplying the alpha through it would put the offset
// row somewhere it does not belong and give a half-transparent pixel half a
// contrast lift. The alpha itself is never touched — a grade changes what
// colour a pixel is, not whether it is there.
static inline float4 vd_grade_premultiplied(float4 texel,
                                            constant VdLayerUniforms& u,
                                            texture3d<float> lut) {
  if ((u.graded == 0u && u.lut_size == 0u) || texel.a <= 0.0) return texel;
  return float4(vd_grade(texel.rgb / texel.a, u, lut) * texel.a, texel.a);
}

constexpr sampler vd_sampler(filter::linear, address::clamp_to_edge);

// VideoToolbox output: Y plane plus interleaved CbCr.
fragment float4 vd_fragment_nv12(VertexOut in [[stage_in]],
                                 constant VdLayerUniforms& u [[buffer(0)]],
                                 texture2d<float> luma [[texture(0)]],
                                 texture2d<float> chroma [[texture(1)]],
                                 texture3d<float> lut [[texture(3)]]) {
  if (vd_hidden(in.quad, u.hide)) discard_fragment();
  float y = luma.sample(vd_sampler, in.uv).r;
  float2 cbcr = chroma.sample(vd_sampler, in.uv).rg;
  float3 rgb = ycbcr_to_rgb(y, cbcr.x, cbcr.y, u.kr, u.kb, u.full_range != 0u);
  rgb = vd_grade(rgb, u, lut);
  // Premultiplied, to match the blend state.
  return float4(rgb * u.opacity, u.opacity);
}

// Software decode: three separate planes.
fragment float4 vd_fragment_yuv420p(VertexOut in [[stage_in]],
                                    constant VdLayerUniforms& u [[buffer(0)]],
                                    texture2d<float> luma [[texture(0)]],
                                    texture2d<float> cb [[texture(1)]],
                                    texture2d<float> cr [[texture(2)]],
                                    texture3d<float> lut [[texture(3)]]) {
  if (vd_hidden(in.quad, u.hide)) discard_fragment();
  float y = luma.sample(vd_sampler, in.uv).r;
  float u_ = cb.sample(vd_sampler, in.uv).r;
  float v_ = cr.sample(vd_sampler, in.uv).r;
  float3 rgb = vd_grade(
      ycbcr_to_rgb(y, u_, v_, u.kr, u.kb, u.full_range != 0u), u, lut);
  return float4(rgb * u.opacity, u.opacity);
}

// --- blur fill --------------------------------------------------------------
// The background behind a letterboxed clip: the same picture, cover-fitted so
// it reaches the edges, blurred until it reads as a colour rather than as a
// second copy of the shot.

constant float vd_blur_weights[5] = {0.2270270270, 0.1945945946, 0.1216216216,
                                     0.0540540541, 0.0162162162};

fragment float4 vd_fragment_blur(VertexOut in [[stage_in]],
                                 constant VdLayerUniforms& u [[buffer(0)]],
                                 texture2d<float> source [[texture(0)]]) {
  float4 sum = source.sample(vd_sampler, in.uv) * vd_blur_weights[0];
  for (int i = 1; i < 5; i++) {
    const float2 offset = u.blur_step * float(i);
    sum += source.sample(vd_sampler, in.uv + offset) * vd_blur_weights[i];
    sum += source.sample(vd_sampler, in.uv - offset) * vd_blur_weights[i];
  }
  return sum;
}

// Draws an already-composited RGBA texture, at a given opacity.
fragment float4 vd_fragment_texture(VertexOut in [[stage_in]],
                                    constant VdLayerUniforms& u [[buffer(0)]],
                                    texture2d<float> source [[texture(0)]],
                                    texture3d<float> lut [[texture(3)]]) {
  if (vd_hidden(in.quad, u.hide)) discard_fragment();
  const float4 texel =
      vd_grade_premultiplied(source.sample(vd_sampler, in.uv), u, lut);
  // Already premultiplied by the pass that produced it, so opacity scales
  // both halves together.
  return texel * u.opacity;
}
