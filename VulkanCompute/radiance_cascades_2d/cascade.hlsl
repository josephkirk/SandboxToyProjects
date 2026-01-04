/*==============================================================================
    RADIANCE CASCADES 2D - PROBE-BASED IMPLEMENTATION
    ============================================================================
    
    Refactored to match the efficient Probe-Based Radiance Cascades algorithm.
    
    KEY DIFFERENCES FROM NAIVE:
    1.  Fixed Ray Count: We always cast BASE_RAYS (4) rays per pixel, 
        regardless of cascade level.
    2.  Probe Addressing (Atlas): Higher levels use "Probes" to distribute 
        rays spatially. We use the texture as an Atlas where adjacent 
        pixels represent the same spatial location but different ray directions.
    3.  Bilinear Merging: Correctly interpolates radiance from the coarser 
        upper cascade.
    4.  Interval Logic: Proper geometric progression for ray lengths.
    
    Data Layout:
    - Level > 0 (Intermediate): Output Texture Layer 0 stores Radiance (RGB) + Alpha (A).
      The texture is effectively an Atlas of directions.
    - Level 0 (Final): Output Texture Layers 0,1,2 store SH (L0, L1x, L1y).
      This preserves compatibility with the Accumulation/Display passes.
      
    Author: Nguyen Phi Hung (Refactored)
==============================================================================*/

#define PI 3.14159265
#define TAU 6.28318530718

// CONSTANTS matching the reference customization
#define BASE_RAYS 4
#define CASCADE_INTERVAL 1.0
#define RAY_INTERVAL 1.0

/*------------------------------------------------------------------------------
    DATA STRUCTURES
------------------------------------------------------------------------------*/

struct Light {
    float2 pos;
    float radius;
    float falloff;
    float3 color;
    float padding2;
};

struct Obstacle {
    float2 pos;
    float radius;
    float padding;
    float3 color;
    float padding2;
};

struct PushConstants {
    int level;
    int maxLevel;
    int baseRays;        // Should be 4
    int lightCount;
    int obstacleCount;
    float time;
    int showIntervals;   // Debug: visualize cascade intervals
    int stochasticMode;
    float2 resolution;
    float blendRadius;
    float padding1;
};

[[vk::push_constant]] PushConstants pc;

/*------------------------------------------------------------------------------
    RESOURCES
------------------------------------------------------------------------------*/

[[vk::binding(0, 0)]] RWTexture2DArray<float4> OutputSH;
[[vk::binding(1, 0)]] Texture2DArray<float4> UpperSH;
[[vk::binding(2, 0)]] Texture2DArray<float4> HistorySH;
[[vk::binding(3, 0)]] StructuredBuffer<Light> LightBuffer;
[[vk::binding(4, 0)]] StructuredBuffer<Obstacle> ObstacleBuffer;
[[vk::binding(5, 0)]] SamplerState LinearSampler;
[[vk::binding(6, 0)]] Texture2D<float2> JFABuffer;

/*------------------------------------------------------------------------------
    HELPERS
------------------------------------------------------------------------------*/

void encodeSH(float angle, float3 radiance, inout float3 L0, inout float3 L1x, inout float3 L1y) {
    L0 += radiance;
    L1x += radiance * cos(angle);
    L1y += radiance * sin(angle);
}

float3 decodeSH(float angle, float3 L0, float3 L1x, float3 L1y) {
    float c = cos(angle);
    float s = sin(angle);
    return max(0.0, L0 + 2.0 * (L1x * c + L1y * s));
}

float dirToAngle(float2 dir) {
    return atan2(dir.y, dir.x);
}

float integrateLightSegment(float2 ro, float2 rd, float tMin, float tMax, float2 lightPos, float radius) {
    float2 L = lightPos - ro;
    float tClosest = dot(L, rd);
    float2 pClosest = ro + rd * tClosest;
    float distSq = dot(pClosest - lightPos, pClosest - lightPos);
    
    if(distSq > radius * radius) return 0.0;
    
    float halfChord = sqrt(radius * radius - distSq);
    float start = max(tMin, tClosest - halfChord);
    float end = min(tMax, tClosest + halfChord);
    
    if(start >= end) return 0.0;
    float d = length(L);
    return (end - start) / max(1.0, d/radius); 
}

/*------------------------------------------------------------------------------
    SDF FUNCTIONS
------------------------------------------------------------------------------*/

float sdCircle(float2 p, float r) { return length(p) - r; }
float sdBox(float2 p, float2 b) {
    float2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}
float smin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

