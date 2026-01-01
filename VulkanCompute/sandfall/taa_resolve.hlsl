// TAA Resolve Compute Shader
// Blends current frame with history buffer using neighborhood clamping to prevent ghosting.
// Includes dithering to reduce banding artifacts.

RWTexture2D<float4> CurrentFrame : register(u0);  // Input: Current frame from sand_display
RWTexture2D<float4> HistoryBuffer : register(u1); // Input/Output: History from previous frame
RWTexture2D<float4> OutputFrame : register(u2);   // Output: Final resolved image

// Blend factor: lower = more temporal smoothing, higher = more responsive
static const float BLEND_FACTOR = 0.15; // Increased slightly for faster convergence

// Hash function for dithering (returns 0-1)
float Hash(uint2 coord, uint frame) {
    uint seed = coord.x + coord.y * 1024 + frame * 1048576;
    seed = (seed ^ 61) ^ (seed >> 16);
    seed *= 9;
    seed = seed ^ (seed >> 4);
    seed *= 0x27d4eb2d;
    seed = seed ^ (seed >> 15);
    return float(seed) / 4294967295.0;
}

// Sample the 3x3 neighborhood and compute min/max for clamping
void GetNeighborhoodMinMax(uint2 coord, uint2 size, out float3 minColor, out float3 maxColor) {
    minColor = float3(1.0, 1.0, 1.0);
    maxColor = float3(0.0, 0.0, 0.0);
    
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            int2 sampleCoord = int2(coord) + int2(x, y);
            sampleCoord = clamp(sampleCoord, int2(0, 0), int2(size) - 1);
            
            float3 sample = CurrentFrame[sampleCoord].rgb;
            minColor = min(minColor, sample);
            maxColor = max(maxColor, sample);
        }
    }
}

// Convert sRGB to linear for better blending
float3 SRGBToLinear(float3 srgb) {
    return pow(max(srgb, 0.0), 2.2);
}

// Convert linear back to sRGB
float3 LinearToSRGB(float3 linColor) {
    return pow(max(linColor, 0.0), 1.0 / 2.2);
}

[numthreads(16, 16, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    uint2 size;
    CurrentFrame.GetDimensions(size.x, size.y);
    
    if (id.x >= size.x || id.y >= size.y) return;
    
    uint2 coord = id.xy;
    
    // Sample current frame and history
    float3 current = CurrentFrame[coord].rgb;
    float3 history = HistoryBuffer[coord].rgb;
    
    // Neighborhood clamping to reduce ghosting
    float3 minColor, maxColor;
    GetNeighborhoodMinMax(coord, size, minColor, maxColor);
    
    // Expand the clamping range slightly to reduce over-aggressive clamping
    float3 colorRange = maxColor - minColor;
    minColor -= colorRange * 0.1;
    maxColor += colorRange * 0.1;
    
    history = clamp(history, minColor, maxColor);
    
    // Blend in linear space for better quality
    float3 currentLinear = SRGBToLinear(current);
    float3 historyLinear = SRGBToLinear(history);
    
    float3 resolvedLinear = lerp(historyLinear, currentLinear, BLEND_FACTOR);
    
    // Convert back to sRGB
    float3 resolved = LinearToSRGB(resolvedLinear);
    
    // Add dithering to break up banding (1/256 noise amplitude)
    float dither = (Hash(coord, 0) - 0.5) / 128.0;
    resolved += dither;
    
    // Clamp to valid range
    resolved = saturate(resolved);
    
    // Write to both output and history for next frame
    OutputFrame[coord] = float4(resolved, 1.0);
    HistoryBuffer[coord] = float4(resolved, 1.0);
}
