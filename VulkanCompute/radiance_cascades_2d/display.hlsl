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

// Output: Final display-ready image
[[vk::binding(0, 0)]] RWTexture2D<float4> Result;

// Input: Accumulated SH history (Layer 0=L0, Layer 1=L1x, Layer 2=L1y)
[[vk::binding(1, 0)]] Texture2DArray<float4> HistorySH;

struct DisplayConstants {
    int debugMode; // 0=None, 1=L1x, 2=L1y, 3=Vector
};
[[vk::push_constant]] DisplayConstants pc;

// Reinhard Tone Mapping
float3 toneMap(float3 color) {
    return color / (color + 1.0);
}

// Gamma Correction
float3 gammaCorrect(float3 color) {
    return pow(color, 1.0 / 2.2);
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadID : SV_DispatchThreadID) {
    uint2 pos = dispatchThreadID.xy;
    
    // Bounds check
    int2 dim;
    Result.GetDimensions(dim.x, dim.y);
    if(pos.x >= (uint)dim.x || pos.y >= (uint)dim.y) return;

    // Read SH coefficients from array layers using Load with int4(x, y, layer, mip)
    float3 L0 = HistorySH.Load(int4(pos, 0, 0)).rgb;
    float3 L1x = HistorySH.Load(int4(pos, 1, 0)).rgb;
    float3 L1y = HistorySH.Load(int4(pos, 2, 0)).rgb;
    
    // DEBUG: Force test values to verify shader is being called
    // Uncomment to test: if Mode 1 is Red, shader switching works
    // L1x = float3(10.0, 0.0, 0.0); // Force Red for L1x debug

    float3 finalColor = float3(0.0, 0.0, 0.0);
    
    // Boost factor for visualizing small directional components
    float visualBoost = 10.0;
    
    // Debug Visualization
    if (pc.debugMode == 1) {
        // L1x Visualization (Red/Cyan) - boosted for visibility
        float l1x = L1x.r * visualBoost;
        l1x = clamp(l1x, -1.0, 1.0);  // Clamp to valid range after boost
        finalColor = float3(0.5 + 0.5 * l1x, 0.5 - 0.5 * abs(l1x), 0.5 - 0.5 * l1x);
    } 
    else if (pc.debugMode == 2) {
        // L1y Visualization (Green/Magenta) - boosted for visibility
        float l1y = L1y.r * visualBoost;
        l1y = clamp(l1y, -1.0, 1.0);
        finalColor = float3(0.5 - 0.5 * l1y, 0.5 + 0.5 * l1y, 0.5 - 0.5 * abs(l1y));
    }
    else if (pc.debugMode == 3) {
        // Vector Field Visualization (Direction -> Hue, Magnitude -> Brightness)
        float l1x = L1x.r;
        float l1y = L1y.r;
        
        // Calculate magnitude and angle
        float mag = sqrt(l1x*l1x + l1y*l1y) * visualBoost;
        float angle = atan2(l1y, l1x);
        
        // Cosine-based hue palette
        float3 dirColor = float3(
            0.5 + 0.5 * cos(angle),
            0.5 + 0.5 * cos(angle - 2.094),
            0.5 + 0.5 * cos(angle + 2.094)
        );
        
        finalColor = dirColor * min(mag, 1.0);
    }
    else {
        // Standard Display (L0)
        float3 mapped = toneMap(L0);
        finalColor = gammaCorrect(mapped);
    }
    
    Result[pos] = float4(finalColor, 1.0);
}
