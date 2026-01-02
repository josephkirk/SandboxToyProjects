[[vk::binding(0, 0)]] RWTexture2D<float4> Result : register(u0);
[[vk::binding(1, 0)]] Texture2D<float4> Current : register(t0);
[[vk::binding(2, 0)]] Texture2D<float4> History : register(t1);

struct PushConstants {
   float blend;
};
[[vk::push_constant]] PushConstants pc;

[numthreads(16, 16, 1)]
void main(uint3 DTid : SV_DispatchThreadID) {
    float3 cur = Current[DTid.xy].rgb;
    float3 hist = History[DTid.xy].rgb;
    // Simple exponential moving average
    float3 res = lerp(hist, cur, pc.blend);
    Result[DTid.xy] = float4(res, 1.0);
}
