[[vk::binding(0, 0)]] RWTexture2D<float4> Result : register(u0);
[[vk::binding(1, 0)]] Texture2D<float4> Input : register(t0);

[numthreads(16, 16, 1)]
void main(uint3 DTid : SV_DispatchThreadID) {
    int2 dim;
    Result.GetDimensions(dim.x, dim.y);
    if(DTid.x >= dim.x || DTid.y >= dim.y) return;

    float3 col = Input[DTid.xy].rgb;
    
    // Reinhard Tone Mapping
    col = col / (col + 1.0);
    
    // Gamma Correction
    col = pow(col, float3(1.0/2.2, 1.0/2.2, 1.0/2.2));
    
    Result[DTid.xy] = float4(col, 1.0);
}
