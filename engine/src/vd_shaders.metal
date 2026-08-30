// Composite shaders: YUV planes in, premultiplied BGRA out.
//
// Precompiled to a .metallib by CMake and embedded in the binary, so there is
// no runtime shader compilation and no resource to find in a bundle.

#include <metal_stdlib>
using namespace metal;

struct VdLayerUniforms {
  // Destination rectangle in normalised output space, origin top-left.
  float4 rect;
  float opacity;
  // Clockwise quarter turns to apply when sampling: 0..3.
  uint quarter_turns;
  // 1 when the source is full-range (0-255), 0 for video range (16-235).
  uint full_range;
  uint _pad;
  // Luma coefficients for red and blue. BT.601, BT.709 and BT.2020 differ
  // only in these two numbers, so the matrix is derived rather than branched.
  float kr;
  float kb;
  float2 _pad2;
};

struct VertexOut {
  float4 position [[position]];
  float2 uv;
};

vertex VertexOut vd_vertex(uint vid [[vertex_id]],
                           constant VdLayerUniforms& u [[buffer(0)]]) {
  // Triangle strip over a unit quad: (0,0) (1,0) (0,1) (1,1).
  float2 corner = float2(float(vid & 1u), float((vid >> 1) & 1u));

  float2 unit = u.rect.xy + corner * u.rect.zw;   // 0..1, top-left origin
  VertexOut out;
  out.position = float4(unit.x * 2.0 - 1.0, 1.0 - unit.y * 2.0, 0.0, 1.0);

  // Rotate the sampling coordinates rather than the geometry, so the quad the
  // fit mode computed stays exactly where it was put.
  float2 uv = corner;
  switch (u.quarter_turns) {
    case 1: uv = float2(uv.y, 1.0 - uv.x); break;
    case 2: uv = float2(1.0 - uv.x, 1.0 - uv.y); break;
    case 3: uv = float2(1.0 - uv.y, uv.x); break;
    default: break;
  }
  out.uv = uv;
  return out;
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
  float y = luma.sample(vd_sampler, in.uv).r;
  float u_ = cb.sample(vd_sampler, in.uv).r;
  float v_ = cr.sample(vd_sampler, in.uv).r;
  float3 rgb = ycbcr_to_rgb(y, u_, v_, u.kr, u.kb, u.full_range != 0u);
  return float4(rgb * u.opacity, u.opacity);
}
