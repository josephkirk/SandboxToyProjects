RWTexture2D<float> Input : register(u0);
RWTexture2D<float> Output : register(u1);

struct PushConstants {
    int mouseX;
    int mouseY;
    int mouseLeft;
    int mouseRight;
    uint frame;
};

[[vk::push_constant]] PushConstants pc;

[numthreads(16, 16, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    uint2 size;
    Input.GetDimensions(size.x, size.y);
    
    if (id.x >= size.x || id.y >= size.y) return;

    // Mouse input
    if (pc.mouseLeft || pc.mouseRight) {
        int distSq = (int(id.x) - pc.mouseX) * (int(id.x) - pc.mouseX) + (int(id.y) - pc.mouseY) * (int(id.y) - pc.mouseY);
        if (distSq < 100) {
            Output[id.xy] = pc.mouseLeft ? 1.0 : 0.5;
            return;
        }
    }

    float current = Input[id.xy];
    
    if (current < 0.1) { // Empty cell
        // Check if sand is above us (Y-1 means above in screen coords)
        if (id.y > 0) {
            float above = Input[uint2(id.x, id.y - 1)];
            if (above > 0.9) { 
                Output[id.xy] = 1.0; // Sand falls into this cell
                return; 
            }
            
            // Diagonal fall
            int offset = (pc.frame % 2 == 0) ? 1 : -1;
            int tx = int(id.x) - offset;
            if (tx >= 0 && tx < (int)size.x) {
                float aboveDiag = Input[uint2(tx, id.y - 1)];
                if (aboveDiag > 0.9) {
                    if (Input[uint2(tx, id.y)] > 0.1) {
                         Output[id.xy] = 1.0;
                         return;
                    }
                }
            }
        }
        Output[id.xy] = 0.0;
    } else if (current > 0.9) { // Sand cell
        // Check if we can fall down (Y+1 means below in screen coords)
        if (id.y < size.y - 1) {
            float below = Input[uint2(id.x, id.y + 1)];
            if (below < 0.1) { 
                Output[id.xy] = 0.0; // Sand leaves this cell
                return; 
            }
            
            // Diagonal fall
            int offset = (pc.frame % 2 == 0) ? 1 : -1;
            int tx = int(id.x) + offset;
            if (tx >= 0 && tx < (int)size.x) {
                float belowDiag = Input[uint2(tx, id.y + 1)];
                if (belowDiag < 0.1) { 
                     Output[id.xy] = 0.0;
                     return; 
                }
            }
        }
        Output[id.xy] = 1.0; // Stay as sand
    } else if (current > 0.4) { // Wall
        Output[id.xy] = 0.5;
    } else {
        Output[id.xy] = 0.0;
    }
}