float map(float2 p) {
    float2 center = pc.resolution * 0.5;
    float d = -sdBox(p - center, center - 2.0);
    for(int i = 0; i < pc.obstacleCount; i++) {
        Obstacle obs = ObstacleBuffer[i];
        d = smin(d, sdCircle(p - obs.pos, obs.radius), pc.blendRadius);
    }
    return d;
}

float rayMarchVis(float2 ro, float2 rd, float maxDist) {
    float t = 0.0;
    for(int i = 0; i < 32; i++) { 
        float2 p = ro + rd * t;
        float d = map(p);
        if(d < 0.1) return t;
        t += d;
        if(t >= maxDist) return maxDist; 
    }
    return maxDist;
}

float gold_noise(float2 xy, float seed){
   return frac(tan(distance(xy*1.61803398874989484820459, xy)*seed)*xy.x);
}

/*------------------------------------------------------------------------------
    BILINEAR FIX & MERGE
------------------------------------------------------------------------------*/

// Sample the Upper Cascade (which is an Atlas)
// We need to find the correct 4 probes that surround the current position (in probe space)
// and interpolate their results.
// Note: Upper Cascade Logic
// spacing = 2^(level+1)
// size = resolution / spacing
// We are at 'level'. Merge from 'level+1'.

// Safe modulo for positive/negative consistency
float my_mod(float x, float y) {
    return x - y * floor(x/y);
}

float4 merge(float4 currentRadiance, float index, float2 position, float spacingBase, float cascadeIndex) {
    if (cascadeIndex >= float(pc.maxLevel) - 1.0) {
        return currentRadiance;
    }
    
    if (currentRadiance.a >= 1.0) {
        return currentRadiance;
    }

    // Upper Cascade Parameters
    // spacingBase is 4 (baseRays) or 2 (sqrtBase)?
    // Passed as sqrtBase (2.0 typically).
    
    float upperSpacing = pow(spacingBase, cascadeIndex + 1.0);
    float2 cascadeExtent = pc.resolution;
    float2 upperSize = floor(cascadeExtent / upperSpacing);
    
    // Calculate upper atlas position
    // Matches reference: vec2(mod(index, upperSpacing), floor(index / upperSpacing)) * upperSize
    float x_offset = my_mod(index, upperSpacing);
    float y_offset = floor(index / upperSpacing);
    
    float2 upperPosition = float2(x_offset, y_offset) * upperSize;

    // Offset relates to spatial position within the probe
    // position is probeRelativePosition (from main)
    float2 offset = (position + 0.5) / spacingBase; 
    
    // Bilinear sampling logic
    float2 clamped = clamp(offset, float2(0.5, 0.5), upperSize - 0.5);
    float2 samplePosition = (upperPosition + clamped);
    
    // Sample Upper Cascade
    float2 uv = samplePosition / cascadeExtent;
    float4 upperSample = UpperSH.SampleLevel(LinearSampler, float3(uv, 0), 0);
    
    return float4(
        currentRadiance.rgb + upperSample.rgb,
        currentRadiance.a + upperSample.a // Add visibility/alpha
    );
}

/*------------------------------------------------------------------------------
    MAIN COMPUTE SHADER
------------------------------------------------------------------------------*/

