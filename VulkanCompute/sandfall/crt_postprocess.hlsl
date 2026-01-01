// CRT Post-Process Effects - Balanced CRT Shader (HLSL)
// Subtle, authentic CRT effects without being too noisy

RWTexture2D<float4> InputImage : register(u0);   // TAA output
RWTexture2D<float4> OutputImage : register(u1);  // Final output

struct PostProcessParams {
    float time;
    float flickerSpeed;
    float scanSpeed;
    float padding;
};

[[vk::push_constant]] PostProcessParams params;

// Pseudo-random hash
float hash(float n) {
    return frac(sin(n) * 43758.5453);
}

float hash2(float2 p) {
    return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

// Smooth noise
float noise(float t) {
    float i = floor(t);
    float f = frac(t);
    f = f * f * (3.0 - 2.0 * f);
    return lerp(hash(i), hash(i + 1.0), f);
}

// Subtle scanline pattern
float scanline(float y, float resolution) {
    float scan = sin(y * resolution * 3.14159);
    return 0.85 + 0.15 * scan * scan; // Subtle darkening
}

// Barrel distortion
float2 barrelDistort(float2 uv, float strength) {
    float2 centered = uv - 0.5;
    float r2 = dot(centered, centered);
    return centered * (1.0 + r2 * strength) + 0.5;
}

[numthreads(16, 16, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    uint2 size;
    InputImage.GetDimensions(size.x, size.y);
    
    if (id.x >= size.x || id.y >= size.y) return;
    
    float2 uv = float2(id.xy) / float2(size);
    float time = params.time;
    
    // =========================================================================
    // 1. SUBTLE BARREL DISTORTION
    // =========================================================================
    float2 distortedUV = barrelDistort(uv, 0.04); // Reduced from 0.08
    
    if (distortedUV.x < 0.0 || distortedUV.x > 1.0 || 
        distortedUV.y < 0.0 || distortedUV.y > 1.0) {
        OutputImage[id.xy] = float4(0.0, 0.0, 0.0, 1.0);
        return;
    }
    
    int2 sampleCoord = int2(distortedUV * float2(size));
    sampleCoord = clamp(sampleCoord, int2(0, 0), int2(size) - 1);
    float4 color = InputImage[sampleCoord];
    
    // =========================================================================
    // 2. SUBTLE SCANLINES
    // =========================================================================
    float scanlineVal = scanline(distortedUV.y, float(size.y));
    color.rgb *= scanlineVal;
    
    // =========================================================================
    // 3. VERY SUBTLE MOVING SCAN BAR (much dimmer)
    // =========================================================================
    float scanBarY = frac(time * params.scanSpeed * 0.08);
    float scanBarDist = abs(distortedUV.y - scanBarY);
    
    // Much subtler - just a slight brightness boost
    float scanBar = smoothstep(0.015, 0.0, scanBarDist) * 0.08;
    color.rgb += color.rgb * scanBar; // Additive based on existing color
    
    // =========================================================================
    // 4. GENTLE FLICKER
    // =========================================================================
    float flicker = 0.98 + noise(time * params.flickerSpeed) * 0.02;
    color.rgb *= flicker;
    
    // =========================================================================
    // 5. VERY SUBTLE GRAIN (barely visible)
    // =========================================================================
    float grain = hash2(distortedUV * float2(size) + float2(time * 100.0, 0.0));
    grain = (grain - 0.5) * 0.015; // Very subtle
    color.rgb += grain;
    
    // =========================================================================
    // 6. SOFT VIGNETTE
    // =========================================================================
    float2 centered = distortedUV - 0.5;
    float vignette = 1.0 - dot(centered, centered) * 0.8;
    vignette = saturate(vignette);
    color.rgb *= vignette;
    
    // =========================================================================
    // 7. SUBTLE RGB PHOSPHOR TINT (not a harsh mask)
    // =========================================================================
    // Just add a slight color variation based on pixel position
    int pixelX = int(id.x) % 3;
    float3 tint = float3(1.0, 1.0, 1.0);
    if (pixelX == 0) tint = float3(1.02, 0.99, 0.99);
    else if (pixelX == 1) tint = float3(0.99, 1.02, 0.99);
    else tint = float3(0.99, 0.99, 1.02);
    color.rgb *= tint;
    
    // =========================================================================
    // 8. EDGE DARKENING
    // =========================================================================
    float2 edgeDist = abs(distortedUV - 0.5) * 2.0;
    float edgeDark = smoothstep(0.85, 1.0, max(edgeDist.x, edgeDist.y));
    color.rgb *= 1.0 - edgeDark * 0.5;
    
    // =========================================================================
    // 9. SLIGHT GREEN PHOSPHOR TINT (CRT characteristic)
    // =========================================================================
    float brightness = dot(color.rgb, float3(0.299, 0.587, 0.114));
    color.g += brightness * 0.02; // Very subtle green boost
    
    // Clamp output
    color.rgb = saturate(color.rgb);
    color.a = 1.0;
    
    OutputImage[id.xy] = color;
}
