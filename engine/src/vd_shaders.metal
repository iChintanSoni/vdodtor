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

constexpr sampler vd_sampler(filter::linear, address::clamp_to_edge);

// VideoToolbox output: Y plane plus interleaved CbCr.
fragment float4 vd_fragment_nv12(VertexOut in [[stage_in]],
                                 constant VdLayerUniforms& u [[buffer(0)]],
                                 texture2d<float> luma [[texture(0)]],
                                 texture2d<float> chroma [[texture(1)]]) {
  if (vd_hidden(in.quad, u.hide)) discard_fragment();
  float y = luma.sample(vd_sampler, in.uv).r;
  float2 cbcr = chroma.sample(vd_sampler, in.uv).rg;
  float3 rgb = ycbcr_to_rgb(y, cbcr.x, cbcr.y, u.kr, u.kb, u.full_range != 0u);
  // Premultiplied, to match the blend state.
  return float4(rgb * u.opacity, u.opacity);
}

// Software decode: three separate planes.
fragment float4 vd_fragment_yuv420p(VertexOut in [[stage_in]],
                                    constant VdLayerUniforms& u [[buffer(0)]],
                                    texture2d<float> luma [[texture(0)]],
                                    texture2d<float> cb [[texture(1)]],
                                    texture2d<float> cr [[texture(2)]]) {
  if (vd_hidden(in.quad, u.hide)) discard_fragment();
  float y = luma.sample(vd_sampler, in.uv).r;
  float u_ = cb.sample(vd_sampler, in.uv).r;
  float v_ = cr.sample(vd_sampler, in.uv).r;
  float3 rgb = ycbcr_to_rgb(y, u_, v_, u.kr, u.kb, u.full_range != 0u);
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
                                    texture2d<float> source [[texture(0)]]) {
  if (vd_hidden(in.quad, u.hide)) discard_fragment();
  const float4 texel = source.sample(vd_sampler, in.uv);
  // Already premultiplied by the pass that produced it, so opacity scales
  // both halves together.
  return texel * u.opacity;
}
