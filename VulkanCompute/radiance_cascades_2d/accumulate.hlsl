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

// Output: Accumulated SH results (Layer 0=L0, Layer 1=L1x, Layer 2=L1y)
[[vk::binding(0, 0)]] RWTexture2DArray<float4> ResultSH;

// Current: This frame's cascade output
[[vk::binding(1, 0)]] Texture2DArray<float4> CurrentSH;

// History: Previous frame's accumulated result  
[[vk::binding(2, 0)]] Texture2DArray<float4> HistorySH;

// Blend factor passed from CPU
struct PushConstants {
   float blend;  // 0.0 = keep history, 1.0 = use only current frame
};
[[vk::push_constant]] PushConstants pc;

[numthreads(16, 16, 1)]
void main(uint3 DTid : SV_DispatchThreadID) {
    // Process all 3 SH layers: L0, L1x, L1y
    for(int layer = 0; layer < 3; layer++) {
        int4 coord = int4(DTid.xy, layer, 0);
        
        float4 cur = CurrentSH.Load(coord);
        float4 hist = HistorySH.Load(coord);
        
        ResultSH[uint3(DTid.xy, layer)] = lerp(hist, cur, pc.blend);
    }
}