[numthreads(16, 16, 1)]
void main(uint3 DTid : SV_DispatchThreadID) {
    uint dim_w, dim_h, dim_layers;
    OutputSH.GetDimensions(dim_w, dim_h, dim_layers);
    if (DTid.x >= dim_w || DTid.y >= dim_h) return;

    float2 coord = float2(DTid.xy);
    float2 resolution = pc.resolution;
    float cascadeIndex = float(pc.level);
    
    // Geometric Progression Parameters
    float base = float(BASE_RAYS); // 4.0
    float sqrtBase = sqrt(base);   // 2.0
    
    // Calculate Ray Count and Spacing for this level
    // In Probe-Based, we don't scale ray count PER PIXEL, but the logical ray count scaling exists
    // spacing = 2^level
    float spacing = pow(sqrtBase, cascadeIndex);
    
    // Grid sizing
    float2 size = floor(resolution / spacing);
    
    // Addressing the Probe Atlas
    // probeRelativePosition: Where we are spatially (wrapping every 'size' pixels)
    // This effectively tiles the screen into 'spacing' x 'spacing' grids
    float2 probeRelativePosition = fmod(coord, size);
    
    // rayPos: Which ray subset (probe index) are we calculating?
    // 0..(spacing-1)
    float2 rayPos = floor(coord / size); 
    
    // Determine the base index of rays for this pixel
    // Each pixel computes 'base' (4) rays starting from baseIndex
    // The 'index' in the loop will range [baseIndex, baseIndex + 4)
    float baseIndex = (rayPos.x + (spacing * rayPos.y)) * base;
    
    // Intervals
    // Reference hack for smoothing? "modifierHack"
    // We'll stick to basic geometric interval
    float intervalStart = (cascadeIndex == 0.0) ? CASCADE_INTERVAL : (RAY_INTERVAL * CASCADE_INTERVAL * pow(base, cascadeIndex - 1.0));
    // Usually standard RC: 
    // L0: 0..1 (if base interval 1)
    // L1: 1..4 (len 3? 4x?)
    // Reference:
    // start = interval (1.0) for L0.
    // start = interval * 4^(L-1) for L>0.
    // len = interval * 4^L
    // So L0: start 1? No.
    // Reference code:
    // float start = cascadeIndex == 0.0 ? cascadeInterval : modifiedInterval; // modified = interval * 4^(L-1)? No ray*casc...
    // Let's simpler logic:
    // Level 0: 0.0 .. BASE_START
    // Level 1: BASE_START .. BASE_START*4
    
    // Re-verify naive implementation logic:
    // L0: 0 .. 2.0
    // L1: 2.0 .. 8.0
    
    float rangeStart, rangeEnd;
    if (cascadeIndex == 0.0) {
        rangeStart = 0.0;
        rangeEnd = 2.0; // Base Start
    } else {
        rangeStart = 2.0 * pow(4.0, cascadeIndex - 1.0);
        rangeEnd = 2.0 * pow(4.0, cascadeIndex);
    }
    
    // Ray Angles
    float totalRaysInLevel = base * pow(base, cascadeIndex); // 4 * 4^L
    // Wait, reference says `rayCount = pow(base, cascadeIndex + 1.0)`.
    // L0: 4^1 = 4.
    // L1: 4^2 = 16.
    // L2: 4^3 = 64.
    // Matches.
    float angleStep = TAU / totalRaysInLevel;
    
    float noise = 0.0;
    if (pc.stochasticMode != 0) {
        noise = gold_noise(coord, pc.time + cascadeIndex * 13.0) / (totalRaysInLevel * 0.5); 
        // Noise scaled by ray count to jitter within the conceptual "pixel cone"
        // Reference: rand(..) / (rayCount * 0.5)
    }

    // Accumulators
    float4 totalRadiance = float4(0.0, 0.0, 0.0, 0.0);
    
    // SH Accumulators (Only used for Level 0)
    float3 shL0 = float3(0.0, 0.0, 0.0);
    float3 shL1x = float3(0.0, 0.0, 0.0);
    float3 shL1y = float3(0.0, 0.0, 0.0);
    
    float2 worldPos = probeRelativePosition * spacing; 
    // Wait. probeRelativePosition is 0..size.
    // size = res/spacing.
    // So spatial position reconstruction:
    // worldPos should be the center of the probe region? 
    // Reference: `vec2 probeCenter = (probeRelativePosition + 0.5) * basePixelsBetweenProbes * spacing;`
    // basePixelsBetweenProbes = 1 (usually).
    // so `(probeRelativePosition + 0.5) * spacing`.
    
    // But `probeRelativePosition` is just `coord % size`.
    // Example L1 (spacing 2). Res 800. Size 400.
    // Pixel 0 (TopLeft). Coord 0. Rel 0. RayPos 0.
    // Pixel 400 (Middle). Coord 400. Rel 0. RayPos 1.
    // They both map to 'Rel 0'.
    // Rel 0 corresponds to World Pos ?
    // If Spacing is 2, it means we have effectively 400x400 spatial probes.
    // They cover the screen 0..800.
    // So Rel 0 -> World 0? Rel 1 -> World 2?
    // Yes. `worldPos = Rel * spacing`.
    // + offsets for centering.
    
    // Correct world position for raymarching:
    // We use the pixel center of the "virtual probe".
    float2 probeCenter = (probeRelativePosition + 0.5) * spacing;
    
    // Iterate BASE_RAYS (4)
    for (int i = 0; i < BASE_RAYS; i++) {
        float index = baseIndex + float(i);
        float angle = (index + 0.5) * angleStep + noise;
        float2 rd = float2(cos(angle), sin(angle));
        
        // Raymarch
        float tHit = rayMarchVis(probeCenter, rd, rangeEnd);

        // Calculate Radiance for this ray
        float3 rayColor = float3(0.0, 0.0, 0.0);
        float alpha = 0.0;
        
        // 1. Direct Light (Analytic) - Only if within range
        // Note: Naive logic checked `tHit < rangeStart` continue.
        // We should do similar.
        
        if (tHit >= rangeStart) {
            float validEnd = min(tHit, rangeEnd);
            
            // Check occlusion/lights
            for(int l = 0; l < pc.lightCount; l++) {
                 Light light = LightBuffer[l];
                 
                 // SRGB Correction: Light color is likely generic, assume Linear or convert?
                 // Reference usually defines colors in script.
                 // We will assume `light.color` is Linear for calculation.
                 // (Or convert if we suspect it's sRGB).
                 // User inputs colors 0..1. Assume sRGB.
                 float3 linearLightColor = pow(light.color, 2.2);
                 
                 float val = integrateLightSegment(probeCenter, rd, rangeStart, validEnd, light.pos, light.radius);
                 if(val > 0.0) {
                     // Falloff
                     float dist = distance(probeCenter, light.pos); // Approx
                     float attenuation = 1.0 / (1.0 + dist * dist * light.falloff * 0.001);
                     rayColor += linearLightColor * val * attenuation;
                 }
            }
            
            // 2. Indirect Hit
            if (tHit < rangeEnd) {
                 float2 hitPos = probeCenter + rd * tHit;
                 // Alpha 1.0 means we hit a wall/obstacle
                 alpha = 1.0;
                 
                 // Wall Albedo
                 float3 wallAlbedo = float3(0.0, 0.0, 0.0);
                 float minDist = 9999.0;
                 for(int ob = 0; ob < pc.obstacleCount; ob++) {
                     Obstacle obs = ObstacleBuffer[ob];
                     float d = length(hitPos - obs.pos) - obs.radius;
                     if(d < minDist) {
                         minDist = d;
                         wallAlbedo = pow(obs.color, 2.2); // SRGB -> Linear
                     }
                 }
                 
                 // Bounce?
                 // Naive: Sample HistorySH.
                 // Problem: HistorySH is correct for Previous Frame.
                 // We can add it.
                 // Note: We are in 'Level 0' logic or 'Level N'?
                 // All levels can sample history for infinite bounce.
                 
                 // Sample History at hit uv
                 float2 hitUV = hitPos / resolution;
                 if(hitUV.x >= 0.0 && hitUV.x <= 1.0 && hitUV.y >= 0.0 && hitUV.y <= 1.0) {
                     float3 histL0 = HistorySH.SampleLevel(LinearSampler, float3(hitUV, 0), 0).rgb;
                     float3 histL1x = HistorySH.SampleLevel(LinearSampler, float3(hitUV, 1), 0).rgb;
                     float3 histL1y = HistorySH.SampleLevel(LinearSampler, float3(hitUV, 2), 0).rgb;
                     // Decode
                     float bounceAngle = dirToAngle(-rd);
                     float3 bounceColor = decodeSH(bounceAngle, histL0, histL1x, histL1y);
                     rayColor += bounceColor * wallAlbedo;
                 }
            }
        }
        
        float4 rayRes = float4(rayColor, alpha);
        
        // Merge with Upper Cascade
        // Pass 'index' (absolute ray index) so merging finds the correct parent ray
        float4 merged = merge(rayRes, index, probeRelativePosition, sqrtBase, cascadeIndex);
        
        // Accumulate Average
        // We are averaging 4 rays.
        totalRadiance += merged * 0.25; // 1/4
        
        // For Level 0: Encode SH
        if (cascadeIndex == 0.0) {
            // Encode the MERGED radiance into SH
            encodeSH(angle, merged.rgb, shL0, shL1x, shL1y);
            // Note: We are encoding 'merged.rgb' which includes light + upper bounce
        }
    }
    
    // OUTPUT
    if (cascadeIndex == 0.0) {
        // Level 0: Write SH
        // Normalize SH by ray count (4)
        shL0 *= 0.25;
        shL1x *= 0.25;
        shL1y *= 0.25;
        
        // Output Linear Radiance (Accumulate shader will handle blending)
        // Note: Accumulate expects SH.
        OutputSH[uint3(DTid.xy, 0)] = float4(shL0, 1.0);
        OutputSH[uint3(DTid.xy, 1)] = float4(shL1x, 0.0);
        OutputSH[uint3(DTid.xy, 2)] = float4(shL1y, 0.0);
    } 
    else {
        // Level > 0: Write packed Atlas Radiance
        // We write 'totalRadiance' (average of 4 rays) to Layer 0.
        // The texture Coord is just DTid.xy.
        // The data is spatially scrambled (Atlas), but consistent for reading.
        OutputSH[uint3(DTid.xy, 0)] = totalRadiance;
        // Layers 1, 2 unused for intermediate cascades
    }
}
