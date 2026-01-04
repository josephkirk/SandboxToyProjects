/*==============================================================================
    RADIANCE CASCADES 2D - CORE CASCADE COMPUTE SHADER
    ============================================================================
    
    This shader implements the Radiance Cascades algorithm for real-time 2D
    global illumination (GI). The key insight is that radiance information at
    different distances can be computed at different resolutions - far away
    light needs less detail than nearby light.
    
    ==== CORE CONCEPTS ====
    
    1. CASCADE LEVELS:
       - Level 0: Direct lighting (closest rays, highest detail)
       - Level 1..N: Indirect lighting / GI bounces (further rays, lower detail)
       - Each level handles a specific distance interval
       
    2. INTERVAL SPACING (Geometric Progression):
       - Level 0: 0 to BASE_START pixels
       - Level 1: BASE_START to BASE_START * 4
       - Level N: BASE_START * 4^(N-1) to BASE_START * 4^N
       
    3. RAY COUNT SCALING:
       - Higher levels use more rays (covers larger area)
       - Rays per level = baseRays * 2^level
       
    4. MERGING:
       - Each level merges with the level above it
       - Creates a complete picture: direct light + GI from all distances
    
    ==== RENDERING FLOW ====
    
    For each pixel:
      1. If level == 0: Compute direct lighting from all light sources
      2. Else: Cast rays in the cascade's distance interval
      3. For each ray hit: Sample the History buffer (previous frame) for bounce
      4. Merge with UpperCascade (coarser level)
      5. Render wall materials with PBR if inside an obstacle
    
    Author: Nguyen Phi Hung
==============================================================================*/

#define PI 3.14159265

// BASE_START: The distance where cascade intervals begin.
// Level 0 covers 0 to BASE_START, Level 1 covers BASE_START to BASE_START*4, etc.
#define BASE_START 2.0

/*------------------------------------------------------------------------------
    DATA STRUCTURES - Must exactly match Zig struct layouts (extern struct)
------------------------------------------------------------------------------*/

struct Light {
    float2 pos;      // Position in screen coordinates
    float radius;    // Light influence radius
    float padding;   // GPU alignment padding
    float3 color;    // RGB color (HDR values allowed)
    float padding2;  // GPU alignment padding
};

struct Obstacle {
    float2 pos;      // Position in screen coordinates  
    float radius;    // Circle radius
    float padding;   // GPU alignment padding
    float3 color;    // Material albedo for PBR rendering
    float padding2;  // GPU alignment padding
};

// Push constants are small amounts of data passed directly to shaders.
// More efficient than uniform buffers for frequently-changing small data.
struct PushConstants {
    int level;           // Current cascade level (0 = base/direct light)
    int maxLevel;        // Total number of cascade levels
    int baseRays;        // Number of rays at level 0 (scales up with level)
    int lightCount;      // Number of active lights
    int obstacleCount;   // Number of active obstacles/walls
    float time;          // Animation time for temporal noise
    int showIntervals;   // Debug: visualize cascade intervals
    int stochasticMode;  // 0 = stable dither, 1 = temporal noise (for accumulation)
    float2 resolution;   // Screen dimensions in pixels
    float blendRadius;   // Smooth union radius for wall SDF (metaball effect)
    float padding1;      // Alignment padding
};

[[vk::push_constant]] PushConstants pc;

/*------------------------------------------------------------------------------
    RESOURCE BINDINGS
    
    In Vulkan, resources are bound to numbered "slots" in descriptor sets.
    [[vk::binding(N, M)]] = binding N in descriptor set M
------------------------------------------------------------------------------*/

// Output: Where we write the computed radiance for this cascade level
[[vk::binding(0, 0)]] RWTexture2D<float4> Output : register(u0);

// UpperCascade: The cascade level above this one (coarser/further range)
// We sample this and add it to our radiance for complete GI
[[vk::binding(1, 0)]] Texture2D<float4> UpperCascade : register(t0);

// History: Previous frame's accumulated radiance (for bounce lighting)
// When a ray hits a wall, we sample what color was there last frame
[[vk::binding(2, 0)]] Texture2D<float4> History : register(t1);

