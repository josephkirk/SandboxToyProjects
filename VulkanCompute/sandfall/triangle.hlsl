struct VSOutput {
    float4 pos : SV_POSITION;
    float4 color : COLOR;
};

VSOutput VSMain(uint id : SV_VertexID) {
    VSOutput output;
    float2 positions[3] = {
        float2(0.0, -0.5),
        float2(0.5, 0.5),
        float2(-0.5, 0.5)
    };
    float3 colors[3] = {
        float3(1.0, 0.0, 0.0),
        float3(0.0, 1.0, 0.0),
        float3(0.0, 0.0, 1.0)
    };
    output.pos = float4(positions[id], 0.0, 1.0);
    output.color = float4(colors[id], 1.0);
    return output;
}

float4 PSMain(VSOutput input) : SV_TARGET {
    return input.color;
}
