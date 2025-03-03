#include <metal_stdlib>
#include <simd/simd.h>
using namespace metal;

constant uint kBlockWidth = 16;
constant uint kBlockHeight = 16;

typedef struct {
    float4 clipSpacePosition [[position]];
    float2 texcoord;
} RasterizerData;

vertex RasterizerData vertexShader(
    uint vertexID [[vertex_id]],
    constant vector_float2 *positions[[buffer(0)]]) {
  RasterizerData out;
  out.clipSpacePosition = vector_float4(0.0, 0.0, 0.0, 1.0);
  out.clipSpacePosition.xy = positions[vertexID].xy;
  out.texcoord.x = (0.5 + 0.5 * positions[vertexID].x);
  out.texcoord.y = (0.5 - 0.5 * positions[vertexID].y);
  return out;
}

fragment float4 fragmentShader(RasterizerData in [[stage_in]],
                               texture2d<float> tex[[texture(0)]]) {
  constexpr sampler s(coord::normalized,
                      address::clamp_to_edge,
                      filter::linear);

  float4 color = tex.sample(s, in.texcoord);
  color.a = 1.0;
  return color;
}

//////////// Motion vector computation

float computeSumOfAbsoluteDifference(texture2d<float> a,
                                     texture2d<float> b,
                                     float2 a_texcoord,
                                     float2 b_texcoord) {
  constexpr sampler s(coord::pixel,
                      address::clamp_to_edge,
                      filter::linear);
  float total = 0.0;
  for (uint x = 0; x < kBlockWidth; ++x) {
    for (uint y = 0; y < kBlockHeight; ++y) {
      float2 delta = float2(x, y);
      float a_sample = a.sample(s, a_texcoord + delta).r;
      float b_sample = b.sample(s, b_texcoord + delta).r;
      total += abs(a_sample - b_sample);
    }
  }
  return total;
}

typedef struct {
    float2 vector;
    float residual;
} MotionVectorWithResidual;

MotionVectorWithResidual findBestMotionVector(
      texture2d<float> a,
      texture2d<float> b,
      float2 texcoord) {
  constexpr float kSearchStep = 1.0;
  constexpr float kSearchRadius = 32.0;

  MotionVectorWithResidual result;
  result.vector = float2(0, 0);
  result.residual = computeSumOfAbsoluteDifference(a, b, texcoord, texcoord);
  if (result.residual == 0.0)
    return result;

  for (float dx = -kSearchRadius; dx <= kSearchRadius; dx += kSearchStep) {
    for (float dy = -kSearchRadius; dy <= kSearchRadius; dy += kSearchStep) {
      float2 mv = float2(dx, dy);
      float sad = computeSumOfAbsoluteDifference(a, b, texcoord, texcoord + mv);
      if (sad < result.residual) {
        result.vector = mv;
        result.residual = sad;
        if (sad == 0.0)
          return result;
      }
    }
  }

  return result;
}

typedef struct {
    float4 clipSpacePosition [[position]];
    float2 texcoord;
} MotionVectorSearchRasterizerData;

vertex MotionVectorSearchRasterizerData motionVectorSearchVertexShader(
    uint vertexID [[vertex_id]],
    constant vector_float2 *positions[[buffer(0)]]) {
  MotionVectorSearchRasterizerData out;
  out.clipSpacePosition = vector_float4(0.0, 0.0, 0.0, 1.0);
  out.clipSpacePosition.xy = positions[vertexID].xy;
  out.texcoord.x = 1280 * (0.5 + 0.5 * positions[vertexID].x);
  out.texcoord.y =  720 * (0.5 + 0.5 * positions[vertexID].y);
  return out;
}

fragment float4 motionVectorSearchFragmentShader(
    MotionVectorSearchRasterizerData in [[stage_in]],
    texture2d<float> frame[[texture(0)]],
    texture2d<float> previous[[texture(1)]]) {
  MotionVectorWithResidual mv = findBestMotionVector(
      frame, previous, in.texcoord);
  float4 result = float4(0, 0, 0, 1);
  result.rg = mv.vector;
  return result;
}

///////// Visualize motion vectors as lines...

typedef struct {
    float4 clipSpacePosition [[position]];
    float endpoint;
} MotionVectorDrawRasterizerData;

vertex MotionVectorDrawRasterizerData motionVectorDrawVertexShader(
    uint vertexID [[vertex_id]],
    texture2d<float> motionVectors[[texture(0)]]) {
  uint width = 1280 / kBlockWidth;
  uint height = 720 / kBlockHeight;

  uint p = vertexID % 2;
  uint2 xy = uint2((vertexID / 2) % width, (vertexID / 2) / width);
  float2 xyf = float2(xy.x + 0.5, xy.y + 0.5);

  MotionVectorDrawRasterizerData out;
  out.clipSpacePosition.xy = xyf;
  if (p) {
    constexpr sampler s(coord::pixel,
                        address::clamp_to_edge,
                        filter::linear);

    float2 mv = motionVectors.sample(s, xyf).xy;
    out.clipSpacePosition.x -= mv.x / kBlockWidth;
    out.clipSpacePosition.y -= mv.y / kBlockHeight;
  }
  out.endpoint = p;


  out.clipSpacePosition.xy *= 2;
  out.clipSpacePosition.x /= width;
  out.clipSpacePosition.y /= height;
  out.clipSpacePosition.xy -= float2(1.0, 1.0);
  out.clipSpacePosition.z = 0.0;
  out.clipSpacePosition.w = 1.0;
  return out;
}

fragment float4 motionVectorDrawFragmentShader(
    MotionVectorDrawRasterizerData in [[stage_in]]) {
  float4 result = float4(in.endpoint, 0, 1, 0.3);
  return result;
}

////// Reconstruct image from motion vectors

typedef struct {
    float4 clipSpacePosition [[position]];
    float2 texcoord;
    float2 mvTexcoord;
} ReconstructRasterizerData;

vertex ReconstructRasterizerData reconstructVertexShader(
    uint vertexID [[vertex_id]],
    constant vector_float2 *positions[[buffer(0)]]) {
  ReconstructRasterizerData out;
  out.clipSpacePosition = vector_float4(0.0, 0.0, 0.0, 1.0);
  out.clipSpacePosition.xy = positions[vertexID].xy;
  out.texcoord.x = (0.5 + 0.5 * positions[vertexID].x);
  out.texcoord.y = (0.5 - 0.5 * positions[vertexID].y);
  out.mvTexcoord.x = (0.5 + 0.5 * positions[vertexID].x);
  out.mvTexcoord.y = (0.5 + 0.5 * positions[vertexID].y);
  return out;
}

fragment float4 reconstructFragmentShader(ReconstructRasterizerData in [[stage_in]],
                               texture2d<float> previous[[texture(0)]],
                               texture2d<float> motionVectors[[texture(1)]]) {
  constexpr sampler s(coord::normalized,
                      address::clamp_to_edge,
                      filter::nearest);

  float2 mv = motionVectors.sample(s, in.mvTexcoord).rg;
  mv.x /= 1280.0;
  mv.y /=  720.0;

  float4 color = previous.sample(s, in.texcoord + mv);
  color.a = 1.0;
  return color;
}