// Light and Obstacle buffers - GPU-side storage
[[vk::binding(3, 0)]] StructuredBuffer<Light> LightBuffer : register(t2);
[[vk::binding(4, 0)]] StructuredBuffer<Obstacle> ObstacleBuffer : register(t3);

// Linear sampler for smooth texture interpolation
[[vk::binding(5, 0)]] SamplerState LinearSampler : register(s0);

/*==============================================================================
    SIGNED DISTANCE FUNCTIONS (SDF)
    
    SDFs return the distance from a point to the nearest surface:
    - Negative = inside the shape
    - Zero = on the surface
    - Positive = outside the shape
    
    SDFs enable efficient ray marching: step by the SDF value each iteration
    (you cannot hit anything sooner than that distance).
==============================================================================*/

// Circle SDF: distance from point to circle edge
float sdCircle(float2 p, float r) { 
    return length(p) - r; 
}

// Box SDF: distance from point to box edge
float sdBox(float2 p, float2 b) {
    float2 d = abs(p) - b;
    // Outside: use Euclidean distance to corner
    // Inside: use Chebyshev distance (max component)
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

// Smooth minimum: blends two SDFs together like metaballs
// k controls blend radius (larger = smoother blending)
// Uses polynomial smoothing for C1 continuity
float smin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

// Scene SDF with smooth blending - used for GI ray marching
// The smin creates organic, blob-like shapes from circles
float map(float2 p) {
    // Room boundary: inverted box SDF (inside is positive)
    float2 center = pc.resolution * 0.5;
    float d = -sdBox(p - center, center - 2.0);

    // Blend all obstacles using smooth minimum
    for(int i = 0; i < pc.obstacleCount; i++) {
        Obstacle obs = ObstacleBuffer[i];
        float obsDist = sdCircle(p - obs.pos, obs.radius);
        d = smin(d, obsDist, pc.blendRadius);
    }
    return d;
}

// Sharp SDF without smooth blending - used for wall material ID lookup
// We need exact per-obstacle detection to know which color to use
float mapSharp(float2 p) {
    float2 center = pc.resolution * 0.5;
    float d = -sdBox(p - center, center - 2.0);
    
    for(int i = 0; i < pc.obstacleCount; i++) {
        Obstacle obs = ObstacleBuffer[i];
        d = min(d, sdCircle(p - obs.pos, obs.radius));
    }
    return d;
}

/*==============================================================================
    LIGHTING UTILITIES
==============================================================================*/

// Analytic light segment integration
// Calculates how much of a ray segment passes through a spherical light
// Returns contribution weighted by distance (closer = brighter)
float integrateLightSegment(float2 ro, float2 rd, float tMin, float tMax, float2 lightPos, float radius) {
    float2 L = lightPos - ro;
    float tClosest = dot(L, rd);  // Project light center onto ray
    float2 pClosest = ro + rd * tClosest;
    float distSq = dot(pClosest - lightPos, pClosest - lightPos);
    
    // Ray misses the light entirely
    if(distSq > radius * radius) return 0.0;
    
    // Calculate chord intersection with light sphere
    float halfChord = sqrt(radius * radius - distSq);
    float start = max(tMin, tClosest - halfChord);
    float end = min(tMax, tClosest + halfChord);
    
    if(start >= end) return 0.0;
    float d = length(L);
    return (end - start) / max(1.0, d/radius); 
}

// Sphere-tracing ray march: find distance to first wall hit
// Returns the distance traveled before hitting something (or maxDist if no hit)
float rayMarchVis(float2 ro, float2 rd, float maxDist) {
    float t = 0.0;
    for(int i = 0; i < 32; i++) { 
        float2 p = ro + rd * t;
        float d = map(p);
        if(d < 0.1) return t;  // Hit threshold
        t += d;                 // Step by SDF distance (safe step)
        if(t >= maxDist) return maxDist; 
    }
    return maxDist;
}

// Gold noise: high-quality pseudo-random based on golden ratio
// Used for stochastic ray jittering in temporal accumulation mode
float gold_noise(float2 xy, float seed){
   return frac(tan(distance(xy*1.61803398874989484820459, xy)*seed)*xy.x);
}

/*==============================================================================
    PBR (Physically Based Rendering) UTILITIES
    
    These implement the Cook-Torrance microfacet BRDF for realistic shading.
    While this is a 2D GI demo, we use PBR for nice-looking wall materials.
==============================================================================*/

// GGX/Trowbridge-Reitz Normal Distribution Function
// Models the statistical distribution of microfacet normals
// Higher roughness = wider highlight, lower roughness = sharper specular
float DistributionGGX(float3 N, float3 H, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float NdotH = max(dot(N, H), 0.0);
    float NdotH2 = NdotH * NdotH;
    float num = a2;
    float denom = (NdotH2 * (a2 - 1.0) + 1.0);
    denom = PI * denom * denom;
    return num / max(denom, 0.0001);
}

// Schlick-GGX Geometry Function (single direction)
// Models self-shadowing of microfacets
float GeometrySchlickGGX(float NdotV, float roughness) {
    float r = (roughness + 1.0);
    float k = (r*r) / 8.0;
    float num = NdotV;
    float denom = NdotV * (1.0 - k) + k;
    return num / max(denom, 0.0001);
}

// Smith Geometry Function: combines view and light direction shadowing
float GeometrySmith(float3 N, float3 V, float3 L, float roughness) {
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    float ggx2 = GeometrySchlickGGX(NdotV, roughness);
    float ggx1 = GeometrySchlickGGX(NdotL, roughness);
    return ggx1 * ggx2;
}

// Fresnel-Schlick: reflectance increases at grazing angles
// F0 = reflectance at normal incidence (0.04 for dielectrics)
float3 FresnelSchlick(float cosTheta, float3 F0) {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

/*==============================================================================
    MAIN COMPUTE SHADER
    
    Dispatched in 16x16 thread groups. Each thread handles one pixel.
    The behavior changes based on cascade level:
    - Level 0: Direct lighting + merge GI from higher levels
    - Level 1+: Ray march for indirect lighting in distance interval
==============================================================================*/

[numthreads(16, 16, 1)]
void main(uint3 DTid : SV_DispatchThreadID) {
    // Bounds check - threads outside image dimensions exit early
    int2 dim;
    Output.GetDimensions(dim.x, dim.y);
    if (DTid.x >= dim.x || DTid.y >= dim.y) return;

    // Calculate UV and world position for this pixel
    float2 uv = (float2(DTid.xy) + 0.5) / float2(dim.x, dim.y);
    float2 worldPos = uv * pc.resolution;
    
    /*==========================================================================
        LEVEL 0: DIRECT LIGHTING PATH
        
        This is the base level - computes lighting directly from light sources.
        Also merges the GI from all higher cascade levels into the final image.
    ==========================================================================*/
    if (pc.level == 0) {
        float3 radiance = float3(0.0, 0.0, 0.0);
        
        // For each light, ray march to check for occlusion (shadows)
        for (int l = 0; l < pc.lightCount; l++) {
            Light light = LightBuffer[l];
            float2 toLight = light.pos - worldPos;
            float dist = length(toLight);
            float2 dir = toLight / max(dist, 0.001);
            
            // Shadow ray: check if any obstacle blocks the light
            bool occluded = false;
            float t = 0.0;
            for (int step = 0; step < 32; step++) {
                float2 p = worldPos + dir * t;
                
                // Find closest obstacle (simplified, not using map() for perf)
                float minDist = 9999.0;
                for (int o = 0; o < pc.obstacleCount; o++) {
                    Obstacle obs = ObstacleBuffer[o];
                    float d = length(p - obs.pos) - obs.radius;
                    minDist = min(minDist, d);
                }
                
                if (minDist < 1.0) {
                    occluded = true;
                    break;
                }
                
                t += max(minDist, 2.0);
                if (t >= dist) break;
            }
            
            // Add light contribution if not occluded
            if (!occluded) {
                float falloff = 1.0 / (1.0 + dist * dist * 0.001);
                radiance += light.color * falloff;
            }
        }
        
        // CRITICAL: Merge global illumination from higher cascade levels
        // This is what makes the walls glow with bounced light
        float3 gi = UpperCascade.SampleLevel(LinearSampler, uv, 0).rgb;
        radiance += gi;
        
        /*----------------------------------------------------------------------
            WALL MATERIAL RENDERING
            
            If this pixel is inside a wall, blend the wall's material color
            into the output. Uses smooth edges for anti-aliasing.
        ----------------------------------------------------------------------*/
        float minDist = 9999.0;
        int hitID = -1;
        for(int i = 0; i < pc.obstacleCount; i++) {
            Obstacle obs = ObstacleBuffer[i];
            float d = length(worldPos - obs.pos) - obs.radius;
            if(d < minDist) {
                minDist = d;
                hitID = i;
            }
        }
        
        // Smooth edge: smoothstep creates anti-aliased wall boundaries
        float edgeWidth = 3.0;
        float edgeFactor = 1.0 - smoothstep(-edgeWidth, edgeWidth, minDist);
        
        if(edgeFactor > 0.0 && hitID != -1) {
            Obstacle obs = ObstacleBuffer[hitID];
            float3 albedo = obs.color;
            
            // Wall shading: 20% base color + 50% GI-tinted ambient
            float3 wallColor = albedo * 0.2 + radiance * albedo * 0.5;
            radiance = lerp(radiance, wallColor, edgeFactor);
        }
        
        Output[DTid.xy] = float4(radiance, 1.0);
        return;
    }
    
    /*==========================================================================
        LEVEL 1+: CASCADE RADIANCE COMPUTATION
        
        For each cascade level, we cast rays within a specific distance range.
        The intervals form a geometric progression that covers progressively
        larger distances with each level.
        
        Config: 4x Branching (Interval length quadruples each level)
        - Level 0: 0 to BASE_START
        - Level 1: BASE_START to BASE_START * 4
        - Level N: BASE_START * 4^(N-1) to BASE_START * 4^N
    ==========================================================================*/
    
    // Calculate distance interval for this cascade level
    float rangeStart = (pc.level == 0) ? 0.0 : BASE_START * pow(4.0, float(pc.level) - 1.0);
    float rangeEnd = BASE_START * pow(4.0, float(pc.level));
    
    // Ray count doubles with each level (more rays for larger coverage area)
    // This matches the 4x area increase (2x radius increase)
    float rayCountF = float(pc.baseRays) * pow(2.0, float(pc.level));
    int rayCount = int(rayCountF);
    
    /*--------------------------------------------------------------------------
        STOCHASTIC VS DETERMINISTIC NOISE
        
        - Stochastic: Uses time-varying noise. Produces noisy frames that 
          smooth out with temporal accumulation. Best for animation.
        - Deterministic: Uses consistent dither pattern. Stable but shows
          visible pattern. Best for static scenes.
    --------------------------------------------------------------------------*/
    float noise;
    if (pc.stochasticMode != 0) {
        noise = gold_noise(DTid.xy, pc.time + float(pc.level) * 13.0);
    } else {
        // Interleaved gradient noise (Bayer-like pattern)
        float3 magic = float3(0.06711056, 0.00583715, 52.9829189);
        noise = frac(magic.z * frac(dot(float2(DTid.xy), magic.xy)));
    }
    
    float angleStep = 6.28318 / float(rayCount);  // 2*PI / rayCount
    float3 radiance = float3(0.0, 0.0, 0.0);
    
    /*--------------------------------------------------------------------------
        RAY MARCHING LOOP
        
        Cast rays in all directions, accumulating light contributions.
        For each ray:
        1. Find where it hits a wall (within our distance interval)
        2. Collect direct light contributions along the ray
        3. Sample bounce light from previous frame at hit point
    --------------------------------------------------------------------------*/
    for(int r = 0; r < 512; r++) {
        if(r >= rayCount) break;
        
        // Calculate ray direction with jitter for anti-aliasing
        float angle = (float(r) + noise) * angleStep;
        float2 rd = float2(cos(angle), sin(angle));
        
        // Ray march to find wall hit
        float tHit = rayMarchVis(worldPos, rd, rangeEnd);
        if(tHit < rangeStart) continue;  // Hit before our interval starts
        float validEnd = min(tHit, rangeEnd);
        
        // 1. Direct Lighting: Check for light sources along this ray segment
        for(int l = 0; l < pc.lightCount; l++) {
            Light light = LightBuffer[l];
            float val = integrateLightSegment(worldPos, rd, rangeStart, validEnd, light.pos, light.radius);
            if(val > 0.0) radiance += light.color * val;
        }

        // 2. Indirect Lighting: Sample bounce from previous frame at hit point
        // This is the "magic" - light bouncing off walls accumulates over frames
        if(tHit < rangeEnd) {
            float2 hitPos = worldPos + rd * tHit;
            float2 hitUV = hitPos / pc.resolution;
            
            if(hitUV.x > 0.0 && hitUV.x < 1.0 && hitUV.y > 0.0 && hitUV.y < 1.0) {
                 float3 bounceColor = History.SampleLevel(LinearSampler, hitUV, 0).rgb;
                 radiance += bounceColor; 
            }
        }
    }
    
    // Average contributions across all rays
    if (rayCount > 0)
        radiance /= float(rayCount);
        
    // Merge with upper cascade (coarser level covers further distances)
    if (pc.level < pc.maxLevel - 1) {
        // NOTE: Strictly speaking, we should multiply the upper cascade radiance
        // by a visibility term (1.0 - opacity of this level).
        // Since we are not tracking detailed visibility in the alpha channel here,
        // we simply add the contributions. This can lead to slight light leaking
        // through walls from background cascades, but for diffuse GI in this
        // demo it acts as a valid simplification (walls are effectively "emissive"
        // with bounced light).
        radiance += UpperCascade.SampleLevel(LinearSampler, uv, 0).rgb;
    }
    
    /*--------------------------------------------------------------------------
        PBR WALL RENDERING (Level 0 only gets here via the cascade path
        when showIntervals is on, but this code path is for higher levels)
    --------------------------------------------------------------------------*/
    if(pc.level == 0) {
        float minDist = 9999.0;
        int hitID = -1;
        
        for(int i = 0; i < pc.obstacleCount; i++) {
            Obstacle obs = ObstacleBuffer[i];
            float d = length(worldPos - obs.pos) - obs.radius;
            if(d < minDist) {
                minDist = d;
                hitID = i;
            }
        }
        
        float edgeWidth = 2.0;
        float edgeFactor = 1.0 - smoothstep(-edgeWidth, edgeWidth, minDist);
        
        if(edgeFactor > 0.0 && hitID != -1) {
            Obstacle obs = ObstacleBuffer[hitID];
            float3 albedo = obs.color;
            
            // Simplified PBR: normal from circle center, view from top
            float roughness = 0.6;
            float2 centerDir = normalize(worldPos - obs.pos);
            float3 N = normalize(float3(centerDir, 0.4));
            float3 V = float3(0.0, 0.0, 1.0);
            
            float3 Lo = float3(0.0, 0.0, 0.0);
            
            for(int l = 0; l < pc.lightCount; l++) {
                Light light = LightBuffer[l];
                float3 lPos = float3(light.pos, 40.0);  // Light elevated in Z
                float3 pixelPos3D = float3(worldPos, 0.0);
                
                float3 L_vec = lPos - pixelPos3D;
                float distance = length(L_vec);
                float3 L = normalize(L_vec);
                float3 H = normalize(V + L);  // Half vector for specular
                
                float attenuation = 1.0 / (1.0 + distance * distance * 0.0003);
                float3 radianceIn = light.color * 2.5 * attenuation;
                
                float NdotL = max(dot(N, L), 0.0);
                float NdotH = max(dot(N, H), 0.0);
                
                // Blinn-Phong-like specular + diffuse
                float spec = pow(NdotH, (1.0 - roughness) * 64.0);
                Lo += (albedo * 0.7 + spec * 0.3) * radianceIn * NdotL;
            }
            
            float3 ambient = radiance * albedo * 0.4;
            float3 baseAmbient = albedo * 0.15;
            float3 wallColor = Lo + ambient + baseAmbient;
            radiance = lerp(radiance, wallColor, edgeFactor);
        }
    }
    
    // Debug: Visualize cascade intervals as red rings around first light
    if(pc.showIntervals && pc.lightCount > 0) {
         float2 lPos = LightBuffer[0].pos;
         float d = length(worldPos - lPos);
         if(d > rangeStart && d < rangeEnd) radiance += float3(0.1, 0.0, 0.0);
    }
    
    Output[DTid.xy] = float4(radiance, 1.0);
}
