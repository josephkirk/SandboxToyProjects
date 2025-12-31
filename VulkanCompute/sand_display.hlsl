struct VSOutput {
    float4 pos : SV_POSITION;
    float2 uv : TEXCOORD0;
};

VSOutput VSMain(uint id : SV_VertexID) {
    VSOutput output;
    output.uv = float2((id << 1) & 2, id & 2);
    output.pos = float4(output.uv * 2.0 - 1.0, 0.0, 1.0);
    // No Y flip - simulation Y=0 is top, which maps to screen top
    return output;
}

RWTexture2D<float> SimMap : register(u0);

float4 PSMain(VSOutput input) : SV_TARGET {
    uint w, h;
    SimMap.GetDimensions(w, h);
    uint2 coord = uint2(input.uv * float2(w, h));
    float val = SimMap[coord];
    
    if (val > 0.9) return float4(0.9, 0.8, 0.3, 1.0); // Sand
    if (val > 0.4) return float4(0.4, 0.4, 0.4, 1.0); // Wall
    return float4(0.05, 0.05, 0.1, 1.0); // Background
}
