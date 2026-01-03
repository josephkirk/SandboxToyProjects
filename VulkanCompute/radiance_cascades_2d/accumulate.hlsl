/*==============================================================================
    TEMPORAL ACCUMULATION SHADER
    ============================================================================
    
    This shader blends the current frame's radiance with previous frames using
    an exponential moving average (EMA). This is essential for stochastic 
    rendering techniques where each frame has noise that averages out over time.
    
    ==== WHY TEMPORAL ACCUMULATION? ====
    
    The cascade shader uses random ray jittering (stochastic mode) to reduce
    visible banding artifacts. However, each individual frame is noisy because
    rays only sample a subset of directions. By blending many frames together,
    the noise averages out and we get a smooth, converged result.
    
    ==== EXPONENTIAL MOVING AVERAGE ====
    
    Formula: result = lerp(history, current, blend)
           = history * (1 - blend) + current * blend
    
    - blend = 1.0: Only use current frame (instant response, maximum noise)
    - blend = 0.1: 10% new, 90% old (smooth, some lag)
    - blend = 0.01: Very smooth but slow to respond to changes
    
    A good default is 0.05-0.1 for static scenes, higher for dynamic.
    
    Author: Nguyen Phi Hung
==============================================================================*/

// Output: Accumulated result written here
[[vk::binding(0, 0)]] RWTexture2D<float4> Result : register(u0);

// Current: This frame's cascade output (level 0 - the final radiance)
[[vk::binding(1, 0)]] Texture2D<float4> Current : register(t0);

// History: Previous frame's accumulated result (used as blend source)
[[vk::binding(2, 0)]] Texture2D<float4> History : register(t1);

// Blend factor passed from CPU - can be adjusted in real-time via ImGui
struct PushConstants {
   float blend;  // 0.0 = keep history, 1.0 = use only current frame
};
[[vk::push_constant]] PushConstants pc;

[numthreads(16, 16, 1)]
void main(uint3 DTid : SV_DispatchThreadID) {
    // Sample current and previous frame colors
    float3 cur = Current[DTid.xy].rgb;
    float3 hist = History[DTid.xy].rgb;
    
    // Exponential moving average: gradual blend toward current frame
    // This smooths out stochastic noise while preserving responsiveness
    float3 res = lerp(hist, cur, pc.blend);
    
    Result[DTid.xy] = float4(res, 1.0);
}
