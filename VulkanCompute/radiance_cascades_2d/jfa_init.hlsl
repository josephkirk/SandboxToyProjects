/*==============================================================================
    JUMP FLOODING ALGORITHM (JFA) - INIT
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

// Output: Seed Coordinate in RG.
[[vk::binding(0, 0)]] RWTexture2D<float2> Output : register(u0);

// Input: Unused in Init
[[vk::binding(1, 0)]] Texture2D<float2> Input : register(t0);

// Obstacles
[[vk::binding(2, 0)]] StructuredBuffer<Obstacle> ObstacleBuffer : register(t1);

// Helpers
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

[numthreads(16, 16, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    if (id.x >= (uint)pc.resolution.x || id.y >= (uint)pc.resolution.y) return;
    
    float2 pixelPos = float2(id.xy);
    
    if (isSeed(pixelPos)) {
        Output[id.xy] = pixelPos;
    } else {
        Output[id.xy] = float2(99999.0, 99999.0);
    }
}
