/*==============================================================================
    JUMP FLOODING ALGORITHM (JFA) - JUMP
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

// Output: Seed Coordinate.
[[vk::binding(0, 0)]] RWTexture2D<float2> Output : register(u0);

// Input: Previous pass
[[vk::binding(1, 0)]] Texture2D<float2> Input : register(t0);

// Obstacles (Unused in Jump but kept for binding layout consistency)
[[vk::binding(2, 0)]] StructuredBuffer<Obstacle> ObstacleBuffer : register(t1);

[numthreads(16, 16, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    if (id.x >= (uint)pc.resolution.x || id.y >= (uint)pc.resolution.y) return;
    
    float2 myPos = float2(id.xy);
    float bestDistSq = 1e38;
    float2 bestSeed = float2(99999.0, 99999.0);
    
    // 3x3 kernel around current pixel
    for(int y = -1; y <= 1; y++) {
        for(int x = -1; x <= 1; x++) {
            int2 offset = int2(x, y) * pc.stepSize;
            int2 sampleCoord = int2(id.xy) + offset;
            
            // Bounds check
            if(sampleCoord.x >= 0 && sampleCoord.x < (int)pc.resolution.x &&
               sampleCoord.y >= 0 && sampleCoord.y < (int)pc.resolution.y) 
            {
                float2 seed = Input.Load(int3(sampleCoord, 0)).xy;
                
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
