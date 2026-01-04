/*==============================================================================
    JUMP FLOODING ALGORITHM (JFA) - 2D SDF GENERATION
    ============================================================================
    
    Generates a Distance Field (SDF) texture in O(1) time per pixel (after O(log N) passes).
    
    Two Kernel Entry Points:
    1. InitCS: Seeds the JFA buffer. Pixels inside obstacles store their own coordinates.
               Others store an invalid large coordinate.
    2. JumpCS: Propagates the closest seed using the JFA step pattern.
    
    Author: Nguyen Phi Hung
==============================================================================*/

struct Obstacle {
    float2 pos;
    float radius;
    float padding;
    float3 color;
    float padding2;
};

struct PushConstants {
    int stepSize;        // Step size for Jump pass
    int obstacleCount;   // For Init pass
    float2 resolution;   // Texture size
};

[[vk::push_constant]] PushConstants pc;

// Output: RGB = encoded data (not used), A = unused? 
// Actually we store Seed Coordinate in RG (float2).
[[vk::binding(0, 0)]] RWTexture2D<float2> Output : register(u0);

// Input: Previous pass result (Ping-Pong)
[[vk::binding(1, 0)]] Texture2D<float2> Input : register(t0);

// Obstacles for Init pass
[[vk::binding(2, 0)]] StructuredBuffer<Obstacle> ObstacleBuffer : register(t1);

// SDF Helpers
float sdCircle(float2 p, float r) { 
    return length(p) - r; 
}

float sdBox(float2 p, float2 b) {
    float2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

// Check if pixel is valid seed (inside obstacle)
bool isSeed(float2 p) {
    // Check Room Boundary (inverted box)
    float2 center = pc.resolution * 0.5;
    float d = -sdBox(p - center, center - 2.0);
    
    if (d < 0.0) return true; // Room walls are seeds

    // Check Obstacles
    for(int i = 0; i < pc.obstacleCount; i++) {
        Obstacle obs = ObstacleBuffer[i];
        if (sdCircle(p - obs.pos, obs.radius) < 0.0) return true;
    }
    return false;
}

/*==============================================================================
    INIT PASS
    - Each pixel checks if it is inside an obstacle.
    - If YES: Store pixel coordinate (Self).
    - If NO: Store huge value (Infinite).
==============================================================================*/
[numthreads(16, 16, 1)]
void InitCS(uint3 id : SV_DispatchThreadID) {
    if (id.x >= (uint)pc.resolution.x || id.y >= (uint)pc.resolution.y) return;
    
    float2 pixelPos = float2(id.xy); // Pixel center logic handled in sampling
    
    if (isSeed(pixelPos)) {
        Output[id.xy] = pixelPos;
    } else {
        Output[id.xy] = float2(99999.0, 99999.0);
    }
}

/*==============================================================================
    JUMP PASS
    - Sample 9 neighbors at offset 'k'.
    - Keep the one whose Seed is closest to current pixel.
==============================================================================*/
[numthreads(16, 16, 1)]
void JumpCS(uint3 id : SV_DispatchThreadID) {
    if (id.x >= (uint)pc.resolution.x || id.y >= (uint)pc.resolution.y) return;
    
    float2 myPos = float2(id.xy);
    float bestDistSq = 1e38;
    float2 bestSeed = float2(99999.0, 99999.0);
    
    // 3x3 kernel around current pixel
    for(int y = -1; y <= 1; y++) {
        for(int x = -1; x <= 1; x++) {
            int2 offset = int2(x, y) * pc.stepSize;
            int2 sampleCoord = int2(id.xy) + offset;
            
            // Bounds check (clamp/wrap handled by texture or logic? Logic prefered for JFA)
            // If out of bounds, ignore? or clamp?
            // Typically clamp, but finding closest valid seed is better.
            if(sampleCoord.x >= 0 && sampleCoord.x < (int)pc.resolution.x &&
               sampleCoord.y >= 0 && sampleCoord.y < (int)pc.resolution.y) 
            {
                float2 seed = Input[sampleCoord];
                
                // If seed is valid
                if(seed.x < 99990.0) {
                    float dSq = dot(seed - myPos, seed - myPos);
                    if(dSq < bestDistSq) {
                        bestDistSq = dSq;
                        bestSeed = seed;
                    }
                }
            }
        }
    }
    
    Output[id.xy] = bestSeed;
}
