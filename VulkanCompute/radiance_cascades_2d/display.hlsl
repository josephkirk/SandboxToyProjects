/*==============================================================================
    DISPLAY / POST-PROCESSING SHADER
    ============================================================================
    
    This shader prepares the HDR radiance data for display on a standard
    monitor. It performs two critical operations:
    
    1. TONE MAPPING - Compress HDR values to displayable [0,1] range
    2. GAMMA CORRECTION - Convert linear light to sRGB for correct display
    
    ==== WHY TONE MAPPING? ====
    
    The cascade shader outputs High Dynamic Range (HDR) values - light 
    intensities can exceed 1.0. Monitors can only display values in [0,1],
    so we need to compress the range while preserving visual detail.
    
    Without tone mapping: bright areas clip to white, losing detail.
    With tone mapping: smooth rolloff preserves highlights and shadows.
    
    ==== REINHARD TONE MAPPING ====
    
    Formula: mapped = color / (color + 1.0)
    
    This simple operator:
    - Maps 0 -> 0 (black stays black)
    - Maps 1 -> 0.5 (mid-gray) 
    - Maps infinity -> 1.0 (asymptotic approach to white)
    - Never clips, always produces valid output
    
    ==== GAMMA CORRECTION ====
    
    Human perception of brightness is non-linear - we're more sensitive
    to differences in dark values than bright values. Monitors use sRGB
    color space which is gamma-encoded (~2.2).
    
    Rendering is done in linear space (physically correct), so we must
    convert to sRGB for display: sRGB = pow(linear, 1/2.2)
    
    Without gamma: image appears too dark and contrasty
    With gamma: natural-looking brightness distribution
    
    Author: Nguyen Phi Hung
==============================================================================*/

// Output: Final display-ready image (written directly to swapchain)
[[vk::binding(0, 0)]] RWTexture2D<float4> Result : register(u0);

// Input: Accumulated HDR radiance from temporal accumulation pass
[[vk::binding(1, 0)]] Texture2D<float4> Input : register(t0);

[numthreads(16, 16, 1)]
void main(uint3 DTid : SV_DispatchThreadID) {
    // Bounds check - prevent out-of-bounds writes
    int2 dim;
    Result.GetDimensions(dim.x, dim.y);
    if(DTid.x >= dim.x || DTid.y >= dim.y) return;

    // Sample HDR radiance
    float3 col = Input[DTid.xy].rgb;
    
    // TONE MAPPING: Reinhard operator
    // Compresses infinite HDR range to [0,1] with soft highlights
    col = col / (col + 1.0);
    
    // GAMMA CORRECTION: Linear to sRGB
    // Approximation of sRGB transfer function (exact would use piecewise formula)
    col = pow(col, float3(1.0/2.2, 1.0/2.2, 1.0/2.2));
    
    Result[DTid.xy] = float4(col, 1.0);
}
