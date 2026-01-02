#define PI 3.14159265
#define BASE_START 2.0

struct Light {
    float2 pos;
    float radius;
    float padding;  // Matches Zig padding before color
    float3 color;
    float padding2; // Matches Zig padding2
};

struct Obstacle {
    float2 pos;
    float radius;
    float padding;  // Matches Zig padding before color
    float3 color;
    float padding2; // Matches Zig padding2
};

struct PushConstants {
    int level;
    int maxLevel;
    int baseRays;
    int lightCount;
    int obstacleCount;
    float time;
    int showIntervals;
    int stochasticMode;   // 0 = deterministic dither, 1 = stochastic noise
    float2 resolution;    // Screen resolution
};

[[vk::push_constant]] PushConstants pc;

[[vk::binding(0, 0)]] RWTexture2D<float4> Output : register(u0);
[[vk::binding(1, 0)]] Texture2D<float4> UpperCascade : register(t0);
[[vk::binding(2, 0)]] Texture2D<float4> History : register(t1);
[[vk::binding(3, 0)]] StructuredBuffer<Light> LightBuffer : register(t2);
[[vk::binding(4, 0)]] StructuredBuffer<Obstacle> ObstacleBuffer : register(t3);
[[vk::binding(5, 0)]] SamplerState LinearSampler : register(s0);

