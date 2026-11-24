#include <metal_stdlib>

using namespace metal;

// Matches MetalPetal's passthrough vertex output. The fragment below is
// paired with its built-in vertex function by MTIRenderPipelineKernel.
struct FocusPeakingVertexOut {
    float4 position [[position]];
    float2 textureCoordinate;
};

inline float focusPeakingLuma(float3 rgb) {
    return dot(rgb, float3(0.2126, 0.7152, 0.0722));
}

/// A compact 3x3 Sobel focus-peaking fragment. It returns transparent black
/// for low-detail areas and a non-premultiplied red overlay for fine resolved
/// contrast. This is intentionally an overlay, not a re-render of the camera
/// image below it.
fragment float4 focusPeakingOverlay(
    FocusPeakingVertexOut vertexIn [[stage_in]],
    texture2d<float, access::sample> sourceTexture [[texture(0)]],
    sampler sourceSampler [[sampler(0)]]) {
    const float2 texel = 1.0 / float2(sourceTexture.get_width(), sourceTexture.get_height());
    const float2 uv = vertexIn.textureCoordinate;

    const float topLeft = focusPeakingLuma(sourceTexture.sample(sourceSampler, uv + texel * float2(-1, -1)).rgb);
    const float top = focusPeakingLuma(sourceTexture.sample(sourceSampler, uv + texel * float2(0, -1)).rgb);
    const float topRight = focusPeakingLuma(sourceTexture.sample(sourceSampler, uv + texel * float2(1, -1)).rgb);
    const float left = focusPeakingLuma(sourceTexture.sample(sourceSampler, uv + texel * float2(-1, 0)).rgb);
    const float right = focusPeakingLuma(sourceTexture.sample(sourceSampler, uv + texel * float2(1, 0)).rgb);
    const float bottomLeft = focusPeakingLuma(sourceTexture.sample(sourceSampler, uv + texel * float2(-1, 1)).rgb);
    const float bottom = focusPeakingLuma(sourceTexture.sample(sourceSampler, uv + texel * float2(0, 1)).rgb);
    const float bottomRight = focusPeakingLuma(sourceTexture.sample(sourceSampler, uv + texel * float2(1, 1)).rgb);

    const float horizontal = -topLeft - 2.0 * left - bottomLeft + topRight + 2.0 * right + bottomRight;
    const float vertical = -topLeft - 2.0 * top - topRight + bottomLeft + 2.0 * bottom + bottomRight;
    const float contrast = length(float2(horizontal, vertical));

    // The lower threshold removes texture noise; the upper threshold turns
    // only strongly resolved edges into full-red focus assistance.
    const float opacity = smoothstep(0.14, 0.31, contrast) * 0.82;
    return float4(1.0, 0.015, 0.0, opacity);
}