// --- SDF ---
float sdCircle(float2 p, float r) { return length(p) - r; }
float sdBox(float2 p, float2 b) {
    float2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

float map(float2 p) {
    // Screen is 0..res. 
    // Box SDF inverted for room boundaries? 
    // The JS uses center-based coords for box.
    float2 center = pc.resolution * 0.5;
    float d = -sdBox(p - center, center - 2.0);

    for(int i = 0; i < pc.obstacleCount; i++) {
        Obstacle obs = ObstacleBuffer[i];
        d = min(d, sdCircle(p - obs.pos, obs.radius));
    }
    return d;
}

// --- LIGHTING ---
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

// --- PBR MATH (Simplified) ---
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
float GeometrySchlickGGX(float NdotV, float roughness) {
    float r = (roughness + 1.0);
    float k = (r*r) / 8.0;
    float num = NdotV;
    float denom = NdotV * (1.0 - k) + k;
    return num / max(denom, 0.0001);
}
float GeometrySmith(float3 N, float3 V, float3 L, float roughness) {
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    float ggx2 = GeometrySchlickGGX(NdotV, roughness);
    float ggx1 = GeometrySchlickGGX(NdotL, roughness);
    return ggx1 * ggx2;
}
float3 FresnelSchlick(float cosTheta, float3 F0) {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

[numthreads(16, 16, 1)]
void main(uint3 DTid : SV_DispatchThreadID) {
    int2 dim;
    Output.GetDimensions(dim.x, dim.y);
    if (DTid.x >= dim.x || DTid.y >= dim.y) return;

    float2 uv = (float2(DTid.xy) + 0.5) / float2(dim.x, dim.y);
    float2 worldPos = uv * pc.resolution;
    
    // Direct lighting with wall occlusion (Level 0 only)
    // Level 0 computes direct lighting, higher levels compute GI bounces
    if (pc.level == 0) {
        float3 radiance = float3(0.0, 0.0, 0.0);
        
        for (int l = 0; l < pc.lightCount; l++) {
            Light light = LightBuffer[l];
            float2 toLight = light.pos - worldPos;
            float dist = length(toLight);
            float2 dir = toLight / max(dist, 0.001);
            
            // Ray march to check for wall occlusion
            bool occluded = false;
            float t = 0.0;
            for (int step = 0; step < 32; step++) {
                float2 p = worldPos + dir * t;
                
                // Check against all obstacles
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
            
            if (!occluded) {
                // Faster falloff for smaller lights
                float falloff = 1.0 / (1.0 + dist * dist * 0.001);
                radiance += light.color * falloff;
            }
        }
        
        // Merge Upper Cascade GI into level 0 output
        // This brings the indirect lighting from higher cascade levels into the final image
        float3 gi = UpperCascade.SampleLevel(LinearSampler, uv, 0).rgb;
        radiance += gi;
        
        Output[DTid.xy] = float4(radiance, 1.0);
        return;
    }
    
    // Calculate Intervals for this Cascade Level
    // Level 0: 0 -> BASE_START
    // Level 1: BASE_START -> BASE_START * 4
    // Level N: BASE_START*4^(N-1) -> BASE_START*4^N
    
    float rangeStart = (pc.level == 0) ? 0.0 : BASE_START * pow(4.0, float(pc.level) - 1.0);
    // Fix for level 1 gap logic in reference (it ensures contiguity)
    // if(u_level == 0) rangeStart = 0.0; else if(u_level == 1) rangeStart = BASE_START;
    // The power formula works if BASE_START is 2.0:
    // L0: 0
    // L1: 2 * 4^0 = 2
    // L2: 2 * 4^1 = 8
    
    float rangeEnd = BASE_START * pow(4.0, float(pc.level));
    
    float rayCountF = float(pc.baseRays) * pow(2.0, float(pc.level));
    int rayCount = int(rayCountF);
    
    // Noise for ray angle jitter
    float noise;
    if (pc.stochasticMode != 0) {
        // Stochastic: temporal noise for smooth accumulation
        noise = gold_noise(DTid.xy, pc.time + float(pc.level) * 13.0);
    } else {
        // Deterministic: Bayer-like dither pattern (stable, no accumulation needed)
        float3 magic = float3(0.06711056, 0.00583715, 52.9829189);
        noise = frac(magic.z * frac(dot(float2(DTid.xy), magic.xy)));
    }
    
    float angleStep = 6.28318 / float(rayCount);
    float3 radiance = float3(0.0, 0.0, 0.0);
    
    // --- RAY MARCHING ---
    for(int r = 0; r < 512; r++) {
        if(r >= rayCount) break;
        float angle = (float(r) + noise) * angleStep;
        float2 rd = float2(cos(angle), sin(angle));
        
        float tHit = rayMarchVis(worldPos, rd, rangeEnd);
        if(tHit < rangeStart) continue; 
        float validEnd = min(tHit, rangeEnd);
        
        // 1. Direct Lighting (Analytic)
        for(int l = 0; l < pc.lightCount; l++) {
            Light light = LightBuffer[l];
            float val = integrateLightSegment(worldPos, rd, rangeStart, validEnd, light.pos, light.radius);
            if(val > 0.0) radiance += light.color * val;
        }

        // 2. Indirect Lighting (Bounce from History)
        // Only valid if we hit nothing (or hit something very far) ?
        // Actually reference says: if(tHit < rangeEnd) bounce from history
        if(tHit < rangeEnd) {
            float2 hitPos = worldPos + rd * tHit;
            float2 hitUV = hitPos / pc.resolution; // Normalize to 0..1 for texture sample
            
            if(hitUV.x > 0.0 && hitUV.x < 1.0 && hitUV.y > 0.0 && hitUV.y < 1.0) {
                 // Sample History from PREVIOUS frame
                 // Use LinearSampler
                 float3 bounceColor = History.SampleLevel(LinearSampler, hitUV, 0).rgb;
                 radiance += bounceColor; 
            }
        }
    }
    
    if (rayCount > 0)
        radiance /= float(rayCount);
        
    // Merge Upper Cascade (Bilinear)
    if (pc.level < pc.maxLevel - 1) {
        // Sample at current UV
        // UpperCascade is lower res, so LinearSampler acts as upscale
        radiance += UpperCascade.SampleLevel(LinearSampler, uv, 0).rgb;
    }
    
    // --- WALL MATERIAL & PBR (Only Level 0 - Immediate Hit) ---
    if(pc.level == 0) {
        int hitID = -1;
        for(int i = 0; i < pc.obstacleCount; i++) {
             Obstacle obs = ObstacleBuffer[i];
             float d = length(worldPos - obs.pos) - obs.radius;
             if(d < 0.0) {
                 hitID = i;
                 break; 
             }
        }
        
        if(hitID != -1) {
            Obstacle obs = ObstacleBuffer[hitID];
            float3 albedo = obs.color;
            
            float roughness = 0.5;
            float metallic = 0.0;
            float3 F0 = float3(0.04, 0.04, 0.04); 
            F0 = lerp(F0, albedo, metallic);

            float2 centerDir = normalize(worldPos - obs.pos);
            float3 N = normalize(float3(centerDir, 0.5));
            float3 V = float3(0.0, 0.0, 1.0); 

            float3 Lo = float3(0.0, 0.0, 0.0);

            for(int l = 0; l < pc.lightCount; l++) {
                Light light = LightBuffer[l];
                float3 lPos = float3(light.pos, 50.0);
                float3 pixelPos3D = float3(worldPos, 0.0);
                
                float3 L_vec = lPos - pixelPos3D;
                float distance = length(L_vec);
                float3 L = normalize(L_vec);
                float3 H = normalize(V + L);

                float attenuation = 1.0 / (1.0 + distance * distance * 0.0005);
                float3 radianceIn = light.color * 2.0 * attenuation;

                float NDF = DistributionGGX(N, H, roughness);
                float G = GeometrySmith(N, V, L, roughness);
                float3 F = FresnelSchlick(max(dot(H, V), 0.0), F0);

                float3 numerator = NDF * G * F;
                float denominator = 4.0 * max(dot(N, V), 0.0) * max(dot(N, L), 0.0) + 0.0001;
                float3 specular = numerator / denominator;

                float3 kS = F;
                float3 kD = float3(1.0, 1.0, 1.0) - kS;
                kD *= 1.0 - metallic;

                float NdotL = max(dot(N, L), 0.0);
                Lo += (kD * albedo / PI + specular) * radianceIn * NdotL;
            }
            
            radiance = Lo + float3(0.03, 0.03, 0.03) * albedo; 
        }
    }
    
    // Debug Intervals
    if(pc.showIntervals && pc.lightCount > 0) {
         float2 lPos = LightBuffer[0].pos;
         float d = length(worldPos - lPos);
         if(d > rangeStart && d < rangeEnd) radiance += float3(0.1, 0.0, 0.0);
    }
    
    Output[DTid.xy] = float4(radiance, 1.0);
}
